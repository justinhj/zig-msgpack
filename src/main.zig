const std = @import("std");
const Io = std.Io;

const zig_msgpack = @import("zig_msgpack");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try zig_msgpack.printAnotherMessage(stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}

//// Unpacker implementation 

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

pub const MsgPackError = error {
    incomplete, // If you run out of bytes while parsing
    outOfMemory,
    noRoomInBuffer,
};

pub const Unpacker = struct {
    pub const Options = struct {
        max_buffer_size: usize = 1024 * 1024, // 1MB default
    };

    const This = @This();
    allocator: std.mem.Allocator, 
    start: usize,
    end: usize,
    count: usize,
    buffer: []u8,
    buffer_size: usize,

    pub fn init(allocator: std.mem.Allocator, options: Options) MsgPackError!This {
        const buffer = allocator.alloc(u8, options.max_buffer_size) catch return MsgPackError.outOfMemory;
        return This {
            .allocator = allocator,
            .start = 0,
            .end = 0,
            .count = 0,
            .buffer = buffer,
            .buffer_size = options.max_buffer_size,
        };
    }

    pub fn deinit(this: *This) void {
        this.allocator.free(this.buffer);
    }

    pub fn feed(this: *This, data: []const u8) MsgPackError!void {
        if (this.count + data.len > this.buffer_size) {
            return MsgPackError.noRoomInBuffer;
        }

        // Since this is a ring buffer it will either fit in one go or we 
        // need to fill to the end then do the rest at the beginning
        if (this.start + data.len > this.buffer_size) {
            const fill = data.len - this.end;
            @memcpy(this.buffer[this.end..this.buffer_size], data[0..fill]);
            @memcpy(this.buffer[0..fill], data[fill..data.len]);
            this.count += data.len;
            this.end = fill;
        } else {
            @memcpy(this.buffer[this.end..this.end + data.len], data[0..data.len]);
            this.end = this.end + data.len;
        }
        this.count += data.len;
        return;
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
        return MsgPackError.incomplete;
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

test "Unpacker: construction with 128-byte buffer" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try std.testing.expectEqual(@as(usize, 128), unpacker.buffer_size);
    try std.testing.expectEqual(@as(usize, 128), unpacker.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), unpacker.count);
    try std.testing.expectEqual(@as(usize, 0), unpacker.start);
    try std.testing.expectEqual(@as(usize, 0), unpacker.end);
}

test "Unpacker.feed: empty input (0 bytes)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try unpacker.feed(&.{});

    try std.testing.expectEqual(@as(usize, 0), unpacker.count);
    try std.testing.expectEqual(@as(usize, 0), unpacker.end);
}

test "Unpacker.feed: partial and sequential feeds without wrap" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // First chunk: 40 bytes
    const chunk1 = "A" ** 40;
    try unpacker.feed(chunk1);
    try std.testing.expectEqual(@as(usize, 40), unpacker.count);
    try std.testing.expectEqual(@as(usize, 40), unpacker.end);
    try std.testing.expectEqualSlices(u8, chunk1, unpacker.buffer[0..40]);

    // Second chunk: 50 bytes (total 90 bytes)
    const chunk2 = "B" ** 50;
    try unpacker.feed(chunk2);
    try std.testing.expectEqual(@as(usize, 90), unpacker.count);
    try std.testing.expectEqual(@as(usize, 90), unpacker.end);
    try std.testing.expectEqualSlices(u8, chunk2, unpacker.buffer[40..90]);
}

test "Unpacker.feed: exact full capacity (128 bytes)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    const full_data = "X" ** 128;
    try unpacker.feed(full_data);

    try std.testing.expectEqual(@as(usize, 128), unpacker.count);
    try std.testing.expectEqualSlices(u8, full_data, unpacker.buffer[0..128]);
}

test "Unpacker.feed: overflow on empty buffer (> 128 bytes)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    const too_large = "Z" ** 129;
    try std.testing.expectError(error.noRoomInBuffer, unpacker.feed(too_large));

    // State should remain unchanged
    try std.testing.expectEqual(@as(usize, 0), unpacker.count);
    try std.testing.expectEqual(@as(usize, 0), unpacker.end);
}

test "Unpacker.feed: overflow on partially full buffer" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // Fill 100 bytes
    try unpacker.feed("A" ** 100);
    try std.testing.expectEqual(@as(usize, 100), unpacker.count);

    // Attempt to feed 29 bytes (100 + 29 = 129 > 128)
    try std.testing.expectError(error.noRoomInBuffer, unpacker.feed("B" ** 29));

    // State should remain unchanged from before the failed feed
    try std.testing.expectEqual(@as(usize, 100), unpacker.count);
    try std.testing.expectEqual(@as(usize, 100), unpacker.end);
}

test "Unpacker.feed: feeding when completely full" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    try unpacker.feed("A" ** 128);
    try std.testing.expectEqual(@as(usize, 128), unpacker.count);

    // Even a single byte should fail
    try std.testing.expectError(error.noRoomInBuffer, unpacker.feed("B"));
    try std.testing.expectEqual(@as(usize, 128), unpacker.count);
}

test "Unpacker.feed: wrap-around across buffer boundary" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // Simulate state where 100 bytes were written and consumed:
    // end is at 100, buffer has 28 bytes until the end of the array.
    unpacker.start = 100;
    unpacker.end = 100;
    unpacker.count = 0;

    // Feed 50 bytes: 28 bytes fit at [100..128], 22 bytes wrap to [0..22]
    const data = ("A" ** 28) ++ ("B" ** 22);
    try unpacker.feed(data);

    try std.testing.expectEqual(@as(usize, 50), unpacker.count);
    try std.testing.expectEqual(@as(usize, 22), unpacker.end);

    // Verify both contiguous halves
    try std.testing.expectEqualSlices(u8, "A" ** 28, unpacker.buffer[100..128]);
    try std.testing.expectEqualSlices(u8, "B" ** 22, unpacker.buffer[0..22]);
}

test "Unpacker.feed: wrap-around landing exactly at boundary (end == 128 wraps to 0)" {
    const allocator = std.testing.allocator;
    var unpacker = try Unpacker.init(allocator, .{ .max_buffer_size = 128 });
    defer unpacker.deinit();

    // Start at offset 100 with 0 count
    unpacker.start = 100;
    unpacker.end = 100;
    unpacker.count = 0;

    // Exactly 28 bytes to reach index 128
    const data = "C" ** 28;
    try unpacker.feed(data);

    try std.testing.expectEqual(@as(usize, 28), unpacker.count);
    try std.testing.expectEqual(@as(usize, 0), unpacker.end);
    try std.testing.expectEqualSlices(u8, data, unpacker.buffer[100..128]);
}
