"""Print source locations for user-facing controls to review against the MPCut guide."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUIDE = (ROOT / "docs/USAGE.md").read_text()
CONTROL = re.compile(
    r'\b(?:Button|Toggle|Menu|CommandMenu|Picker|Section|LabeledContent|TextField|Stepper|Slider)'
    r'\("([^"\\]+)"'
)
COMMAND = re.compile(r'\.init\(name: "([^"]+)"')
CODE = " ".join(block or inline for block, inline in
                re.findall(r"```[^\n]*\n(.*?)```|`([^`\n]+)`", GUIDE, re.DOTALL))


def normalized(text):
    return " ".join(text.casefold().replace("…", "").split())


def inventory(paths, pattern):
    guide = normalized(GUIDE)
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for label in pattern.findall(line):
                if pattern is COMMAND:
                    present = re.search(r"(?<!\w)" + re.escape(label) + r"(?![\w-])", CODE)
                else:
                    present = normalized(label) in guide
                yield (str(path.relative_to(ROOT)) + ":" + str(number),
                       label, "mentioned" if present else "review wording")


if __name__ == "__main__":
    print("source\tlabel\tguide text match")
    rows = inventory((ROOT / "Sources/MPCutApp").glob("*.swift"), CONTROL)
    for row in rows:
        print(*row, sep="\t")
    for row in inventory([ROOT / "Sources/MPCutCLI/CommandHelp.swift"], COMMAND):
        print(*row, sep="\t")
