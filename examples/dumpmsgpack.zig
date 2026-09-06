const std = @import("std");
const Io = std.Io;
const msgpack = @import("zig_msgpack");

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

fn printObject(writer: anytype, obj: msgpack.MsgPackObject, indent: usize) anyerror!void {
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
    if (args.len < 2) {
        _ = try stdout_writer.write(
            \\Usage: dumpmsgpack <path-to-msgpack-file>
            \\
            \\Reads a MessagePack file, unpacks its contents, and pretty-prints it.
            \\
            \\Example:
            \\  dumpmsgpack testdata/nvimapi.msgpack
            \\
        );
        try stdout_writer.flush();
        return;
    }

    const file_path = args[1];
    const file = Io.Dir.openFile(.cwd(), io, file_path, .{}) catch |err| {
        std.log.err("Failed to open file '{s}': {s}", .{ file_path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    const file_len = try file.length(io);
    const buffer = try arena.alloc(u8, @intCast(file_len));
    const bytes_read = try file.readPositionalAll(io, buffer, 0);

    const obj = msgpack.unpack(arena, buffer[0..bytes_read]) catch |err| {
        std.log.err("Failed to unpack MessagePack data in '{s}': {s}", .{ file_path, @errorName(err) });
        return err;
    };

    printObject(stdout_writer, obj, 0) catch |err| switch (err) {
        error.WriteFailed => return,
        else => return err,
    };
    _ = stdout_writer.write("\n") catch {};
    stdout_writer.flush() catch {};
}
