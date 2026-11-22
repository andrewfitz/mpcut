"""Inspect a running MPCut session using Python 3 and the bundled stdio helper."""

import argparse
import base64
import json
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

PROTOCOL_VERSION = "2026-07-28"
GUIDES = {
    "mpcut://docs/agent-guide",
    "mpcut://docs/tool-reference",
}


class Client:
    def __init__(self, helper):
        self.process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True)
        self.next_id = 0

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        finally:
            self.process.stdout.close()

    def request(self, method, **params):
        self.next_id += 1
        params["_meta"] = {"io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                           "io.modelcontextprotocol/clientCapabilities": {}}
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        for line in self.process.stdout:
            response = json.loads(line)
            if response.get("id") == self.next_id:
                if "error" in response:
                    error = response["error"]
                    raise ValueError(f"{method}: {error['code']}: {error['message']}")
                return response["result"]
        raise RuntimeError(f"The helper exited before replying to {method}.")

    def pages(self, method, key):
        params = {}
        while True:
            page = self.request(method, **params)
            yield from page[key]
            cursor = page.get("nextCursor")
            if not cursor:
                return
            params = {"cursor": cursor}

    def call(self, tool, **arguments):
        result = self.request("tools/call", name=tool, arguments=arguments)
        data = result.get("structuredContent")
        if result.get("isError"):
            if isinstance(data, dict) and "code" in data and "message" in data:
                raise ValueError(f"{tool}: {data['code']}: {data['message']}")
            messages = [block["text"] for block in result.get("content", []) if block.get("type") == "text"]
            raise ValueError(f"{tool}: {' '.join(messages) or 'Tool call failed.'}")
        if not isinstance(data, dict):
            raise ValueError(f"{tool}: expected an object in structuredContent.")
        return data


def inspect_file(client, path):
    job = client.call("file_inspect", operationID=str(uuid.uuid4()),
                      file=str(path.resolve()), detail="metadata", no_sidecar=True)
    job_id = job["job_id"]
    while job["state"] in ("running", "cancelling"):
        time.sleep(0.25)
        job = client.call("file_job_status", job_id=job_id)
    if job["state"] != "succeeded":
        print(json.dumps(job, indent=2), file=sys.stderr)
        raise ValueError("Inspection failed. See the job diagnostic above.")
    if "result" not in job and job.get("result_bytes", 0) > 0:
        data = bytearray()
        while True:
            page = client.call("file_job_result", job_id=job_id, offset=len(data))
            data.extend(base64.b64decode(page["base64"], validate=True))
            if page["next_offset"] != len(data):
                raise ValueError("File job returned an inconsistent byte offset.")
            if page["done"]:
                break
        job["result"] = json.loads(data)
    print(json.dumps(job, indent=2))


def inspect(client, args):
    names = {entry["name"] for entry in client.pages("tools/list", "tools")}
    print(f"Discovered {len(names)} tools.")
    if args.discovery:
        available = {entry["uri"] for entry in client.pages("resources/list", "resources")}
        missing = GUIDES - available
        if missing:
            raise ValueError(f"Missing documentation resources: {', '.join(sorted(missing))}")
        for uri in sorted(GUIDES):
            content = client.request("resources/read", uri=uri)["contents"][0]
            print(uri, content["text"].splitlines()[0])
        return
    if args.file:
        inspect_file(client, args.file)
        return
    if not args.project:
        print(json.dumps(client.call("list_projects")["projects"], indent=2))
        return
    target = {"project": args.project}
    state = client.call("get_editor_state", **target, limit=5)
    print("Timeline", json.dumps(state, indent=2))
    print("History", json.dumps(client.call("get_history", **target), indent=2))
    print("Presentation", json.dumps(client.call("get_presentation", **target), indent=2))
    print("Analysis", json.dumps(client.call("analysis_state", **target, limit=5), indent=2))
    print("Export queue", json.dumps(client.call("get_export_queue", **target), indent=2))
    if state["kind"] == "multicam":
        sources = client.call("get_multicam", **target, section="sources", limit=5)
        print("Group sources", json.dumps(sources, indent=2))


def timed_out(_signum, _frame):
    raise TimeoutError("The walkthrough timed out. Check the helper connection or increase --timeout.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=Path("/Applications/MPCut.app/Contents/Helpers/mpcut-mcp"))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--discovery", action="store_true", help="list tools and read offline guides")
    mode.add_argument("--project", help="inspect this live handle from the default listing")
    mode.add_argument("--file", type=Path, help="inspect metadata of this file via a CLI job")
    parser.add_argument("--timeout", type=int, default=60, help="seconds to wait for the walkthrough")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    signal.signal(signal.SIGALRM, timed_out)
    try:
        client = Client(args.helper.expanduser().resolve())
        try:
            signal.alarm(args.timeout)
            inspect(client, args)
        finally:
            signal.alarm(0)
            client.close()
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
