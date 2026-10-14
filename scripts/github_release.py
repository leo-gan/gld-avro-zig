#!/usr/bin/env python3
"""Update the GitHub Release that triggered scripts/publish.sh.

Outside GitHub Actions this prints what it would change and exits 0.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

START = "<!-- publish-info -->"
END = "<!-- /publish-info -->"


def request(method, url, payload=None, data=None, content_type=None):
    token = os.environ["GITHUB_TOKEN"]
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "gld-publish",
    }
    body = data
    if payload is not None:
        body = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        print(f"GitHub API {method} {url} failed: {exc.code} {detail}", file=sys.stderr)
        raise SystemExit(1) from exc
    if not raw:
        return {}
    return json.loads(raw.decode())


def on_actions():
    return os.environ.get("GITHUB_ACTIONS") == "true" and bool(os.environ.get("GITHUB_TOKEN"))


def release_for(tag):
    repo = os.environ["GITHUB_REPOSITORY"]
    quoted = urllib.parse.quote(tag, safe="")
    return request("GET", f"https://api.github.com/repos/{repo}/releases/tags/{quoted}")


def upsert(body, block):
    section = f"{START}\n{block.rstrip()}\n{END}\n"
    if START in body and END in body:
        pre, rest = body.split(START, 1)
        _, post = rest.split(END, 1)
        return pre.rstrip() + "\n\n" + section + "\n" + post.lstrip("\n")
    if body.strip():
        return body.rstrip() + "\n\n" + section
    return section


def cmd_notes(args):
    block = sys.stdin.read()
    if not on_actions():
        return
    rel = release_for(args.tag)
    body = upsert(rel.get("body") or "", block)
    request("PATCH", rel["url"], {"body": body})
    print(f"updated release notes for {args.tag}")


def cmd_upload(args):
    if not on_actions():
        print(f"release asset left local: {args.file}")
        return
    rel = release_for(args.tag)
    name = os.path.basename(args.file)
    for asset in rel.get("assets") or []:
        if asset.get("name") == name:
            request("DELETE", asset["url"])
    upload = rel["upload_url"].split("{", 1)[0]
    with open(args.file, "rb") as handle:
        data = handle.read()
    content_type = "application/zip" if name.endswith(".zip") else "text/plain"
    quoted = urllib.parse.quote(name)
    request("POST", f"{upload}?name={quoted}", data=data, content_type=content_type)
    print(f"uploaded {name}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    notes = sub.add_parser("notes")
    notes.add_argument("--tag", required=True)
    upload = sub.add_parser("upload")
    upload.add_argument("--tag", required=True)
    upload.add_argument("--file", required=True)
    args = parser.parse_args()
    if args.cmd == "notes":
        cmd_notes(args)
    else:
        cmd_upload(args)


if __name__ == "__main__":
    main()
