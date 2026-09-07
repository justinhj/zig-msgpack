const std = @import("std");
const extension_registry = @import("extension_registry.zig");
pub const AnyWriter = extension_registry.AnyWriter;

pub const MsgPackTimestamp = struct {
    seconds: i64,
    nanoseconds: u32,
};

pub const TimestampError = error{
    InvalidTimestampLength,
    InvalidTimestampNanoseconds,
    OutOfMemory,
};

pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !*MsgPackTimestamp {
    var seconds: i64 = undefined;
    var nanoseconds: u32 = undefined;

    switch (data.len) {
        4 => {
            const sec = std.mem.readInt(u32, data[0..4], .big);
            seconds = @as(i64, sec);
            nanoseconds = 0;
        },
        8 => {
            const val = std.mem.readInt(u64, data[0..8], .big);
            nanoseconds = @as(u32, @intCast(val >> 34));
            seconds = @as(i64, @intCast(val & 0x00000003_ffffffff));
            if (nanoseconds > 999_999_999) {
                return TimestampError.InvalidTimestampNanoseconds;
            }
        },
        12 => {
            nanoseconds = std.mem.readInt(u32, data[0..4], .big);
            seconds = std.mem.readInt(i64, data[4..12], .big);
            if (nanoseconds > 999_999_999) {
                return TimestampError.InvalidTimestampNanoseconds;
            }
        },
        else => return TimestampError.InvalidTimestampLength,
    }

    const ts = try allocator.create(MsgPackTimestamp);
    ts.* = .{
        .seconds = seconds,
        .nanoseconds = nanoseconds,
    };
    return ts;
}

pub fn toBytes(writer: AnyWriter, ts: *const MsgPackTimestamp) !void {
    if (ts.nanoseconds == 0 and ts.seconds >= 0 and ts.seconds <= std.math.maxInt(u32)) {
        // timestamp 32
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @as(u32, @intCast(ts.seconds)), .big);
        try writer.writeAll(&buf);
    } else if (ts.seconds >= 0 and (ts.seconds >> 34) == 0 and ts.nanoseconds < (1 << 30)) {
        // timestamp 64
        var buf: [8]u8 = undefined;
        const val: u64 = (@as(u64, ts.nanoseconds) << 34) | @as(u64, @intCast(ts.seconds));
        std.mem.writeInt(u64, &buf, val, .big);
        try writer.writeAll(&buf);
    } else {
        // timestamp 96
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], ts.nanoseconds, .big);
        std.mem.writeInt(i64, buf[4..12], ts.seconds, .big);
        try writer.writeAll(&buf);
    }
}

pub fn free(allocator: std.mem.Allocator, ts: *MsgPackTimestamp) void {
    allocator.destroy(ts);
}

pub const handler: extension_registry.ExtensionType =
    extension_registry.extHandlerFor(MsgPackTimestamp, fromBytes, toBytes, free);

const TestBuffer = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    fn write(self: *@This(), bytes: []const u8) anyerror!void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn writer(self: *@This()) AnyWriter {
        return AnyWriter.init(self, write);
    }

    fn getWritten(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }
};

test "MsgPackTimestamp 32 serialize and deserialize" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ts = MsgPackTimestamp{
        .seconds = 1_700_000_000,
        .nanoseconds = 0,
    };

    var tb = TestBuffer{};
    try toBytes(tb.writer(), &ts);

    const written = tb.getWritten();
    try testing.expectEqual(@as(usize, 4), written.len);

    const unpacked = try fromBytes(allocator, written);
    defer free(allocator, unpacked);

    try testing.expectEqual(ts.seconds, unpacked.seconds);
    try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
}

test "MsgPackTimestamp 64 serialize and deserialize" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ts = MsgPackTimestamp{
        .seconds = 1_700_000_000,
        .nanoseconds = 500_000_000,
    };

    var tb = TestBuffer{};
    try toBytes(tb.writer(), &ts);

    const written = tb.getWritten();
    try testing.expectEqual(@as(usize, 8), written.len);

    const unpacked = try fromBytes(allocator, written);
    defer free(allocator, unpacked);

    try testing.expectEqual(ts.seconds, unpacked.seconds);
    try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
}

test "MsgPackTimestamp 96 serialize and deserialize (negative seconds)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ts = MsgPackTimestamp{
        .seconds = -100_000,
        .nanoseconds = 250_000,
    };

    var tb = TestBuffer{};
    try toBytes(tb.writer(), &ts);

    const written = tb.getWritten();
    try testing.expectEqual(@as(usize, 12), written.len);

    const unpacked = try fromBytes(allocator, written);
    defer free(allocator, unpacked);

    try testing.expectEqual(ts.seconds, unpacked.seconds);
    try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
}

test "MsgPackTimestamp 96 serialize and deserialize (large seconds > 34 bits)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ts = MsgPackTimestamp{
        .seconds = (@as(i64, 1) << 35) + 42,
        .nanoseconds = 123_456_789,
    };

    var tb = TestBuffer{};
    try toBytes(tb.writer(), &ts);

    const written = tb.getWritten();
    try testing.expectEqual(@as(usize, 12), written.len);

    const unpacked = try fromBytes(allocator, written);
    defer free(allocator, unpacked);

    try testing.expectEqual(ts.seconds, unpacked.seconds);
    try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
}

test "MsgPackTimestamp invalid inputs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Invalid lengths
    try testing.expectError(TimestampError.InvalidTimestampLength, fromBytes(allocator, &[_]u8{ 1, 2, 3 }));
    try testing.expectError(TimestampError.InvalidTimestampLength, fromBytes(allocator, &[_]u8{ 1, 2, 3, 4, 5 }));

    // Invalid nanoseconds in 64-bit (> 999_999_999)
    var buf64: [8]u8 = undefined;
    const bad_val64: u64 = (@as(u64, 1_000_000_000) << 34) | 100;
    std.mem.writeInt(u64, &buf64, bad_val64, .big);
    try testing.expectError(TimestampError.InvalidTimestampNanoseconds, fromBytes(allocator, &buf64));

    // Invalid nanoseconds in 96-bit (> 999_999_999)
    var buf96: [12]u8 = undefined;
    std.mem.writeInt(u32, buf96[0..4], 1_000_000_000, .big);
    std.mem.writeInt(i64, buf96[4..12], 100, .big);
    try testing.expectError(TimestampError.InvalidTimestampNanoseconds, fromBytes(allocator, &buf96));
}

test "MsgPackTimestamp boundary values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Boundary timestamp 32: max u32
    {
        const ts = MsgPackTimestamp{
            .seconds = std.math.maxInt(u32),
            .nanoseconds = 0,
        };
        var tb = TestBuffer{};
        try toBytes(tb.writer(), &ts);
        try testing.expectEqual(@as(usize, 4), tb.getWritten().len);
        const unpacked = try fromBytes(allocator, tb.getWritten());
        defer free(allocator, unpacked);
        try testing.expectEqual(ts.seconds, unpacked.seconds);
        try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
    }

    // Boundary timestamp 64: max 34-bit seconds and max valid nanoseconds (999_999_999)
    {
        const max_34bit_sec: i64 = (@as(i64, 1) << 34) - 1;
        const ts = MsgPackTimestamp{
            .seconds = max_34bit_sec,
            .nanoseconds = 999_999_999,
        };
        var tb = TestBuffer{};
        try toBytes(tb.writer(), &ts);
        try testing.expectEqual(@as(usize, 8), tb.getWritten().len);
        const unpacked = try fromBytes(allocator, tb.getWritten());
        defer free(allocator, unpacked);
        try testing.expectEqual(ts.seconds, unpacked.seconds);
        try testing.expectEqual(ts.nanoseconds, unpacked.nanoseconds);
    }

    // Boundary timestamp 96: min i64 and max i64
    {
        const min_ts = MsgPackTimestamp{
            .seconds = std.math.minInt(i64),
            .nanoseconds = 999_999_999,
        };
        var tb = TestBuffer{};
        try toBytes(tb.writer(), &min_ts);
        try testing.expectEqual(@as(usize, 12), tb.getWritten().len);
        const unpacked = try fromBytes(allocator, tb.getWritten());
        defer free(allocator, unpacked);
        try testing.expectEqual(min_ts.seconds, unpacked.seconds);
        try testing.expectEqual(min_ts.nanoseconds, unpacked.nanoseconds);
    }
}
