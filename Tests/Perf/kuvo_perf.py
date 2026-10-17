"""How fast the conversation streams and scrolls, measured the same way every time: a real run is
recorded once from a separate copy of the app (run.kuvo.code.perf), then played back into a debug
build as often as you like (KUVO_DEMO_REPLAY), while the app measures how long its main thread
keeps you waiting, its CPU, memory and frames. See README.md.

Everything it makes is in its folder under the user's temporary folder, and in the perf copy's
own folders, which `clean` removes.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BUNDLE = "run.kuvo.code.perf"
HOME = os.path.expanduser("~")
SUPPORT = HOME + "/Library/Application Support/" + BUNDLE
TEMP = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
ROOT = os.path.join(TEMP, "kuvo-perf")
DERIVED = os.path.join(ROOT, "DerivedData")
APP = DERIVED + "/Build/Products/Debug/Kuvo Code.app"
MODEL = os.environ.get("KUVO_PERF_MODEL", "opencode/deepseek-v4.1-flash-free")


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def sh(command, check=True, **kwargs):
    done = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if check and done.returncode != 0:
        raise RuntimeError("%s failed: %s" % (command[0], (done.stderr or done.stdout)[-1500:]))
    return done.stdout.strip()


def build(source=REPO, app=None):
    """A debug build of `source` (this checkout, or another, like one at an older commit) as the
    perf copy; with `app`, also copied there to keep."""
    log("building", source)
    sh(["xcodebuild", "-project", source + "/KuvoCode.xcodeproj", "-scheme", "KuvoCode", "-configuration", "Debug",
        "-derivedDataPath", DERIVED, "-clonedSourcePackagesDirPath", os.path.join(ROOT, "SourcePackages"),
        "APP_BUNDLE_ID=" + BUNDLE, "COMPILER_INDEX_STORE_ENABLE=NO", "build"])
    if app:
        shutil.rmtree(app, ignore_errors=True)
        sh(["cp", "-cR", APP, app])
    return app or APP


def project(name):
    """A folder for a run's project, a git repository, in the perf folder."""
    folder = os.path.join(ROOT, "projects", name)
    if not os.path.exists(os.path.join(folder, ".git")):
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, "README.md"), "w").write("# %s\n" % name)
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null")
        for args in (["init", "-q"], ["add", "-A"], ["-c", "user.name=perf", "-c", "user.email=perf@example.com", "commit", "-qm", "Start"]):
            sh(["git", "-C", folder] + args, env=env)
    return folder


def quit_app(app=None):
    sh(["osascript", "-e", 'tell application id "%s" to quit' % BUNDLE], check=False)
    time.sleep(2)
    for path in [app or APP]:
        sh(["pkill", "-f", path + "/Contents/MacOS"], check=False)
    time.sleep(1)


def launch(app, **env):
    """The perf copy, in the background, its window past the screen's edge."""
    quit_app(app)
    sh(["defaults", "write", BUNDLE, "analytics.noticeShown", "-bool", "true"])
    values = {"KUVO_DEMO_BACKGROUND": "1", "KUVO_DEMO_USAGE": "off", "KUVO_DEMO_OFFSCREEN": "1", "KUVO_DEMO_WINDOW": "1300x820",
              "KUVO_DEMO_MACHINE_ROOT": ".kuvo-code-perf"}
    values.update({k: str(v) for k, v in env.items()})
    command = ["open", "-n", "-g"]
    for k, v in values.items():
        command += ["--env", "%s=%s" % (k, v)]
    sh(command + [app, "--args", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"])


def record(name, prompt, app=APP, limit=1200):
    """Has the perf copy's agent answer `prompt` with a free model, and keeps the engine's events
    until the run ends, in <name>.jsonl."""
    os.makedirs(ROOT, exist_ok=True)
    out = os.path.join(ROOT, name + ".jsonl")
    engine = os.path.join(SUPPORT, "e2e-engine.json")
    if os.path.exists(engine):
        os.remove(engine)
    launch(app, KUVO_E2E="1", KUVO_DEMO_FOLDER=project(name), KUVO_DEMO_PROMPT=prompt, KUVO_DEMO_MODEL=MODEL)
    deadline = time.time() + 300
    while not os.path.exists(engine):
        if time.time() > deadline:
            raise RuntimeError("the perf copy's engine didn't start")
        time.sleep(0.5)
    record = json.load(open(engine))
    auth = "Basic " + base64.b64encode(("%s:%s" % (record["username"], record["password"])).encode()).decode()
    request = urllib.request.Request(record["url"].rstrip("/") + "/api/event", headers={"Authorization": auth})
    start, count = time.time(), 0
    with urllib.request.urlopen(request, timeout=limit) as events, open(out, "w") as f:
        for line in events:
            line = line.decode().rstrip("\n")
            if not line.startswith("data:"):
                continue
            raw = line[5:].strip()
            f.write(json.dumps({"t": round((time.time() - start) * 1000), "raw": raw}) + "\n")
            count += 1
            kind = json.loads(raw).get("type", "")
            if kind.startswith("session.execution.") and kind != "session.execution.started":
                break
    quit_app(app)
    log("recorded %d events in %d s: %s" % (count, time.time() - start, out))
    return out


def bench(app, replay, label, **env):
    """Plays `replay` into a new session of `app`, and the app's measurements of it."""
    result = os.path.join(ROOT, "result.txt")
    if os.path.exists(result):
        os.remove(result)
    launch(app, KUVO_DEMO_FOLDER=project("replay"), KUVO_DEMO_REPLAY=replay, KUVO_PERF_LOG=result, **env)
    deadline = time.time() + 1800
    while not (os.path.exists(result) and os.path.getsize(result) > 0):
        if time.time() > deadline:
            raise RuntimeError("no result")
        time.sleep(1)
    quit_app(app)
    line = "[%s] %s" % (label, open(result).read().strip())
    with open(os.path.join(ROOT, "results.txt"), "a") as f:
        f.write(line + "\n")
    return line


# The measurements that matter, each a way of using a conversation while it streams.
CASES = {
    "thinking": dict(KUVO_DEMO_OPEN_STEPS=1),
    "thinking-scrolling": dict(KUVO_DEMO_OPEN_STEPS=1, KUVO_DEMO_WANDER=15, KUVO_DEMO_WANDER_FOR=600),
    "reply": dict(),
    "reply-scrolling": dict(KUVO_DEMO_WANDER=15, KUVO_DEMO_WANDER_FOR=600),
    "finished-scrolling": dict(KUVO_DEMO_REPLAY_SPEED=50, KUVO_DEMO_REPLAY_HOLD=30, KUVO_DEMO_WANDER=8, KUVO_DEMO_WANDER_FOR=40),
}


def clean():
    """Removes everything the perf copy keeps on this Mac, and the perf folder."""
    quit_app()
    sh(["defaults", "delete", BUNDLE], check=False)
    lib = HOME + "/Library/"
    for path in [SUPPORT, lib + "Caches/" + BUNDLE, lib + "HTTPStorages/" + BUNDLE, lib + "HTTPStorages/" + BUNDLE + ".binarycookies",
                 lib + "WebKit/" + BUNDLE, lib + "Saved Application State/" + BUNDLE + ".savedState",
                 lib + "Preferences/" + BUNDLE + ".plist", os.path.join(TEMP, BUNDLE),
                 os.path.join(sh(["getconf", "DARWIN_USER_CACHE_DIR"]), BUNDLE), ROOT]:
        if os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        elif os.path.exists(path):
            os.remove(path)
    log("cleaned the perf copy's folders")


USAGE = """kuvo_perf.py <command>
  build [source] [app]           the perf copy, from this checkout or another; app keeps a copy of it
  record <name> <prompt>         a real run with a free model, recorded as <name>.jsonl
  bench <app> <name> <case>      plays <name>.jsonl into <app> and prints the measurements
                                 (cases: %s; KEY=VALUE adds launch values)
  clean                          quits the copy and removes all it keeps""" % ", ".join(CASES)

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(USAGE)
        sys.exit(2)
    if a[0] == "build":
        print(build(*a[1:3]))
    elif a[0] == "record" and len(a) >= 3:
        record(a[1], " ".join(a[2:]))
    elif a[0] == "bench" and len(a) >= 4:
        extra = dict(kv.split("=", 1) for kv in a[4:])
        print(bench(os.path.abspath(a[1]), os.path.join(ROOT, a[2] + ".jsonl"), "%s %s %s" % (os.path.basename(a[1]), a[2], a[3]), **{**CASES[a[3]], **extra}))
    elif a[0] == "clean":
        clean()
    else:
        print(USAGE)
        sys.exit(2)
