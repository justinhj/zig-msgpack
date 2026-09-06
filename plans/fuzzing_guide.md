# Fuzzing Guide

Zig 0.14+ has `std.testing.fuzz` built in, backed by LibFuzzer. It does
coverage-guided mutation automatically and reports a minimised crashing input
if it finds one. Run until you kill it or a crash is found:

```bash
zig build test --fuzz
```

## Target 1: one-shot `unpack()`

Feed arbitrary bytes and assert only expected errors come back and all memory
is freed cleanly.

```zig
// src/fuzz_test.zig
const std = @import("std");
const unpacker = @import("unpacker.zig");

test "fuzz unpack" {
    try std.testing.fuzz(fuzzUnpack, .{});
}

fn fuzzUnpack(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const obj = unpacker.unpack(allocator, input) catch |err| switch (err) {
        error.Incomplete,
        error.NoMessage,
        error.ValueTooLarge,
        error.MaxDepthExceeded,
        error.UsedNeverUsed,
        error.OutOfMemory,
        => return,
        else => return err, // unexpected error → test failure
    };
    unpacker.freeObject(allocator, obj);
}
```

## Target 2: streaming `Unpacker`

Feed input in variable-sized chunks to exercise the resumable parser state
machine — the part that survives `Incomplete` and continues mid-blob or
mid-container. This is the most valuable target because it exercises state
transitions that one-shot parsing never sees.

The first byte of the fuzz input is used to pick a chunk size so the fuzzer
explores different fragmentation patterns across runs.

```zig
test "fuzz streaming unpacker" {
    try std.testing.fuzz(fuzzStreaming, .{});
}

fn fuzzStreaming(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var unp = unpacker.Unpacker.init(allocator, .{ .max_buffer_size = 4096 }) catch return;
    defer unp.deinit();

    if (input.len == 0) return;
    const chunk_size = @max(1, input[0] & 0xf);
    var pos: usize = 1;
    while (pos < input.len) {
        const end = @min(pos + chunk_size, input.len);
        unp.feed(input[pos..end]) catch {};
        pos = end;
        while (true) {
            const obj = unp.next() catch break;
            unpacker.freeObject(allocator, obj);
        }
    }
}
```

## Target 3: pack/unpack roundtrip invariant

Anything that unpacks successfully must survive a pack → unpack cycle. This
catches asymmetries between the packer and unpacker that individual unit tests
may miss.

```zig
test "fuzz roundtrip" {
    try std.testing.fuzz(fuzzRoundtrip, .{});
}

fn fuzzRoundtrip(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const packer = @import("packer.zig");

    const obj = unpacker.unpack(allocator, input) catch return;
    defer unpacker.freeObject(allocator, obj);

    const repacked = try packer.pack(allocator, obj);
    defer allocator.free(repacked);

    const obj2 = try unpacker.unpack(allocator, repacked);
    unpacker.freeObject(allocator, obj2);
}
```

## Practical tips

- **Seed the corpus** with your existing test payloads. LibFuzzer learns much
  faster from real inputs than random bytes. Put `.msgpack` files or raw byte
  literals from the unit tests into a `corpus/` directory and pass it:
  ```bash
  zig build test --fuzz -- corpus/
  ```
- **Cap `max_buffer_size`** in the streaming target (4096 above) so the fuzzer
  stays memory-bounded and spends time on parser logic rather than hitting OOM.
- **Run overnight.** A few hours of fuzzing with a good corpus will cover the
  interesting state space. Use `2>/dev/null` to suppress LibFuzzer's progress
  noise if you want clean output.
- **The `max_blob_bytes` / `max_container_len` limits** (added to `Parser.Options`
  and `Unpacker.Options`) are important prerequisites — without them the fuzzer
  is likely to exhaust memory on a large-length header before finding real
  parser bugs.

## What fuzzing is likely to find

- Inputs that hit the `else => unreachable` branch in the scalar tag dispatch
  (`unpacker.zig` `step()`) if there is a gap in tag coverage.
- Memory issues in the `reset()` cleanup path triggered by errors mid-parse of
  a nested structure.
- Pack/unpack asymmetries for edge-case integer or float values.
- Any `unreachable` or safety-check panic reachable from malformed input.
