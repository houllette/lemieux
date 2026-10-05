"""Shared machinery for the investigators-v2 generators.

Every generator builds `Case` objects: a fixture (path -> text), a prompt, the
tokens the grader expects, a reference answer and the manifest metadata.
`emit/2` writes the fixture, its `check.sh` (every file pinned by a POSIX
cksum, tokens stored octal-escaped so the script never shows an answer) and
`answers/<id>.txt`, and returns the manifest entry.

Only the Python standard library is used, and every source of randomness is a
`random.Random` seeded per case, so rerunning `build.py` reproduces the corpus
byte for byte.
"""

from __future__ import annotations

import json
import os
import random
import shutil
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# POSIX cksum (CRC-32, polynomial 0x04C11DB7, MSB first, length appended).
# Implemented here so the generators do not depend on a `cksum` binary.

_CRC_TABLE = []
for _i in range(256):
    _c = _i << 24
    for _ in range(8):
        _c = ((_c << 1) ^ 0x04C11DB7) if _c & 0x80000000 else (_c << 1)
    _CRC_TABLE.append(_c & 0xFFFFFFFF)


def cksum(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ b) & 0xFF]
    length = len(data)
    while length:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ (length & 0xFF)) & 0xFF]
        length >>= 8
    return (~crc) & 0xFFFFFFFF


def octal_escape(token: str) -> str:
    return "".join("\\%03o" % b for b in token.encode("utf-8"))


# ---------------------------------------------------------------------------
# Vocabulary. Everything here is invented; no real names, hosts or products.

WORDS = (
    "alder amber anvil arbor ashen aster atlas auger aurora avon badger balsa "
    "basalt beacon birch bison blaze bramble brine bronze cairn canvas cedar "
    "cinder citrine cobalt comet copper coral crag cypress dapple delta dune "
    "ember falcon fathom fennel ferric flint fjord garnet glacier granite "
    "gravel harbor hazel heron hollow ingot iris jasper juniper kelp kestrel "
    "lantern larch lichen linden lumen marrow meadow mica moss nettle ochre "
    "onyx orchard osprey pebble pewter pine plover quartz quill raven reed "
    "rowan russet saffron sedge shale slate sorrel spruce sterling summit "
    "tallow tarn thistle timber topaz tundra umber vale vellum verdant "
    "walnut wicker willow yarrow zephyr"
).split()

SYLLABLES = (
    "bran nock quill mere vel drin tor vane ash gale fen wick hal dor mor "
    "wen rus kel ith ord lan ver nim os tal wyn cor bel dar fal gri hol "
    "ist jor kal lor mir nor pel ran sel tam ul vor wal yor zan"
).split()

LOREM = (
    "the service keeps its state in an append-only journal and rebuilds the "
    "index on start. operators should not edit generated files by hand. a "
    "value set here applies only after the next reload. see the runbook for "
    "the rollout procedure. this section is kept for historical reasons and "
    "may be removed in a later revision. every entry is validated before it "
    "is written. retries are bounded and jittered. the reader tolerates "
    "trailing whitespace. keys are compared case-sensitively. unknown keys "
    "are ignored with a warning. the default is deliberately conservative."
).split(". ")


def word(rng: random.Random) -> str:
    return rng.choice(WORDS)


def words(rng: random.Random, n: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n))


def syl_name(rng: random.Random, parts: int = 2) -> str:
    return "".join(rng.choice(SYLLABLES) for _ in range(parts))


def hex_id(rng: random.Random, n: int = 8) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def sentence(rng: random.Random) -> str:
    s = rng.choice(LOREM).strip().rstrip(".")
    return s[0].upper() + s[1:] + "."


def paragraph(rng: random.Random, sentences: int = 4) -> str:
    return " ".join(sentence(rng) for _ in range(sentences))


def ts(day: str, h: int, m: int, s: int) -> str:
    return "%sT%02d:%02d:%02dZ" % (day, h, m, s)


# ---------------------------------------------------------------------------
# Fictional Python source filler shared by the code-shaped clusters.


def py_function(rng, name=None, args=None):
    name = name or "%s_%s" % (rng.choice(["build", "load", "check", "merge", "emit", "parse", "collect", "format", "resolve", "apply"]), word(rng))
    args = args or ", ".join(rng.sample(["ctx", "payload", "record", "options", "clock", "limit", "cursor", "source"], rng.randint(1, 3)))
    body = [
        "def %s(%s):" % (name, args),
        '    """%s"""' % sentence(rng),
        "    %s = %s" % (word(rng), rng.choice(["[]", "{}", "None", "0", "ctx.get(%r)" % word(rng), "_DEFAULTS.copy()"])),
        "    for item in %s:" % rng.choice(["payload", "record.items()", "options.get('rows', [])", "source or []"]),
        "        if item is None:",
        "            continue",
        "        %s = %s(item)" % (word(rng), rng.choice(["str", "_normalize", "_coerce", "list", "_key"])),
        "    return %s" % rng.choice(["None", word(rng), "{'ok': True}", "len(%s)" % word(rng)]),
    ]
    return "\n".join(body)


def py_module(rng, dotted, extra="", n=None):
    lines = ['"""%s\n\n%s\n"""' % (dotted, paragraph(rng, 3)), "", "from app.core import container, errors", "", "_DEFAULTS = {%s}" % ", ".join("%r: %r" % (word(rng), rng.randint(1, 99)) for _ in range(4)), ""]
    lines.append("\n\ndef _normalize(value):\n    return value if isinstance(value, str) else str(value)\n\n\ndef _coerce(value):\n    return value\n\n\ndef _key(value):\n    return getattr(value, 'id', value)\n")
    for _ in range(n or rng.randint(10, 14)):
        lines.append("\n" + py_function(rng) + "\n")
    if extra:
        lines.append("\n" + extra.strip("\n") + "\n")
    return "\n".join(lines)



# ---------------------------------------------------------------------------


@dataclass
class Case:
    id: str
    cluster: str
    prompt: str
    tokens: list  # list of lists of acceptable synonyms, one inner list per fact
    answer: str
    minimum_files: int
    notes: str
    tags: list
    files: dict = field(default_factory=dict)

    def add(self, path: str, content: str) -> None:
        if path in self.files:
            raise ValueError("duplicate fixture path %s in %s" % (path, self.id))
        if "\0" in content:
            raise ValueError("binary content in %s" % path)
        self.files[path] = content

    def total_bytes(self) -> int:
        return sum(len(c.encode("utf-8")) for c in self.files.values())


def check_script(case: Case) -> str:
    lines = [
        "#!/bin/sh",
        "# Grader for %s: every fixture file must be unchanged and the" % case.id,
        "# reported answer (argv 1) must contain each expected fact.",
        "set -u",
        "fail() { printf 'check failed: %s\\n' \"$1\"; exit 1; }",
        "answer=$(printf '%s' \"${1:-}\" | tr 'A-Z' 'a-z')",
        "verify() {",
        "  [ -f \"$1\" ] || fail \"$1 is missing\"",
        "  actual=$(cksum < \"$1\" | awk '{print $1}')",
        "  [ \"$actual\" = \"$2\" ] || fail \"$1 was modified\"",
        "}",
        "expect() {",
        "  label=$1; shift",
        "  for enc in \"$@\"; do",
        "    tok=$(printf \"$enc\")",
        "    case \"$answer\" in *\"$tok\"*) return 0 ;; esac",
        "  done",
        "  fail \"answer is missing expected fact $label\"",
        "}",
    ]
    for path in sorted(case.files):
        lines.append("verify %s %d" % (path, cksum(case.files[path].encode("utf-8"))))
    lines.append("[ -n \"$answer\" ] || fail \"no answer was reported\"")
    for index, synonyms in enumerate(case.tokens, 1):
        encoded = " ".join("'%s'" % octal_escape(s.lower()) for s in synonyms)
        lines.append("expect %d %s" % (index, encoded))
    lines.append("echo \"report ok\"")
    return "\n".join(lines) + "\n"


def validate(case: Case) -> None:
    lowered = case.answer.lower()
    for synonyms in case.tokens:
        if not any(s.lower() in lowered for s in synonyms):
            raise ValueError("%s: reference answer lacks token %r" % (case.id, synonyms))
    for path in case.files:
        if path.startswith("/") or ".." in path.split("/"):
            raise ValueError("%s: bad path %s" % (case.id, path))
    if len(case.prompt) >= 400:
        raise ValueError("%s: prompt is %d chars" % (case.id, len(case.prompt)))
    if "check.sh" in case.files:
        raise ValueError("%s: fixture may not ship its own check.sh" % case.id)
    if "without changing any files" not in case.prompt:
        raise ValueError("%s: prompt must say to report back without changing files" % case.id)
    dirs = {os.path.dirname(p) for p in case.files if os.path.dirname(p)}
    if len(case.files) < 40:
        raise ValueError("%s: only %d files" % (case.id, len(case.files)))
    if len(dirs) < 6:
        raise ValueError("%s: only %d directories" % (case.id, len(dirs)))
    if not any(d.count("/") >= 1 for d in dirs):
        raise ValueError("%s: no directory nested two levels deep" % case.id)
    if case.total_bytes() < 250_000:
        raise ValueError("%s: only %d bytes" % (case.id, case.total_bytes()))
    if case.total_bytes() > 650_000:
        raise ValueError("%s: %d bytes is over budget" % (case.id, case.total_bytes()))
    if not any(len(c.encode("utf-8")) > 30_000 for c in case.files.values()):
        raise ValueError("%s: no file over 30,000 bytes" % case.id)


def emit(case: Case, corpus_root: str) -> dict:
    validate(case)
    repo = os.path.join(corpus_root, "repos", case.id)
    if os.path.isdir(repo):
        shutil.rmtree(repo)
    for path, content in case.files.items():
        full = os.path.join(repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
    with open(os.path.join(repo, "check.sh"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(check_script(case))
    answers = os.path.join(corpus_root, "answers")
    os.makedirs(answers, exist_ok=True)
    with open(os.path.join(answers, case.id + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(case.answer.rstrip("\n") + "\n")
    return {
        "id": case.id,
        "prompt": case.prompt,
        "cwd": "repos/" + case.id,
        "grader": {"command": ["sh", "check.sh", "{answer}"], "timeout_ms": 30000},
        "metadata": {
            "cluster_id": case.cluster,
            "tags": ["investigators", "v2", "read", "report"] + list(case.tags),
            "required_tools": ["read"],
            "forbidden_tools": ["write", "edit"],
            "minimum_files": case.minimum_files,
            "fixture_files": len(case.files),
            "fixture_bytes": case.total_bytes(),
            "notes": case.notes,
            "safety": {"allowed_changed_paths": []},
        },
    }


def dump_json(obj) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"
