"""Check the public MPCut vocabulary in catalogs and shipped agent workflows."""

import ast
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Sources/MPCutApp/MCPResources"
IDENTIFIER = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*")


def schemas_for_object(node, inherited=frozenset()):
    """Constraints in a conditional or union apply to the same object."""
    if not isinstance(node, dict):
        return
    properties = node.get("properties", {})
    available = inherited.union(properties)
    yield node, available
    for keyword in ("allOf", "anyOf", "oneOf"):
        for branch in node.get(keyword, []):
            yield from schemas_for_object(branch, available)
    for keyword in ("if", "then", "else", "not"):
        yield from schemas_for_object(node.get(keyword), available)
    for field in properties.values():
        yield from schemas_for_object(field)
    yield from schemas_for_object(node.get("items"))


class PublicContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = {}
        for path in sorted(CATALOG.glob("*.json")):
            for tool in json.loads(path.read_text()):
                name = tool["name"]
                if name in cls.tools:
                    raise AssertionError(f"{path.name} duplicates MCP tool {name}")
                cls.tools[name] = tool

    def test_catalog_identifiers_and_argument_boundaries(self):
        self.assertTrue(self.tools)
        for name, tool in self.tools.items():
            with self.subTest(tool=name):
                self.assertRegex(name, rf"^{IDENTIFIER.pattern}$")
                schema = tool["inputSchema"]
                self.assertIs(schema.get("additionalProperties"), False)
                for branch, fields in schemas_for_object(schema):
                    self.assertEqual(sorted(k for k in fields if not IDENTIFIER.fullmatch(k)), [])
                    self.assertEqual(sorted(set(branch.get("required", [])) - fields), [])

    def test_distinct_operations_have_no_effect_selector(self):
        # These operations are selected by name. Accepting the former selector
        # would allow a caller to request the opposite effect in the same input.
        families = [
            (("playback_transport_play", "playback_transport_pause"), {"playing"}),
            (("export_queue_plan", "export_queue_render", "export_editor_project_plan",
              "export_editor_project_render"), {"dry_run"}),
            (("project_file_resolve_import", "project_file_resolve_export",
              "project_editor_resolve_import", "project_editor_resolve_export"), {"open"}),
            (("silence_file_scan",), {"output", "export_to", "dry_run", "report"}),
            (("scenes_file_scan",), {"export_to", "output", "dry_run"}),
        ]
        for names, selectors in families:
            for name in names:
                with self.subTest(tool=name):
                    fields = self.tools[name]["inputSchema"]["properties"]
                    self.assertFalse(selectors.intersection(fields), selectors.intersection(fields))

    def test_walkthrough_calls_match_discovery(self):
        path = ROOT / "docs/mcp_walkthrough.py"
        for call in ast.walk(ast.parse(path.read_text())):
            if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Attribute):
                continue
            if call.func.attr != "call" or not call.args or not isinstance(call.args[0], ast.Constant):
                continue
            name = call.args[0].value
            with self.subTest(line=call.lineno, tool=name):
                self.assertTrue(name in self.tools, f"Unknown MCP tool {name}")
                declared = self.tools[name]["inputSchema"]["properties"].keys()
                self.assertEqual(sorted(kw.arg for kw in call.keywords if kw.arg and kw.arg not in declared), [])

    def test_documented_tool_links_resolve(self):
        headings = re.findall(r"^### `([a-z][a-z0-9_]+)`$", (ROOT / "docs/MCP-REFERENCE.md").read_text(), re.M)
        self.assertCountEqual(headings, self.tools.keys())

    def test_live_test_calls_match_discovery(self):
        # Only tool calls with a literal target. Dynamic cases run against the staged bundle.
        for path in sorted((ROOT / "mcp/integration").glob("*_test.go")):
            for match in re.finditer(r'\b(?:call|mutate)\("([a-z][a-z0-9_]*)",', path.read_text()):
                name = match.group(1)
                with self.subTest(file=path.name, tool=name):
                    self.assertTrue(name in self.tools, f"Unknown MCP tool {name}")


if __name__ == "__main__":
    unittest.main()
