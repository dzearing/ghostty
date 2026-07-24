#!/usr/bin/env python3
"""Generate GENERAL release-notes JSON drafts from GitHub Releases.

Reference/curation helper. Fetches each GitHub release body for the Ghoztty
macOS app, strips the install boilerplate, parses `### Section` +
`- **Title** — text` bullets, and writes <out>/<semver>.json keyed by the app's
CFBundleShortVersionString (bare semver, no leading 'v').

The output is a GENERAL draft — it does not know the agent-vs-client split. The
bundled agent notes (`release-notes/agent/*.json`) are curated by hand from
these drafts down to session-persistence / background-agent changes only (the
reasons to restart the agent). See release-notes/README.md.

Usage: python3 scripts/backfill-release-notes.py [out_dir]   (run from repo root;
       default out_dir is release-notes/.drafts). Requires authenticated `gh`.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "dzearing/ghoztty"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("release-notes/.drafts")
MIN = (1, 4, 0)  # skip pre-1.4 -dz dev tags (predate session persistence)

BULLET = re.compile(r"^\s*[-*]\s+(.*)$")
BOLD_LEAD = re.compile(r"^\*\*(.+?)\*\*\s*[—–-]\s*(.*)$")
HEADING = re.compile(r"^###\s+(.*)$")


def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def semver_tuple(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", v)
    return tuple(int(x) for x in m.groups()) if m else None


def list_versions():
    out = sh("gh", "release", "list", "--repo", REPO, "--limit", "200",
             "--json", "tagName", "-q", ".[].tagName")
    vs = []
    for tag in out.splitlines():
        tag = tag.strip()
        if not tag.startswith("v"):
            continue
        t = semver_tuple(tag[1:])
        if t and t >= MIN:
            vs.append(tag[1:])
    return sorted(set(vs), key=semver_tuple)


def parse_body(body):
    sections = []
    current = None
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("## "):  # top "What's new in …" title — skip
            continue
        if s == "---" or re.match(r"^###\s+(Installation|Requirements)\b", s):
            break  # install/requirements boilerplate begins
        h = HEADING.match(s)
        if h:
            current = {"title": h.group(1).strip(), "items": []}
            sections.append(current)
            continue
        b = BULLET.match(line)
        if b and current is not None:
            content = b.group(1).strip()
            m = BOLD_LEAD.match(content)
            if m:
                current["items"].append(
                    {"title": m.group(1).strip(), "text": m.group(2).strip()})
            else:
                current["items"].append({"text": content.replace("**", "")})
    return [sec for sec in sections if sec["items"]]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for v in list_versions():
        body = sh("gh", "release", "view", f"v{v}", "--repo", REPO,
                  "--json", "body", "-q", ".body")
        sections = parse_body(body)
        if not sections:
            print(f"skip {v}: no parseable sections", file=sys.stderr)
            continue
        doc = {"version": v, "sections": sections}
        (OUT / f"{v}.json").write_text(
            json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        n = sum(len(sec["items"]) for sec in sections)
        print(f"wrote release-notes/{v}.json ({n} items)")


if __name__ == "__main__":
    main()
