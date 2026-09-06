const std = @import("std");
const types = @import("types.zig");
const packer = @import("packer.zig");
const unpacker = @import("unpacker.zig");

pub const MsgPackObject = types.MsgPackObject;
pub const MsgPackType = types.MsgPackType;
pub const freeObject = types.freeObject;

pub const RpcError = error{
    InvalidMessageFormat,
    InvalidMessageType,
    InvalidMsgId,
    InvalidMethod,
    InvalidParams,
    UnexpectedResponseType,
};

pub const MessageType = enum(u8) {
    request = 0,
    response = 1,
    notification = 2,
};

pub const Request = struct {
    msgid: u32,
    method: []const u8,
    params: []const MsgPackObject,
};

pub const Response = struct {
    msgid: u32,
    @"error": ?MsgPackObject,
    result: ?MsgPackObject,
};

pub const Notification = struct {
    method: []const u8,
    params: []const MsgPackObject,
};

pub const Message = union(MessageType) {
    request: Request,
    response: Response,
    notification: Notification,
};

/// Parse an unpacked MsgPackObject as a MessagePack-RPC message.
/// The resulting Message borrows slices directly from `obj` (zero-copy).
pub fn parseMessage(obj: MsgPackObject) RpcError!Message {
    if (obj != .array) return RpcError.InvalidMessageFormat;
    const arr = obj.array;

    if (arr.len < 3 or arr.len > 4) return RpcError.InvalidMessageFormat;

    const raw_type: u64 = switch (arr[0]) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else return RpcError.InvalidMessageType,
        .unsigned_integer => |u| u,
        else => return RpcError.InvalidMessageType,
    };

    switch (raw_type) {
        0 => {
            // Request: [0, msgid, method, params]
            if (arr.len != 4) return RpcError.InvalidMessageFormat;

            const msgid = try parseMsgId(arr[1]);
            if (arr[2] != .string) return RpcError.InvalidMethod;
            if (arr[3] != .array) return RpcError.InvalidParams;

            return Message{
                .request = .{
                    .msgid = msgid,
                    .method = arr[2].string,
                    .params = arr[3].array,
                },
            };
        },
        1 => {
            // Response: [1, msgid, error, result]
            if (arr.len != 4) return RpcError.InvalidMessageFormat;

            const msgid = try parseMsgId(arr[1]);
            const err: ?MsgPackObject = if (arr[2] == .nil) null else arr[2];
            const res: ?MsgPackObject = if (arr[3] == .nil) null else arr[3];

            return Message{
                .response = .{
                    .msgid = msgid,
                    .@"error" = err,
                    .result = res,
                },
            };
        },
        2 => {
            // Notification: [2, method, params]
            if (arr.len != 3) return RpcError.InvalidMessageFormat;

            if (arr[1] != .string) return RpcError.InvalidMethod;
            if (arr[2] != .array) return RpcError.InvalidParams;

            return Message{
                .notification = .{
                    .method = arr[1].string,
                    .params = arr[2].array,
                },
            };
        },
        else => return RpcError.InvalidMessageType,
    }
}

fn parseMsgId(obj: MsgPackObject) RpcError!u32 {
    return switch (obj) {
        .integer => |i| {
            if (i >= 0 and i <= std.math.maxInt(u32)) {
                return @as(u32, @intCast(i));
            } else {
                return RpcError.InvalidMsgId;
            }
        },
        .unsigned_integer => |u| {
            if (u <= std.math.maxInt(u32)) {
                return @as(u32, @intCast(u));
            } else {
                return RpcError.InvalidMsgId;
            }
        },
        else => RpcError.InvalidMsgId,
    };
}

/// Serialize a MessagePack-RPC Request: [0, msgid, method, params]
pub fn packRequest(writer: anytype, msgid: u32, method: []const u8, params: []const MsgPackObject) !void {
    try packer.packArrayHeader(writer, 4);
    try packer.packInt(writer, @as(u8, 0));
    try packer.packUInt(writer, msgid);
    try packer.packString(writer, method);
    try packer.packArrayHeader(writer, params.len);
    for (params) |param| {
        try packer.packObject(writer, param);
    }
}

/// Serialize a MessagePack-RPC Response: [1, msgid, error, result]
pub fn packResponse(writer: anytype, msgid: u32, err: ?MsgPackObject, result: ?MsgPackObject) !void {
    try packer.packArrayHeader(writer, 4);
    try packer.packInt(writer, @as(u8, 1));
    try packer.packUInt(writer, msgid);
    if (err) |e| {
        try packer.packObject(writer, e);
    } else {
        try packer.packNil(writer);
    }
    if (result) |r| {
        try packer.packObject(writer, r);
    } else {
        try packer.packNil(writer);
    }
}

/// Serialize a MessagePack-RPC Notification: [2, method, params]
pub fn packNotification(writer: anytype, method: []const u8, params: []const MsgPackObject) !void {
    try packer.packArrayHeader(writer, 3);
    try packer.packInt(writer, @as(u8, 2));
    try packer.packString(writer, method);
    try packer.packArrayHeader(writer, params.len);
    for (params) |param| {
        try packer.packObject(writer, param);
    }
}

/// Serialize any RpcMessage to writer
pub fn packMessage(writer: anytype, msg: Message) !void {
    switch (msg) {
        .request => |req| try packRequest(writer, req.msgid, req.method, req.params),
        .response => |res| try packResponse(writer, res.msgid, res.@"error", res.result),
        .notification => |notif| try packNotification(writer, notif.method, notif.params),
    }
}

/// Transport-agnostic RPC Session tracking message IDs
pub const Session = struct {
    allocator: std.mem.Allocator,
    next_msgid: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .next_msgid = 1,
        };
    }

    pub fn deinit(self: *Session) void {
        _ = self;
    }

    pub fn nextMsgId(self: *Session) u32 {
        const id = self.next_msgid;
        self.next_msgid +%= 1;
        if (self.next_msgid == 0) self.next_msgid = 1;
        return id;
    }

    /// Pack a request, automatically assigning the next message ID
    pub fn packRequest(self: *Session, writer: anytype, method: []const u8, params: []const MsgPackObject) !u32 {
        const msgid = self.nextMsgId();
        try @import("rpc.zig").packRequest(writer, msgid, method, params);
        return msgid;
    }

    /// Pack a response
    pub fn packResponse(self: *Session, writer: anytype, msgid: u32, err: ?MsgPackObject, result: ?MsgPackObject) !void {
        _ = self;
        try @import("rpc.zig").packResponse(writer, msgid, err, result);
    }

    /// Pack a notification
    pub fn packNotification(self: *Session, writer: anytype, method: []const u8, params: []const MsgPackObject) !void {
        _ = self;
        try @import("rpc.zig").packNotification(writer, method, params);
    }
};

// --------------------------------------------------------------------------
// Unit Tests
// --------------------------------------------------------------------------

test "rpc: pack and parse request roundtrip" {
    const allocator = std.testing.allocator;
    var p = packer.Packer.init(allocator);
    defer p.deinit();

    var param_str = "echo 'zig'".*;
    const params = [_]MsgPackObject{
        .{ .string = &param_str },
    };

    try packRequest(&p, 42, "nvim_command", &params);

    const obj = try unpacker.unpack(allocator, p.getSlice());
    defer freeObject(allocator, obj);

    const msg = try parseMessage(obj);
    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(u32, 42), msg.request.msgid);
    try std.testing.expectEqualStrings("nvim_command", msg.request.method);
    try std.testing.expectEqual(@as(usize, 1), msg.request.params.len);
    try std.testing.expectEqualStrings("echo 'zig'", msg.request.params[0].string);
}

test "rpc: pack and parse response roundtrip (success)" {
    const allocator = std.testing.allocator;
    var p = packer.Packer.init(allocator);
    defer p.deinit();

    try packResponse(&p, 42, null, MsgPackObject{ .integer = 100 });

    const obj = try unpacker.unpack(allocator, p.getSlice());
    defer freeObject(allocator, obj);

    const msg = try parseMessage(obj);
    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(u32, 42), msg.response.msgid);
    try std.testing.expect(msg.response.@"error" == null);
    try std.testing.expect(msg.response.result != null);
    try std.testing.expectEqual(@as(i64, 100), msg.response.result.?.integer);
}

test "rpc: pack and parse response roundtrip (error)" {
    const allocator = std.testing.allocator;
    var p = packer.Packer.init(allocator);
    defer p.deinit();

    var err_str = "Invalid argument".*;
    try packResponse(&p, 7, MsgPackObject{ .string = &err_str }, null);

    const obj = try unpacker.unpack(allocator, p.getSlice());
    defer freeObject(allocator, obj);

    const msg = try parseMessage(obj);
    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(u32, 7), msg.response.msgid);
    try std.testing.expect(msg.response.@"error" != null);
    try std.testing.expectEqualStrings("Invalid argument", msg.response.@"error".?.string);
    try std.testing.expect(msg.response.result == null);
}

test "rpc: pack and parse notification roundtrip" {
    const allocator = std.testing.allocator;
    var p = packer.Packer.init(allocator);
    defer p.deinit();

    var param1 = "grid_resize".*;
    const params = [_]MsgPackObject{
        .{ .string = &param1 },
        .{ .integer = 80 },
        .{ .integer = 24 },
    };

    try packNotification(&p, "redraw", &params);

    const obj = try unpacker.unpack(allocator, p.getSlice());
    defer freeObject(allocator, obj);

    const msg = try parseMessage(obj);
    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("redraw", msg.notification.method);
    try std.testing.expectEqual(@as(usize, 3), msg.notification.params.len);
    try std.testing.expectEqualStrings("grid_resize", msg.notification.params[0].string);
    try std.testing.expectEqual(@as(i64, 80), msg.notification.params[1].integer);
    try std.testing.expectEqual(@as(i64, 24), msg.notification.params[2].integer);
}

test "rpc: packMessage generic union" {
    const allocator = std.testing.allocator;
    var p = packer.Packer.init(allocator);
    defer p.deinit();

    const notif = Message{
        .notification = .{
            .method = "ping",
            .params = &[_]MsgPackObject{},
        },
    };

    try packMessage(&p, notif);

    const obj = try unpacker.unpack(allocator, p.getSlice());
    defer freeObject(allocator, obj);

    const parsed = try parseMessage(obj);
    try std.testing.expect(parsed == .notification);
    try std.testing.expectEqualStrings("ping", parsed.notification.method);
    try std.testing.expectEqual(@as(usize, 0), parsed.notification.params.len);
}

test "rpc: invalid message formats" {
    // Not an array
    {
        const obj = MsgPackObject{ .integer = 0 };
        try std.testing.expectError(RpcError.InvalidMessageFormat, parseMessage(obj));
    }

    // Array too short
    {
        var items = [_]MsgPackObject{ .{ .integer = 0 }, .{ .integer = 1 } };
        const obj = MsgPackObject{ .array = &items };
        try std.testing.expectError(RpcError.InvalidMessageFormat, parseMessage(obj));
    }

    // Invalid message type code (e.g. 99)
    {
        var items = [_]MsgPackObject{ .{ .integer = 99 }, .{ .integer = 1 }, .{ .nil = {} } };
        const obj = MsgPackObject{ .array = &items };
        try std.testing.expectError(RpcError.InvalidMessageType, parseMessage(obj));
    }
}

test "rpc: session message ID generation" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u32, 1), session.nextMsgId());
    try std.testing.expectEqual(@as(u32, 2), session.nextMsgId());
    try std.testing.expectEqual(@as(u32, 3), session.nextMsgId());
}
