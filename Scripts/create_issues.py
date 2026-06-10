#!/usr/bin/env python3
"""Create milestones + epic issues + linked sub-issues on GitHub from issues.json.

Idempotent for milestones (skips existing by title). Epics/sub-issues are created
once; a log is written to Scripts/created_issues.log so a partial run is recoverable.
Usage: python3 Scripts/create_issues.py [--dry-run]
"""
import json, subprocess, sys, os, time

REPO = "tom21100227/sleap-io.swift"
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "issues.json")
LOG = os.path.join(HERE, "created_issues.log")
DRY = "--dry-run" in sys.argv


def run(args, input_text=None):
    r = subprocess.run(args, capture_output=True, text=True, input=input_text)
    if r.returncode != 0:
        sys.stderr.write(f"FAIL: {' '.join(args)}\n{r.stderr}\n")
        raise SystemExit(1)
    return r.stdout.strip()


def gh_api(path, method="GET", fields=None):
    args = ["gh", "api"]
    if method != "GET":
        args += ["--method", method]
    args.append(path)
    for k, v in (fields or {}).items():
        args += ["-f", f"{k}={v}"]
    return run(args)


def log(msg):
    print(msg, flush=True)
    with open(LOG, "a") as f:
        f.write(msg + "\n")


def ensure_milestones(milestones):
    existing = json.loads(gh_api(f"repos/{REPO}/milestones?state=all&per_page=100"))
    have = {m["title"]: m["number"] for m in existing}
    for m in milestones:
        if m["title"] in have:
            log(f"milestone exists: {m['title']} (#{have[m['title']]})")
            continue
        if DRY:
            log(f"[dry] would create milestone: {m['title']}")
            continue
        out = gh_api(f"repos/{REPO}/milestones", "POST",
                     {"title": m["title"], "description": m["description"]})
        num = json.loads(out)["number"]
        log(f"created milestone: {m['title']} (#{num})")


def create_issue(title, body, labels, milestone):
    """Create an issue via gh issue create; return its number."""
    args = ["gh", "issue", "create", "--repo", REPO, "--title", title, "--body", body]
    for lb in labels:
        args += ["--label", lb]
    if milestone:
        args += ["--milestone", milestone]
    url = run(args)
    return int(url.rstrip("/").split("/")[-1])


def issue_db_id(number):
    return json.loads(gh_api(f"repos/{REPO}/issues/{number}"))["id"]


def link_sub_issue(parent_number, child_db_id):
    run(["gh", "api", "--method", "POST",
         f"repos/{REPO}/issues/{parent_number}/sub_issues",
         "-F", f"sub_issue_id={child_db_id}"])


def sub_body(s, epic_num, epic_id):
    return (
        f"**Part of:** {epic_id} #{epic_num}\n"
        f"**Upstream ref:** `{s['ref']}`\n"
        f"**Swift target:** {s['target']}\n"
        f"**Effort:** {s['cx']}\n\n"
        f"{s['desc']}\n\n"
        f"**Acceptance / TDD tests:** {s['accept']}\n\n"
        f"_See [MEGA_PLAN.md](../blob/main/MEGA_PLAN.md) §{s['id']} and "
        f"[GAP_ANALYSIS.md](../blob/main/GAP_ANALYSIS.md)._"
    )


def main():
    data = json.load(open(DATA))
    log(f"=== run {'(dry)' if DRY else ''} {time.strftime('%Y-%m-%d %H:%M:%S')} ===")
    ensure_milestones(data["milestones"])

    for epic in data["epics"]:
        if DRY:
            log(f"[dry] epic {epic['id']}: {epic['title']} + {len(epic['subissues'])} subs")
            continue
        epic_num = create_issue(epic["title"], epic["body"], epic["labels"], epic["milestone"])
        log(f"EPIC {epic['id']} -> #{epic_num}: {epic['title']}")
        for s in epic["subissues"]:
            body = sub_body(s, epic_num, epic["id"])
            num = create_issue(s["title"], body, s["labels"], epic["milestone"])
            cid = issue_db_id(num)
            link_sub_issue(epic_num, cid)
            log(f"  sub {s['id']} -> #{num} (linked to #{epic_num})")
    log("=== done ===")


if __name__ == "__main__":
    main()
