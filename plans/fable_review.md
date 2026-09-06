# Code Review: zig-msgpack

*Review of commit `cbc03f8` ("resumable parsing"), 2026-09-06. Scope: code quality, API design, performance; security considered but the library is not intended for adversarial input. All six source modules (~3.5k lines), examples, build files, and README were read; `zig build test` passes on Zig 0.16.0.*

## Summary

This is a clean, well-tested small library with a genuinely nice resumable parser design. The state-machine `Parser` that survives `Incomplete` and resumes mid-blob/mid-container is the strongest part of the codebase, and the test suite (byte-exact format checks, 1-byte-at-a-time streaming, leak-on-abandoned-parse) is above average.

**TL;DR:** solid foundation. Fix the trust-the-length-header allocation (add a `max_length`/byte-budget option), switch payload slices to `[]const u8`, de-duplicate the RPC packing functions, and either document or redesign the self-referential `Unpacker` — the rest is polish.

## Robustness (the one real correctness risk)

**Length headers are trusted before any payload arrives.** `startArray`/`startMap`/`startBlob` (`src/unpacker.zig:209-297`) allocate whatever the wire says. A corrupted or truncated 5-byte input like `\xdd\xff\xff\xff\xff` triggers an attempted allocation of 4 billion `MsgPackObject`s (~100 GB) — likewise a `str 32` header claims 4 GB and gets it allocated up front. There is a `max_depth` option but no `max_length` / `max_total_bytes`. Even in a non-adversarial setting, a single flipped bit in a stream turns into an OOM abort instead of `InvalidFormat`. For the streaming `Unpacker`, blob lengths could additionally be sanity-checked against `max_buffer_size`. This is the first thing to add.

**`unpack()` silently ignores trailing bytes** (`src/unpacker.zig:632`). `unpack(alloc, "\xc0<garbage>")` succeeds. Callers can't detect concatenated messages or garbage; consider returning the consumed byte count or an error on leftover input.

## API design

- **`MsgPackObject.string/binary/extension.data` should be `[]const u8`** (`src/types.zig:34-35`). The mutable slices are why every test and README example needs the awkward `var s = "hello".*;` dance — you can't build an object from a string literal. `allocator.free` accepts const slices, so `freeObject` still works. This is the single biggest ergonomics win available.
- **The RPC pack functions exist twice**, verbatim: `src/packer.zig:389-426` (`packRpcRequest/Response/Notification`) and `src/rpc.zig:134-171` (`packRequest/Response/Notification`), and both are exported from `root.zig` under different names. That's a maintenance hazard and a confusing surface — keep the `rpc.zig` set and have any convenience wrappers delegate.
- **Type asymmetry on unpack:** unsigned values ≤ `maxInt(i64)` come back as `.integer`, larger ones as `.unsigned_integer` (`src/unpacker.zig:448-455`). So `.unsigned_integer = 5` does not round-trip to the same tag. This is a common convention (msgpack-c does it), but it's undocumented and forces every consumer to match both variants — worth a doc note at minimum.
- **Error-set pollution:** `MsgPackError` includes all of `RingBufferError` (`src/unpacker.zig:19`), so `unpack()` callers must handle `EndOfBuffer`, `NoRoomInBuffer`, `InvalidBufferSize` that can never occur from a slice parse. `InvalidFormat` is declared but never returned anywhere; `RpcError.UnexpectedResponseType` is likewise unused.
- **README claims "Full MessagePack specification support"** but there's no Timestamp extension (ext type -1) support — it decodes as an opaque extension, which is fine, but the claim overstates it slightly.

## Code quality

- **`Unpacker` is self-referential and only accidentally safe** (`src/unpacker.zig:591-628`). `init` returns `Self` by value, so `reader.ring` and `parser.source` dangle the moment it's copied to the caller. It works only because `next()` re-patches both pointers before every use — a repair with no explaining comment. Anyone adding a new method that touches `self.parser` without the patch gets undefined behavior. Cleaner: don't store `reader`/pointers at all; construct `RingReader{ .ring = &self.ring }` locally inside `next()` and pass it down, or use a pinned-init pattern.
- **`writeByte`/`writeBytes` duck-type on `*RingBuffer`** (`src/packer.zig:16-32`). The `if (@TypeOf(writer) == *RingBuffer)` special case is ad hoc; giving `RingBuffer` its own `writeByte`/`writeAll` methods would delete both branches and make the writer contract uniform.
- **`Packer` has ~20 one-line wrappers each re-importing `packer.zig`** (`src/packer.zig:315-373`). A single file-scope `const stream = @import("packer.zig");` (or renaming the free functions) would remove the repeated inline imports.
- `Session.allocator` is stored but never used, and `deinit` is a no-op — the field misleads readers into thinking the session owns memory (`src/rpc.zig:183-196`).
- `RingBuffer.peek` is exported but unused by the library.

## Performance

Nothing alarming for the intended use (Neovim RPC-scale messages):

- The streaming path copies every byte twice — `feed` memcpys into the ring, then the blob/scalar states memcpy out. That's an inherent cost of the ring design and fine at this scale; `readAvailable` doing bulk copies for blobs (rather than byte-at-a-time) is already the right optimization. If it ever matters, a zero-copy path that parses directly from fed slices and only buffers stragglers would halve memory traffic.
- `RingReader.readAvailable` delegates to `readBytes`, which handles the wrap in one call — good.
- `RingBuffer.init` eagerly allocates the full `max_buffer_size` (1 MB default) even if never used; growable-up-to-max would be friendlier for many small sessions.
- One footgun: `feed()` hard-fails with `NoRoomInBuffer` if a chunk exceeds free ring space, even though the parser could drain it incrementally. Callers must implement feed-a-bit/parse-a-bit backpressure themselves; the README example doesn't mention this. Worth documenting, or having `Unpacker.feed` loop internally (feed what fits, run the parser, repeat).
- `packObject` and `freeObject` recurse without a depth limit. Parsed objects are bounded by `max_depth`, so this only matters for user-constructed trees — acceptable, but an easy `max_depth` check if symmetry is wanted.

## Tests

Coverage is genuinely good. Gaps noticed:

- No test for the huge-length-header case above (it would currently OOM rather than error, which is why it's untested).
- No `0xc1` encountered *inside* a container (verifying cleanup via `reset`).
- No fuzzing — Zig's `std.testing.fuzz` would suit this parser very well and would have surfaced the length-header issue immediately.
