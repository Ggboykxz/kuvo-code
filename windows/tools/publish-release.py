#!/usr/bin/env python3
"""Publish the Windows release from the successful Windows-engine run.

  python3 windows/tools/publish-release.py 0.5.56 [sha]

It waits for the "Windows engine" push run on the branch head, downloads the installer,
the portable build and the harness executable, adds the source zip, and creates the
windows-v<version> release on Ggboykxz/kuvo-code. It never prints the token.

The release's notes are the file docs/releases/<version>.md, so the release and the
repository always say the same thing.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
VERSION = sys.argv[1] if len(sys.argv) > 1 else "0.5.56"
REPO = "Ggboykxz/kuvo-code"
TAG = f"windows-v{VERSION}"
OUT = "/tmp/opencode/release-" + VERSION
TOKEN = open(os.path.join(ROOT, "github-token-to-revoke.txt"), "r", encoding="utf-8").read().splitlines()[2].strip()
SHA = sys.argv[2] if len(sys.argv) > 2 else subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()
API = "https://api.github.com"
HEADERS = {
    "Authorization": f"token {TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}


def request(url, method="GET", data=None, headers=None):
    body = None
    hdrs = dict(HEADERS)
    if headers:
        hdrs.update(headers)
    if data is not None:
        body = json.dumps(data).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw)
        except Exception:
            payload = raw.decode("utf-8", "replace")
        return error.code, payload


def curl(url, path):
    subprocess.run(
        ["curl", "-sS", "-L", "--fail", "-H", f"Authorization: token {TOKEN}", "-o", path, url],
        check=True,
    )


def latest_run():
    query = urllib.parse.urlencode({"head_sha": SHA, "per_page": 30})
    status, runs = request(f"{API}/repos/{REPO}/actions/runs?{query}")
    if status != 200:
        return None
    for run in runs.get("workflow_runs", []):
        if run.get("name") == "Windows engine" and run.get("event") == "push":
            return run
    return None


def notes_for(version):
    """The release's notes: the file in the repository, or the one in the temp folder."""
    for path in (
        os.path.join(ROOT, "docs", "releases", f"{version}.md"),
        f"/tmp/opencode/notes-{version}.md",
    ):
        if os.path.exists(path):
            return open(path, "r", encoding="utf-8").read()
    raise SystemExit(f"no notes for {version}: put them in docs/releases/{version}.md")


os.makedirs(OUT, exist_ok=True)
print(f"waiting for the Windows engine run on {SHA[:7]}…", flush=True)
run = None
while True:
    run = latest_run()
    if run is not None:
        print(f"  run {run['id']}: {run['status']} / {run['conclusion']}", flush=True)
        if run["status"] == "completed":
            break
    time.sleep(20)
if run["conclusion"] != "success":
    raise SystemExit(f"the Windows engine run failed: {run['html_url']}")

status, artifacts = request(f"{API}/repos/{REPO}/actions/runs/{run['id']}/artifacts?per_page=50")
wanted = {artifact["name"]: artifact for artifact in artifacts.get("artifacts", [])}
for name in ["kuvo-windows-shell-x64", "kuvo-windows-harness-x64"]:
    if name not in wanted:
        raise SystemExit(f"the run has no {name}")
    artifact = wanted[name]
    print(f"downloading {name}…", flush=True)
    curl(f"{API}/repos/{REPO}/actions/artifacts/{artifact['id']}/zip", os.path.join(OUT, f"{name}.zip"))
    with zipfile.ZipFile(os.path.join(OUT, f"{name}.zip")) as archive:
        archive.extractall(OUT)

installer = None
portable = None
exe = None
for root, _, files in os.walk(OUT):
    for name in files:
        path = os.path.join(root, name)
        if not name.endswith(".exe"):
            continue
        if "Setup" in name:
            installer = path
        elif name.startswith("kuvo-windows-harness"):
            exe = path
        else:
            portable = path
if not (installer and portable and exe):
    raise SystemExit("the artifacts are not what they should be")

source = os.path.join(OUT, "kuvo-code-" + VERSION + "-source.zip")
subprocess.run(
    ["git", "-C", ROOT, "archive", "--format=zip", "--prefix=kuvo-code-" + VERSION + "/", "-o", source, SHA],
    check=True,
)

notes = notes_for(VERSION)
status, release = request(f"{API}/repos/{REPO}/releases", "POST", {
    "tag_name": TAG,
    "name": f"Kuvo Code {VERSION}",
    "body": notes,
    "draft": False,
    "prerelease": False,
    "target_commitish": SHA,
    "generate_release_notes": False,
})
if status not in (200, 201):
    status, existing = request(f"{API}/repos/{REPO}/releases/tags/{TAG}")
    if status != 200:
        raise SystemExit(f"creating the release answered {status}: {release}")
    release = existing
    print("the release was already there; its assets are filled in", flush=True)
upload = release["upload_url"].split("{")[0]
assets = [
    (f"Kuvo-Code-Setup-{VERSION}.exe", installer),
    (f"Kuvo-Code-{VERSION}.exe", portable),
    ("kuvo-windows-harness.exe", exe),
    (f"kuvo-code-{VERSION}-source.zip", source),
]


def upload_asset(url, path):
    size = os.path.getsize(path)
    request = urllib.request.Request(url, data=open(path, "rb").read(), method="POST", headers={
        **HEADERS,
        "Content-Type": "application/octet-stream",
        "Content-Length": str(size),
    })
    with urllib.request.urlopen(request) as response:
        return response.status


for name, path in assets:
    print(f"  uploaded {name} ({os.path.getsize(path)} bytes)", flush=True)
    upload_asset(f"{upload}?name={urllib.parse.quote(name)}", path)
print(f"published {TAG}: " + ", ".join(name for name, _ in assets), flush=True)
print(release["html_url"], flush=True)
