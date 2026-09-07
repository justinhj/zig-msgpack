const std = @import("std");
const timestamp_ext = @import("timestamp_ext.zig");

pub const AnyWriter = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn init(pointer: anytype, comptime write_fn: fn (@TypeOf(pointer), []const u8) anyerror!void) AnyWriter {
        const Ptr = @TypeOf(pointer);
        const S = struct {
            fn call(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                const typed_ptr: Ptr = @ptrCast(@alignCast(ctx));
                return write_fn(typed_ptr, bytes);
            }
        };
        return .{
            .context = @ptrCast(pointer),
            .writeFn = S.call,
        };
    }

    pub fn writeAll(self: AnyWriter, bytes: []const u8) anyerror!void {
        return self.writeFn(self.context, bytes);
    }

    pub fn writeByte(self: AnyWriter, byte: u8) anyerror!void {
        const b = [1]u8{byte};
        return self.writeFn(self.context, &b);
    }
};

pub const ExtensionType = struct {
    unpackFn: *const fn (allocator: std.mem.Allocator, data: []const u8) anyerror!*anyopaque,
    packFn: *const fn (writer: AnyWriter, value: *const anyopaque) anyerror!void,
    freeFn: *const fn (allocator: std.mem.Allocator, value: *anyopaque) void,
};

pub fn extHandlerFor(
    comptime T: type,
    comptime unpackFn: fn (std.mem.Allocator, []const u8) anyerror!*T,
    comptime packFn: fn (AnyWriter, *const T) anyerror!void,
    comptime freeFn: fn (std.mem.Allocator, *T) void,
) ExtensionType {
    const S = struct {
        fn unpack(a: std.mem.Allocator, d: []const u8) anyerror!*anyopaque {
            return @ptrCast(try unpackFn(a, d));
        }
        fn pack(w: AnyWriter, v: *const anyopaque) anyerror!void {
            return packFn(w, @ptrCast(@alignCast(v)));
        }
        fn free(a: std.mem.Allocator, v: *anyopaque) void {
            freeFn(a, @ptrCast(@alignCast(v)));
        }
    };
    return .{ .unpackFn = S.unpack, .packFn = S.pack, .freeFn = S.free };
}

pub const ExtensionRegistry = struct {
    handlers: std.AutoHashMap(i8, ExtensionType),

    pub fn init(allocator: std.mem.Allocator) ExtensionRegistry {
        return .{
            .handlers = std.AutoHashMap(i8, ExtensionType).init(allocator),
        };
    }

    pub fn deinit(self: *ExtensionRegistry) void {
        self.handlers.deinit();
    }

    pub fn register(self: *ExtensionRegistry, type_code: i8, handler: ExtensionType) !void {
        try self.handlers.put(type_code, handler);
    }

    pub fn get(self: *const ExtensionRegistry, type_code: i8) ?ExtensionType {
        return self.handlers.get(type_code);
    }

    // Pre-registers type -1 with the timestamp handler.
    pub fn initWithDefaults(allocator: std.mem.Allocator) !ExtensionRegistry {
        var self = init(allocator);
        errdefer self.deinit();
        try self.register(-1, timestamp_ext.handler);
        return self;
    }
};

test "ExtensionRegistry custom type registration and roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const NvimBuffer = struct {
        id: u64,
    };

    const Helper = struct {
        fn unpackBuffer(a: std.mem.Allocator, data: []const u8) !*NvimBuffer {
            if (data.len != 8) return error.InvalidDataLength;
            const buf = try a.create(NvimBuffer);
            buf.* = .{ .id = std.mem.readInt(u64, data[0..8], .big) };
            return buf;
        }

        fn packBuffer(w: AnyWriter, buf: *const NvimBuffer) !void {
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, buf.id, .big);
            try w.writeAll(&tmp);
        }

        fn freeBuffer(a: std.mem.Allocator, buf: *NvimBuffer) void {
            a.destroy(buf);
        }
    };

    var registry = ExtensionRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(0, extHandlerFor(NvimBuffer, Helper.unpackBuffer, Helper.packBuffer, Helper.freeBuffer));

    const handler_opt = registry.get(0);
    try testing.expect(handler_opt != null);
    const h = handler_opt.?;

    // Test unpack
    const payload = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x2a };
    const raw_unpacked = try h.unpackFn(allocator, &payload);
    defer h.freeFn(allocator, raw_unpacked);

    const unpacked_buf: *NvimBuffer = @ptrCast(@alignCast(raw_unpacked));
    try testing.expectEqual(@as(u64, 0x12a), unpacked_buf.id);

    // Test pack
    var out_buf: [8]u8 = undefined;
    var written_len: usize = 0;
    const WriterContext = struct {
        buf: *[8]u8,
        len: *usize,

        fn write(self: *@This(), bytes: []const u8) anyerror!void {
            @memcpy(self.buf[self.len.* .. self.len.* + bytes.len], bytes);
            self.len.* += bytes.len;
        }
    };
    var ctx = WriterContext{ .buf = &out_buf, .len = &written_len };
    const any_writer = AnyWriter.init(&ctx, WriterContext.write);

    try h.packFn(any_writer, unpacked_buf);
    try testing.expectEqualSlices(u8, &payload, out_buf[0..written_len]);
}

test "ExtensionRegistry initWithDefaults has timestamp registered" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try ExtensionRegistry.initWithDefaults(allocator);
    defer registry.deinit();

    const handler_opt = registry.get(-1);
    try testing.expect(handler_opt != null);
    try testing.expect(registry.get(0) == null);
}
