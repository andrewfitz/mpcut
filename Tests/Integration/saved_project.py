"""Read saved projects as their plain documents in test assertions."""


def read_saved(path):
    """The JSON of a saved project."""
    import json
    from pathlib import Path

    return json.loads(Path(path).read_bytes())


def _expand_refs(document):
    """A saved project lists what it repeats once, in a root `refs` table keyed by content.

    "~KEY" stands for a text entry, {"~": "KEY"} for an object or list entry, and "~~x" for
    the text "~x". A `media_snapshot` is carried as it is.
    """
    refs = document["refs"]
    done = {}

    def value(key):
        if key not in done:
            if key not in refs or isinstance(refs[key], str):
                raise ValueError(f"Invalid refs entry {key!r}")
            done[key] = expand(refs[key])
        return done[key]

    def expand(node):
        if isinstance(node, str) and node.startswith("~"):
            if node.startswith("~~"):
                return node[1:]
            if not isinstance(refs.get(node[1:]), str):
                raise ValueError(f"Invalid refs entry {node[1:]!r}")
            return refs[node[1:]]
        if isinstance(node, list):
            return [expand(item) for item in node]
        if isinstance(node, dict):
            if list(node) == ["~"]:
                return value(node["~"])
            return {key: item if key == "media_snapshot" else expand(item) for key, item in node.items()}
        return node

    return expand({key: item for key, item in document.items() if key != "refs"})


def expand_saved(document):
    """The plain project document that a saved one stands for. A plain document comes back as it is."""
    if not isinstance(document, dict) or not isinstance(document.get("refs"), dict):
        return document
    document = _expand_refs(document)
    # `base` marks the edit a history was saved for. Like `refs`, it belongs to the saved layout.
    if isinstance(document.get("history"), dict):
        document["history"] = {name: value for name, value in document["history"].items() if name != "base"}
    return document


def read_project(path):
    """A project file as its plain document, however MPCut saved it."""
    return expand_saved(read_saved(path))


def media_paths(document):
    """Every media path a project document names."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("file", "original_file") and isinstance(value, str):
                    found.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(document)
    return found
