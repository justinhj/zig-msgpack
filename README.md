# zig-msgpack

A simple and efficient MessagePack and MessagePack-RPC library for Zig.

## Installation

`zig-msgpack` requires **Zig 0.16.0** or later.

Run `zig fetch` to add `zig-msgpack` to your `build.zig.zon`:

```sh
# Add from git repository
zig fetch --save git+https://github.com/justinhj/zig-msgpack.git

# Or add a specific tagged release
# Replace `<VERSION>` with the version you want to use
# See: https://github.com/justinhj/zig-msgpack/releases
zig fetch --save https://github.com/justinhj/zig-msgpack/archive/refs/tags/<VERSION>.tar.gz
```

Then add the following to `build.zig`:

```zig
const msgpack = b.dependency("zig_msgpack", .{});
exe.root_module.addImport("zig_msgpack", msgpack.module("zig_msgpack"));
```

## Features

- Full MessagePack specification support
  - Positive and negative fixints, int 8..64, uint 8..64
  - Floating point numbers (float 32, float 64)
  - Booleans and nil
  - Strings and binary buffers
  - Nested arrays and key-value maps
  - Extension types (fixext 1..16, ext 8..32)
- One-shot deserialization (`msgpack.unpack`) and serialization (`msgpack.pack`)
- Streaming unpacker (`msgpack.Unpacker`) backed by a ring buffer for incremental network or stream parsing
- Flexible in-memory builder (`msgpack.Packer`) as well as direct `Writer` packing functions
- MessagePack-RPC support (`msgpack.rpc`)
  - Request, response, and notification serialization
  - Typed RPC message parsing (`Request`, `Response`, `Notification`) projected over unpacked objects without redundant allocations
  - Transport-agnostic session manager (`RpcSession`)

## Examples

### `msgpack.unpack`

The simplest way to deserialize MessagePack data is to call the `msgpack.unpack` function.

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Packed MessagePack bytes for: ["hello", 42]
    const data = [_]u8{ 0x92, 0xa5, 'h', 'e', 'l', 'l', 'o', 0x2a };

    const obj = try msgpack.unpack(allocator, &data);
    defer msgpack.freeObject(allocator, obj);

    switch (obj) {
        .array => |items| {
            std.debug.print("Array with {} items:\n", .{items.len});
            std.debug.print("  [0] = {s}\n", .{items[0].string});
            std.debug.print("  [1] = {}\n", .{items[1].integer});
        },
        else => {},
    }
}

const msgpack = @import("zig_msgpack");
const std = @import("std");
```

`msgpack.unpack` returns a `MsgPackObject`, which is a tagged union of all supported MessagePack
types. If the object contains dynamically allocated nodes (such as strings, binary data, arrays, or
maps), call `msgpack.freeObject(allocator, obj)` to recursively free all associated memory.

### `msgpack.pack`

The simplest way to serialize a `MsgPackObject` into bytes is to call `msgpack.pack`.

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var text = "hello world".*;
    const obj = msgpack.MsgPackObject{ .string = &text };

    const bytes = try msgpack.pack(allocator, obj);
    defer allocator.free(bytes);

    std.debug.print("Serialized {} bytes\n", .{bytes.len});
}

const msgpack = @import("zig_msgpack");
const std = @import("std");
```

### `msgpack.Packer`

For building MessagePack payloads incrementally without having to construct a full `MsgPackObject`
tree first, `msgpack.Packer` provides a dynamic byte builder:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var packer = msgpack.Packer.init(allocator);
    defer packer.deinit();

    // Pack an array of 2 elements: ["ping", 1]
    try packer.packArrayHeader(2);
    try packer.packString("ping");
    try packer.packUInt(1);

    const slice = packer.getSlice();
    std.debug.print("Packed payload len: {}\n", .{slice.len});
}

const msgpack = @import("zig_msgpack");
const std = @import("std");
```

The underlying functions (`msgpack.packer.packNil`, `packInt`, `packString`, `packObject`, etc.)
also accept any arbitrary Zig `Writer` directly.

### `msgpack.Unpacker` (Streaming)

When reading data incrementally from a network socket or stream where messages arrive in chunks,
`msgpack.Unpacker` buffers input in an internal ring buffer and yields objects as soon as complete
messages are available:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var unpacker = try msgpack.Unpacker.init(allocator, .{});
    defer unpacker.deinit();

    // Feed chunks into unpacker as they arrive from socket/stream
    try unpacker.feed(&[_]u8{ 0x92, 0xa4 }); // array header + start of string
    try unpacker.feed(&[_]u8{ 't', 'e', 's', 't', 0x2a }); // rest of string + int 42

    while (unpacker.next()) |obj| {
        defer msgpack.freeObject(allocator, obj);
        std.debug.print("Unpacked complete object: {}\n", .{@tagName(obj)});
    } else |err| switch (err) {
        error.NoMessage, error.Incomplete => {
            // Need more data to form a complete object
        },
        else => return err,
    }
}

const msgpack = @import("zig_msgpack");
const std = @import("std");
```

### MessagePack-RPC

`zig-msgpack` includes helpers and data structures for building MessagePack-RPC clients and
servers (such as communicating with Neovim over a Unix socket or pipe):

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var session = msgpack.RpcSession.init(allocator);
    defer session.deinit();

    var packer = msgpack.Packer.init(allocator);
    defer packer.deinit();

    // Pack an RPC request: method "nvim_eval", params ["2 + 2"]
    var expr = "2 + 2".*;
    const params = [_]msgpack.MsgPackObject{
        .{ .string = &expr },
    };
    const msgid = try session.packRequest(&packer, "nvim_eval", &params);
    _ = msgid;

    // Parse incoming RPC message
    const obj = try msgpack.unpack(allocator, packer.getSlice());
    defer msgpack.freeObject(allocator, obj);

    const rpc_msg = try msgpack.rpc.parseMessage(obj);
    switch (rpc_msg) {
        .request => |req| {
            std.debug.print("RPC Request #{}: {s}\n", .{ req.msgid, req.method });
        },
        .response => |res| {
            std.debug.print("RPC Response #{}\n", .{ res.msgid });
        },
        .notification => |notif| {
            std.debug.print("RPC Notification: {s}\n", .{ notif.method });
        },
    }
}

const msgpack = @import("zig_msgpack");
const std = @import("std");
```

## Running Examples

The repository includes runnable examples in the `examples/` directory:

```sh
# Dump and pretty-print a MessagePack file
zig build run -- input.msgpack

# Or run the dumpmsgpack example directly
zig build run-dumpmsgpack -- input.msgpack

# Run the Neovim RPC example (requires a running Neovim instance listening on a socket)
zig build run-hellonvim -- /tmp/nvim.sock
```

To compile all example executables into `zig-out/bin/`:

```sh
zig build examples
```
