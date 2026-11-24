"""Resolve file references in saved project assertions."""


def saved_file(document, reference):
    if document["schema_version"] in (5, 7) and type(reference) is int:
        files = document["files"]
        if not 0 <= reference < len(files):
            raise ValueError(f"Invalid saved file index {reference}")
        reference = files[reference]
    if not isinstance(reference, str):
        raise TypeError(f"Invalid saved file path {reference!r}")
    return reference


def saved_text(document, reference):
    if document["schema_version"] not in (5, 7) or not reference.startswith("~"):
        return reference
    if reference.startswith("~~"):
        return reference[1:]
    index = int(reference[1:])
    strings = document["strings"]
    if not 0 <= index < len(strings):
        raise ValueError(f"Invalid saved string index {index}")
    return strings[index]


_COMPRESSED = b"\x00MPCUT1\n"


def read_saved(path):
    """The JSON of a saved project. MPCut writes it compressed: a 16-byte header, then raw DEFLATE."""
    import json
    import zlib
    from pathlib import Path

    data = Path(path).read_bytes()
    if data.startswith(_COMPRESSED):
        size = int.from_bytes(data[8:16], "little")
        data = zlib.decompress(data[16:], wbits=-15)
        if len(data) != size:
            raise ValueError(f"Damaged saved project {path}")
    return json.loads(data)


def _expand_shared(history, shared):
    """Inside history, {"~": n} stands for entry n of the root `shared` list."""
    values = []

    def expand(node, available):
        if isinstance(node, dict):
            if list(node) == ["~"] and type(node["~"]) is int:
                if not 0 <= node["~"] < available:
                    raise ValueError(f"Invalid shared reference {node['~']}")
                return values[node["~"]]
            return {key: expand(value, available) for key, value in node.items()}
        if isinstance(node, list):
            return [expand(item, available) for item in node]
        return node

    for index, entry in enumerate(shared):
        values.append(expand(entry, index))
    return expand(history, len(values))


def _expand_strings(node, strings):
    """"~3" stands for entry 3 of the root `strings` list, and "~~x" for the text "~x"."""
    if isinstance(node, dict):
        return {key: value if key == "media_snapshot" else _expand_strings(value, strings) for key, value in node.items()}
    if isinstance(node, list):
        return [_expand_strings(item, strings) for item in node]
    if isinstance(node, str) and node.startswith("~"):
        return node[1:] if node.startswith("~~") else strings[int(node[1:])]
    return node


def _expand_time(value):
    if not isinstance(value, str):
        return value
    numerator, _, denominator = value.partition("/")
    return {"denominator": int(denominator or 1), "numerator": int(numerator)}


def _expand_binding(binding, files):
    binding = _expand_layout(binding, files)
    return {key: _expand_time(value) if key in ("offset", "sequence_clock_origin") else value
            for key, value in binding.items()}


def _expand_layout(node, files):
    if isinstance(node, list):
        return [_expand_layout(item, files) for item in node]
    if not isinstance(node, dict):
        return node
    result = {}
    for key, value in node.items():
        if key == "media_snapshot":
            result[key] = value
        elif key in ("file", "original_file") and type(value) is int:
            result[key] = files[value]
        elif key == "bindings" and isinstance(value, list):
            rows = []
            for item in value:
                item = _expand_binding(item, files)
                if "track_ids" in item:
                    rows += [{("track_id" if k == "track_ids" else k): (track if k == "track_ids" else v)
                              for k, v in item.items()} for track in item["track_ids"]]
                else:
                    rows.append(item)
            result[key] = rows
        elif key == "binding" and isinstance(value, dict):
            result[key] = _expand_binding(value, files)
        elif key == "import_origin" and "bindings" in node:
            result[key] = _expand_time(value)
        else:
            result[key] = _expand_layout(value, files)
    return result


def expand_saved(document):
    """The plain project document that a saved one stands for. A plain document comes back as it is."""
    versions = {5: 4, 7: 6}
    if not isinstance(document, dict) or document.get("schema_version") not in versions:
        return document
    document = dict(document)
    files = document.pop("files", [])
    strings = document.pop("strings", [])
    shared = document.pop("shared", [])
    if shared and "history" in document:
        document["history"] = _expand_shared(document["history"], shared)
    document = _expand_layout(_expand_strings(document, strings), files)
    document["schema_version"] = versions[document["schema_version"]]
    return document


def read_project(path):
    """A project file as its plain document, however MPCut saved it."""
    return expand_saved(read_saved(path))
