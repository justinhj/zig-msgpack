# Arena-Copy vs. Borrowed Sliding-Buffer Decoding

`zig-msgpack` currently uses an arena-copy-friendly streaming model: incoming
wire bytes enter a fixed-size ring buffer, and `Unpacker.nextAlloc` builds the
decoded `MsgPackObject` tree with the allocator supplied by the caller.

Strings, binary values, and extension payloads are copied from the ring buffer
to allocator-owned memory. Arrays and maps have contiguous backing storage;
scalar values are stored inline in `MsgPackObject`. An application can decode a
complete message into an arena, process it, then call
`arena.reset(.retain_capacity)` to reclaim all message memory while retaining
the arena's capacity for the next message.

An alternative is a borrowed, sliding-buffer decoder. It parses container
metadata, but strings, binary values, and extension payloads are slices that
point directly into a buffer retaining the original wire bytes.

| Area | Current: copy into arena | Borrowed: point into sliding buffer |
| --- | --- | --- |
| Blob processing | Copies each string, binary value, and extension payload once | Avoids copying payload bytes |
| Memory retained | Ring buffer plus decoded tree and copied payloads | Decoded tree plus raw bytes for every live message |
| Object lifetime | A decoded message remains usable while its arena remains alive, even as more data is read | Objects become invalid when their source bytes are compacted, overwritten, or released |
| Streaming behavior | The parser can consume and reuse ring-buffer space immediately | The transport must retain source bytes until all borrowers release them |
| Large payloads | Allocates/copies the payload, which is predictable but can be expensive | Avoids a payload allocation, but the sliding buffer must retain the entire payload |
| Cache behavior | Sequential parsing and arena allocation usually provide good locality; array/map storage is contiguous | Wire bytes are contiguous, but object metadata and source data remain separate |
| API ergonomics | Handle the object, then reset/free its allocation scope | Callers need an explicit release/acknowledgement protocol and must avoid dangling slices |
| Pipelining | Multiple decoded messages can remain live without holding transport storage | Buffer capacity must cover all unread or un-released message bytes |
| Failure modes | Allocation limits and arena lifetime are the principal concerns | Lifetime bugs and accidental buffer retention are additional concerns |

## Current model: lifecycle

1. Bytes arrive in the ring buffer.
2. The parser consumes bytes incrementally.
3. `nextAlloc(arena.allocator())` creates the message tree and copies blob
   payloads into the arena.
4. The application handles the complete object.
5. `arena.reset(.retain_capacity)` reclaims the message's allocations in
   effectively constant time.

This is a good default for RPC clients and servers. A request handler can retain
its decoded request for the duration of processing, while the transport keeps
reading and reusing its ring buffer independently.

## Important constraint for the current API

Keep the same allocator alive and pass that allocator to every `nextAlloc` call
until the current message completes. A call returning `error.Incomplete` means
the parser may retain partial arrays, maps, or blob data allocated through that
allocator. Do not reset the arena or switch allocators at that point. Reset it
only after receiving a complete object and finishing with that object.

## When borrowing is preferable

Borrowing is compelling for large binary blobs, proxies, and other workloads
that consume a decoded value immediately and do not need to retain it. It can
eliminate the dominant memory copy and allocation in those workloads.

The API needs to make the lifetime explicit. A robust shape would be:

```zig
const borrowed = try unpacker.next();
defer unpacker.release(borrowed.lease);

handleMessage(borrowed.object);
```

`release` would tell the unpacker that the corresponding source bytes may be
reclaimed or compacted. Borrowed values must not outlive their lease, and the
unpacker must avoid overwriting their backing bytes while the lease is live.

## A practical hybrid

A hybrid decoder can allocate array/map metadata in an arena while borrowing
string, binary, and extension payloads from the sliding buffer. This preserves
convenient, contiguous container traversal while removing most payload copying.
It still needs leases and backpressure, since retained blobs keep transport
storage live.

Providing both modes is often the best public design:

- Arena-copy decoding for safe, general-purpose RPC handling.
- Borrowed decoding for immediate-consumption, high-throughput, or large-blob
  workloads.
