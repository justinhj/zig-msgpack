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

pub const MsgPackMapEntry = struct {
    key: MsgPackObject,
    value: MsgPackObject,
};

pub const MsgPackExtension = struct {
    type: i8,
    data: []u8,
};

pub const MsgPackType = enum {
    nil,
    boolean,
    integer,
    unsigned_integer,
    float32,
    float64,
    string,
    binary,
    array,
    map,
    extension,
};

pub const MsgPackObject = union(MsgPackType) {
    nil: void,
    boolean: bool,
    integer: i64,
    unsigned_integer: u64,
    float32: f32,
    float64: f64,
    string: []u8,
    binary: []u8,
    array: []MsgPackObject,
    map: []MsgPackMapEntry,
    extension: MsgPackExtension,
};

pub fn freeObject(allocator: std.mem.Allocator, obj: MsgPackObject) void {
    switch (obj) {
        .array => |arr| {
            for (arr) |item| {
                freeObject(allocator, item);
            }
            allocator.free(arr);
        },
        .map => |entries| {
            for (entries) |entry| {
                freeObject(allocator, entry.key);
                freeObject(allocator, entry.value);
            }
            allocator.free(entries);
        },
        .string => |str| allocator.free(str),
        .binary => |bin| allocator.free(bin),
        .extension => |ext| allocator.free(ext.data),
        else => {},
    }
}

pub const MsgPackError = error{
    Incomplete, // If you run out of bytes while parsing
    NoMessage,
    UsedNeverUsed,
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

    fn getNext(self: *Self) MsgPackError!u8 {
        return self.ring.get() catch |err| switch (err) {
            error.EndOfBuffer => return MsgPackError.Incomplete,
            else => return err,
        };
    }

    fn parseObject(self: *Self) MsgPackError!MsgPackObject {
        const next_char = try self.getNext();

        return switch (next_char) {
            // positive fixint
            0x00...0x7f => MsgPackObject{ .integer = next_char },

            // fixmap
            0x80...0x8f => {
                const item_count = next_char - 0x80;
                const map = try self.allocator.alloc(MsgPackMapEntry, item_count);
                var parsed: usize = 0;
                while (parsed < item_count) : (parsed += 1) {
                    const key = try self.parseObject();
                    const value = try self.parseObject();
                    const entry = MsgPackMapEntry{.key = key, .value = value};
                    map[parsed] = entry;
                }
                return MsgPackObject{.map = map};

            },  

            // fixarray
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

            // fixstr
            0xa0...0xbf => {
                const length = next_char - 0xa0;
                const str = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(str);

                for (0..length) |i| {
                    str[i] = try self.ring.get();
                }
                return MsgPackObject{ .string = str };
            },

            // str 8
            0xd9 => {
                const length = try self.ring.get();
                const str = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(str);

                for (0..length) |i| {
                    str[i] = try self.ring.get();
                }
                return MsgPackObject{ .string = str };
            },

            // str 16
            0xda => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const length = std.mem.readInt(u16, &[2]u8{ l1, l2 }, .big);
                const str = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(str);

                for (0..length) |i| {
                    str[i] = try self.ring.get();
                }
                return MsgPackObject{ .string = str };
            },

            // str 32
            0xdb => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const length = std.mem.readInt(u32, &[4]u8{ l1, l2, l3, l4 }, .big);
                const str = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(str);

                for (0..length) |i| {
                    str[i] = try self.ring.get();
                }
                return MsgPackObject{ .string = str };
            },

            // nil
            0xc0 => {
                return MsgPackObject{.nil = {}};
            },

            // (never used)
            0xc1 => {
                return MsgPackError.UsedNeverUsed;
            },

            // false
            0xc2 => {
                return MsgPackObject{.boolean = false};
            },

            // true
            0xc3 => {
                return MsgPackObject{.boolean = true};
            },

            // bin 8
            0xc4 => {
                const length = try self.getNext();
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }
                return MsgPackObject{ .binary = bin };
            },

            // bin 16
            0xc5 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const length = std.mem.readInt(u16, &[2]u8{ l1, l2 }, .big);
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }

                return MsgPackObject{ .binary = bin };
            },

            // bin 32
            0xc6 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const length = std.mem.readInt(u32, &[4]u8{ l1, l2, l3, l4 }, .big);
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }

                return MsgPackObject{ .binary = bin };
            },

            // fixext 1
            0xd4 => {
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const data = try self.ring.get();
                const bin = try self.allocator.alloc(u8, 1);
                bin[0] = data;
                errdefer self.allocator.free(bin);
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // fixext 2
            0xd5 => {
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, 2);
                errdefer self.allocator.free(bin);

                for (0..2) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // fixext 4
            0xd6 => {
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, 4);
                errdefer self.allocator.free(bin);

                for (0..4) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // fixext 8
            0xd7 => {
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, 8);
                errdefer self.allocator.free(bin);

                for (0..8) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // fixext 16
            0xd8 => {
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, 16);
                errdefer self.allocator.free(bin);

                for (0..16) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // ext 8
            0xc7 => {
                const length = try self.getNext();
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // ext 16
            0xc8 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const length = std.mem.readInt(u16, &[2]u8{ l1, l2 }, .big);
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },
            
            // ext 32
            0xc9 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const length = std.mem.readInt(u32, &[4]u8{ l1, l2, l3, l4 }, .big);
                const ext_type = @as(i8, @bitCast(try self.getNext()));
                const bin = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(bin);

                for (0..length) |i| {
                    bin[i] = try self.ring.get();
                }
                const ext = MsgPackExtension{.type = ext_type, .data = bin};
                return MsgPackObject{ .extension = ext };
            },

            // float 32
            0xca => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const val: f32 = @bitCast(std.mem.readInt(u32, &[4]u8{ l1, l2, l3, l4 }, .big));
                return MsgPackObject{.float32 = val};
            },

            // float 64
            0xcb => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const l5 = try self.getNext();
                const l6 = try self.getNext();
                const l7 = try self.getNext();
                const l8 = try self.getNext();
                const val: f64 = @bitCast(std.mem.readInt(u64, &[8]u8{ l1, l2, l3, l4, l5, l6, l7, l8 }, .big));
                return MsgPackObject{.float64 = val};
            },

            // uint 8
            0xcc => {
                const val = try self.getNext();
                return MsgPackObject{.integer = val};
            },

            // uint 16
            0xcd => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const val = std.mem.readInt(i16, &[2]u8{ l1, l2 }, .big);
                return MsgPackObject{.integer = val};
            },

            // uint 32
            0xce => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const val = std.mem.readInt(i32, &[4]u8{ l1, l2, l3, l4 }, .big);
                return MsgPackObject{.integer = val};
            },

            // uint 64
            0xcf => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const l5 = try self.getNext();
                const l6 = try self.getNext();
                const l7 = try self.getNext();
                const l8 = try self.getNext();
                const val = std.mem.readInt(u64, &[8]u8{ l1, l2, l3, l4, l5, l6, l7, l8 }, .big);
                return MsgPackObject{.unsigned_integer = val};
            },

            // int 8
            0xd0 => {
                const val = try self.getNext();
                return MsgPackObject{.integer = val};
            },

            // int 16
            0xd1 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const val = std.mem.readInt(i16, &[2]u8{ l1, l2 }, .big);
                return MsgPackObject{.integer = val};
            },

            // int 32
            0xd2 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const val = std.mem.readInt(i32, &[4]u8{ l1, l2, l3, l4 }, .big);
                return MsgPackObject{.integer = val};
            },

            // int 64
            0xd3 => {
                const l1 = try self.getNext();
                const l2 = try self.getNext();
                const l3 = try self.getNext();
                const l4 = try self.getNext();
                const l5 = try self.getNext();
                const l6 = try self.getNext();
                const l7 = try self.getNext();
                const l8 = try self.getNext();
                const val = std.mem.readInt(i64, &[8]u8{ l1, l2, l3, l4, l5, l6, l7, l8 }, .big);
                return MsgPackObject{.integer = val};
            },

            // Unhandled formats for this stage
            else => MsgPackError.Incomplete,
        };
    }
};

test "unpack command" {
    const gpa = std.testing.allocator;
    var unpacker = try Unpacker.init(gpa, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    const test_input = "\x94\x00\x01\xa9nvim_eval\x91\xa52 + 2";
    try unpacker.feed(test_input);

    const obj = try unpacker.next();
    defer freeObject(gpa, obj);

    // Verify outer array: [0, 1, "nvim_eval", ["2 + 2"]]
    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 4), obj.array.len);

    // [0] = 0
    try std.testing.expectEqual(@as(i64, 0), obj.array[0].integer);

    // [1] = 1
    try std.testing.expectEqual(@as(i64, 1), obj.array[1].integer);

    // [2] = "nvim_eval"
    try std.testing.expect(obj.array[2] == .string);
    try std.testing.expectEqualStrings("nvim_eval", obj.array[2].string);

    // [3] = ["2 + 2"]
    const params = obj.array[3];
    try std.testing.expect(params == .array);
    try std.testing.expectEqual(@as(usize, 1), params.array.len);
    try std.testing.expect(params.array[0] == .string);
    try std.testing.expectEqualStrings("2 + 2", params.array[0].string);

    // End of buffer
    try std.testing.expectError(error.NoMessage, unpacker.next());
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

// =========================================================================
// Tests for Unimplemented MsgPack Formats (TDD)
// =========================================================================

// --- Nil Format ---
test "Unpacker: nil format (0xc0)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try unpacker.feed("\xc0");
    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .nil);
}

// --- Bool Format Family ---
test "Unpacker: bool false (0xc2) and true (0xc3)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try unpacker.feed("\xc2\xc3");

    const obj_false = try unpacker.next();
    defer freeObject(allocator, obj_false);
    try std.testing.expect(obj_false == .boolean);
    try std.testing.expectEqual(false, obj_false.boolean);

    const obj_true = try unpacker.next();
    defer freeObject(allocator, obj_true);
    try std.testing.expect(obj_true == .boolean);
    try std.testing.expectEqual(true, obj_true.boolean);
}

// --- Negative Fixint (0xe0 - 0xff) ---
test "Unpacker: negative fixint" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xff = -1, 0xe0 = -32, 0xf0 = -16
    try unpacker.feed("\xff\xe0\xf0");

    const obj1 = try unpacker.next();
    try std.testing.expect(obj1 == .integer);
    try std.testing.expectEqual(@as(i64, -1), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expect(obj2 == .integer);
    try std.testing.expectEqual(@as(i64, -32), obj2.integer);

    const obj3 = try unpacker.next();
    try std.testing.expect(obj3 == .integer);
    try std.testing.expectEqual(@as(i64, -16), obj3.integer);
}

// --- Unsigned Int Family (uint8, uint16, uint32, uint64) ---
test "Unpacker: uint 8 (0xcc)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xcc followed by 0x80 (128) and 0xff (255)
    try unpacker.feed("\xcc\x80\xcc\xff");

    const obj1 = try unpacker.next();
    try std.testing.expect(obj1 == .integer);
    try std.testing.expectEqual(@as(i64, 128), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expect(obj2 == .integer);
    try std.testing.expectEqual(@as(i64, 255), obj2.integer);
}

test "Unpacker: uint 16 (0xcd)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xcd followed by 0x01, 0x00 (256) and 0xff, 0xff (65535)
    try unpacker.feed("\xcd\x01\x00\xcd\xff\xff");

    const obj1 = try unpacker.next();
    try std.testing.expect(obj1 == .integer);
    try std.testing.expectEqual(@as(i64, 256), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expect(obj2 == .integer);
    try std.testing.expectEqual(@as(i64, 65535), obj2.integer);
}

test "Unpacker: uint 32 (0xce)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xce followed by 0x00, 0x01, 0x00, 0x00 (65536)
    try unpacker.feed("\xce\x00\x01\x00\x00");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .integer);
    try std.testing.expectEqual(@as(i64, 65536), obj.integer);
}

test "Unpacker: uint 64 (0xcf)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xcf followed by 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 (2^63, exceeds max i64)
    try unpacker.feed("\xcf\x80\x00\x00\x00\x00\x00\x00\x00");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .unsigned_integer);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), obj.unsigned_integer);
}

// --- Signed Int Family (int8, int16, int32, int64) ---
test "Unpacker: int 8 (0xd0)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd0 followed by 0x80 (-128) and 0x7f (127)
    try unpacker.feed("\xd0\x80\xd0\x7f");

    const obj1 = try unpacker.next();
    try std.testing.expect(obj1 == .integer);
    try std.testing.expectEqual(@as(i64, -128), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expect(obj2 == .integer);
    try std.testing.expectEqual(@as(i64, 127), obj2.integer);
}

test "Unpacker: int 16 (0xd1)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd1 followed by 0x80, 0x00 (-32768) and 0x7f, 0xff (32767)
    try unpacker.feed("\xd1\x80\x00\xd1\x7f\xff");

    const obj1 = try unpacker.next();
    try std.testing.expect(obj1 == .integer);
    try std.testing.expectEqual(@as(i64, -32768), obj1.integer);

    const obj2 = try unpacker.next();
    try std.testing.expect(obj2 == .integer);
    try std.testing.expectEqual(@as(i64, 32767), obj2.integer);
}

test "Unpacker: int 32 (0xd2)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd2 followed by 0x80, 0x00, 0x00, 0x00 (-2147483648)
    try unpacker.feed("\xd2\x80\x00\x00\x00");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .integer);
    try std.testing.expectEqual(@as(i64, -2147483648), obj.integer);
}

test "Unpacker: int 64 (0xd3)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd3 followed by -9223372036854775808 (min i64: 0x8000000000000000)
    try unpacker.feed("\xd3\x80\x00\x00\x00\x00\x00\x00\x00");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .integer);
    try std.testing.expectEqual(std.math.minInt(i64), obj.integer);
}

// --- Float Family (float32, float64) ---
test "Unpacker: float 32 (0xca)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xca followed by 0x40, 0x20, 0x00, 0x00 (2.5f)
    try unpacker.feed("\xca\x40\x20\x00\x00");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .float32);
    try std.testing.expectEqual(@as(f32, 2.5), obj.float32);
}

test "Unpacker: float 64 (0xcb)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xcb followed by 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18 (3.141592653589793)
    try unpacker.feed("\xcb\x40\x09\x21\xfb\x54\x44\x2d\x18");

    const obj = try unpacker.next();
    try std.testing.expect(obj == .float64);
    try std.testing.expectEqual(@as(f64, 3.141592653589793), obj.float64);
}

// --- String Format Family (str8, str16, str32) ---
test "Unpacker: str 8 (0xd9)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256 });
    defer unpacker.deinit();

    // 0xd9, length 32 (0x20), followed by 32 'X's (above fixstr limit of 31)
    const payload = "X" ** 32;
    try unpacker.feed("\xd9\x20" ++ payload);

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .string);
    try std.testing.expectEqualStrings(payload, obj.string);
}

test "Unpacker: str 16 (0xda)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 512 });
    defer unpacker.deinit();

    // 0xda, length 256 (0x0100), followed by 256 'Y's
    const payload = "Y" ** 256;
    try unpacker.feed("\xda\x01\x00" ++ payload);

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .string);
    try std.testing.expectEqualStrings(payload, obj.string);
}

test "Unpacker: str 32 (0xdb)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xdb, length 5 (0x00000005), followed by "hello"
    try unpacker.feed("\xdb\x00\x00\x00\x05hello");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .string);
    try std.testing.expectEqualStrings("hello", obj.string);
}

// --- Binary Format Family (bin8, bin16, bin32) ---
test "Unpacker: bin 8 (0xc4)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc4, length 4, followed by 4 raw bytes
    try unpacker.feed("\xc4\x04\x01\x02\x03\x04");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .binary);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, obj.binary);
}

test "Unpacker: bin 16 (0xc5)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc5, length 3 (0x0003), followed by 3 raw bytes
    try unpacker.feed("\xc5\x00\x03\xaa\xbb\xcc");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .binary);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0xcc }, obj.binary);
}

test "Unpacker: bin 32 (0xc6)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc6, length 2 (0x00000002), followed by 2 raw bytes
    try unpacker.feed("\xc6\x00\x00\x00\x02\xde\xad");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .binary);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad }, obj.binary);
}

// --- Array Extended Family (array16, array32) ---
test "Unpacker: array 16 (0xdc)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xdc, length 16 (0x0010, above fixarray limit of 15), 16 positive fixints 0x01
    try unpacker.feed("\xdc\x00\x10" ++ ("\x01" ** 16));

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 16), obj.array.len);
    for (obj.array) |item| {
        try std.testing.expectEqual(@as(i64, 1), item.integer);
    }
}

test "Unpacker: array 32 (0xdd)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xdd, length 2 (0x00000002), followed by [1, 2]
    try unpacker.feed("\xdd\x00\x00\x00\x02\x01\x02");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 2), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), obj.array[1].integer);
}

// --- Map Format Family (fixmap, map16, map32) ---
test "Unpacker: empty fixmap (0x80)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try unpacker.feed("\x80");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .map);
    try std.testing.expectEqual(@as(usize, 0), obj.map.len);
}

test "Unpacker: fixmap with key-value pairs (0x82)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // fixmap of 2 entries: {"a": 1, "b": 2}
    // 0x82, 0xa1 'a', 0x01, 0xa1 'b', 0x02
    try unpacker.feed("\x82\xa1a\x01\xa1b\x02");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .map);
    try std.testing.expectEqual(@as(usize, 2), obj.map.len);

    try std.testing.expectEqualStrings("a", obj.map[0].key.string);
    try std.testing.expectEqual(@as(i64, 1), obj.map[0].value.integer);

    try std.testing.expectEqualStrings("b", obj.map[1].key.string);
    try std.testing.expectEqual(@as(i64, 2), obj.map[1].value.integer);
}

test "Unpacker: map 16 (0xde)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xde, 1 entry (0x0001): {"x": 5}
    try unpacker.feed("\xde\x00\x01\xa1x\x05");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .map);
    try std.testing.expectEqual(@as(usize, 1), obj.map.len);
    try std.testing.expectEqualStrings("x", obj.map[0].key.string);
    try std.testing.expectEqual(@as(i64, 5), obj.map[0].value.integer);
}

test "Unpacker: map 32 (0xdf)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xdf, 1 entry (0x00000001): {"y": 9}
    try unpacker.feed("\xdf\x00\x00\x00\x01\xa1y\x09");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .map);
    try std.testing.expectEqual(@as(usize, 1), obj.map.len);
    try std.testing.expectEqualStrings("y", obj.map[0].key.string);
    try std.testing.expectEqual(@as(i64, 9), obj.map[0].value.integer);
}

// --- Extension Format Family (fixext, ext) ---
test "Unpacker: fixext 1 (0xd4)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd4, type 0x01, data 0xaa
    try unpacker.feed("\xd4\x01\xaa");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 1), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xaa}, obj.extension.data);
}

test "Unpacker: fixext 2 (0xd5)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd5, type 0x02, data 0xaa, 0xbb
    try unpacker.feed("\xd5\x02\xaa\xbb");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 2), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, obj.extension.data);
}

test "Unpacker: fixext 4 (0xd6)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd6, type 0x03, data 4 bytes
    try unpacker.feed("\xd6\x03\x01\x02\x03\x04");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 3), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, obj.extension.data);
}

test "Unpacker: fixext 8 (0xd7)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd7, type 0x04, data 8 bytes
    try unpacker.feed("\xd7\x04\x01\x02\x03\x04\x05\x06\x07\x08");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 4), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, obj.extension.data);
}

test "Unpacker: fixext 16 (0xd8)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xd8, type 0x05, data 16 bytes
    try unpacker.feed("\xd8\x05" ++ ("\x42" ** 16));

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 5), obj.extension.type);
    try std.testing.expectEqualSlices(u8, "\x42" ** 16, obj.extension.data);
}

test "Unpacker: ext 8 (0xc7)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc7, length 3, type 10 (0x0a), data 3 bytes
    try unpacker.feed("\xc7\x03\x0a\x01\x02\x03");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 10), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, obj.extension.data);
}

test "Unpacker: ext 16 (0xc8)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc8, length 2 (0x0002), type 11 (0x0b), data 2 bytes
    try unpacker.feed("\xc8\x00\x02\x0b\xde\xad");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 11), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad }, obj.extension.data);
}

test "Unpacker: ext 32 (0xc9)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // 0xc9, length 1 (0x00000001), type 12 (0x0c), data 1 byte
    try unpacker.feed("\xc9\x00\x00\x00\x01\x0c\xff");

    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .extension);
    try std.testing.expectEqual(@as(i8, 12), obj.extension.type);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, obj.extension.data);
}



