#!/usr/bin/env python3
"""Publish only the two FaceScan pages and their nginx location snippet."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
BASE_URL = "https://kiki.group"
URLS = {
    "support": BASE_URL + "/facescan/support.html",
    "privacy": BASE_URL + "/facescan/privacy-policy.html",
}
FILES = {
    "support.html": ROOT / "website/facescan/support.html",
    "privacy-policy.html": ROOT / "website/facescan/privacy-policy.html",
    "facescan.locations.conf": ROOT / "backend/deploy/facescan.locations.conf",
}
SSH = [
    "ssh", "-F", str(Path.home() / ".ssh/kikitalk.conf"),
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "kikitalk-server",
    "python3 -",
]

# Sent over stdin; no paths, HTML, or configuration are interpolated into a shell.
REMOTE = r'''
import base64, fcntl, hashlib, json, os, pathlib, re, stat, subprocess, sys

if os.geteuid() != 0:
    raise RuntimeError("Deployment requires the configured root SSH account")
if not re.fullmatch(r"\d{8}T\d{12}Z", request["releaseId"]):
    raise RuntimeError("Invalid release ID")
os.umask(0o077)
deployment_lock = open("/root/.kiki-facescan-deploy.lock", "a")
fcntl.flock(deployment_lock, fcntl.LOCK_EX)
stamp = request["releaseId"]
stage = pathlib.Path("/root/kiki-facescan-releases") / stamp
previous = stage / "previous"
web = pathlib.Path("/var/www/facescan")
release = web / "releases" / stamp
current = web / "current"
nginx = pathlib.Path("/etc/nginx/conf.d/kiki.group.conf")
snippet = pathlib.Path("/etc/nginx/snippets/facescan.locations.conf")

def atomic_file(path, data, metadata=None):
    temporary = path.with_name(path.name + "." + stamp + ".next")
    try:
        with temporary.open("xb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), metadata["mode"] if metadata else 0o644)
            if metadata:
                os.fchown(output.fileno(), metadata["uid"], metadata["gid"])
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()

def replace_link(target):
    temporary = current.with_name("current." + stamp + ".next")
    try:
        temporary.symlink_to(target)
        os.replace(temporary, current)
    finally:
        if temporary.is_symlink():
            temporary.unlink()

def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(" ".join(arguments) + ": " + result.stderr.strip())

def save_original(path, name):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError("Expected a regular configuration file: " + str(path))
    if not path.exists():
        return None
    info = path.stat()
    backup = previous / name
    backup.write_bytes(path.read_bytes())
    backup.chmod(0o600)
    return {"mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}

def rollback():
    state_file = previous / "state.json"
    if not state_file.exists():
        return {"status": "no_changes_to_restore", "releaseId": stamp}
    state = json.loads(state_file.read_text())
    if current.is_symlink():
        if os.readlink(current) not in (str(release), state["current"]):
            raise RuntimeError("Another release owns current; refusing to overwrite it")
    elif current.exists():
        raise RuntimeError("Current is no longer a symlink; refusing to overwrite it")
    atomic_file(nginx, (previous / "nginx.conf").read_bytes(), state["nginx"])
    if state["snippet"] is None:
        snippet.unlink(missing_ok=True)
    else:
        atomic_file(snippet, (previous / "facescan.locations.conf").read_bytes(), state["snippet"])
    if state["current"] is None:
        current.unlink(missing_ok=True)
    else:
        replace_link(state["current"])
    command(["nginx", "-t"])
    command(["systemctl", "reload", "nginx"])
    result = {"status": "rolled_back", "releaseId": stamp,
              "rollbackDirectory": str(previous)}
    (stage / "rollback-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result

if request["action"] == "rollback":
    print(json.dumps(rollback()))
    sys.exit(0)

expected_names = {"support.html", "privacy-policy.html", "facescan.locations.conf"}
if set(request["files"]) != expected_names:
    raise RuntimeError("Release must contain exactly the three allowed files")
content = {name: base64.b64decode(item["content"], validate=True)
           for name, item in request["files"].items()}
for name, data in content.items():
    if hashlib.sha256(data).hexdigest() != request["files"][name]["sha256"]:
        raise RuntimeError("Payload hash mismatch: " + name)
if web.is_symlink() or (web.exists() and not web.is_dir()):
    raise RuntimeError("FaceScan release root must be a directory")
if current.exists() and not current.is_symlink():
    raise RuntimeError("Existing FaceScan current must be a symlink")
if not nginx.is_file() or nginx.is_symlink():
    raise RuntimeError("Expected the existing regular kiki.group nginx configuration")
original = nginx.read_bytes()
lines = original.splitlines(keepends=True)
anchors = [index for index, line in enumerate(lines)
           if line.rstrip(b"\r\n") == b"    location = /health {"]
if len(anchors) != 1:
    raise RuntimeError("Expected exactly one existing /health insertion point")
include = b"include /etc/nginx/snippets/facescan.locations.conf;"
include_count = sum(bool(re.fullmatch(
    rb"\s*include\s+/etc/nginx/snippets/facescan\.locations\.conf;\s*(?:#.*)?",
    line.rstrip(b"\r\n"))) for line in lines)
if include_count > 1:
    raise RuntimeError("FaceScan include is duplicated in the live configuration")
updated = original
if not include_count:
    index = anchors[0]
    newline = b"\r\n" if lines[index].endswith(b"\r\n") else b"\n"
    updated = b"".join(lines[:index]) + b"    " + include + newline + b"".join(lines[index:])

stage.parent.mkdir(mode=0o700, exist_ok=True)
stage.parent.chmod(0o700)
stage.mkdir(mode=0o700)
previous.mkdir(mode=0o700)
state = {"nginx": save_original(nginx, "nginx.conf"),
         "snippet": save_original(snippet, "facescan.locations.conf"),
         "current": os.readlink(current) if current.is_symlink() else None}
(previous / "state.json").write_text(json.dumps(state, indent=2) + "\n")
(previous / "state.json").chmod(0o600)
try:
    web.mkdir(mode=0o755, exist_ok=True)
    (web / "releases").mkdir(mode=0o755, exist_ok=True)
    release.mkdir(mode=0o755)
    for directory in (web, web / "releases", release):
        directory.chmod(0o755)
    for name in ("support.html", "privacy-policy.html"):
        atomic_file(release / name, content[name])
    snippet.parent.mkdir(mode=0o755, exist_ok=True)
    atomic_file(snippet, content["facescan.locations.conf"])
    if updated != original:
        atomic_file(nginx, updated, state["nginx"])
    replace_link(str(release))
    command(["nginx", "-t"])
    command(["systemctl", "reload", "nginx"])
    result = {"status": "installed", "releaseId": stamp,
              "releaseDirectory": str(release), "rollbackDirectory": str(previous),
              "nginxBeforeSha256": hashlib.sha256(original).hexdigest(),
              "nginxAfterSha256": hashlib.sha256(nginx.read_bytes()).hexdigest(),
              "sourceHashes": {name: item["sha256"] for name, item in request["files"].items()}}
    (stage / "release-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
except BaseException:
    try:
        rollback()
    except BaseException as error:
        print("Automatic remote rollback failed: " + str(error), file=sys.stderr)
    raise
'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_sources():
    sources = {}
    for name, path in FILES.items():
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("Expected a local regular source file: " + str(path))
        sources[name] = path.read_bytes()
        if not sources[name]:
            raise RuntimeError("Source file is empty: " + str(path))
        sources[name].decode("utf-8")
    styles = set()
    for name in ("support.html", "privacy-policy.html"):
        html = sources[name].decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        blocks = re.findall(r"<style(?:\s[^>]*)?>(.*?)</style\s*>", html, re.I | re.S)
        if not blocks:
            raise RuntimeError("Expected an inline style block in " + name)
        styles.update(base64.b64encode(hashlib.sha256(block.encode()).digest()).decode()
                      for block in blocks)
    configured = set(re.findall(r"'sha256-([^']+)'", sources["facescan.locations.conf"].decode()))
    if styles != configured:
        raise RuntimeError("The nginx CSP style hashes do not match the two source pages")
    return sources


def remote_script(stamp, action, sources=None):
    request = {"releaseId": stamp, "action": action}
    if sources is not None:
        request["files"] = {
            name: {"content": base64.b64encode(data).decode(), "sha256": sha256(data)}
            for name, data in sources.items()
        }
    script = "request = " + repr(request) + "\n" + REMOTE
    compile(script, "<facescan-" + action + ">", "exec")
    return script


def run_remote(script):
    result = subprocess.run(SSH, input=script, capture_output=True, text=True, timeout=150)
    if result.returncode:
        raise RuntimeError("Remote operation failed: " + result.stderr.strip()[-4000:])
    return json.loads(result.stdout.strip().splitlines()[-1])


def fetch(url):
    # Use the system CA store, including on macOS Python installations without one.
    if not url.startswith(BASE_URL + "/"):
        raise RuntimeError("Unexpected verification URL: " + url)
    response = subprocess.run([
        "curl", "--noproxy", "*", "--proto", "=https", "--tlsv1.2",
        "--fail", "--silent", "--show-error", "--connect-timeout", "10",
        "--max-time", "20", "--header", "Cache-Control: no-cache",
        "--header", "Accept-Encoding: identity", "--user-agent",
        "FaceScan-release-verifier/1.0", "--write-out", "\n%{http_code}", url,
    ], capture_output=True, timeout=30)
    body, _, status = response.stdout.rpartition(b"\n")
    if response.returncode or status != b"200":
        raise RuntimeError("HTTPS verification failed for " + url + ": " +
                           response.stderr.decode(errors="replace")[-1000:])
    return body


def verify_public(sources, homepage_hash):
    for attempt in range(3):
        try:
            for key, name in (("support", "support.html"), ("privacy", "privacy-policy.html")):
                if sha256(fetch(URLS[key])) != sha256(sources[name]):
                    raise RuntimeError("Public HTML differs from source: " + URLS[key])
            health = json.loads(fetch(BASE_URL + "/health"))
            if health.get("status") != "ok":
                raise RuntimeError("Public /health did not report ok")
            if sha256(fetch(BASE_URL + "/")) != homepage_hash:
                raise RuntimeError("The public homepage changed during deployment")
            return health
        except Exception:
            if attempt == 2:
                raise
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check local sources and script syntax without network access")
    args = parser.parse_args()
    sources = read_sources()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    install_script = remote_script(stamp, "install", sources)
    rollback_script = remote_script(stamp, "rollback")
    result = {"releaseId": stamp, "rollbackDirectory": "/root/kiki-facescan-releases/" + stamp + "/previous",
              "urls": URLS, "sourceHashes": {name: sha256(data) for name, data in sources.items()},
              "remoteScriptCompiled": True, "networkActions": not args.check}
    if args.check:
        result["status"] = "local_check_passed"
        print(json.dumps(result, ensure_ascii=False))
        return
    attempted = False
    try:
        homepage_hash = sha256(fetch(BASE_URL + "/"))
        attempted = True
        result.update(run_remote(install_script))
        result["health"] = verify_public(sources, homepage_hash)
        result.update(status="published", homepageSha256=homepage_hash, publicHtmlHashesVerified=True)
    except BaseException as error:
        result.update(status="failed", error=str(error))
        if attempted:
            try:
                result["rollback"] = run_remote(rollback_script)
            except BaseException as rollback_error:
                result["rollbackError"] = str(rollback_error)
        print(json.dumps(result, ensure_ascii=False), file=sys.stderr)
        raise
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
