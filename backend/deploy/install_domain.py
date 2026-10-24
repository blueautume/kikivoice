"""Run as root on the server with a private, already-uploaded staging directory.

The stage contains backend/, website/dist/, fullchain.pem and privkey.pem.
Private credentials are never logged or copied into the source checkout.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import time


def run(*args, capture=False):
    return subprocess.run(args, check=True, capture_output=capture)


def copy_file(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(mode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", type=Path)
    args = parser.parse_args()
    stage = args.stage.resolve()
    if os.geteuid() != 0 or not stage.is_dir():
        raise SystemExit("Run as root with an existing private staging directory")
    required = ["backend/app/main.py", "backend/deploy/kikitalk.service",
                "backend/deploy/nginx.conf", "backend/deploy/kiki.group.conf",
                "backend/deploy/facescan.locations.conf",
                "website/dist/index.html", "fullchain.pem", "privkey.pem"]
    if not all((stage / name).is_file() for name in required):
        raise SystemExit("Staging directory is incomplete")
    # Validate pair and hostname before changing live configuration.
    cert_public = run("openssl", "x509", "-in", str(stage / "fullchain.pem"),
                      "-pubkey", "-noout", capture=True).stdout
    key_public = run("openssl", "pkey", "-in", str(stage / "privkey.pem"),
                     "-pubout", capture=True).stdout
    if cert_public != key_public:
        raise SystemExit("TLS certificate does not match private key")
    run("openssl", "x509", "-in", str(stage / "fullchain.pem"), "-noout",
        "-checkhost", "kiki.group", capture=True)
    run("openssl", "x509", "-in", str(stage / "fullchain.pem"), "-noout",
        "-checkend", "604800", capture=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = Path("/var/backups/kikitalk") / ("domain-install-" + stamp)
    backup.mkdir(parents=True, mode=0o700)
    paths = [Path(p) for p in ["/etc/nginx/nginx.conf", "/etc/nginx/conf.d/kiki.group.conf",
             "/etc/nginx/snippets/facescan.locations.conf",
             "/etc/nginx/tls/kiki.group", "/etc/systemd/system/kikitalk.service",
             "/etc/kikitalk/server.env", "/opt/kikitalk/app", "/opt/kikitalk/deploy"]]
    existed = [p for p in paths if p.exists()]
    archive = backup / "previous.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for path in existed:
            tar.add(path, arcname=str(path).lstrip("/"))
    archive.chmod(0o600)
    # Capture DB and referenced avatars under a writer lock; existing readers run.
    with sqlite3.connect("/var/lib/kikitalk/kikitalk.sqlite3", timeout=10) as lock:
        lock.execute("BEGIN IMMEDIATE")
        with sqlite3.connect("/var/lib/kikitalk/kikitalk.sqlite3") as source:
            with sqlite3.connect(backup / "kikitalk.sqlite3") as target:
                source.backup(target)
        (backup / "kikitalk.sqlite3").chmod(0o600)
        shutil.copytree("/var/lib/kikitalk/avatars", backup / "avatars", dirs_exist_ok=True)
    website_root = Path("/var/www/kikitalk")
    current = website_root / "current"
    previous_site = current.readlink() if current.is_symlink() else None
    previous_nginx = subprocess.run(["systemctl", "is-active", "--quiet", "nginx"]).returncode == 0
    switched = False
    try:
        release = website_root / "releases" / stamp
        release.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stage / "website/dist", release)
        for path in [release, *release.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        temporary_link = website_root / ("current-" + stamp)
        temporary_link.symlink_to(release)
        temporary_link.replace(current)
        tls = Path("/etc/nginx/tls/kiki.group")
        tls.mkdir(parents=True, exist_ok=True, mode=0o700)
        tls.chmod(0o700)
        copy_file(stage / "fullchain.pem", tls / "fullchain.pem")
        copy_file(stage / "privkey.pem", tls / "privkey.pem", 0o600)
        copy_file(stage / "backend/deploy/nginx.conf", Path("/etc/nginx/nginx.conf"))
        copy_file(stage / "backend/deploy/facescan.locations.conf", Path("/etc/nginx/snippets/facescan.locations.conf"))
        copy_file(stage / "backend/deploy/kiki.group.conf", Path("/etc/nginx/conf.d/kiki.group.conf"))
        run("nginx", "-t")
        shutil.copytree(stage / "backend/app", "/opt/kikitalk/app", dirs_exist_ok=True)
        shutil.copytree(stage / "backend/deploy", "/opt/kikitalk/deploy", dirs_exist_ok=True)
        env = Path("/etc/kikitalk/server.env")
        lines = [line for line in env.read_text().splitlines() if not line.startswith("PUBLIC_BASE_URL=")]
        env.write_text("\n".join(lines + ["PUBLIC_BASE_URL=https://kiki.group"]) + "\n")
        env.chmod(0o600)
        copy_file(stage / "backend/deploy/kikitalk.service", Path("/etc/systemd/system/kikitalk.service"))
        run("systemctl", "daemon-reload")
        switched = True
        run("systemctl", "restart", "kikitalk")
        for attempt in range(15):
            try:
                run("curl", "--noproxy", "*", "-fsS", "--max-time", "3",
                    "http://127.0.0.1:8000/health", capture=True)
                break
            except subprocess.CalledProcessError:
                if attempt == 14:
                    raise
                time.sleep(1)
        run("systemctl", "enable", "nginx")
        run("systemctl", "reload" if previous_nginx else "start", "nginx")
        for path in ["/", "/health"]:
            run("curl", "--noproxy", "*", "--resolve", "kiki.group:443:127.0.0.1",
                "-fsS", "--max-time", "10", "https://kiki.group" + path, capture=True)
        print("Domain and website deployed; rollback snapshot:", backup)
        print("Website release:", release)
    except Exception:
        print("Deployment failed; restoring previous configuration")
        if switched:
            subprocess.run(["systemctl", "stop", "nginx"])
            subprocess.run(["systemctl", "stop", "kikitalk"])
        for path in paths:
            if path.exists():
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        # Archive contains only the fixed paths captured above, never user input.
        with tarfile.open(archive) as tar:
            tar.extractall("/", filter="fully_trusted")
        if current.is_symlink():
            current.unlink()
        if previous_site:
            current.symlink_to(previous_site)
        run("systemctl", "daemon-reload")
        if switched:
            run("systemctl", "start", "kikitalk")
        if previous_nginx:
            run("systemctl", "start", "nginx")
        raise


if __name__ == "__main__":
    main()
