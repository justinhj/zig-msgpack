const std = @import("std");
const Io = std.Io;
const msgpack = @import("zig_msgpack");

fn printObject(writer: anytype, obj: msgpack.MsgPackObject) anyerror!void {
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
        .string => |s| {
            _ = try writer.write("\"");
            _ = try writer.write(s);
            _ = try writer.write("\"");
        },
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
            _ = try writer.write("[");
            for (arr, 0..) |item, idx| {
                if (idx > 0) _ = try writer.write(", ");
                try printObject(writer, item);
            }
            _ = try writer.write("]");
        },
        .map => |entries| {
            _ = try writer.write("{");
            for (entries, 0..) |entry, idx| {
                if (idx > 0) _ = try writer.write(", ");
                try printObject(writer, entry.key);
                _ = try writer.write(": ");
                try printObject(writer, entry.value);
            }
            _ = try writer.write("}");
        },
    }
}

// Feed socket data into the unpacker until one complete object arrives.
// Mirrors the pynvim _on_data pattern: try next(), and if more data is
// needed read a chunk, feed it, then try again.
fn readNextObject(fd: std.posix.fd_t, unpacker: *msgpack.Unpacker) !msgpack.MsgPackObject {
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const obj = unpacker.next() catch |err| switch (err) {
            error.Incomplete, error.NoMessage => {
                const n = std.c.read(fd, &read_buf, read_buf.len);
                if (n <= 0) return error.ReadFailed;
                try unpacker.feed(read_buf[0..@intCast(n)]);
                continue;
            },
            else => return err,
        };
        return obj;
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
            \\Usage: hellonvim <path-to-nvim-unix-socket>
            \\
            \\Connects to a running Neovim instance via Unix domain socket and performs RPC calls.
            \\
            \\Example:
            \\  1. In a separate terminal, start Neovim listening on a socket:
            \\     nvim --headless --listen /tmp/nvim.sock
            \\
            \\  2. Run this example:
            \\     zig build run-hellonvim -- /tmp/nvim.sock
            \\
        );
        try stdout_writer.flush();
        return;
    }

    const socket_path = args[1];

    const addr = Io.net.UnixAddress.init(socket_path) catch |err| {
        std.log.err("Invalid socket path '{s}': {s}", .{ socket_path, @errorName(err) });
        return err;
    };

    const stream = addr.connect(io) catch |err| {
        std.log.err("Failed to connect to Neovim socket at '{s}': {s}", .{ socket_path, @errorName(err) });
        return err;
    };
    defer stream.close(io);

    const fd = stream.socket.handle;

    _ = try stdout_writer.write("Successfully connected to Neovim at: ");
    _ = try stdout_writer.write(socket_path);
    _ = try stdout_writer.write("\n\n");
    try stdout_writer.flush();

    var session = msgpack.RpcSession.init(arena);
    defer session.deinit();

    // One unpacker for the lifetime of the connection. Responses arrive as a
    // stream of bytes; readNextObject feeds chunks in and drains complete
    // objects out, so fragmented or back-to-back messages are handled correctly.
    var unpacker = try msgpack.Unpacker.init(arena, .{});
    defer unpacker.deinit();

    // Call 1: Evaluate 2 + 2
    {
        var p = msgpack.Packer.init(arena);
        defer p.deinit();

        var expr = "2 + 2".*;
        const params = [_]msgpack.MsgPackObject{
            .{ .string = &expr },
        };

        const msgid = try session.packRequest(&p, "nvim_eval", &params);

        _ = try stdout_writer.write("--> [Request]  msgid=");
        var id_buf: [16]u8 = undefined;
        _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{msgid}));
        _ = try stdout_writer.write(" method=\"nvim_eval\" params=[\"2 + 2\"]\n");
        try stdout_writer.flush();

        const written = std.c.write(fd, p.getSlice().ptr, p.getSlice().len);
        if (written < 0) return error.WriteFailed;

        const obj = try readNextObject(fd, &unpacker);
        defer msgpack.freeObject(arena, obj);

        const rpc_msg = try msgpack.rpc.parseMessage(obj);
        switch (rpc_msg) {
            .response => |res| {
                _ = try stdout_writer.write("<-- [Response] msgid=");
                _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{res.msgid}));
                if (res.@"error") |err_obj| {
                    _ = try stdout_writer.write(" error=");
                    try printObject(stdout_writer, err_obj);
                }
                if (res.result) |res_obj| {
                    _ = try stdout_writer.write(" result=");
                    try printObject(stdout_writer, res_obj);
                }
                _ = try stdout_writer.write("\n\n");
                try stdout_writer.flush();
            },
            else => {
                _ = try stdout_writer.write("<-- Unexpected message received\n\n");
                try stdout_writer.flush();
            },
        }
    }

    // Call 2: Greet Neovim and query version
    {
        var p = msgpack.Packer.init(arena);
        defer p.deinit();

        var expr = "'Hello from Zig! Running Neovim version ' . v:version".*;
        const params = [_]msgpack.MsgPackObject{
            .{ .string = &expr },
        };

        const msgid = try session.packRequest(&p, "nvim_eval", &params);

        _ = try stdout_writer.write("--> [Request]  msgid=");
        var id_buf: [16]u8 = undefined;
        _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{msgid}));
        _ = try stdout_writer.write(" method=\"nvim_eval\" params=[\"'Hello from Zig! ...'\"]\n");
        try stdout_writer.flush();

        const written = std.c.write(fd, p.getSlice().ptr, p.getSlice().len);
        if (written < 0) return error.WriteFailed;

        const obj = try readNextObject(fd, &unpacker);
        defer msgpack.freeObject(arena, obj);

        const rpc_msg = try msgpack.rpc.parseMessage(obj);
        switch (rpc_msg) {
            .response => |res| {
                _ = try stdout_writer.write("<-- [Response] msgid=");
                _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{res.msgid}));
                if (res.@"error") |err_obj| {
                    _ = try stdout_writer.write(" error=");
                    try printObject(stdout_writer, err_obj);
                }
                if (res.result) |res_obj| {
                    _ = try stdout_writer.write(" result=");
                    try printObject(stdout_writer, res_obj);
                }
                _ = try stdout_writer.write("\n\n");
                try stdout_writer.flush();
            },
            else => {
                _ = try stdout_writer.write("<-- Unexpected message received\n\n");
                try stdout_writer.flush();
            },
        }
    }

    // Call 3: Execute a command in Neovim
    {
        var p = msgpack.Packer.init(arena);
        defer p.deinit();

        var cmd = "let g:zig_msgpack_greeting = 'Greetings from zig-msgpack library!'".*;
        const params = [_]msgpack.MsgPackObject{
            .{ .string = &cmd },
        };

        const msgid = try session.packRequest(&p, "nvim_command", &params);

        _ = try stdout_writer.write("--> [Request]  msgid=");
        var id_buf: [16]u8 = undefined;
        _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{msgid}));
        _ = try stdout_writer.write(" method=\"nvim_command\" params=[\"let g:zig_msgpack_greeting = ...\"]\n");
        try stdout_writer.flush();

        const written = std.c.write(fd, p.getSlice().ptr, p.getSlice().len);
        if (written < 0) return error.WriteFailed;

        const obj = try readNextObject(fd, &unpacker);
        defer msgpack.freeObject(arena, obj);

        const rpc_msg = try msgpack.rpc.parseMessage(obj);
        switch (rpc_msg) {
            .response => |res| {
                _ = try stdout_writer.write("<-- [Response] msgid=");
                _ = try stdout_writer.write(try std.fmt.bufPrint(&id_buf, "{d}", .{res.msgid}));
                _ = try stdout_writer.write(" (command executed successfully)\n");
                try stdout_writer.flush();
            },
            else => {
                _ = try stdout_writer.write("<-- Unexpected message received\n");
                try stdout_writer.flush();
            },
        }
    }
}
