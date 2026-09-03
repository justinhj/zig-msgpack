const std = @import("std");

pub const RingBufferError = error{
    OutOfMemory,
    NoRoomInBuffer,
    InvalidBufferSize,
};

pub const RingBuffer = struct {
    pub const Options = struct {
        max_buffer_size: usize = 1024 * 1024, // 1MB default
    };

    const Self = @This();
    allocator: std.mem.Allocator,
    start: usize,
    end: usize,
    count: usize,
    buffer: []u8,
    buffer_size: usize,

    pub fn init(allocator: std.mem.Allocator, options: Options) RingBufferError!Self {
        if (options.max_buffer_size == 0) {
            return RingBufferError.InvalidBufferSize;
        }
        const buffer = allocator.alloc(u8, options.max_buffer_size) catch return RingBufferError.OutOfMemory;
        return Self{
            .allocator = allocator,
            .start = 0,
            .end = 0,
            .count = 0,
            .buffer = buffer,
            .buffer_size = options.max_buffer_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn get(self: *Self) RingBufferError!u8 {
        if (self.count == 0) {
            return RingBufferError.EndOfBuffer;
        }
        const value = self.buffer[self.start];
        self.start = self.start + 1;
        if (self.start == self.buffer_size) {
            self.start = 0;
        }
        return value;
    }

    pub fn peek(self: *Self) RingBufferError!u8 {
        if (self.count == 0) {
            return RingBufferError.EndOfBuffer;
        }
        return self.buffer[self.start];
    }

    pub fn feed(self: *Self, data: []const u8) RingBufferError!void {
        if (data.len == 0) {
            return;
        }

        if (data.len > self.buffer_size - self.count) {
            return RingBufferError.NoRoomInBuffer;
        }

        // Since this is a ring buffer it will either fit in one go or we 
        // need to fill to the end then do the rest at the beginning
        const remaining_space = self.buffer_size - self.end;
        if (remaining_space < data.len) {
            // Wrap
            const left_over = data.len - remaining_space;
            @memcpy(self.buffer[self.end .. self.end + remaining_space], data[0..remaining_space]);
            @memcpy(self.buffer[0..left_over], data[remaining_space..data.len]);
            self.end = left_over;
        } else {
            // No wrap
            @memcpy(self.buffer[self.end .. self.end + data.len], data[0..data.len]);
            const new_end = self.end + data.len;
            self.end = if (new_end == self.buffer_size) 0 else new_end;
        }
        self.count += data.len;
        return;
    }
};

test "RingBuffer: construction with 128-byte buffer" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    try std.testing.expectEqual(@as(usize, 128), rb.buffer_size);
    try std.testing.expectEqual(@as(usize, 128), rb.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), rb.count);
    try std.testing.expectEqual(@as(usize, 0), rb.start);
    try std.testing.expectEqual(@as(usize, 0), rb.end);
}

test "RingBuffer.feed: empty input (0 bytes)" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    try rb.feed(&.{});

    try std.testing.expectEqual(@as(usize, 0), rb.count);
    try std.testing.expectEqual(@as(usize, 0), rb.end);
}

test "RingBuffer.feed: partial and sequential feeds without wrap" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    // First chunk: 40 bytes
    const chunk1 = "A" ** 40;
    try rb.feed(chunk1);
    try std.testing.expectEqual(@as(usize, 40), rb.count);
    try std.testing.expectEqual(@as(usize, 40), rb.end);
    try std.testing.expectEqualSlices(u8, chunk1, rb.buffer[0..40]);

    // Second chunk: 50 bytes (total 90 bytes)
    const chunk2 = "B" ** 50;
    try rb.feed(chunk2);
    try std.testing.expectEqual(@as(usize, 90), rb.count);
    try std.testing.expectEqual(@as(usize, 90), rb.end);
    try std.testing.expectEqualSlices(u8, chunk2, rb.buffer[40..90]);
}

test "RingBuffer.feed: exact full capacity (128 bytes)" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    const full_data = "X" ** 128;
    try rb.feed(full_data);

    try std.testing.expectEqual(@as(usize, 128), rb.count);
    try std.testing.expectEqualSlices(u8, full_data, rb.buffer[0..128]);
}

test "RingBuffer.feed: overflow on empty buffer (> 128 bytes)" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    const too_large = "Z" ** 129;
    try std.testing.expectError(error.NoRoomInBuffer, rb.feed(too_large));

    // State should remain unchanged
    try std.testing.expectEqual(@as(usize, 0), rb.count);
    try std.testing.expectEqual(@as(usize, 0), rb.end);
}

test "RingBuffer.feed: overflow on partially full buffer" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    // Fill 100 bytes
    try rb.feed("A" ** 100);
    try std.testing.expectEqual(@as(usize, 100), rb.count);

    // Attempt to feed 29 bytes (100 + 29 = 129 > 128)
    try std.testing.expectError(error.NoRoomInBuffer, rb.feed("B" ** 29));

    // State should remain unchanged from before the failed feed
    try std.testing.expectEqual(@as(usize, 100), rb.count);
    try std.testing.expectEqual(@as(usize, 100), rb.end);
}

test "RingBuffer.feed: feeding when completely full" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    try rb.feed("A" ** 128);
    try std.testing.expectEqual(@as(usize, 128), rb.count);

    // Even a single byte should fail
    try std.testing.expectError(error.NoRoomInBuffer, rb.feed("B"));
    try std.testing.expectEqual(@as(usize, 128), rb.count);
}

test "RingBuffer.feed: wrap-around across buffer boundary" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    // Simulate state where 100 bytes were written and consumed:
    // end is at 100, buffer has 28 bytes until the end of the array.
    rb.start = 100;
    rb.end = 100;
    rb.count = 0;

    // Feed 50 bytes: 28 bytes fit at [100..128], 22 bytes wrap to [0..22]
    const data = ("A" ** 28) ++ ("B" ** 22);
    try rb.feed(data);

    try std.testing.expectEqual(@as(usize, 50), rb.count);
    try std.testing.expectEqual(@as(usize, 22), rb.end);

    // Verify both contiguous halves
    try std.testing.expectEqualSlices(u8, "A" ** 28, rb.buffer[100..128]);
    try std.testing.expectEqualSlices(u8, "B" ** 22, rb.buffer[0..22]);
}

test "RingBuffer.feed: wrap-around landing exactly at boundary (end == 128 wraps to 0)" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    // Start at offset 100 with 0 count
    rb.start = 100;
    rb.end = 100;
    rb.count = 0;

    // Exactly 28 bytes to reach index 128
    const data = "C" ** 28;
    try rb.feed(data);

    try std.testing.expectEqual(@as(usize, 28), rb.count);
    try std.testing.expectEqual(@as(usize, 0), rb.end);
    try std.testing.expectEqualSlices(u8, data, rb.buffer[100..128]);
}

test "RingBuffer.init: zero-sized buffer returns InvalidBufferSize" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidBufferSize, RingBuffer.init(allocator, .{ .max_buffer_size = 0 }));
}

test "RingBuffer.feed: multiple successive wraps" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    // Cycle 1: Fill 100, simulate consuming 100
    try rb.feed("A" ** 100);
    rb.start = 100;
    rb.count = 0;

    // Wrap 1: 50 bytes (28 at end [100..128], 22 at start [0..22])
    try rb.feed("B" ** 50);
    try std.testing.expectEqual(@as(usize, 22), rb.end);
    try std.testing.expectEqual(@as(usize, 50), rb.count);
    try std.testing.expectEqualSlices(u8, "B" ** 28, rb.buffer[100..128]);
    try std.testing.expectEqualSlices(u8, "B" ** 22, rb.buffer[0..22]);

    // Simulate consuming 50 bytes
    rb.start = 22;
    rb.count = 0;

    // Wrap 2: 120 bytes from offset 22 (106 at end [22..128], 14 at start [0..14])
    try rb.feed("C" ** 120);
    try std.testing.expectEqual(@as(usize, 14), rb.end);
    try std.testing.expectEqual(@as(usize, 120), rb.count);
    try std.testing.expectEqualSlices(u8, "C" ** 106, rb.buffer[22..128]);
    try std.testing.expectEqualSlices(u8, "C" ** 14, rb.buffer[0..14]);
}

test "RingBuffer.feed: byte-by-byte until full" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, .{ .max_buffer_size = 128 });
    defer rb.deinit();

    const byte = [_]u8{'Z'};
    for (0..128) |i| {
        try rb.feed(&byte);
        try std.testing.expectEqual(i + 1, rb.count);
    }
    try std.testing.expectEqual(@as(usize, 0), rb.end);
    try std.testing.expectError(error.NoRoomInBuffer, rb.feed(&byte));
}
