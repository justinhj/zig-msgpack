# Msgpack Streaming Unpacker — Zig Implementation Plan

## Context

Implement a streaming msgpack `Unpacker` in Zig, modelled on the Python msgpack library's `Unpacker` class. The implementation must handle incremental data arrival (e.g. from a socket), returning decoded `Value` objects one at a time. It does not need to be a full msgpack library — the focus is the streaming unpacker.

---

## Target file

`src/unpacker.zig` (new file)

---

## Step 1 — Value type

Define a recursive tagged union covering all msgpack types:

```zig
pub const KV = struct { key: Value, val: Value };
pub const Ext = struct { typecode: i8, data: []const u8 };

pub const Value = union(enum) {
    nil,
    bool: bool,
    uint: u64,
    int:  i64,
    float32: f32,
    float64: f64,
    str: []const u8,   // slice into internal buffer (zero-copy)
    bin: []const u8,
    array: []Value,
    map:   []KV,
    ext:   Ext,
};
```

Slices for `str`/`bin`/`ext.data` point into the unpacker's internal buffer. Callers must copy them before the next `feed()` call if they need to outlive the buffer.

---

## Step 2 — Error set

```zig
pub const UnpackError = error{
    OutOfData,
    BufferFull,
    FormatError,
    StackError,
};
```

---

## Step 3 — Unpacker struct

```zig
pub const Unpacker = struct {
    buf: std.ArrayList(u8),
    pos: usize,
    max_buffer_size: usize,
    allocator: std.mem.Allocator,
};
```

### `init` / `deinit`
- `init(allocator, max_buffer_size)` — allocate `buf`, set `pos = 0`
- `deinit()` — free `buf`

### `feed(data: []const u8) !void`
1. Check `buf.items.len - pos + data.len <= max_buffer_size`, else return `error.BufferFull`
2. If `pos > buf.items.len / 2`, slide unconsumed bytes to the front and reset `pos = 0` (compact)
3. Append `data` to `buf`

### `unpack(allocator) !Value`
Call the internal `parseValue` function (see Step 4). `allocator` is used for `[]Value` and `[]KV` slices for arrays and maps. Returns `error.OutOfData` if the buffer is exhausted before a complete object is decoded — the caller feeds more data and retries.

---

## Step 4 — `parseValue` — format byte dispatch

```zig
fn parseValue(self: *Unpacker, allocator: std.mem.Allocator) !Value {
    const b = try self.readByte();
    return switch (b) {
        0x00...0x7f => .{ .uint = b },                        // positive fixint
        0x80...0x8f => self.parseMap(allocator, b & 0x0f),    // fixmap
        0x90...0x9f => self.parseArray(allocator, b & 0x0f),  // fixarray
        0xa0...0xbf => self.parseStr(b & 0x1f),               // fixstr
        0xc0 => .nil,
        0xc2 => .{ .bool = false },
        0xc3 => .{ .bool = true },
        0xc4 => self.parseBin(try self.readUint(1)),           // bin8
        0xc5 => self.parseBin(try self.readUint(2)),           // bin16
        0xc6 => self.parseBin(try self.readUint(4)),           // bin32
        0xc7 => self.parseExt(try self.readUint(1)),           // ext8
        0xc8 => self.parseExt(try self.readUint(2)),           // ext16
        0xc9 => self.parseExt(try self.readUint(4)),           // ext32
        0xca => .{ .float32 = try self.readF32() },
        0xcb => .{ .float64 = try self.readF64() },
        0xcc => .{ .uint = try self.readUint(1) },
        0xcd => .{ .uint = try self.readUint(2) },
        0xce => .{ .uint = try self.readUint(4) },
        0xcf => .{ .uint = try self.readUint(8) },
        0xd0 => .{ .int = try self.readInt(1) },
        0xd1 => .{ .int = try self.readInt(2) },
        0xd2 => .{ .int = try self.readInt(4) },
        0xd3 => .{ .int = try self.readInt(8) },
        0xd4...0xd8 => self.parseFixExt(b),                   // fixext 1/2/4/8/16
        0xd9 => self.parseStr(try self.readUint(1)),           // str8
        0xda => self.parseStr(try self.readUint(2)),           // str16
        0xdb => self.parseStr(try self.readUint(4)),           // str32
        0xdc => self.parseArray(allocator, try self.readUint(2)),
        0xdd => self.parseArray(allocator, try self.readUint(4)),
        0xde => self.parseMap(allocator, try self.readUint(2)),
        0xdf => self.parseMap(allocator, try self.readUint(4)),
        0xe0...0xff => .{ .int = @as(i8, @bitCast(b)) },      // negative fixint
        else => error.FormatError,
    };
}
```

All `readByte` / `readUint` / `readInt` helpers check `pos < buf.items.len` before reading, returning `error.OutOfData` if insufficient data is available. On `OutOfData` the caller should NOT advance `pos` — use a saved `pos` snapshot and restore it so the next `feed()` + `unpack()` retries cleanly:

```zig
pub fn unpack(self: *Unpacker, allocator: std.mem.Allocator) !Value {
    const saved_pos = self.pos;
    return self.parseValue(allocator) catch |err| {
        self.pos = saved_pos;  // rewind so retry works
        return err;
    };
}
```

### `parseArray(allocator, len) !Value`
Allocate `[]Value` of `len`, call `parseValue` recursively for each element. On `OutOfData` mid-array, rewind is handled by the outer `unpack` snapshot.

### `parseMap(allocator, len) !Value`
Allocate `[]KV` of `len`, call `parseValue` for each key then each value.

### Nesting depth limit
Add a `depth: usize` field to `Unpacker`. Increment on entering array/map, decrement on exit. Return `error.StackError` if `depth > max_depth` (default 512).

---

## Step 5 — Iterator interface

```zig
pub fn next(self: *Unpacker, allocator: std.mem.Allocator) !?Value {
    return self.unpack(allocator) catch |err| switch (err) {
        error.OutOfData => null,
        else => err,
    };
}
```

---

## Step 6 — Tests (`src/unpacker_test.zig`)

Test cases to cover:

| Case | Input bytes |
|------|-------------|
| nil | `0xc0` |
| bool false/true | `0xc2`, `0xc3` |
| positive fixint | `0x2a` → 42 |
| negative fixint | `0xff` → -1 |
| uint8/16/32/64 | `0xcc 0x80`, etc. |
| int8/16/32/64 | `0xd0 0x80`, etc. |
| float32 / float64 | |
| fixstr | `0xa5 "hello"` |
| str8/16/32 | |
| bin8 | |
| fixarray | `0x92 0x01 0x02` → [1, 2] |
| fixmap | `0x81 0xa1 "k" 0x01` → {"k": 1} |
| ext8 | typecode + data |
| nested array/map | |
| streaming: split across two `feed()` calls | partial fixstr, then rest |
| `OutOfData` rewind: feed 1 byte of a 2-byte int, unpack returns OutOfData, feed rest, unpack succeeds | |
| `BufferFull` | exceed max_buffer_size |
| `StackError` | deeply nested array |

---

## Verification

```sh
zig build test          # run unpacker_test.zig
zig build run           # smoke test against a known msgpack file if one exists
```

For manual end-to-end testing: encode a Python dict with `msgpack.packb({"x": [1, 2, 3]})`, write the bytes to a file, read them in chunks in Zig, feed to `Unpacker`, and print the decoded `Value`.
