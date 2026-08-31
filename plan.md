In this repo we build a Zig implementation of msgpack. Only the following is needed, as we plan to use this to implement a Neovim rpc client.

  ### 1. Incremental Streaming Unpacker (Unpacker)

  • Why: Neovim sends data asynchronously in arbitrary byte chunks over Unix domain sockets, named pipes, TCP, or
  stdin/stdout.
  • Requirement: A parser that can buffer/feed incoming chunks and incrementally yield complete MessagePack values (or
  notify when more bytes are required), matching how msgpack_stream.py:54-66 processes bytes.

  ### 2. Serializer / Packer (Packer)

  • Why: To serialize outgoing RPC arrays into bytes for transport:
      • Request: [0, msgid, "method_name", [args...]] (see async_session.py:44-52)
      • Notification: [2, "method_name", [args...]] (see async_session.py:56-62)
      • Response: [1, msgid, error, result] (see async_session.py:91-147)
  • In Zig, this is typically implemented using a std.ArrayList(u8) or std.io.AnyWriter.

  ### 3. Extension Type Support (ExtType)

  • Why: Neovim represents remote objects (such as Buffer, Window, and Tabpage) using MessagePack Extension types (FixExt
  / Ext8 / Ext16 / Ext32).
  • Requirement:
      • A struct representing an extension tag (type: i8) and a byte slice (data: []const u8).
      • Deserialization and serialization support for extension types.


  ### 4. Buffer Unpack (unpackb)

  • Why: When Neovim returns an ExtType for a remote object, the data payload itself contains a MessagePack-encoded
  integer handle (e.g. the buffer or window ID). As shown in common.py:44:
    self.handle = unpackb(code_data[1])

  • In Zig, unpackb is just decoding a standalone byte slice into an integer/value.
  ──────
  ### Summary

  You do not need complex high-level schema mappers or custom object-graph serialization frameworks. A MessagePack
  implementation in Zig supporting standard primitives (nil, booleans, integers, floats, strings/binaries, arrays, maps),
  Extension types (ExtType), and streaming read/write is all that is required.
