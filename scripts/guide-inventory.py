"""Print source locations for user-facing controls to review against the MPCut guide."""

import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUIDE = (ROOT / "docs/USAGE.md").read_text()
CONTROL = re.compile(
    r'\b(?:Button|Toggle|Menu|CommandMenu|Picker|Section|LabeledContent|TextField|Stepper|Slider)'
    r'\("([^"\\]+)"'
)


def normalized(text):
    return " ".join(text.casefold().replace("…", "").split())


def inventory(paths, pattern):
    guide = normalized(GUIDE)
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for label in pattern.findall(line):
                present = normalized(label) in guide
                yield (str(path.relative_to(ROOT)) + ":" + str(number),
                       label, "mentioned" if present else "review wording")


def check_commands(executable):
    catalog = json.loads(subprocess.check_output([executable, "help", "--json"]))["commands"]
    topics = set(catalog)
    paths = {topic for topic in topics if " " in topic}
    path_lengths = sorted({len(path.split()) for path in paths}, reverse=True)
    guides = [ROOT / "README.md", *(ROOT / "docs").glob("*.md"), *(ROOT / "plugins").rglob("*.md")]
    invocation = re.compile(r'(?:^|\|\s*)(?:mpcut|"\$(?:mpcut|cli)")\s+([^\n`|;&<>]+)')
    count = 0
    problems = []
    for guide in guides:
        if any(tag in guide.name for tag in ("-PLAN", "-AUDIT", "NAMING-CONVENTION")):
            continue
        for line_no, line in enumerate(guide.read_text().splitlines(), 1):
            for snippet in [line.strip(), *re.findall(r"`([^`]+)`", line)]:
                match = invocation.search(snippet)
                if not match:
                    continue
                words = match[1].split()
                if not words:
                    continue
                words = [word for word in words if word not in ("--json", "--no-sidecar")]
                if not words:
                    valid = False
                elif words[0] == "help":
                    topic = " ".join(words[1:])
                    valid = topic in topics or topic in ("", "manual", "--help")
                elif words[-1] == "--help":
                    valid = len(words) == 1 or " ".join(words[:-1]) in topics
                elif words == ["--version"]:
                    valid = True
                else:
                    valid = any(" ".join(words[:size]) in paths for size in path_lengths)
                if not valid:
                    problems.append(f"{guide.relative_to(ROOT)}:{line_no}: {snippet}")
                count += 1
    if problems:
        raise SystemExit("Unrecognized command paths:\n" + "\n".join(problems))
    print(f"Verified {count} documented command paths against CLI help.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, help="Check documented invocations against this built CLI.")
    arguments = parser.parse_args()
    if arguments.cli:
        check_commands(arguments.cli.resolve())
        raise SystemExit(0)
    print("source\tlabel\tguide text match")
    rows = inventory((ROOT / "Sources/MPCutApp").glob("*.swift"), CONTROL)
    for row in rows:
        print(*row, sep="\t")
    path = ROOT / "Sources/MPCutCLI/CommandPath.swift"
    guide = (ROOT / "docs/CLI.md").read_text()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        for command in re.findall(r'"([a-z]+(?: [a-z]+)+)"', line):
            print(f"{path.relative_to(ROOT)}:{number}", command,
                  "mentioned" if command in guide else "review wording", sep="\t")
