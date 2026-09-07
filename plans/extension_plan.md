# Extension Type System Plan

## Goal

Provide a registry-based extension type system that:
- Ships with timestamp (type `-1`) handled out of the box
- Lets users register their own types (e.g. Neovim buffer, window, tabpage)
- Keeps `MsgPackObject` and the unpacker/packer unchanged
- Uses a comptime wrapper to eliminate user-visible `anyopaque` casts

---

## New Files

### `src/timestamp_ext.zig`

Implements the msgpack timestamp extension (type `-1`).

**Types:**

```zig
pub const MsgPackTimestamp = struct {
    seconds: i64,
    nanoseconds: u32,
};
```

The 4/8/12-byte wire formats are an encoding detail. The decoded value is always a flat `seconds` + `nanoseconds`.

**Functions:**

```zig
pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !*MsgPackTimestamp
pub fn toBytes(writer: std.io.AnyWriter, ts: *const MsgPackTimestamp) !void
pub fn free(allocator: std.mem.Allocator, ts: *MsgPackTimestamp) void
```

`fromBytes` dispatches on `data.len`:
- 4 bytes → timestamp 32 (seconds in 32 bits, nanoseconds = 0)
- 8 bytes → timestamp 64 (nanoseconds in upper 30 bits, seconds in lower 34 bits)
- 12 bytes → timestamp 96 (nanoseconds as u32, seconds as i64)

`toBytes` picks the most compact representation:
- timestamp 32 if `nanoseconds == 0` and `seconds` fits in u32
- timestamp 64 if `seconds` fits in 34 bits
- timestamp 96 otherwise

**Pre-built handler constant:**

```zig
pub const handler: extension_registry.ExtensionType = 
    extension_registry.extHandlerFor(MsgPackTimestamp, fromBytes, toBytes, free);
```

---

### `src/extension_registry.zig`

**`ExtensionType` vtable:**

```zig
pub const ExtensionType = struct {
    unpackFn: *const fn(allocator: std.mem.Allocator, data: []const u8) anyerror!*anyopaque,
    packFn:   *const fn(writer: std.io.AnyWriter, value: *const anyopaque) anyerror!void,
    freeFn:   *const fn(allocator: std.mem.Allocator, value: *anyopaque) void,
};
```

**Comptime wrapper — the key safety mechanism:**

```zig
pub fn extHandlerFor(
    comptime T: type,
    comptime unpackFn: fn(std.mem.Allocator, []const u8) anyerror!*T,
    comptime packFn:   fn(std.io.AnyWriter, *const T) anyerror!void,
    comptime freeFn:   fn(std.mem.Allocator, *T) void,
) ExtensionType {
    const S = struct {
        fn unpack(a: std.mem.Allocator, d: []const u8) anyerror!*anyopaque {
            return @ptrCast(try unpackFn(a, d));
        }
        fn pack(w: std.io.AnyWriter, v: *const anyopaque) anyerror!void {
            return packFn(w, @ptrCast(@alignCast(v)));
        }
        fn free(a: std.mem.Allocator, v: *anyopaque) void {
            freeFn(a, @ptrCast(@alignCast(v)));
        }
    };
    return .{ .unpackFn = S.unpack, .packFn = S.pack, .freeFn = S.free };
}
```

All `@ptrCast` is confined to this one location per type. User-facing code is fully typed.

**`ExtensionRegistry`:**

```zig
pub const ExtensionRegistry = struct {
    handlers: std.AutoHashMap(i8, ExtensionType),

    pub fn init(allocator: std.mem.Allocator) ExtensionRegistry
    pub fn deinit(self: *ExtensionRegistry) void
    pub fn register(self: *ExtensionRegistry, type_code: i8, handler: ExtensionType) !void
    pub fn get(self: *const ExtensionRegistry, type_code: i8) ?ExtensionType

    // Pre-registers type -1 with the timestamp handler.
    pub fn initWithDefaults(allocator: std.mem.Allocator) !ExtensionRegistry
};
```

---

## Usage

### Timestamp (built-in)

```zig
const msgpack = @import("msgpack");

var registry = try msgpack.ExtensionRegistry.initWithDefaults(allocator);
defer registry.deinit();

// Unpack
const obj = try unpacker.next(); // MsgPackObject{ .extension = ... }
if (obj == .extension) {
    if (registry.get(obj.extension.type)) |h| {
        const raw = try h.unpackFn(allocator, obj.extension.data);
        defer h.freeFn(allocator, raw);
        if (obj.extension.type == -1) {
            const ts: *msgpack.MsgPackTimestamp = @ptrCast(@alignCast(raw));
            std.debug.print("seconds={d}\n", .{ts.seconds});
        }
    }
}

// Pack
var packer = msgpack.Packer.init(allocator);
const ts = msgpack.MsgPackTimestamp{ .seconds = 1_700_000_000, .nanoseconds = 0 };
const h = registry.get(-1).?;
try h.packFn(packer.writer(), &ts);
```

### Custom type (e.g. Neovim buffer)

```zig
const NvimBuffer = struct { id: u64 };

fn unpackBuffer(allocator: std.mem.Allocator, data: []const u8) !*NvimBuffer {
    const buf = try allocator.create(NvimBuffer);
    buf.* = .{ .id = std.mem.readInt(u64, data[0..8], .big) };
    return buf;
}
fn packBuffer(writer: std.io.AnyWriter, buf: *const NvimBuffer) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, buf.id, .big);
    try writer.writeAll(&tmp);
}
fn freeBuffer(allocator: std.mem.Allocator, buf: *NvimBuffer) void {
    allocator.destroy(buf);
}

try registry.register(0, msgpack.extHandlerFor(NvimBuffer, unpackBuffer, packBuffer, freeBuffer));

// Retrieval — caller knows type 0 is NvimBuffer:
const raw = try h.unpackFn(allocator, obj.extension.data);
const buf: *NvimBuffer = @ptrCast(@alignCast(raw));
```

---

## Type Safety Contract

The retrieval side is buyer-beware: the caller casts `*anyopaque` to the type they registered for that code. This is acceptable because:

1. The user who calls `registry.register(code, extHandlerFor(T, ...))` knows what `T` is for that code.
2. The comptime wrapper ensures function signature mismatches (wrong argument types) are caught at compile time, not runtime.
3. The pattern is standard Zig for runtime dispatch and familiar to the expert users this targets (e.g. Neovim API implementors).

---

## Changes to Existing Files

- `src/root.zig` — export `ExtensionRegistry`, `ExtensionType`, `extHandlerFor`, `MsgPackTimestamp`
- No changes to `types.zig`, `packer.zig`, or `unpacker.zig`
