//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ringbuffer = @import("ringbuffer.zig");
pub const RingBuffer = ringbuffer.RingBuffer;
pub const RingBufferError = ringbuffer.RingBufferError;

test {
    std.testing.refAllDecls(@This());
    _ = ringbuffer;
}

