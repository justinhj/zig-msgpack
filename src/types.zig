const std = @import("std");

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
