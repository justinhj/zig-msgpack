const std = @import("std");
const Io = std.Io;

const zig_msgpack = @import("zig_msgpack");

fn printIndent(writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        _ = try writer.write("  ");
    }
}

fn printString(writer: anytype, str: []const u8) !void {
    _ = try writer.write("\"");
    for (str) |c| {
        switch (c) {
            '"' => _ = try writer.write("\\\""),
            '\\' => _ = try writer.write("\\\\"),
            '\n' => _ = try writer.write("\\n"),
            '\r' => _ = try writer.write("\\r"),
            '\t' => _ = try writer.write("\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    var buf: [8]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c});
                    _ = try writer.write(hex);
                } else {
                    const b = [1]u8{c};
                    _ = try writer.write(&b);
                }
            },
        }
    }
    _ = try writer.write("\"");
}

fn printObject(writer: anytype, obj: MsgPackObject, indent: usize) anyerror!void {
    switch (obj) {
        .nil => _ = try writer.write("nil"),
        .boolean => |b| _ = try writer.write(if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{d}", .{i});
            _ = try writer.write(str);
        },
        .unsigned_integer => |u| {
            var buf: [32]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{d}", .{u});
            _ = try writer.write(str);
        },
        .float32 => |f| {
            var buf: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
            _ = try writer.write(str);
        },
        .float64 => |f| {
            var buf: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
            _ = try writer.write(str);
        },
        .string => |s| try printString(writer, s),
        .binary => |b| {
            var buf: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "<bin len={d}>", .{b.len});
            _ = try writer.write(str);
        },
        .extension => |ext| {
            var buf: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "<ext type={d} len={d}>", .{ ext.type, ext.data.len });
            _ = try writer.write(str);
        },
        .array => |arr| {
            if (arr.len == 0) {
                _ = try writer.write("[]");
                return;
            }
            _ = try writer.write("[\n");
            for (arr, 0..) |item, idx| {
                try printIndent(writer, indent + 1);
                try printObject(writer, item, indent + 1);
                if (idx + 1 < arr.len) {
                    _ = try writer.write(",");
                }
                _ = try writer.write("\n");
            }
            try printIndent(writer, indent);
            _ = try writer.write("]");
        },
        .map => |entries| {
            if (entries.len == 0) {
                _ = try writer.write("{}");
                return;
            }
            _ = try writer.write("{\n");
            for (entries, 0..) |entry, idx| {
                try printIndent(writer, indent + 1);
                try printObject(writer, entry.key, indent + 1);
                _ = try writer.write(": ");
                try printObject(writer, entry.value, indent + 1);
                if (idx + 1 < entries.len) {
                    _ = try writer.write(",");
                }
                _ = try writer.write("\n");
            }
            try printIndent(writer, indent);
            _ = try writer.write("}");
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var file_path: []const u8 = "testdata/nvimapi.msgpack";
    if (args.len > 1 and (std.mem.endsWith(u8, args[1], ".msgpack") or std.mem.eql(u8, args[1], "testdata/nvimapi.msgpack"))) {
        file_path = args[1];
    }

    const file = Io.Dir.openFile(.cwd(), io, file_path, .{}) catch |err| {
        std.log.err("Failed to open {s}: {s}", .{ file_path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    const file_len = try file.length(io);
    const buffer = try arena.alloc(u8, @intCast(file_len));
    const bytes_read = try file.readPositionalAll(io, buffer, 0);

    const obj = unpack(arena, buffer[0..bytes_read]) catch |err| {
        std.log.err("Failed to unpack {s}: {s}", .{ file_path, @errorName(err) });
        return err;
    };

    printObject(stdout_writer, obj, 0) catch |err| switch (err) {
        error.WriteFailed => return,
        else => return err,
    };
    _ = stdout_writer.write("\n") catch {};
    stdout_writer.flush() catch {};
}

//// Unpacker implementation 

const RingBuffer = zig_msgpack.RingBuffer;
const RingBufferError = zig_msgpack.RingBufferError;

pub const MsgPackMapEntry = zig_msgpack.MsgPackMapEntry;
pub const MsgPackExtension = zig_msgpack.MsgPackExtension;
pub const MsgPackType = zig_msgpack.MsgPackType;
pub const MsgPackObject = zig_msgpack.MsgPackObject;
pub const freeObject = zig_msgpack.freeObject;

pub const packer = zig_msgpack.packer;
pub const Packer = zig_msgpack.Packer;
pub const pack = zig_msgpack.pack;
pub const packRpcRequest = zig_msgpack.packRpcRequest;
pub const packRpcResponse = zig_msgpack.packRpcResponse;
pub const packRpcNotification = zig_msgpack.packRpcNotification;


pub const unpacker = zig_msgpack.unpacker;
pub const Unpacker = zig_msgpack.Unpacker;
pub const unpack = zig_msgpack.unpack;
pub const MsgPackError = zig_msgpack.MsgPackError;
pub const SliceReader = zig_msgpack.SliceReader;
pub const RingReader = zig_msgpack.RingReader;
pub const Parser = zig_msgpack.Parser;

test "roundtrip: nil and booleans" {
    const allocator = std.testing.allocator;

    const n = MsgPackObject{ .nil = {} };
    const bytes_nil = try pack(allocator, n);
    defer allocator.free(bytes_nil);
    const obj_nil = try unpack(allocator, bytes_nil);
    defer freeObject(allocator, obj_nil);
    try std.testing.expect(obj_nil == .nil);

    const b_true = MsgPackObject{ .boolean = true };
    const bytes_true = try pack(allocator, b_true);
    defer allocator.free(bytes_true);
    const obj_true = try unpack(allocator, bytes_true);
    defer freeObject(allocator, obj_true);
    try std.testing.expect(obj_true == .boolean);
    try std.testing.expectEqual(true, obj_true.boolean);

    const b_false = MsgPackObject{ .boolean = false };
    const bytes_false = try pack(allocator, b_false);
    defer allocator.free(bytes_false);
    const obj_false = try unpack(allocator, bytes_false);
    defer freeObject(allocator, obj_false);
    try std.testing.expect(obj_false == .boolean);
    try std.testing.expectEqual(false, obj_false.boolean);
}

test "roundtrip: integers across all boundaries" {
    const allocator = std.testing.allocator;

    const test_ints = [_]i64{
        0, 1, 127, 128, 255, 256, 65535, 65536, 2147483647,
        -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649,
    };

    for (test_ints) |val| {
        const obj_in = MsgPackObject{ .integer = val };
        const bytes = try pack(allocator, obj_in);
        defer allocator.free(bytes);

        const obj_out = try unpack(allocator, bytes);
        defer freeObject(allocator, obj_out);

        try std.testing.expect(obj_out == .integer);
        try std.testing.expectEqual(val, obj_out.integer);
    }

    // uint 64 that exceeds maxInt(i64)
    const large_u64: u64 = 0x9000_0000_0000_0000;
    const obj_in = MsgPackObject{ .unsigned_integer = large_u64 };
    const bytes = try pack(allocator, obj_in);
    defer allocator.free(bytes);

    const obj_out = try unpack(allocator, bytes);
    defer freeObject(allocator, obj_out);

    try std.testing.expect(obj_out == .unsigned_integer);
    try std.testing.expectEqual(large_u64, obj_out.unsigned_integer);
}

test "roundtrip: float32 and float64" {
    const allocator = std.testing.allocator;

    const f32_val: f32 = 3.14159;
    const bytes32 = try pack(allocator, MsgPackObject{ .float32 = f32_val });
    defer allocator.free(bytes32);
    const obj32 = try unpack(allocator, bytes32);
    defer freeObject(allocator, obj32);
    try std.testing.expect(obj32 == .float32);
    try std.testing.expectEqual(f32_val, obj32.float32);

    const f64_val: f64 = -2.718281828459;
    const bytes64 = try pack(allocator, MsgPackObject{ .float64 = f64_val });
    defer allocator.free(bytes64);
    const obj64 = try unpack(allocator, bytes64);
    defer freeObject(allocator, obj64);
    try std.testing.expect(obj64 == .float64);
    try std.testing.expectEqual(f64_val, obj64.float64);
}

test "roundtrip: strings (fixstr, str8)" {
    const allocator = std.testing.allocator;

    // fixstr
    {
        var s = "hello world".*;
        const bytes = try pack(allocator, MsgPackObject{ .string = &s });
        defer allocator.free(bytes);
        const obj = try unpack(allocator, bytes);
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .string);
        try std.testing.expectEqualStrings("hello world", obj.string);
    }

    // str 8 (300 bytes)
    {
        var s: [300]u8 = undefined;
        @memset(&s, 'x');
        const bytes = try pack(allocator, MsgPackObject{ .string = &s });
        defer allocator.free(bytes);
        const obj = try unpack(allocator, bytes);
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .string);
        try std.testing.expectEqualStrings(&s, obj.string);
    }
}

test "roundtrip: binary data" {
    const allocator = std.testing.allocator;

    var bin_data = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x42 };
    const bytes = try pack(allocator, MsgPackObject{ .binary = &bin_data });
    defer allocator.free(bytes);
    const obj = try unpack(allocator, bytes);
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .binary);
    try std.testing.expectEqualSlices(u8, &bin_data, obj.binary);
}

test "roundtrip: nested array and map" {
    const allocator = std.testing.allocator;

    var s1 = "nvim".*;
    var s2 = "buffer".*;
    var val_str = "value".*;

    var map_entries = [_]MsgPackMapEntry{
        .{ .key = MsgPackObject{ .string = &s2 }, .value = MsgPackObject{ .integer = 42 } },
    };

    var array_items = [_]MsgPackObject{
        MsgPackObject{ .string = &s1 },
        MsgPackObject{ .map = &map_entries },
        MsgPackObject{ .string = &val_str },
    };

    const obj_in = MsgPackObject{ .array = &array_items };
    const bytes = try pack(allocator, obj_in);
    defer allocator.free(bytes);

    const obj_out = try unpack(allocator, bytes);
    defer freeObject(allocator, obj_out);

    try std.testing.expect(obj_out == .array);
    try std.testing.expectEqual(@as(usize, 3), obj_out.array.len);
    try std.testing.expectEqualStrings("nvim", obj_out.array[0].string);
    try std.testing.expect(obj_out.array[1] == .map);
    try std.testing.expectEqual(@as(usize, 1), obj_out.array[1].map.len);
    try std.testing.expectEqualStrings("buffer", obj_out.array[1].map[0].key.string);
    try std.testing.expectEqual(@as(i64, 42), obj_out.array[1].map[0].value.integer);
    try std.testing.expectEqualStrings("value", obj_out.array[2].string);
}

test "roundtrip: extension data" {
    const allocator = std.testing.allocator;

    var ext_data = [_]u8{ 1, 2, 3, 4 };
    const ext_in = MsgPackExtension{ .type = -5, .data = &ext_data };
    const bytes = try pack(allocator, MsgPackObject{ .extension = ext_in });
    defer allocator.free(bytes);

    const obj_out = try unpack(allocator, bytes);
    defer freeObject(allocator, obj_out);

    try std.testing.expect(obj_out == .extension);
    try std.testing.expectEqual(@as(i8, -5), obj_out.extension.type);
    try std.testing.expectEqualSlices(u8, &ext_data, obj_out.extension.data);
}

test "roundtrip: Neovim RPC request" {
    const allocator = std.testing.allocator;

    var packer_inst = Packer.init(allocator);
    defer packer_inst.deinit();

    var arg1 = "nvim_get_current_line".*;
    const params = [_]MsgPackObject{};

    try packRpcRequest(&packer_inst, 101, &arg1, &params);

    const obj = try unpack(allocator, packer_inst.getSlice());
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 4), obj.array.len);
    try std.testing.expectEqual(@as(i64, 0), obj.array[0].integer); // 0 = request
    try std.testing.expectEqual(@as(i64, 101), obj.array[1].integer); // msgid
    try std.testing.expectEqualStrings("nvim_get_current_line", obj.array[2].string);
    try std.testing.expect(obj.array[3] == .array);
    try std.testing.expectEqual(@as(usize, 0), obj.array[3].array.len);
}

test "roundtrip: Neovim RPC response" {
    const allocator = std.testing.allocator;

    var packer_inst = Packer.init(allocator);
    defer packer_inst.deinit();

    var res_str = "hello nvim".*;
    try packRpcResponse(&packer_inst, 101, null, MsgPackObject{ .string = &res_str });

    const obj = try unpack(allocator, packer_inst.getSlice());
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 4), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer); // 1 = response
    try std.testing.expectEqual(@as(i64, 101), obj.array[1].integer); // msgid
    try std.testing.expect(obj.array[2] == .nil); // error is nil
    try std.testing.expectEqualStrings("hello nvim", obj.array[3].string);
}





