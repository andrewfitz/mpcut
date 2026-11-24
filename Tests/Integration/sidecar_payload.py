"""Read logical bytes for integration tests that inspect or reseal SQLite sections."""
import ctypes


def _lzfse(stored, capacity):
    decode = ctypes.CDLL("/usr/lib/libcompression.dylib").compression_decode_buffer
    decode.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                       ctypes.c_void_p, ctypes.c_int)
    decode.restype = ctypes.c_size_t
    result = ctypes.create_string_buffer(capacity)
    written = decode(result, capacity, stored, len(stored), None, 0x801)
    return result.raw[:written]


def _varint(data, position):
    value = shift = 0
    while True:
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, position
        shift += 7


def section_digest(db, key):
    """What tells one section's contents from another without decoding them."""
    return db.execute("SELECT digest FROM sections WHERE name=?", (key,)).fetchone()[0]


def section_bytes(db, key):
    stored, size = db.execute("SELECT value, logical_size FROM sections WHERE name=?", (key,)).fetchone()
    if not size:
        return stored
    if stored[0] == 1:
        result = _lzfse(stored[1:], size)
    elif stored[0] == 11:
        # Float32 runs are stored with their four byte planes apart. A list of the runs comes first.
        packed = _lzfse(stored[1:], size + 161)
        count, position = _varint(packed, 0)
        cursor, regions = 0, []
        for _ in range(count):
            gap, position = _varint(packed, position)
            samples, position = _varint(packed, position)
            regions.append((cursor + gap, samples))
            cursor += gap + 4 * samples
        body = bytearray(packed[position:])
        for start, samples in regions:
            planes = bytes(body[start:start + 4 * samples])
            for plane in range(4):
                body[start + plane:start + 4 * samples:4] = planes[plane * samples:(plane + 1) * samples]
        result = bytes(body)
    else:
        raise ValueError(f"Section {key} is stored in a packed form this reader does not expand (tag {stored[0]})")
    if len(result) != size:
        raise ValueError(f"Invalid compressed section {key}: tag {stored[0]}, expected {size} bytes, read {len(result)}")
    return result
