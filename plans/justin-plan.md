# API needed

Basing the API on the pynvim use of msgpack which uses Unpacker.

  In msgpack_stream.py:13-65:

  1. Initialization (msgpack_stream.py:24):
    self._unpacker = Unpacker()

  2. Feeding data & iterating over messages (msgpack_stream.py:54-65):
  When chunks of bytes are received from the event loop, they are fed into the unpacker buffer and unpacked iteratively
  until StopIteration indicates more data is needed:
    def _on_data(self, data: bytes) -> None:
        self._unpacker.feed(data)
        while True:
            try:
                debug('waiting for message...')
                msg = next(self._unpacker)
                debug('received message: %s', msg)
                assert self._message_cb is not None
                self._message_cb(msg)
            except StopIteration:
                debug('unpacker needs more data...')
                break

Note the callback approach may or may not be the best interface in Zig.



