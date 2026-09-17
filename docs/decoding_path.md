# Decoding Path: An Array Containing Two Strings

This example follows the decoding of:

    ["a", "b"]

The MessagePack bytes are:

    0x92 0xa1 'a' 0xa1 'b'

0x92 means “array with 2 elements”. Each 0xa1 means “string with 1 byte”.

## One-shot path: unpack

The call is:

    const obj = try msgpack.unpack(allocator, bytes);

The sequence is:

1. unpack creates a SliceReader over the input bytes.

       var reader = SliceReader{ .buffer = buffer, .pos = 0 };

2. It creates a Parser(SliceReader) and calls parser.parseObject().

3. parseObject repeatedly calls parser.step().

4. step reads 0x92, recognizes a fixarray, and calls:

       startArray(2)

   startArray:

   - allocates space for two MsgPackObject values;
   - pushes an array frame onto the parser stack;
   - sets the frame count to 0 and total to 2.

   Conceptually, the stack now contains:

       array frame
         items: [ ?, ? ]
         count: 0
         total: 2

5. step reads 0xa1, recognizes a one-byte string, and calls:

       startBlob(.string, 0, 1)

   startBlob allocates one byte for the string and changes the parser state to
   .blob.

6. On the next loop iteration, the .blob state copies 'a' from the reader into
   the allocated string buffer. It creates:

       MsgPackObject{ .string = "a" }

7. routeObject sees the array frame and stores the string in element zero:

       array frame
         items: [ "a", ? ]
         count: 1
         total: 2

8. The parser reads the second 0xa1, allocates another one-byte string, and
   copies 'b'.

9. routeObject stores "b" in element one:

       array frame
         items: [ "a", "b" ]
         count: 2
         total: 2

10. Since the array is complete, the frame is popped and the parser returns:

        MsgPackObject{
            .array = [
                .{ .string = "a" },
                .{ .string = "b" },
            ],
        }

11. The caller owns the result and eventually calls:

        msgpack.freeObject(allocator, obj);

    This recursively frees the "a" buffer, the "b" buffer, and the array
    backing storage.

The allocation shape is approximately:

    array backing storage
    ├── string "a" backing storage
    └── string "b" backing storage

## Streaming path: Unpacker

With streaming input:

    try unpacker.feed(bytes);
    const obj = try unpacker.nextAlloc(arena.allocator());

feed first copies the bytes into the ring buffer. nextAlloc then:

1. points the parser at the ring-buffer reader;
2. selects the supplied object allocator;
3. calls parser.next();
4. runs the same state machine described above.

If the bytes arrive in pieces, the parser preserves its state. For example,
after receiving only:

    0x92

it has already allocated the array backing storage and stored this frame:

    array frame
      items: [ ?, ? ]
      count: 0
      total: 2

It then returns error.Incomplete. After more bytes are fed, the next call
resumes from the next expected tag rather than reparsing 0x92.

With an arena allocator, all three allocations belong to the arena. After the
complete object has been handled:

    _ = arena.reset(.retain_capacity);

reclaims the whole decoded object at once.

## Allocator lifetime

Keep the same allocator alive, and pass that allocator to every nextAlloc call,
until the current message completes. A call returning error.Incomplete means
the parser may still hold partial arrays, maps, or blob data allocated through
that allocator. Do not reset the arena or switch allocators at that point.
