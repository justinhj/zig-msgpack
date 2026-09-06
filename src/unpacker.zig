const std = @import("std");
const ringbuffer = @import("ringbuffer.zig");
pub const RingBuffer = ringbuffer.RingBuffer;
pub const RingBufferError = ringbuffer.RingBufferError;

const types = @import("types.zig");
pub const MsgPackMapEntry = types.MsgPackMapEntry;
pub const MsgPackExtension = types.MsgPackExtension;
pub const MsgPackType = types.MsgPackType;
pub const MsgPackObject = types.MsgPackObject;
pub const freeObject = types.freeObject;

pub const MsgPackError = error{
    Incomplete, // If you run out of bytes while parsing
    NoMessage,
    UsedNeverUsed,
    MaxDepthExceeded,
    ValueTooLarge,
    InvalidFormat,
} || RingBufferError || std.mem.Allocator.Error;

pub const SliceReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn readByte(self: *SliceReader) MsgPackError!u8 {
        if (self.pos >= self.buffer.len) return MsgPackError.Incomplete;
        const b = self.buffer[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *SliceReader, dest: []u8) MsgPackError!void {
        if (self.pos + dest.len > self.buffer.len) return MsgPackError.Incomplete;
        @memcpy(dest, self.buffer[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
    }

    pub fn readAvailable(self: *SliceReader, dest: []u8) usize {
        if (self.pos >= self.buffer.len) return 0;
        const available = self.buffer.len - self.pos;
        const n = @min(dest.len, available);
        @memcpy(dest[0..n], self.buffer[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    pub fn readInt(self: *SliceReader, comptime T: type, endian: std.builtin.Endian) MsgPackError!T {
        const size = @sizeOf(T);
        if (self.pos + size > self.buffer.len) return MsgPackError.Incomplete;
        const val = std.mem.readInt(T, self.buffer[self.pos .. self.pos + size][0..size], endian);
        self.pos += size;
        return val;
    }
};

pub const RingReader = struct {
    ring: *RingBuffer,

    pub fn readByte(self: *RingReader) MsgPackError!u8 {
        return self.ring.get() catch |err| switch (err) {
            error.EndOfBuffer => return MsgPackError.Incomplete,
            else => return err,
        };
    }

    pub fn readBytes(self: *RingReader, dest: []u8) MsgPackError!void {
        return self.ring.readBytes(dest) catch |err| switch (err) {
            error.EndOfBuffer => return MsgPackError.Incomplete,
            else => return err,
        };
    }

    pub fn readAvailable(self: *RingReader, dest: []u8) usize {
        if (self.ring.count == 0) return 0;
        const n = @min(dest.len, self.ring.count);
        self.ring.readBytes(dest[0..n]) catch unreachable;
        return n;
    }

    pub fn readInt(self: *RingReader, comptime T: type, endian: std.builtin.Endian) MsgPackError!T {
        const size = @sizeOf(T);
        var buf: [size]u8 = undefined;
        try self.readBytes(&buf);
        return std.mem.readInt(T, &buf, endian);
    }
};

pub const BlobKind = enum {
    string,
    binary,
    extension,
};

pub const StepState = union(enum) {
    tag: void,
    scalar: struct {
        tag: u8,
        buf: [8]u8,
        needed: u8,
        len: u8,
    },
    ext_type: struct {
        len: usize,
    },
    blob: struct {
        kind: BlobKind,
        ext_type: i8,
        data: []u8,
        offset: usize,
    },
};

pub const ContainerFrame = struct {
    pub const Kind = enum {
        array,
        map_key,
        map_val,
    };

    kind: Kind,
    count: usize,
    total: usize,
    items: union {
        array: []MsgPackObject,
        map: struct {
            entries: []MsgPackMapEntry,
            current_key: ?MsgPackObject,
        },
    },
};

pub fn Parser(comptime Source: type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            max_depth: usize = 128,
            max_blob_bytes: usize = 16 * 1024 * 1024, // per string/binary/ext (16 MB)
            max_container_len: usize = 1_000_000, // per array/map element count
        };

        source: *Source,
        allocator: std.mem.Allocator,
        options: Options = .{},
        state: StepState = .{ .tag = {} },
        stack: std.ArrayListUnmanaged(ContainerFrame) = .empty,

        pub fn init(source: *Source, allocator: std.mem.Allocator, options: Options) Self {
            return .{
                .source = source,
                .allocator = allocator,
                .options = options,
                .state = .{ .tag = {} },
                .stack = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            self.stack.deinit(self.allocator);
        }

        pub fn isIdle(self: *const Self) bool {
            return self.state == .tag and self.stack.items.len == 0;
        }

        pub fn reset(self: *Self) void {
            switch (self.state) {
                .blob => |b| {
                    self.allocator.free(b.data);
                },
                else => {},
            }
            self.state = .{ .tag = {} };

            for (self.stack.items) |frame| {
                switch (frame.kind) {
                    .array => {
                        for (frame.items.array[0..frame.count]) |item| {
                            freeObject(self.allocator, item);
                        }
                        self.allocator.free(frame.items.array);
                    },
                    .map_key, .map_val => {
                        for (frame.items.map.entries[0..frame.count]) |entry| {
                            freeObject(self.allocator, entry.key);
                            freeObject(self.allocator, entry.value);
                        }
                        if (frame.items.map.current_key) |k| {
                            freeObject(self.allocator, k);
                        }
                        self.allocator.free(frame.items.map.entries);
                    },
                }
            }
            self.stack.clearRetainingCapacity();
        }

        pub fn parseObject(self: *Self) MsgPackError!MsgPackObject {
            while (true) {
                if (try self.step()) |obj| {
                    return obj;
                }
            }
        }

        pub fn next(self: *Self) MsgPackError!?MsgPackObject {
            return self.step();
        }

        fn startBlob(self: *Self, kind: BlobKind, ext_type: i8, len: usize) MsgPackError!?MsgPackObject {
            if (len > self.options.max_blob_bytes) {
                self.reset();
                return MsgPackError.ValueTooLarge;
            }
            if (len == 0) {
                const empty_data = self.allocator.alloc(u8, 0) catch |err| {
                    self.reset();
                    return err;
                };
                const obj = switch (kind) {
                    .string => MsgPackObject{ .string = empty_data },
                    .binary => MsgPackObject{ .binary = empty_data },
                    .extension => MsgPackObject{ .extension = .{ .type = ext_type, .data = empty_data } },
                };
                return self.routeObject(obj);
            }

            const data = self.allocator.alloc(u8, len) catch |err| {
                self.reset();
                return err;
            };

            self.state = .{
                .blob = .{
                    .kind = kind,
                    .ext_type = ext_type,
                    .data = data,
                    .offset = 0,
                },
            };
            return null;
        }

        fn startArray(self: *Self, len: usize) MsgPackError!?MsgPackObject {
            if (self.stack.items.len >= self.options.max_depth) {
                self.reset();
                return MsgPackError.MaxDepthExceeded;
            }
            if (len > self.options.max_container_len) {
                self.reset();
                return MsgPackError.ValueTooLarge;
            }

            const array = self.allocator.alloc(MsgPackObject, len) catch |err| {
                self.reset();
                return err;
            };

            if (len == 0) {
                return self.routeObject(MsgPackObject{ .array = array });
            }

            self.stack.append(self.allocator, .{
                .kind = .array,
                .count = 0,
                .total = len,
                .items = .{ .array = array },
            }) catch |err| {
                self.allocator.free(array);
                self.reset();
                return err;
            };

            self.state = .{ .tag = {} };
            return null;
        }

        fn startMap(self: *Self, len: usize) MsgPackError!?MsgPackObject {
            if (self.stack.items.len >= self.options.max_depth) {
                self.reset();
                return MsgPackError.MaxDepthExceeded;
            }
            if (len > self.options.max_container_len) {
                self.reset();
                return MsgPackError.ValueTooLarge;
            }

            const map = self.allocator.alloc(MsgPackMapEntry, len) catch |err| {
                self.reset();
                return err;
            };

            if (len == 0) {
                return self.routeObject(MsgPackObject{ .map = map });
            }

            self.stack.append(self.allocator, .{
                .kind = .map_key,
                .count = 0,
                .total = len,
                .items = .{ .map = .{ .entries = map, .current_key = null } },
            }) catch |err| {
                self.allocator.free(map);
                self.reset();
                return err;
            };

            self.state = .{ .tag = {} };
            return null;
        }

        fn routeObject(self: *Self, object: MsgPackObject) MsgPackError!?MsgPackObject {
            var curr = object;
            while (self.stack.items.len > 0) {
                var top = &self.stack.items[self.stack.items.len - 1];
                switch (top.kind) {
                    .array => {
                        top.items.array[top.count] = curr;
                        top.count += 1;
                        if (top.count == top.total) {
                            const completed_array = top.items.array;
                            _ = self.stack.pop();
                            curr = MsgPackObject{ .array = completed_array };
                            continue;
                        } else {
                            self.state = .{ .tag = {} };
                            return null;
                        }
                    },
                    .map_key => {
                        top.items.map.current_key = curr;
                        top.kind = .map_val;
                        self.state = .{ .tag = {} };
                        return null;
                    },
                    .map_val => {
                        const key = top.items.map.current_key.?;
                        top.items.map.current_key = null;
                        top.items.map.entries[top.count] = MsgPackMapEntry{ .key = key, .value = curr };
                        top.count += 1;
                        top.kind = .map_key;
                        if (top.count == top.total) {
                            const completed_map = top.items.map.entries;
                            _ = self.stack.pop();
                            curr = MsgPackObject{ .map = completed_map };
                            continue;
                        } else {
                            self.state = .{ .tag = {} };
                            return null;
                        }
                    },
                }
            }

            self.state = .{ .tag = {} };
            return curr;
        }

        fn step(self: *Self) MsgPackError!?MsgPackObject {
            while (true) {
                switch (self.state) {
                    .tag => {
                        const tag = try self.source.readByte();
                        switch (tag) {
                            // positive fixint
                            0x00...0x7f => {
                                if (try self.routeObject(MsgPackObject{ .integer = tag })) |obj| return obj;
                            },
                            // negative fixint
                            0xe0...0xff => {
                                const val: i8 = @bitCast(tag);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            // nil
                            0xc0 => {
                                if (try self.routeObject(MsgPackObject{ .nil = {} })) |obj| return obj;
                            },
                            // (never used)
                            0xc1 => {
                                self.reset();
                                return MsgPackError.UsedNeverUsed;
                            },
                            // false
                            0xc2 => {
                                if (try self.routeObject(MsgPackObject{ .boolean = false })) |obj| return obj;
                            },
                            // true
                            0xc3 => {
                                if (try self.routeObject(MsgPackObject{ .boolean = true })) |obj| return obj;
                            },

                            // fixmap
                            0x80...0x8f => {
                                const count = tag - 0x80;
                                if (try self.startMap(count)) |obj| return obj;
                            },
                            // fixarray
                            0x90...0x9f => {
                                const count = tag - 0x90;
                                if (try self.startArray(count)) |obj| return obj;
                            },
                            // fixstr
                            0xa0...0xbf => {
                                const len = tag - 0xa0;
                                if (try self.startBlob(.string, 0, len)) |obj| return obj;
                            },

                            // uint 8 / int 8
                            0xcc, 0xd0 => self.state = .{ .scalar = .{ .tag = tag, .needed = 1, .len = 0, .buf = undefined } },
                            // uint 16 / int 16
                            0xcd, 0xd1 => self.state = .{ .scalar = .{ .tag = tag, .needed = 2, .len = 0, .buf = undefined } },
                            // uint 32 / int 32 / float 32
                            0xce, 0xd2, 0xca => self.state = .{ .scalar = .{ .tag = tag, .needed = 4, .len = 0, .buf = undefined } },
                            // uint 64 / int 64 / float 64
                            0xcf, 0xd3, 0xcb => self.state = .{ .scalar = .{ .tag = tag, .needed = 8, .len = 0, .buf = undefined } },

                            // str 8 / bin 8 / ext 8
                            0xd9, 0xc4, 0xc7 => self.state = .{ .scalar = .{ .tag = tag, .needed = 1, .len = 0, .buf = undefined } },
                            // str 16 / bin 16 / ext 16
                            0xda, 0xc5, 0xc8 => self.state = .{ .scalar = .{ .tag = tag, .needed = 2, .len = 0, .buf = undefined } },
                            // str 32 / bin 32 / ext 32
                            0xdb, 0xc6, 0xc9 => self.state = .{ .scalar = .{ .tag = tag, .needed = 4, .len = 0, .buf = undefined } },

                            // fixext 1, 2, 4, 8, 16
                            0xd4 => self.state = .{ .ext_type = .{ .len = 1 } },
                            0xd5 => self.state = .{ .ext_type = .{ .len = 2 } },
                            0xd6 => self.state = .{ .ext_type = .{ .len = 4 } },
                            0xd7 => self.state = .{ .ext_type = .{ .len = 8 } },
                            0xd8 => self.state = .{ .ext_type = .{ .len = 16 } },

                            // array 16 / map 16
                            0xdc, 0xde => self.state = .{ .scalar = .{ .tag = tag, .needed = 2, .len = 0, .buf = undefined } },
                            // array 32 / map 32
                            0xdd, 0xdf => self.state = .{ .scalar = .{ .tag = tag, .needed = 4, .len = 0, .buf = undefined } },
                        }
                    },

                    .scalar => |*s| {
                        while (s.len < s.needed) {
                            const b = try self.source.readByte();
                            s.buf[s.len] = b;
                            s.len += 1;
                        }

                        const tag = s.tag;
                        const buf = s.buf;
                        self.state = .{ .tag = {} };

                        switch (tag) {
                            0xcc => { // uint 8
                                if (try self.routeObject(MsgPackObject{ .integer = buf[0] })) |obj| return obj;
                            },
                            0xcd => { // uint 16
                                const val = std.mem.readInt(u16, buf[0..2], .big);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xce => { // uint 32
                                const val = std.mem.readInt(u32, buf[0..4], .big);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xcf => { // uint 64
                                const val = std.mem.readInt(u64, buf[0..8], .big);
                                const obj = if (val > std.math.maxInt(i64))
                                    MsgPackObject{ .unsigned_integer = val }
                                else
                                    MsgPackObject{ .integer = @intCast(val) };
                                if (try self.routeObject(obj)) |res| return res;
                            },
                            0xd0 => { // int 8
                                const val: i8 = @bitCast(buf[0]);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xd1 => { // int 16
                                const val = std.mem.readInt(i16, buf[0..2], .big);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xd2 => { // int 32
                                const val = std.mem.readInt(i32, buf[0..4], .big);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xd3 => { // int 64
                                const val = std.mem.readInt(i64, buf[0..8], .big);
                                if (try self.routeObject(MsgPackObject{ .integer = val })) |obj| return obj;
                            },
                            0xca => { // float 32
                                const val: f32 = @bitCast(std.mem.readInt(u32, buf[0..4], .big));
                                if (try self.routeObject(MsgPackObject{ .float32 = val })) |obj| return obj;
                            },
                            0xcb => { // float 64
                                const val: f64 = @bitCast(std.mem.readInt(u64, buf[0..8], .big));
                                if (try self.routeObject(MsgPackObject{ .float64 = val })) |obj| return obj;
                            },

                            0xd9 => { // str 8
                                const len = buf[0];
                                if (try self.startBlob(.string, 0, len)) |obj| return obj;
                            },
                            0xda => { // str 16
                                const len = std.mem.readInt(u16, buf[0..2], .big);
                                if (try self.startBlob(.string, 0, len)) |obj| return obj;
                            },
                            0xdb => { // str 32
                                const len = std.mem.readInt(u32, buf[0..4], .big);
                                if (try self.startBlob(.string, 0, len)) |obj| return obj;
                            },

                            0xc4 => { // bin 8
                                const len = buf[0];
                                if (try self.startBlob(.binary, 0, len)) |obj| return obj;
                            },
                            0xc5 => { // bin 16
                                const len = std.mem.readInt(u16, buf[0..2], .big);
                                if (try self.startBlob(.binary, 0, len)) |obj| return obj;
                            },
                            0xc6 => { // bin 32
                                const len = std.mem.readInt(u32, buf[0..4], .big);
                                if (try self.startBlob(.binary, 0, len)) |obj| return obj;
                            },

                            0xc7 => { // ext 8
                                const len = buf[0];
                                self.state = .{ .ext_type = .{ .len = len } };
                            },
                            0xc8 => { // ext 16
                                const len = std.mem.readInt(u16, buf[0..2], .big);
                                self.state = .{ .ext_type = .{ .len = len } };
                            },
                            0xc9 => { // ext 32
                                const len = std.mem.readInt(u32, buf[0..4], .big);
                                self.state = .{ .ext_type = .{ .len = len } };
                            },

                            0xdc => { // array 16
                                const len = std.mem.readInt(u16, buf[0..2], .big);
                                if (try self.startArray(len)) |obj| return obj;
                            },
                            0xdd => { // array 32
                                const len = std.mem.readInt(u32, buf[0..4], .big);
                                if (try self.startArray(len)) |obj| return obj;
                            },

                            0xde => { // map 16
                                const len = std.mem.readInt(u16, buf[0..2], .big);
                                if (try self.startMap(len)) |obj| return obj;
                            },
                            0xdf => { // map 32
                                const len = std.mem.readInt(u32, buf[0..4], .big);
                                if (try self.startMap(len)) |obj| return obj;
                            },

                            else => unreachable,
                        }
                    },

                    .ext_type => |e| {
                        const b = try self.source.readByte();
                        const ext_type: i8 = @bitCast(b);
                        if (try self.startBlob(.extension, ext_type, e.len)) |obj| return obj;
                    },

                    .blob => |*b| {
                        while (b.offset < b.data.len) {
                            const available = self.source.readAvailable(b.data[b.offset..]);
                            if (available == 0) {
                                const byte = try self.source.readByte();
                                b.data[b.offset] = byte;
                                b.offset += 1;
                            } else {
                                b.offset += available;
                            }
                        }

                        const data = b.data;
                        const kind = b.kind;
                        const ext_type = b.ext_type;
                        self.state = .{ .tag = {} };

                        const obj = switch (kind) {
                            .string => MsgPackObject{ .string = data },
                            .binary => MsgPackObject{ .binary = data },
                            .extension => MsgPackObject{ .extension = .{ .type = ext_type, .data = data } },
                        };

                        if (try self.routeObject(obj)) |res| return res;
                    },
                }
            }
        }
    };
}

pub const Unpacker = struct {
    pub const Options = struct {
        max_buffer_size: usize = 1024 * 1024, // 1MB default
        max_depth: usize = 128,
        max_blob_bytes: usize = 16 * 1024 * 1024,
        max_container_len: usize = 1_000_000,
    };

    const Self = @This();
    allocator: std.mem.Allocator,
    ring: RingBuffer,
    reader: RingReader,
    parser: Parser(RingReader),

    pub fn init(allocator: std.mem.Allocator, options: Options) MsgPackError!Self {
        var ring = try RingBuffer.init(allocator, .{ .max_buffer_size = options.max_buffer_size });
        errdefer ring.deinit();

        var self = Self{
            .allocator = allocator,
            .ring = ring,
            .reader = .{ .ring = undefined },
            .parser = undefined,
        };
        self.reader.ring = &self.ring;
        self.parser = Parser(RingReader).init(&self.reader, allocator, .{
            .max_depth = options.max_depth,
            .max_blob_bytes = options.max_blob_bytes,
            .max_container_len = options.max_container_len,
        });
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.parser.deinit();
        self.ring.deinit();
    }

    pub fn feed(self: *Self, data: []const u8) MsgPackError!void {
        try self.ring.feed(data);
    }

    pub fn next(self: *Self) MsgPackError!MsgPackObject {
        if (self.ring.count == 0 and self.parser.isIdle()) {
            return MsgPackError.NoMessage;
        }

        self.reader.ring = &self.ring;
        self.parser.source = &self.reader;

        const maybe_obj = try self.parser.next();
        if (maybe_obj) |obj| {
            return obj;
        } else {
            return MsgPackError.Incomplete;
        }
    }
};

pub fn unpack(allocator: std.mem.Allocator, buffer: []const u8) MsgPackError!MsgPackObject {
    if (buffer.len == 0) return MsgPackError.NoMessage;
    var reader = SliceReader{ .buffer = buffer, .pos = 0 };
    // A blob cannot meaningfully exceed the size of the input buffer, so use
    // buffer.len as a tight upper bound rather than the global 16 MB default.
    var parser = Parser(SliceReader).init(&reader, allocator, .{
        .max_blob_bytes = buffer.len,
    });
    defer parser.deinit();
    return parser.parseObject();
}



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

// =========================================================================
// Tests for unpack() directly from contiguous user slices
// =========================================================================

test "unpack: empty buffer returns NoMessage" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NoMessage, unpack(allocator, ""));
}

test "unpack: incomplete buffer returns Incomplete" {
    const allocator = std.testing.allocator;
    // 0x93 specifies array of 3 items, only 1 provided
    try std.testing.expectError(error.Incomplete, unpack(allocator, "\x93\x01"));
}

test "unpack: basic types from contiguous slice" {
    const allocator = std.testing.allocator;

    // nil
    {
        const obj = try unpack(allocator, "\xc0");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .nil);
    }

    // boolean true
    {
        const obj = try unpack(allocator, "\xc3");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .boolean);
        try std.testing.expectEqual(true, obj.boolean);
    }

    // positive fixint
    {
        const obj = try unpack(allocator, "\x2a");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .integer);
        try std.testing.expectEqual(@as(i64, 42), obj.integer);
    }

    // negative fixint
    {
        const obj = try unpack(allocator, "\xff");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .integer);
        try std.testing.expectEqual(@as(i64, -1), obj.integer);
    }

    // float32 (2.5)
    {
        const obj = try unpack(allocator, "\xca\x40\x20\x00\x00");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .float32);
        try std.testing.expectEqual(@as(f32, 2.5), obj.float32);
    }

    // string
    {
        const obj = try unpack(allocator, "\xa5hello");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .string);
        try std.testing.expectEqualStrings("hello", obj.string);
    }

    // binary
    {
        const obj = try unpack(allocator, "\xc4\x03\x01\x02\x03");
        defer freeObject(allocator, obj);
        try std.testing.expect(obj == .binary);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, obj.binary);
    }
}

test "unpack: complex array and map from contiguous slice" {
    const allocator = std.testing.allocator;

    // Outer array: [0, 1, "nvim_eval", ["2 + 2"]]
    const test_input = "\x94\x00\x01\xa9nvim_eval\x91\xa52 + 2";
    const obj = try unpack(allocator, test_input);
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 4), obj.array.len);
    try std.testing.expectEqual(@as(i64, 0), obj.array[0].integer);
    try std.testing.expectEqual(@as(i64, 1), obj.array[1].integer);
    try std.testing.expectEqualStrings("nvim_eval", obj.array[2].string);
    try std.testing.expectEqualStrings("2 + 2", obj.array[3].array[0].string);

    // Map: {"key": 100}
    const map_input = "\x81\xa3key\x64";
    const map_obj = try unpack(allocator, map_input);
    defer freeObject(allocator, map_obj);

    try std.testing.expect(map_obj == .map);
    try std.testing.expectEqual(@as(usize, 1), map_obj.map.len);
    try std.testing.expectEqualStrings("key", map_obj.map[0].key.string);
    try std.testing.expectEqual(@as(i64, 100), map_obj.map[0].value.integer);
}

// =========================================================================
// Advanced Streaming State Machine Tests
// =========================================================================

test "Unpacker: 1-byte-at-a-time incremental streaming of complex structure" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256 });
    defer unpacker.deinit();

    // Nested payload: [1, "hello", {"flag": true, "sub": [3.141592653589793, -42]}]
    const packer_mod = @import("packer.zig");
    var p = packer_mod.Packer.init(allocator);
    defer p.deinit();

    var s_hello = "hello".*;
    var s_flag = "flag".*;
    var s_sub = "sub".*;
    var sub_arr = [_]MsgPackObject{
        .{ .float64 = 3.141592653589793 },
        .{ .integer = -42 },
    };
    var map_entries = [_]MsgPackMapEntry{
        .{ .key = .{ .string = &s_flag }, .value = .{ .boolean = true } },
        .{ .key = .{ .string = &s_sub }, .value = .{ .array = &sub_arr } },
    };
    var root_arr = [_]MsgPackObject{
        .{ .integer = 1 },
        .{ .string = &s_hello },
        .{ .map = &map_entries },
    };

    try p.packObject(MsgPackObject{ .array = &root_arr });
    const full_bytes = p.getSlice();

    // Feed the bytes strictly 1 by 1 and call next() after each byte
    for (full_bytes[0 .. full_bytes.len - 1]) |byte| {
        try unpacker.feed(&[_]u8{byte});
        try std.testing.expectError(error.Incomplete, unpacker.next());
    }

    // Feed the very last byte
    try unpacker.feed(&[_]u8{full_bytes[full_bytes.len - 1]});
    const obj = try unpacker.next();
    defer freeObject(allocator, obj);

    try std.testing.expect(obj == .array);
    try std.testing.expectEqual(@as(usize, 3), obj.array.len);
    try std.testing.expectEqual(@as(i64, 1), obj.array[0].integer);
    try std.testing.expectEqualStrings("hello", obj.array[1].string);
    try std.testing.expect(obj.array[2] == .map);
    try std.testing.expectEqual(@as(usize, 2), obj.array[2].map.len);
    try std.testing.expectEqualStrings("flag", obj.array[2].map[0].key.string);
    try std.testing.expectEqual(true, obj.array[2].map[0].value.boolean);
    try std.testing.expectEqualStrings("sub", obj.array[2].map[1].key.string);
    try std.testing.expect(obj.array[2].map[1].value == .array);
    try std.testing.expectEqual(@as(usize, 2), obj.array[2].map[1].value.array.len);
    try std.testing.expectEqual(@as(f64, 3.141592653589793), obj.array[2].map[1].value.array[0].float64);
    try std.testing.expectEqual(@as(i64, -42), obj.array[2].map[1].value.array[1].integer);

    // End of buffer
    try std.testing.expectError(error.NoMessage, unpacker.next());
}

test "Unpacker: deinit during incomplete parsing leaks zero memory" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256 });

    // Feed part of a map with an array and partial string: {"key": [1, 2, "partial_str...
    try unpacker.feed("\x81\xa3key\x93\x01\x02\xa8part");
    _ = unpacker.next() catch {};

    // Deinit while partial objects are allocated in stack and blob state
    unpacker.deinit();
}

test "Unpacker: max_depth security limit returns error and cleans up" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256, .max_depth = 3 });
    defer unpacker.deinit();

    // 4 levels of nested arrays: [[[[1]]]]
    try unpacker.feed("\x91\x91\x91\x91\x01");

    try std.testing.expectError(error.MaxDepthExceeded, unpacker.next());
}

test "Unpacker: max_blob_bytes rejects oversized string" {
    const allocator = std.testing.allocator;
    // Limit blobs to 4 bytes; str8 claiming 5 bytes should be rejected.
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256, .max_blob_bytes = 4 });
    defer unpacker.deinit();

    // str 8, length=5, "hello"
    try unpacker.feed("\xd9\x05hello");
    try std.testing.expectError(error.ValueTooLarge, unpacker.next());
}

test "Unpacker: max_blob_bytes rejects oversized binary" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256, .max_blob_bytes = 2 });
    defer unpacker.deinit();

    // bin 8, length=3
    try unpacker.feed("\xc4\x03\x01\x02\x03");
    try std.testing.expectError(error.ValueTooLarge, unpacker.next());
}

test "Unpacker: max_container_len rejects oversized array" {
    const allocator = std.testing.allocator;
    // Limit containers to 2 elements; array16 claiming 3 should be rejected.
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256, .max_container_len = 2 });
    defer unpacker.deinit();

    // array 16, length=3, elements [1, 2, 3]
    try unpacker.feed("\xdc\x00\x03\x01\x02\x03");
    try std.testing.expectError(error.ValueTooLarge, unpacker.next());
}

test "Unpacker: max_container_len rejects oversized map" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 256, .max_container_len = 1 });
    defer unpacker.deinit();

    // map 16, length=2: {"a":1, "b":2}
    try unpacker.feed("\xde\x00\x02\xa1a\x01\xa1b\x02");
    try std.testing.expectError(error.ValueTooLarge, unpacker.next());
}

test "unpack: max_blob_bytes auto-bounded to buffer length" {
    const allocator = std.testing.allocator;

    // str32 header claiming 100 bytes, but the buffer is only 6 bytes total.
    // max_blob_bytes is set to buffer.len (6), so 100 > 6 fires ValueTooLarge
    // before any allocation attempt rather than returning Incomplete.
    const input = "\xdb\x00\x00\x00\x64x";
    try std.testing.expectError(error.ValueTooLarge, unpack(allocator, input));
}


