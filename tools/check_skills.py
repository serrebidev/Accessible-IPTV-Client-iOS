"""Checks Resources/Skills.skillsbundle against Apple's app skill rules, so a bad skill fails the
build log loudly instead of Xcode dropping every skill quietly.

    python tools/check_skills.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Resources" / "Skills.skillsbundle" / "Skills"


def problems(folder):
    if [p.name for p in folder.iterdir()] != ["SKILL.md"]:
        yield "must hold only SKILL.md"
        return
    text = (folder / "SKILL.md").read_text(encoding="utf-8")
    match = re.fullmatch(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not match:
        yield "needs --- frontmatter"
        return
    fields = dict(line.split(": ", 1) for line in match.group(1).split("\n"))
    if set(fields) != {"name", "description"}:
        yield f"frontmatter must be name and description only, not {sorted(fields)}"
    name = fields.get("name", "")
    if name != folder.name:
        yield f"name {name} must match its folder"
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) or len(name) > 64:
        yield "name must be 1-64 lowercase letters, digits and single hyphens"
    if not 0 < len(fields.get("description", "")) <= 1024:
        yield "description must be 1-1024 characters on one line"
    if not 0 < len(match.group(2)) <= 10_000:
        yield "body must be 1-10000 characters"


def main():
    folders = sorted(p for p in ROOT.iterdir() if p.is_dir())
    bad = [f"{f.name}: {p}" for f in folders for p in problems(f)]
    if not folders:
        bad.append("no skills found")
    if bad:
        sys.exit("\n".join(bad))
    print(f"{len(folders)} skills ok")


if __name__ == "__main__":
    main()
