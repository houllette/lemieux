#!/usr/bin/env python3
"""Check the repository's Markdown links the way GitHub renders them.

    python3 scripts/check_links.py [FILE.md ...]

With no arguments it reads every tracked Markdown file except the benchmark
corpus and test fixtures (eval/corpus/, test/fixtures/), which are synthetic
repositories rather than documentation. It fails on:

  * a relative link whose target is not a tracked file or directory. A link
    resolves against the linking file's directory, or against the
    repository root when it starts with "/", as it does on GitHub;
  * a #fragment, in a link to a Markdown file or within the same file, that
    names no heading. Headings get GitHub's anchors: lower case, punctuation
    dropped, spaces turned into hyphens, "-1", "-2" for repeats; explicit
    <a name> and id= anchors count too;
  * a github.com/houllette/lemieux/blob|tree|raw/main/... URL whose path is
    not tracked, or whose #fragment names no heading;
  * a URL into any other github.com/houllette repository, in any tracked
    text file. Those repositories are private, so the link is dead for
    everyone but the owner. PUBLIC_REPOSITORIES lists the exceptions.

A link to this repository at a ref other than main is reported as a warning:
it is correct today, but a commit or branch it names can disappear when the
history is rewritten. Other hosts (example.com placeholders, the Ixway
gateway, every external site) are neither fetched nor checked.

Exit status: 0 clean (warnings allowed), 1 broken links, 2 usage error.
Uses only the Python standard library.
"""

import argparse
import html
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse
from pathlib import Path

OWNER = "houllette"
# Repositories under OWNER that are public. A link to any other repository of
# the owner's is reported, because those are private.
PUBLIC_REPOSITORIES = {"lemieux"}
SELF = "lemieux"
EXCLUDED_PREFIXES = ("eval/corpus/", "test/fixtures/")
# Link targets that exist only after `mix deps.get`. AGENTS.md's generated
# usage-rules block links into deps/ for agents working in a checkout.
FETCHED_PREFIXES = ("deps/",)

FENCE_RE = re.compile(r"^(\s{0,3})(`{3,}|~{3,})(.*)$")
INLINE_LINK_RE = re.compile(
    r"(?P<img>!?)\[(?P<text>(?:[^\[\]\n]|\n(?!\s*\n)|\[(?:[^\[\]\n]|\n(?!\s*\n))*\])*)\]"
    r"\(\s*(?P<dest><[^>\n]*>|(?:[^()\s]|\((?:[^()\s])*\))*)"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"
)
# A reference definition; `[^note]: text` is a footnote, not a link.
REF_DEF_RE = re.compile(r"^\s{0,3}\[(?!\^)(?P<label>[^\]\n]+)\]:\s*(?P<dest><[^>\n]+>|\S+)", re.M)
AUTOLINK_RE = re.compile(r"<(?P<dest>https?://[^>\s]+)>")
HTML_LINK_RE = re.compile(r"<(?:a|img|source)\s[^>]*?(?:href|src)\s*=\s*[\"'](?P<dest>[^\"']+)[\"']", re.I)
BARE_URL_RE = re.compile(r"https?://[^\s<>\"'`|\\]+")
ATX_RE = re.compile(r"^\s{0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")
SETEXT_RE = re.compile(r"^\s{0,3}(=+|-+)\s*$")
EXPLICIT_ANCHOR_RE = re.compile(r"<[a-z][a-z0-9]*\s[^>]*?\b(?:name|id)\s*=\s*[\"']([^\"']+)[\"']", re.I)
OWNER_REPO_RE = re.compile(
    r"(?:https?://(?:www\.)?github\.com/|https?://raw\.githubusercontent\.com/|git@github\.com:)"
    + OWNER + r"/(?P<repo>[A-Za-z0-9._-]+)",
    re.I,
)
LINE_ANCHOR_RE = re.compile(r"^L\d+(?:C\d+)?(?:-L\d+(?:C\d+)?)?$")


def blank(text):
    """Every character but newlines replaced by a space, so offsets survive."""
    return re.sub(r"[^\n]", " ", text)


def mask_code(text):
    """Blank fenced code, HTML comments and code spans; keep line numbers."""
    out = []
    fence = None
    for line in text.split("\n"):
        match = FENCE_RE.match(line)
        if fence is None:
            if match:
                fence = (match.group(2)[0], len(match.group(2)))
                out.append(blank(line))
            else:
                out.append(line)
        else:
            if (match and match.group(2)[0] == fence[0] and len(match.group(2)) >= fence[1]
                    and not match.group(3).strip()):
                fence = None
            out.append(blank(line))
    masked = "\n".join(out)
    masked = re.sub(r"<!--.*?-->", lambda m: blank(m.group(0)), masked, flags=re.S)
    return re.sub(r"(?<!`)(`+)(?!`)((?:(?!\n\s*\n).)+?)(?<!`)\1(?!`)",
                  lambda m: blank(m.group(0)), masked, flags=re.S)


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def trim_url(url):
    """Drop punctuation that ends a sentence rather than the URL, as GFM does."""
    url = url.rstrip(".,;:!?*_~")
    while url.endswith(")") and url.count(")") > url.count("("):
        url = url[:-1].rstrip(".,;:!?*_~")
    return url


def extract_links(text):
    """(line, destination) for every link a reader can follow outside code."""
    masked = mask_code(text)
    links = []
    for match in INLINE_LINK_RE.finditer(masked):
        dest = match.group("dest").strip()
        if dest.startswith("<") and dest.endswith(">"):
            dest = dest[1:-1]
        links.append((line_of(masked, match.start()), dest))
    # Every definition is checked, used or not: a stale one is still wrong.
    for match in REF_DEF_RE.finditer(masked):
        dest = match.group("dest")
        if dest.startswith("<") and dest.endswith(">"):
            dest = dest[1:-1]
        links.append((line_of(masked, match.start()), dest))
    for match in AUTOLINK_RE.finditer(masked):
        links.append((line_of(masked, match.start()), match.group("dest")))
    for match in HTML_LINK_RE.finditer(masked):
        links.append((line_of(masked, match.start()), html.unescape(match.group("dest"))))
    seen = {(line, dest) for line, dest in links}
    for match in BARE_URL_RE.finditer(masked):
        entry = (line_of(masked, match.start()), trim_url(match.group(0)))
        if entry not in seen:
            seen.add(entry)
            links.append(entry)
    return sorted(links, key=lambda link: link[0])


def headings(text):
    """(level, raw text) for each ATX or setext heading outside code."""
    result = []
    fence = None
    previous = None
    for line in text.split("\n"):
        match = FENCE_RE.match(line)
        if fence is not None:
            if (match and match.group(2)[0] == fence[0] and len(match.group(2)) >= fence[1]
                    and not match.group(3).strip()):
                fence = None
            previous = None
            continue
        if match:
            fence = (match.group(2)[0], len(match.group(2)))
            previous = None
            continue
        atx = ATX_RE.match(line)
        if atx:
            title = re.sub(r"[ \t]+#+$", "", (atx.group(2) or "").strip())
            if title == "#" * len(title):
                title = ""
            result.append((len(atx.group(1)), title))
            previous = None
            continue
        setext = SETEXT_RE.match(line)
        if setext and previous is not None:
            result.append((1 if setext.group(1).startswith("=") else 2, previous.strip()))
            previous = None
            continue
        stripped = line.strip()
        paragraph = bool(stripped) and not re.match(r"^([-*+]\s|\d+[.)]\s|\||>|<)", stripped)
        previous = line if paragraph else None
    return result


def heading_text(raw):
    """The text GitHub renders for a heading, which its anchor is made from."""
    spans = []

    def stash(match):
        spans.append(match.group(2))
        return "\x00%d\x00" % (len(spans) - 1)

    text = re.sub(r"(`+)(.+?)\1", stash, raw)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"(\*\*|__)(.+?)\1", r"\2", text)
    text = re.sub(r"(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)", r"\1", text)
    text = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"\1", text)
    text = re.sub(r"~~(.+?)~~", r"\1", text)
    text = re.sub(r"\\(.)", r"\1", text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], text)
    return html.unescape(text)


def github_slug(text):
    """GitHub's heading anchor: letters, digits, '_' and '-' kept, spaces to '-'."""
    kept = []
    for char in text.lower():
        category = unicodedata.category(char)
        if char in " -" or category[0] in "LMN" or category == "Pc":
            kept.append(char)
    return "".join(kept).replace(" ", "-")


def anchors(text):
    """Every fragment a link into this Markdown text can name."""
    counts = {}
    found = set()
    for _level, raw in headings(text):
        base = github_slug(heading_text(raw))
        repeat = counts.get(base, 0)
        found.add(base if repeat == 0 else "%s-%d" % (base, repeat))
        counts[base] = repeat + 1
    for match in EXPLICIT_ANCHOR_RE.finditer(text):
        found.add(match.group(1).lower())
    return found


class Repository:
    def __init__(self, root):
        self.root = Path(root).resolve()
        listing = subprocess.run(["git", "-C", str(self.root), "ls-files", "-z"],
                                 capture_output=True, check=True).stdout
        self.files = {name for name in listing.decode("utf-8", "surrogateescape").split("\0") if name}
        self.directories = set()
        for name in self.files:
            parent = os.path.dirname(name)
            while parent and parent not in self.directories:
                self.directories.add(parent)
                parent = os.path.dirname(parent)
        self._texts = {}
        self._anchors = {}

    def text(self, name):
        if name not in self._texts:
            try:
                self._texts[name] = (self.root / name).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                self._texts[name] = None
        return self._texts[name]

    def anchors(self, name):
        if name not in self._anchors:
            self._anchors[name] = anchors(self.text(name) or "")
        return self._anchors[name]

    def target_problem(self, name):
        """Why a link target is unusable, or None when it is tracked."""
        if name in self.files:
            return None if (self.root / name).exists() else "is tracked but deleted in this working tree"
        if name.rstrip("/") in self.directories:
            return None
        if (self.root / name).exists():
            return "exists here but is not tracked (git add it)"
        return "does not exist"

    def markdown_files(self):
        return sorted(name for name in self.files
                      if name.endswith(".md") and not name.startswith(EXCLUDED_PREFIXES))


def check_fragment(repo, target, fragment):
    fragment = urllib.parse.unquote(fragment)
    if not fragment or LINE_ANCHOR_RE.match(fragment):
        return None
    if fragment.lower() in repo.anchors(target):
        return None
    return "no heading in %s has the anchor #%s" % (target, fragment)


def check_markdown(repo, source):
    """(errors, warnings, links) for one Markdown file; findings are (line, message)."""
    errors, warnings = [], []
    text = repo.text(source)
    if text is None:
        return [(0, "is not readable UTF-8 text")], warnings, 0
    links = extract_links(text)
    for line, dest in links:
        if not dest:
            errors.append((line, "a link has an empty destination"))
            continue
        parsed = urllib.parse.urlsplit(dest)
        if parsed.scheme in ("http", "https"):
            problem, warning = check_self_url(repo, parsed)
            if problem:
                errors.append((line, "%s: %s" % (dest, problem)))
            if warning:
                warnings.append((line, "%s: %s" % (dest, warning)))
            continue
        if parsed.scheme or dest.startswith("//"):
            continue
        path = urllib.parse.unquote(parsed.path)
        if not path:
            target = source
        elif path.startswith("/"):
            target = os.path.normpath(path.lstrip("/"))
        else:
            target = os.path.normpath(os.path.join(os.path.dirname(source), path))
        if target == "." or target.startswith(".."):
            errors.append((line, "%s: points outside the repository" % dest))
            continue
        if target.startswith(FETCHED_PREFIXES):
            continue
        problem = repo.target_problem(target)
        if problem:
            errors.append((line, "%s: %s %s" % (dest, target, problem)))
        elif parsed.fragment and target.endswith(".md"):
            problem = check_fragment(repo, target, parsed.fragment)
            if problem:
                errors.append((line, "%s: %s" % (dest, problem)))
    return errors, warnings, len(links)


def check_self_url(repo, parsed):
    """(error, warning) for a URL into this repository's own tree, else (None, None)."""
    if (parsed.hostname or "").lower() not in ("github.com", "www.github.com"):
        return None, None
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 4 or parts[0].lower() != OWNER or parts[1].lower() != SELF:
        return None, None
    if parts[2] not in ("blob", "tree", "raw"):
        return None, None
    ref, path = parts[3], urllib.parse.unquote("/".join(parts[4:]))
    if ref != "main":
        return None, "names the ref %s rather than main; a history rewrite can orphan it" % ref
    if not path:
        return None, None
    problem = repo.target_problem(path)
    if problem:
        return "%s %s" % (path, problem), None
    if parsed.fragment and path.endswith(".md"):
        return check_fragment(repo, path, parsed.fragment), None
    return None, None


def private_repository_links(repo, name):
    """(line, url) for each URL into one of the owner's private repositories."""
    text = repo.text(name)
    if not text:
        return []
    found = []
    for match in OWNER_REPO_RE.finditer(text):
        repository = match.group("repo")
        if repository.endswith(".git"):
            repository = repository[:-4]
        if repository.lower() not in PUBLIC_REPOSITORIES:
            found.append((line_of(text, match.start()), match.group(0)))
    return found


def run(root, only=None):
    repo = Repository(root)
    if only:
        sources = []
        for name in only:
            relative = os.path.relpath(Path(name).resolve(), repo.root)
            if relative.startswith(".."):
                raise SystemExit("check_links: %s is outside %s" % (name, repo.root))
            sources.append(relative)
    else:
        sources = repo.markdown_files()
    errors, warnings = {}, {}
    links_checked = 0
    for source in sources:
        if not source.endswith(".md"):
            continue
        found, cautions, count = check_markdown(repo, source)
        links_checked += count
        errors.setdefault(source, []).extend(found)
        warnings.setdefault(source, []).extend(cautions)
    private_scope = sources if only else sorted(
        name for name in repo.files if not name.startswith(EXCLUDED_PREFIXES))
    for name in private_scope:
        for line, url in private_repository_links(repo, name):
            errors.setdefault(name, []).append(
                (line, "%s: a private repository; the link is dead for everyone else" % url))
    return errors, warnings, len(sources), links_checked


def report(errors, warnings, files, links):
    error_count = sum(len(entries) for entries in errors.values())
    warning_count = sum(len(entries) for entries in warnings.values())
    for kind, table in (("warning", warnings), ("error", errors)):
        for name in sorted(table):
            for line, message in sorted(set(table[name])):
                print("%s:%d: %s: %s" % (name, line, kind, message))
    print("check_links: %d Markdown files, %d links: %d broken, %d warnings"
          % (files, links, error_count, warning_count))
    return 1 if error_count else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="*", help="Markdown files to check (default: every tracked one)")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]),
                        help="repository root (default: this script's checkout)")
    args = parser.parse_args(argv)
    try:
        errors, warnings, files, links = run(args.root, args.files)
    except subprocess.CalledProcessError:
        print("check_links: %s is not a Git checkout" % args.root, file=sys.stderr)
        return 2
    return report(errors, warnings, files, links)


if __name__ == "__main__":
    sys.exit(main())
