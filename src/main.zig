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
}

