"""Check the request contract shared by the app and the separately installed Premiere panel."""

import re
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PremiereBridgeTests(unittest.TestCase):
    def test_panel_reads_the_request_emitted_by_mpcut(self):
        swift = (ROOT / "Sources/MPCutCore/PremiereInterchange.swift").read_text()
        panel = (ROOT / "packaging/premiere/index.js").read_text()
        request = swift.split("struct Request: Encodable {", 1)[1].split("private struct Result", 1)[0]
        keys = re.findall(r'^\s*case (\w+)(?: = "(\w+)")?$', request, re.MULTILINE)
        emitted = {serialized or name for name, serialized in keys}
        consumed = set(re.findall(r"\bjob\.(\w+)", panel))

        self.assertTrue(emitted)
        self.assertEqual(consumed, emitted)
        self.assertEqual(re.search(r"static let protocolVersion = (\d+)", swift)[1],
                         re.search(r"const protocolVersion = (\d+)", panel)[1])

    @unittest.skipUnless(shutil.which("node"), "Node.js is required to run the Premiere panel")
    def test_mailbox_failures_do_not_block_the_next_conversion(self):
        script = r"""
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const responses = new Map();
const deleted = [];
const directory = {
    async getEntries() {
        return [
            { name: "job-1.json", async read() { throw Error("Request disappeared"); } },
            { name: "job-2.json", async read() { return "{"; }, async delete() { deleted.push(2); } },
            {
                name: "job-3.json",
                async read() { return "{}"; },
                async delete() { deleted.push(3); },
            },
            {
                name: "job-4.json",
                async read() {
                    return JSON.stringify({
                        protocol_version: 3, operation: "read", project_path: "/tmp/copy.prproj",
                        timeline_xml_path: "/tmp/copy.xml", allow_loss: true, expected_angle_numbers: [],
                    });
                },
                async delete() { deleted.push(4); },
            },
        ];
    },
    async createFile(name) {
        if (name === "result-3.json") throw Error("Response file is unavailable");
        return { async write(value) { responses.set(name, value); } };
    },
};
const sequence = { async getVideoTrackCount() { return 0; }, async getAudioTrackCount() { return 0; } };
const project = {
    async getSequences() { return [sequence]; },
    async getActiveSequence() { return sequence; },
    async close() {},
};
const context = {
    require(name) {
        if (name === "uxp") return { storage: { localFileSystem: { async getDataFolder() { return directory; } } } };
        return {
            Project: { async open(path) { assert.equal(path, "/tmp/copy.prproj"); return project; } },
            ProjectConverter: {
                async exportAsFinalCutProXML(target, path) {
                    assert.equal(target, sequence);
                    assert.equal(path, "/tmp/copy.xml");
                    return true;
                },
            },
            OpenProjectOptions: class { setShowLocateFileDialog() {} setShowWarningDialog() {} setAddToMRUList() {} },
            CloseProjectOptions: class { setPromptIfDirty() { return this; } },
        };
    },
    document: { getElementById() { return {}; } },
    setInterval() {},
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), context).then(() => {
    assert.deepEqual(deleted, [2, 3, 4]);
    assert.match(JSON.parse(responses.get("result-2.json")).error, /SyntaxError/);
    assert.deepEqual(JSON.parse(responses.get("result-4.json")), { warnings: [] });
}).catch(error => { console.error(error); process.exitCode = 1; });
"""
        subprocess.run(["node", "-e", script, ROOT / "packaging/premiere/index.js"], check=True)
