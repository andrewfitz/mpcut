"""Read logical bytes for integration tests that inspect or reseal SQLite sections."""
import ctypes


def section_bytes(db, key):
    stored, size = db.execute("SELECT value, logical_size FROM sections WHERE name=?", (key,)).fetchone()
    if not size:
        return stored
    if stored[0] != 1:
        raise ValueError(f"Expected an ordinary LZFSE section for {key}")
    decode = ctypes.CDLL("/usr/lib/libcompression.dylib").compression_decode_buffer
    decode.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                       ctypes.c_void_p, ctypes.c_int)
    decode.restype = ctypes.c_size_t
    result = ctypes.create_string_buffer(size)
    if decode(result, size, stored[1:], len(stored) - 1, None, 0x801) != size:
        raise ValueError(f"Invalid compressed section {key}")
    return result.raw
