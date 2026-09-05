const std = @import("std");
const types = @import("types.zig");
const ringbuffer_mod = @import("ringbuffer.zig");

pub const MsgPackObject = types.MsgPackObject;
pub const MsgPackMapEntry = types.MsgPackMapEntry;
pub const MsgPackExtension = types.MsgPackExtension;
pub const MsgPackType = types.MsgPackType;
pub const RingBuffer = ringbuffer_mod.RingBuffer;

pub const PackerError = error{
    ValueTooLarge,
    OutOfMemory,
};

pub fn writeByte(writer: anytype, byte: u8) !void {
    if (@TypeOf(writer) == *RingBuffer) {
        const buf = [1]u8{byte};
        try writer.feed(&buf);
    } else {
        try writer.writeByte(byte);
    }
}

pub fn writeBytes(writer: anytype, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (@TypeOf(writer) == *RingBuffer) {
        try writer.feed(bytes);
    } else {
        try writer.writeAll(bytes);
    }
}

fn writeIntBig(writer: anytype, comptime T: type, val: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, val, .big);
    try writeBytes(writer, &buf);
}

// --------------------------------------------------------------------------
// Core Stream Packing Functions
// --------------------------------------------------------------------------

pub fn packNil(writer: anytype) !void {
    try writeByte(writer, 0xc0);
}

pub fn packBool(writer: anytype, val: bool) !void {
    try writeByte(writer, if (val) 0xc3 else 0xc2);
}

pub fn packUInt(writer: anytype, val: u64) !void {
    if (val <= 127) {
        // positive fixint: 0x00 ... 0x7f
        try writeByte(writer, @as(u8, @intCast(val)));
    } else if (val <= 255) {
        // uint 8: 0xcc + u8
        try writeByte(writer, 0xcc);
        try writeByte(writer, @as(u8, @intCast(val)));
    } else if (val <= 65535) {
        // uint 16: 0xcd + u16 big-endian
        try writeByte(writer, 0xcd);
        try writeIntBig(writer, u16, @as(u16, @intCast(val)));
    } else if (val <= 4294967295) {
        // uint 32: 0xce + u32 big-endian
        try writeByte(writer, 0xce);
        try writeIntBig(writer, u32, @as(u32, @intCast(val)));
    } else {
        // uint 64: 0xcf + u64 big-endian
        try writeByte(writer, 0xcf);
        try writeIntBig(writer, u64, val);
    }
}

pub fn packSignedIntNegative(writer: anytype, val: i64) !void {
    std.debug.assert(val < 0);
    if (val >= -32) {
        // negative fixint: 111xxxxx (-32 ... -1)
        const byte: u8 = @bitCast(@as(i8, @intCast(val)));
        try writeByte(writer, byte);
    } else if (val >= -128) {
        // int 8: 0xd0 + i8
        try writeByte(writer, 0xd0);
        const byte: u8 = @bitCast(@as(i8, @intCast(val)));
        try writeByte(writer, byte);
    } else if (val >= -32768) {
        // int 16: 0xd1 + i16 big-endian
        try writeByte(writer, 0xd1);
        try writeIntBig(writer, i16, @as(i16, @intCast(val)));
    } else if (val >= -2147483648) {
        // int 32: 0xd2 + i32 big-endian
        try writeByte(writer, 0xd2);
        try writeIntBig(writer, i32, @as(i32, @intCast(val)));
    } else {
        // int 64: 0xd3 + i64 big-endian
        try writeByte(writer, 0xd3);
        try writeIntBig(writer, i64, val);
    }
}

pub fn packInt(writer: anytype, val: anytype) !void {
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    switch (info) {
        .int => |int_info| {
            if (int_info.signedness == .signed) {
                if (val < 0) {
                    return packSignedIntNegative(writer, @as(i64, @intCast(val)));
                } else {
                    return packUInt(writer, @as(u64, @intCast(val)));
                }
            } else {
                return packUInt(writer, @as(u64, @intCast(val)));
            }
        },
        .comptime_int => {
            if (val < 0) {
                return packSignedIntNegative(writer, @as(i64, val));
            } else {
                return packUInt(writer, @as(u64, val));
            }
        },
        else => @compileError("packInt expects an integer, found " ++ @typeName(T)),
    }
}

pub fn packFloat32(writer: anytype, val: f32) !void {
    try writeByte(writer, 0xca);
    try writeIntBig(writer, u32, @bitCast(val));
}

pub fn packFloat64(writer: anytype, val: f64) !void {
    try writeByte(writer, 0xcb);
    try writeIntBig(writer, u64, @bitCast(val));
}

pub fn packString(writer: anytype, str: []const u8) !void {
    const len = str.len;
    if (len <= 31) {
        try writeByte(writer, 0xa0 | @as(u8, @intCast(len)));
    } else if (len <= 255) {
        try writeByte(writer, 0xd9);
        try writeByte(writer, @as(u8, @intCast(len)));
    } else if (len <= 65535) {
        try writeByte(writer, 0xda);
        try writeIntBig(writer, u16, @as(u16, @intCast(len)));
    } else if (len <= 4294967295) {
        try writeByte(writer, 0xdb);
        try writeIntBig(writer, u32, @as(u32, @intCast(len)));
    } else {
        return PackerError.ValueTooLarge;
    }
    try writeBytes(writer, str);
}

pub fn packBinary(writer: anytype, bin: []const u8) !void {
    const len = bin.len;
    if (len <= 255) {
        try writeByte(writer, 0xc4);
        try writeByte(writer, @as(u8, @intCast(len)));
    } else if (len <= 65535) {
        try writeByte(writer, 0xc5);
        try writeIntBig(writer, u16, @as(u16, @intCast(len)));
    } else if (len <= 4294967295) {
        try writeByte(writer, 0xc6);
        try writeIntBig(writer, u32, @as(u32, @intCast(len)));
    } else {
        return PackerError.ValueTooLarge;
    }
    try writeBytes(writer, bin);
}

pub fn packArrayHeader(writer: anytype, len: usize) !void {
    if (len <= 15) {
        try writeByte(writer, 0x90 | @as(u8, @intCast(len)));
    } else if (len <= 65535) {
        try writeByte(writer, 0xdc);
        try writeIntBig(writer, u16, @as(u16, @intCast(len)));
    } else if (len <= 4294967295) {
        try writeByte(writer, 0xdd);
        try writeIntBig(writer, u32, @as(u32, @intCast(len)));
    } else {
        return PackerError.ValueTooLarge;
    }
}

pub fn packMapHeader(writer: anytype, len: usize) !void {
    if (len <= 15) {
        try writeByte(writer, 0x80 | @as(u8, @intCast(len)));
    } else if (len <= 65535) {
        try writeByte(writer, 0xde);
        try writeIntBig(writer, u16, @as(u16, @intCast(len)));
    } else if (len <= 4294967295) {
        try writeByte(writer, 0xdf);
        try writeIntBig(writer, u32, @as(u32, @intCast(len)));
    } else {
        return PackerError.ValueTooLarge;
    }
}

pub fn packExt(writer: anytype, ext_type: i8, data: []const u8) !void {
    const len = data.len;
    switch (len) {
        1 => {
            try writeByte(writer, 0xd4);
            try writeByte(writer, @bitCast(ext_type));
        },
        2 => {
            try writeByte(writer, 0xd5);
            try writeByte(writer, @bitCast(ext_type));
        },
        4 => {
            try writeByte(writer, 0xd6);
            try writeByte(writer, @bitCast(ext_type));
        },
        8 => {
            try writeByte(writer, 0xd7);
            try writeByte(writer, @bitCast(ext_type));
        },
        16 => {
            try writeByte(writer, 0xd8);
            try writeByte(writer, @bitCast(ext_type));
        },
        else => {
            if (len <= 255) {
                try writeByte(writer, 0xc7);
                try writeByte(writer, @as(u8, @intCast(len)));
                try writeByte(writer, @bitCast(ext_type));
            } else if (len <= 65535) {
                try writeByte(writer, 0xc8);
                try writeIntBig(writer, u16, @as(u16, @intCast(len)));
                try writeByte(writer, @bitCast(ext_type));
            } else if (len <= 4294967295) {
                try writeByte(writer, 0xc9);
                try writeIntBig(writer, u32, @as(u32, @intCast(len)));
                try writeByte(writer, @bitCast(ext_type));
            } else {
                return PackerError.ValueTooLarge;
            }
        },
    }
    try writeBytes(writer, data);
}

pub fn packObject(writer: anytype, obj: MsgPackObject) anyerror!void {
    switch (obj) {
        .nil => try packNil(writer),
        .boolean => |b| try packBool(writer, b),
        .integer => |i| {
            if (i >= 0) {
                try packUInt(writer, @as(u64, @intCast(i)));
            } else {
                try packSignedIntNegative(writer, i);
            }
        },
        .unsigned_integer => |u| try packUInt(writer, u),
        .float32 => |f| try packFloat32(writer, f),
        .float64 => |f| try packFloat64(writer, f),
        .string => |s| try packString(writer, s),
        .binary => |b| try packBinary(writer, b),
        .array => |arr| {
            try packArrayHeader(writer, arr.len);
            for (arr) |item| {
                try packObject(writer, item);
            }
        },
        .map => |entries| {
            try packMapHeader(writer, entries.len);
            for (entries) |entry| {
                try packObject(writer, entry.key);
                try packObject(writer, entry.value);
            }
        },
        .extension => |ext| {
            try packExt(writer, ext.type, ext.data);
        },
    }
}

// --------------------------------------------------------------------------
// In-Memory Builder: Packer
// --------------------------------------------------------------------------

pub const Packer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Packer {
        return .{
            .allocator = allocator,
            .bytes = .empty,
        };
    }

    pub fn deinit(self: *Packer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn writeByte(self: *Packer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
    }

    pub fn writeAll(self: *Packer, data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }

    pub fn toOwnedSlice(self: *Packer) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn getSlice(self: *const Packer) []const u8 {
        return self.bytes.items;
    }

    pub fn packNil(self: *Packer) !void {
        return @import("packer.zig").packNil(self);
    }

    pub fn packBool(self: *Packer, val: bool) !void {
        return @import("packer.zig").packBool(self, val);
    }

    pub fn packInt(self: *Packer, val: anytype) !void {
        return @import("packer.zig").packInt(self, val);
    }

    pub fn packUInt(self: *Packer, val: u64) !void {
        return @import("packer.zig").packUInt(self, val);
    }

    pub fn packFloat32(self: *Packer, val: f32) !void {
        return @import("packer.zig").packFloat32(self, val);
    }

    pub fn packFloat64(self: *Packer, val: f64) !void {
        return @import("packer.zig").packFloat64(self, val);
    }

    pub fn packString(self: *Packer, str: []const u8) !void {
        return @import("packer.zig").packString(self, str);
    }

    pub fn packBinary(self: *Packer, bin: []const u8) !void {
        return @import("packer.zig").packBinary(self, bin);
    }

    pub fn packArrayHeader(self: *Packer, len: usize) !void {
        return @import("packer.zig").packArrayHeader(self, len);
    }

    pub fn packMapHeader(self: *Packer, len: usize) !void {
        return @import("packer.zig").packMapHeader(self, len);
    }

    pub fn packExt(self: *Packer, ext_type: i8, data: []const u8) !void {
        return @import("packer.zig").packExt(self, ext_type, data);
    }

    pub fn packObject(self: *Packer, obj: MsgPackObject) !void {
        return @import("packer.zig").packObject(self, obj);
    }

    pub fn packRpcRequest(self: *Packer, msgid: u32, method: []const u8, params: []const MsgPackObject) !void {
        return @import("packer.zig").packRpcRequest(self, msgid, method, params);
    }

    pub fn packRpcResponse(self: *Packer, msgid: u32, err: ?MsgPackObject, result: ?MsgPackObject) !void {
        return @import("packer.zig").packRpcResponse(self, msgid, err, result);
    }

    pub fn packRpcNotification(self: *Packer, method: []const u8, params: []const MsgPackObject) !void {
        return @import("packer.zig").packRpcNotification(self, method, params);
    }
};

/// One-shot serialization helper
pub fn pack(allocator: std.mem.Allocator, obj: MsgPackObject) ![]u8 {
    var packer = Packer.init(allocator);
    errdefer packer.deinit();
    try packObject(&packer, obj);
    return packer.toOwnedSlice();
}

// --------------------------------------------------------------------------
// Neovim MessagePack-RPC Helpers
// --------------------------------------------------------------------------

/// Pack a MessagePack-RPC Request: [0, msgid, method, params]
pub fn packRpcRequest(writer: anytype, msgid: u32, method: []const u8, params: []const MsgPackObject) !void {
    try packArrayHeader(writer, 4);
    try packInt(writer, @as(u8, 0));
    try packUInt(writer, msgid);
    try packString(writer, method);
    try packArrayHeader(writer, params.len);
    for (params) |param| {
        try packObject(writer, param);
    }
}

/// Pack a MessagePack-RPC Response: [1, msgid, error, result]
pub fn packRpcResponse(writer: anytype, msgid: u32, err: ?MsgPackObject, result: ?MsgPackObject) !void {
    try packArrayHeader(writer, 4);
    try packInt(writer, @as(u8, 1));
    try packUInt(writer, msgid);
    if (err) |e| {
        try packObject(writer, e);
    } else {
        try packNil(writer);
    }
    if (result) |r| {
        try packObject(writer, r);
    } else {
        try packNil(writer);
    }
}

/// Pack a MessagePack-RPC Notification: [2, method, params]
pub fn packRpcNotification(writer: anytype, method: []const u8, params: []const MsgPackObject) !void {
    try packArrayHeader(writer, 3);
    try packInt(writer, @as(u8, 2));
    try packString(writer, method);
    try packArrayHeader(writer, params.len);
    for (params) |param| {
        try packObject(writer, param);
    }
}

// --------------------------------------------------------------------------
// Unit Tests: Optimal Format Verification
// --------------------------------------------------------------------------

test "packer: nil and booleans" {
    var packer = Packer.init(std.testing.allocator);
    defer packer.deinit();

    try packer.packNil();
    try packer.packBool(true);
    try packer.packBool(false);

    try std.testing.expectEqualSlices(u8, "\xc0\xc3\xc2", packer.getSlice());
}

test "packer: integer optimal format selection" {
    const allocator = std.testing.allocator;

    // positive fixint: 0, 127
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(0);
        try p.packInt(127);
        try std.testing.expectEqualSlices(u8, "\x00\x7f", p.getSlice());
    }

    // uint 8: 128, 255
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(128);
        try p.packInt(255);
        try std.testing.expectEqualSlices(u8, "\xcc\x80\xcc\xff", p.getSlice());
    }

    // uint 16: 256, 65535
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(256);
        try p.packInt(65535);
        try std.testing.expectEqualSlices(u8, "\xcd\x01\x00\xcd\xff\xff", p.getSlice());
    }

    // uint 32: 65536, 4294967295
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(65536);
        try p.packInt(4294967295);
        try std.testing.expectEqualSlices(u8, "\xce\x00\x01\x00\x00\xce\xff\xff\xff\xff", p.getSlice());
    }

    // uint 64: 4294967296
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packUInt(4294967296);
        try std.testing.expectEqualSlices(u8, "\xcf\x00\x00\x00\x01\x00\x00\x00\x00", p.getSlice());
    }

    // negative fixint: -1, -32
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(-1);
        try p.packInt(-32);
        try std.testing.expectEqualSlices(u8, "\xff\xe0", p.getSlice());
    }

    // int 8: -33, -128
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(-33);
        try p.packInt(-128);
        try std.testing.expectEqualSlices(u8, "\xd0\xdf\xd0\x80", p.getSlice());
    }

    // int 16: -129, -32768
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(-129);
        try p.packInt(-32768);
        try std.testing.expectEqualSlices(u8, "\xd1\xff\x7f\xd1\x80\x00", p.getSlice());
    }

    // int 32: -32769, -2147483648
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(-32769);
        try p.packInt(-2147483648);
        try std.testing.expectEqualSlices(u8, "\xd2\xff\xff\x7f\xff\xd2\x80\x00\x00\x00", p.getSlice());
    }

    // int 64: -2147483649
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packInt(-2147483649);
        try std.testing.expectEqualSlices(u8, "\xd3\xff\xff\xff\xff\x7f\xff\xff\xff", p.getSlice());
    }
}

test "packer: float32 and float64" {
    var p = Packer.init(std.testing.allocator);
    defer p.deinit();

    try p.packFloat32(2.5);
    try p.packFloat64(-1.5);

    // 2.5f in IEEE 754: 0x40200000
    // -1.5 in IEEE 754: 0xbff8000000000000
    try std.testing.expectEqualSlices(u8, "\xca\x40\x20\x00\x00\xcb\xbf\xf8\x00\x00\x00\x00\x00\x00", p.getSlice());
}

test "packer: string format selection" {
    const allocator = std.testing.allocator;

    // fixstr: len 5
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packString("hello");
        try std.testing.expectEqualSlices(u8, "\xa5hello", p.getSlice());
    }

    // str 8: len 32
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        const str32 = "12345678901234567890123456789012";
        try p.packString(str32);
        try std.testing.expectEqual(@as(u8, 0xd9), p.getSlice()[0]);
        try std.testing.expectEqual(@as(u8, 32), p.getSlice()[1]);
        try std.testing.expectEqualStrings(str32, p.getSlice()[2..]);
    }
}

test "packer: binary format selection" {
    var p = Packer.init(std.testing.allocator);
    defer p.deinit();

    try p.packBinary(&[_]u8{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, "\xc4\x03\x01\x02\x03", p.getSlice());
}

test "packer: extension format selection" {
    const allocator = std.testing.allocator;

    // fixext 1
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packExt(5, &[_]u8{0xaa});
        try std.testing.expectEqualSlices(u8, "\xd4\x05\xaa", p.getSlice());
    }

    // fixext 2
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packExt(2, &[_]u8{ 0x11, 0x22 });
        try std.testing.expectEqualSlices(u8, "\xd5\x02\x11\x22", p.getSlice());
    }

    // fixext 4
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packExt(3, &[_]u8{ 1, 2, 3, 4 });
        try std.testing.expectEqualSlices(u8, "\xd6\x03\x01\x02\x03\x04", p.getSlice());
    }

    // fixext 8
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packExt(4, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        try std.testing.expectEqualSlices(u8, "\xd7\x04\x01\x02\x03\x04\x05\x06\x07\x08", p.getSlice());
    }

    // fixext 16
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        const data16 = [_]u8{0x42} ** 16;
        try p.packExt(7, &data16);
        try std.testing.expectEqualSlices(u8, "\xd8\x07" ++ ("\x42" ** 16), p.getSlice());
    }

    // ext 8: len 3 (not 1, 2, 4, 8, 16)
    {
        var p = Packer.init(allocator);
        defer p.deinit();
        try p.packExt(1, &[_]u8{ 10, 20, 30 });
        try std.testing.expectEqualSlices(u8, "\xc7\x03\x01\x0a\x14\x1e", p.getSlice());
    }
}

test "packer: pack directly to RingBuffer" {
    var ring = try RingBuffer.init(std.testing.allocator, .{ .max_buffer_size = 64 });
    defer ring.deinit();

    try packNil(&ring);
    try packBool(&ring, true);
    try packString(&ring, "hi");

    var out: [5]u8 = undefined;
    try ring.readBytes(&out);
    try std.testing.expectEqualSlices(u8, "\xc0\xc3\xa2hi", &out);
}

test "packer: RPC request framing" {
    var p = Packer.init(std.testing.allocator);
    defer p.deinit();

    // Request: [0, 1, "nvim_command", ["echo 'hello'"]]
    var param_str = [_]u8{ 'e', 'c', 'h', 'o' };
    const params = [_]MsgPackObject{
        MsgPackObject{ .string = &param_str },
    };

    try p.packRpcRequest(1, "nvim_command", &params);

    const slice = p.getSlice();
    // 0x94 (4-array), 0x00 (req type 0), 0x01 (msgid 1), 0xac + "nvim_command", 0x91 (1-array), 0xa4 + "echo"
    try std.testing.expectEqual(@as(u8, 0x94), slice[0]);
    try std.testing.expectEqual(@as(u8, 0x00), slice[1]);
    try std.testing.expectEqual(@as(u8, 0x01), slice[2]);
    try std.testing.expectEqualSlices(u8, "\xacnvim_command\x91\xa4echo", slice[3..]);
}

test "packer: RPC response framing" {
    var p = Packer.init(std.testing.allocator);
    defer p.deinit();

    // Response: [1, 42, nil, 100]
    try p.packRpcResponse(42, null, MsgPackObject{ .integer = 100 });

    const slice = p.getSlice();
    // [1, 42, nil, 100] -> 0x94, 0x01, 0x2a, 0xc0, 0x64
    try std.testing.expectEqualSlices(u8, "\x94\x01\x2a\xc0\x64", slice);
}

test "packer: RPC notification framing" {
    var p = Packer.init(std.testing.allocator);
    defer p.deinit();

    // Notification: [2, "redraw", []]
    try p.packRpcNotification("redraw", &[_]MsgPackObject{});

    const slice = p.getSlice();
    // [2, "redraw", []] -> 0x93, 0x02, 0xa6 + "redraw", 0x90
    try std.testing.expectEqualSlices(u8, "\x93\x02\xa6redraw\x90", slice);
}
