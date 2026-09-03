const std = @import("std");
const Io = std.Io;

const zig_msgpack = @import("zig_msgpack");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    _ = try stdout_writer.write("Hello, World!\n");

    try stdout_writer.flush(); // Don't forget to flush!
}

//// Unpacker implementation 

const RingBuffer = zig_msgpack.RingBuffer;
const RingBufferError = zig_msgpack.RingBufferError;

pub const MsgPackType = enum {
    array,
    integer,
    string,
};

pub const MsgPackObject = union(MsgPackType) {
    array: []*MsgPackObject,
    integer: i64,
    string: []u8,
};

pub const MsgPackError = error{
    Incomplete, // If you run out of bytes while parsing
    NoMessage,
} || RingBufferError;

pub const Unpacker = struct {
    pub const Options = struct {
        max_buffer_size: usize = 1024 * 1024, // 1MB default
    };

    const Self = @This();
    allocator: std.mem.Allocator,
    ring: RingBuffer,

    pub fn init(allocator: std.mem.Allocator, options: Options) MsgPackError!Self {
        const ring = try RingBuffer.init(allocator, .{ .max_buffer_size = options.max_buffer_size });
        return Self{
            .allocator = allocator,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ring.deinit();
    }

    pub fn feed(self: *Self, data: []const u8) MsgPackError!void {
        try self.ring.feed(data);
    }

    pub fn next(self: *Self) MsgPackError!MsgPackObject {
        // When the buffer is empty
        if (self.ring.count == 0) {
            return MsgPackError.NoMessage;
        }

        // var obj: MsgPackObject = undefined;

        // if (input[i] >= 0x94 and input[i] <= 0x9f) {
        //     const array = try allocator.alloc(*MsgPackObject, input[i] - 0x90);
        //     obj = MsgPackObject{ .array = array };
        // } 
        return MsgPackError.Incomplete; // TEMP
    }
};

// Next step: a read_object command that returns an updated buffer offset 
// and a parsed object. It should return an incomplete error if it runs out of 
// data to parse.
// Unpack should call read object. This allows re-entrant behavior to handle 
// nested objects like arrays and arrays of arrays.

// Unpack the msgpack data to 
pub fn unpack(allocator: std.mem.Allocator, input: []const u8) !MsgPackObject {
    // 94 00 = 1001 0100 0000 0000 
    const i :usize = 0;
    if (input.len == 0) {
        return MsgPackError.Incomplete;
    }

    var obj: MsgPackObject = undefined;

    // maximum number of elements of an Array object is `(2^32)-1`
    // Check for fixarray (up to 15 elements)
    if (input[i] >= 0x94 and input[i] <= 0x9f) {
        const array = try allocator.alloc(*MsgPackObject, input[i] - 0x90);
        obj = MsgPackObject{ .array = array };
    } 
    return obj;
} 

test "unpack command" {
    const gpa = std.testing.allocator;
    const test_input = "\x94\x00\x01\xa9nvim_eval\x91\xa52 + 2";
    // Output [0, 1, 'nvim_eval', ['2 + 2']]
    const obj = try unpack(gpa, test_input);
    try std.testing.expect(obj == .array);
    switch (obj) {
        .array => gpa.free(obj.array),
        else => {}
    }

}

test "Unpacker: construction and feed delegation to RingBuffer" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try std.testing.expectEqual(@as(usize, 128), unpacker.ring.buffer_size);
    try std.testing.expectEqual(@as(usize, 0), unpacker.ring.count);

    try unpacker.feed("hello world");
    try std.testing.expectEqual(@as(usize, 11), unpacker.ring.count);
    try std.testing.expectEqualSlices(u8, "hello world", unpacker.ring.buffer[0..11]);
}

test "Unpacker: invalid buffer size" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidBufferSize, Unpacker.init(allocator, .{ .max_buffer_size = 0 }));
}

test "Unpacker: overflow forwards NoRoomInBuffer" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 10 });
    defer unpacker.deinit();

    try std.testing.expectError(error.NoRoomInBuffer, unpacker.feed("A" ** 11));
}

