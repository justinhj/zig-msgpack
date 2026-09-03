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
    array: []MsgPackObject,
    integer: i64,
    string: []u8,
};

pub fn freeObject(allocator: std.mem.Allocator, obj: MsgPackObject) void {
    switch (obj) {
        .array => |arr| {
            for (arr) |item| {
                freeObject(allocator, item);
            }
            allocator.free(arr);
        },
        .string => |str| allocator.free(str),
        else => {},
    }
}

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

        const saved_start = self.ring.start;
        const saved_count = self.ring.count;

        return self.parseObject() catch |err| switch (err) {
            error.EndOfBuffer, error.Incomplete => {
                // Restore ring buffer state so next feed can resume
                self.ring.start = saved_start;
                self.ring.count = saved_count;
                return MsgPackError.Incomplete;
            },
            else => return err,
        };
    }

    fn parseObject(self: *Self) MsgPackError!MsgPackObject {
        const next_char = self.ring.get() catch |err| switch (err) {
            error.EndOfBuffer => return MsgPackError.Incomplete,
            else => return err,
        };

        return switch (next_char) {
            // positive fixint: 0x00 - 0x7f (0xxxxxxx)
            0x00...0x7f => MsgPackObject{ .integer = next_char },

            // fixarray: 0x90 - 0x9f (1001xxxx)
            0x90...0x9f => {
                const item_count = next_char - 0x90;
                const array = try self.allocator.alloc(MsgPackObject, item_count);
                var parsed: usize = 0;
                errdefer {
                    for (array[0..parsed]) |item| {
                        freeObject(self.allocator, item);
                    }
                    self.allocator.free(array);
                }

                while (parsed < item_count) : (parsed += 1) {
                    array[parsed] = try self.parseObject();
                }
                return MsgPackObject{ .array = array };
            },

            // Unhandled formats for this stage
            else => MsgPackError.Incomplete,
        };
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
        const array = try allocator.alloc(MsgPackObject, input[i] - 0x90);
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

test "Unpacker.next: empty buffer returns NoMessage" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: single positive fixint" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0x00 = 0, 0x2a = 42, 0x7f = 127
    try unpacker.feed("\x00\x2a\x7f");

    const obj1 = try unpacker.next();
    try std.testing.expectEqual(@as(i64, 0), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expectEqual(@as(i64, 42), obj2.integer);

    const obj3 = try unpacker.next();
    try std.testing.expectEqual(@as(i64, 127), obj3.integer);

    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: empty fixarray" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0x90 = fixarray of 0 elements
    try unpacker.feed("\x90");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 0), obj.array.len);
    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: fixarray of positive fixints" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0x93 = fixarray of 3 elements: [1, 2, 3]
    try unpacker.feed("\x93\x01\x02\x03");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 3), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), obj.array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), obj.array[2].integer);
    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: nested fixarrays" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // [[1, 2], [3, 4]]
    // 0x92 (outer array of 2) -> 0x92 (inner array of 2: 1, 2) -> 0x92 (inner array of 2: 3, 4)
    try unpacker.feed("\x92\x92\x01\x02\x92\x03\x04");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 2), obj.array.len);

    const inner1 = obj.array[0];
    try std.testing.expect(inner1 == .array);
    try std.testing.expectEqual(@as(usize, 2), inner1.array.len);
    try std.testing.expectEqual(@as(i64, 1), inner1.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), inner1.array[1].integer);

    const inner2 = obj.array[1];
    try std.testing.expect(inner2 == .array);
    try std.testing.expectEqual(@as(usize, 2), inner2.array.len);
    try std.testing.expectEqual(@as(i64, 3), inner2.array[0].integer);
    try std.testing.expectEqual(@as(i64, 4), inner2.array[1].integer);

    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: sequential multiple messages" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0x05 (int 5), 0x92\x01\x02 (array [1, 2]), 0x0a (int 10)
    try unpacker.feed("\x05\x92\x01\x02\x0a");

    const obj1 = try unpacker.next();
    try std.testing.expectEqual(@as(i64, 5), obj1.integer);

    const obj2 = try unpacker.next();
    defer freeObject(allocator, obj2);
    try std.testing.expect(obj2 == .array);
    try std.testing.expectEqual(@as(usize, 2), obj2.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj2.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), obj2.array[1].integer);

    const obj3 = try unpacker.next();
    try std.testing.expectEqual(@as(i64, 10), obj3.integer);

    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: incomplete array followed by feeds to complete" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 1. Feed only the array header (expects 3 items)
    try unpacker.feed("\x93");
    try std.testing.expectError(error.Incomplete, unpacker.next());

    // 2. Feed 2 items (still missing 1)
    try unpacker.feed("\x01\x02");
    try std.testing.expectError(error.Incomplete, unpacker.next());

    // 3. Feed the 3rd item to complete the array
    try unpacker.feed("\x03");
    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 3), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), obj.array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), obj.array[2].integer);

    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker.next: incomplete nested array followed by feed" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // Outer array expects 2 items, first inner array expects 2 items (only 1 provided)
    try unpacker.feed("\x92\x92\x01");
    try std.testing.expectError(error.Incomplete, unpacker.next());

    // Feed second item of first inner array, and the entire second inner array
    try unpacker.feed("\x02\x92\x03\x04");
    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 2), obj.array.len);

    const inner1 = obj.array[0];
    try std.testing.expectEqual(@as(i64, 1), inner1.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), inner1.array[1].integer);

    const inner2 = obj.array[1];
    try std.testing.expectEqual(@as(i64, 3), inner2.array[0].integer);
    try std.testing.expectEqual(@as(i64, 4), inner2.array[1].integer);

    try std.testing.expectError(error.NoMessage, unpacker.next());
}


