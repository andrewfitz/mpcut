"""Inspect MPCut projects and files using Python 3 and the bundled stdio helper."""

import argparse
import base64
import json
import math
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
    def __init__(self, helper, *arguments, env=None, poll_interval=0.25, timings=False):
        self.started = time.perf_counter()
        self.poll_interval = poll_interval
        self.timings = [] if timings else None
        self.process = subprocess.Popen([str(helper), *arguments], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True)
        self.next_id = 0
        self.record("helper_spawn", self.started)

    def record(self, operation, started, *, ended=None, **fields):
        if self.timings is not None:
            if ended is None:
                ended = time.perf_counter()
            self.timings.append(dict(operation=operation, start_seconds=started - self.started,
                                     duration_seconds=ended - started, **fields))

    def wait_for_poll(self):
        started = time.perf_counter()
        time.sleep(self.poll_interval)
        self.record("poll_wait", started)

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
        started = time.perf_counter()
        self.next_id += 1
        params["_meta"] = {"io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                           "io.modelcontextprotocol/clientInfo": {"name": "MPCut walkthrough", "version": "1"},
                           "io.modelcontextprotocol/clientCapabilities": {}}
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        line_out = json.dumps(request) + "\n"
        self.process.stdin.write(line_out)
        self.process.stdin.flush()
        for line in self.process.stdout:
            response = json.loads(line)
            if response.get("id") == self.next_id:
                if self.timings is not None:
                    self.record(params.get("name", method), started, ended=time.perf_counter(),
                                request_bytes=len(line_out.encode("utf-8")),
                                response_bytes=len(line.encode("utf-8")))
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

    def job_result(self, status):
        if "result" in status:
            return status["result"]
        if "result_bytes" not in status:
            raise ValueError("Wait for the file job to finish before reading its result.")
        total = status["result_bytes"]
        data = bytearray()
        while len(data) < total:
            offset = len(data)
            page = self.call("file_job_result_read", job_id=status["job_id"], offset=offset)
            data.extend(base64.b64decode(page["base64"], validate=True))
            if (page["offset"] != offset or page["next_offset"] != len(data)
                    or page["result_bytes"] != total or not offset < len(data) <= total
                    or page["done"] != (len(data) == total)):
                raise ValueError("File job returned an inconsistent result page.")
        return json.loads(data)


def inspect_file(client, path):
    job = client.call("media_file_inspect", operation_id=str(uuid.uuid4()),
                      file=str(path.resolve()), detail="metadata", no_sidecar=True)
    job_id = job["job_id"]
    while job["state"] in ("running", "cancelling"):
        client.wait_for_poll()
        job = client.call("file_job_status_read", job_id=job_id)
    if job["state"] != "succeeded":
        print(json.dumps(job, indent=2), file=sys.stderr)
        raise ValueError("Inspection failed. See the job diagnostic above.")
    job["result"] = client.job_result(job)
    print(json.dumps(job, indent=2))



def export_quote(client, args, tools):
    required = {"project_open", "project_editor_state_read", "export_queue_list", "transcript_editor_attachments_list", "transcript_editor_words_search",
                "transcript_editor_edit_plan", "transcript_editor_excerpt_queue",
                "export_queue_plan", "export_queue_render", "export_editor_job_status_read", "media_file_inspect", "file_job_status_read", "file_job_result_read"}
    if args.import_transcript:
        required.add("transcript_editor_attachment_import")
    if missing := required - tools:
        raise ValueError(f"Missing quote workflow tools: {', '.join(sorted(missing))}")
    output_dir = args.output_dir.resolve()
    if not output_dir.is_dir() or any(output_dir.iterdir()):
        raise ValueError("Choose an existing, empty output directory.")
    target = {"project_handle": client.call("project_open", project_path=str(args.transcript_project.resolve()),
                                      operation_id=str(uuid.uuid4()))["project_handle"]}
    while True:
        state = client.call("project_editor_state_read", **target, limit=1)
        if state.get("can_edit") or (state["kind"] == "sequence" and state.get("busy") is False):
            break
        client.wait_for_poll()

    queue = client.call("export_queue_list", **target)
    if queue["ranges"]:
        raise ValueError("Open a project with an empty export queue.")
    inspection = client.call("transcript_editor_attachments_list", **target, limit=2)
    if args.import_transcript:
        if inspection["total"] != 0:
            raise ValueError("Open a project with no transcript when importing for this walkthrough.")
        binding = {"track_id": args.bind_track, "audio_stream_index": args.bind_stream}
        if args.bind_source:
            binding["source_id"] = args.bind_source
        else:
            binding["file"] = str(args.bind_file.resolve())
        transcript_path = args.import_transcript.resolve()
        format_name = transcript_path.suffix.lower()[1:]
        if format_name not in ("json", "srt", "vtt"):
            raise ValueError("Choose a JSON, SRT, or WebVTT transcript.")
        client.call("transcript_editor_attachment_import", **target, path=str(transcript_path),
                    format=format_name, bindings=[binding], expected_revision=state["revision"],
                    expected_transcript_revision=inspection["transcript_revision"], operation_id=str(uuid.uuid4()))
        inspection = client.call("transcript_editor_attachments_list", **target, limit=2)
        print("Imported transcript", transcript_path)
    if inspection["total"] != 1:
        raise ValueError("Open a project with one attached transcript.")
    revisions = {"expected_revision": state["revision"],
                 "expected_transcript_revision": inspection["transcript_revision"],
                 "attachment_id": inspection["attachment_id"], "result_id": inspection["result_id"]}
    search = client.call("transcript_editor_words_search", **target, **revisions, query=args.quote,
                         space="current_cut", offset=(args.match or 1) - 1, limit=1)
    if not search["items"] or (search["total"] > 1 and args.match is None):
        raise ValueError(f"Found {search['total']} occurrences. Choose one with --match NUMBER.")
    words = search["items"][0]["words"]
    first, last = words[0], words[-1]
    selection = {"space": "current_cut", "first_word_id": first["word_id"], "last_word_id": last["word_id"],
                 "first_occurrence_id": first["id"], "last_occurrence_id": last["id"]}
    reviewed = client.call("transcript_editor_edit_plan", **target, **revisions,
                           operation_id=str(uuid.uuid4()), edit={"action": "queue", "selections": [selection],
                                                                "name": "Transcript quote"})
    print("Quote plan", json.dumps(reviewed, indent=2))
    queued = client.call("transcript_editor_excerpt_queue", **target, **revisions, operation_id=str(uuid.uuid4()),
                         plan_id=reviewed["plan_id"], name="Transcript quote")
    print("Queued quote", queued["queue_id"])

    settings = {"container": args.container, "output": str(output_dir),
                "tracks": "audio" if args.container == "wav" else "all",
                "mode": "copy" if args.container == "wav" else "smart"}

    def export(dry_run):
        started = client.call("export_queue_plan" if dry_run else "export_queue_render", **target, **settings,
                              expected_revision=queued["revision"], operation_id=str(uuid.uuid4()))
        while True:
            job = client.call("export_editor_job_status_read", **target, job_id=started["job_id"])
            if job["state"] == "succeeded":
                return job
            if job["state"] not in ("running", "cancelling"):
                raise ValueError(f"Quote export failed: {job}")
            client.wait_for_poll()

    preflight = export(True)
    if len(preflight.get("result", {}).get("destinations", [])) != 1:
        raise ValueError(f"The quote preflight did not resolve one destination: {preflight}")
    rendered = export(False)
    if rendered.get("outputs") != preflight["result"]["destinations"]:
        raise ValueError(f"Export did not publish the reviewed destination: {rendered}")
    path = Path(rendered["outputs"][0])
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Published quote is missing or empty: {path}")
    inspect_file(client, path)
    print("Verified quote export", path)


def inspect(client, args):
    names = {entry["name"] for entry in client.pages("tools/list", "tools")}
    print(f"Discovered {len(names)} tools.")
    if args.discovery:
        available = {entry["uri"] for entry in client.pages("resources/list", "resources")}
        expected = GUIDES | ({"mpcut://docs/headless"} if args.files_only else set())
        missing = expected - available
        if missing:
            raise ValueError(f"Missing documentation resources: {', '.join(sorted(missing))}")
        for uri in sorted(expected):
            content = client.request("resources/read", uri=uri)["contents"][0]
            print(uri, content["text"].splitlines()[0])
        return
    if args.transcript_project:
        export_quote(client, args, names)
        return
    if args.file:
        inspect_file(client, args.file)
        return
    if not args.project:
        print(json.dumps(client.call("project_windows_list")["projects"], indent=2))
        return
    target = {"project_handle": args.project}
    state = client.call("project_editor_state_read", **target, limit=5)
    print("Timeline", json.dumps(state, indent=2))
    print("History", json.dumps(client.call("history_read", **target), indent=2))
    print("Presentation", json.dumps(client.call("workspace_layout_read", **target), indent=2))
    print("Analysis", json.dumps(client.call("analysis_editor_state_read", **target, limit=5), indent=2))
    print("Export queue", json.dumps(client.call("export_queue_list", **target), indent=2))
    if state["kind"] == "multicam":
        sources = client.call("multicam_state_read", **target, section="sources", limit=5)
        print("Group sources", json.dumps(sources, indent=2))


def timed_out(_signum, _frame):
    raise TimeoutError("The walkthrough timed out. Check the helper connection or increase --timeout.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=Path("/Applications/MPCut.app/Contents/Helpers/mpcut-mcp"))
    parser.add_argument("--files-only", action="store_true", help="run a private file worker for --discovery or --file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--discovery", action="store_true", help="list tools and read offline guides")
    mode.add_argument("--project", help="inspect this live handle from the default listing")
    mode.add_argument("--file", type=Path, help="inspect metadata of this file via a CLI job")
    mode.add_argument("--transcript-project", type=Path, help="open a saved project and export one transcript quote")
    parser.add_argument("--quote", help="phrase to search in Current Cut")
    parser.add_argument("--match", type=int, help="one-based search occurrence when a phrase repeats")
    parser.add_argument("--output-dir", type=Path, help="existing empty directory for the quote export")
    parser.add_argument("--container", choices=("mov", "wav"), default="mov", help="quote export container")
    parser.add_argument("--import-transcript", type=Path, help="attach a transcript to a project opened for quote export")
    binding = parser.add_mutually_exclusive_group()
    binding.add_argument("--bind-source", help="multicam source ID for the imported track")
    binding.add_argument("--bind-file", type=Path, help="sequence recording for the imported track")
    parser.add_argument("--bind-stream", type=int, help="absolute stream index for transcript import")
    parser.add_argument("--bind-track", default="source", help="imported transcript track ID")
    parser.add_argument("--timeout", type=int, default=60, help="seconds to wait for the walkthrough")
    parser.add_argument("--poll-interval", type=float, default=0.25,
                        help="seconds between status requests")
    parser.add_argument("--timings", type=Path, help="write client timings to a new JSON file")
    args = parser.parse_args()
    if not math.isfinite(args.poll_interval) or args.poll_interval <= 0:
        parser.error("--poll-interval must be finite and positive")
    if args.files_only and not (args.discovery or args.file):
        parser.error("--files-only requires --discovery or --file")
    if args.transcript_project and (not args.quote or not args.output_dir):
        parser.error("--transcript-project requires --quote and --output-dir")
    if args.import_transcript and (not args.transcript_project or not (args.bind_source or args.bind_file)
                                   or args.bind_stream is None or args.bind_stream < 0):
        parser.error("--import-transcript requires a transcript project, a binding source or file, and a stream index")
    if args.match is not None and args.match < 1:
        parser.error("--match must be positive")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    signal.signal(signal.SIGALRM, timed_out)
    try:
        if args.timings and args.timings.exists():
            raise FileExistsError(f"Timing file already exists: {args.timings}")
        arguments = ("--files-only",) if args.files_only else ()
        client = Client(args.helper.expanduser().resolve(), *arguments,
                        poll_interval=args.poll_interval, timings=args.timings is not None)
        try:
            signal.alarm(args.timeout)
            inspect(client, args)
            client.record("walkthrough", client.started)
        finally:
            signal.alarm(0)
            close_started = time.perf_counter()
            client.close()
            client.record("helper_shutdown", close_started)
            if args.timings:
                with args.timings.open("x", encoding="utf-8") as report:
                    json.dump(client.timings, report, indent=2)
                    report.write("\n")
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
