#!/usr/bin/env python3
"""Publish the native room refresh and matching legal pages with private rollback.

Retired business records remain in protected databases/backups. This release
does not alter credentials, historical business tables or media files.
No business credentials or media SFU configuration are changed.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("maintenance_hosts", ROOT / "experiments/livekit/infra/maintenance/install_maintenance.py")
hosts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosts)


def deploy(service, *, check=False):
    config = hosts.HOSTS[service]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    stage = "/root/kiki-native-room-releases/" + stamp
    app = "/opt/kikitalk" if service == "account" else "/opt/kiki-livekit-lab/backend"
    unit = "kikitalk.service" if service == "account" else "livekit-lab-api.service"
    source = ROOT / ("backend/app" if service == "account" else "experiments/livekit/backend/app")
    port = 8000 if service == "account" else 8010
    legal = json.loads((ROOT / "backend/app/legal_documents.json").read_text())
    assert (ROOT / "backend/app/legal_documents.json").read_bytes() == (ROOT / "experiments/livekit/shared/legal_documents.json").read_bytes()
    assert (ROOT / "backend/app/legal_documents.json").read_bytes() == (ROOT / "ios/KikiTalk/Resources/KikiLegalDocuments.json").read_bytes()
    with tempfile.TemporaryDirectory(prefix="kiki-native-room-release-") as temporary:
        archive = Path(temporary) / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for file in sorted(source.rglob("*")):
                if file.is_file() and file.suffix in (".py", ".json") and "__pycache__" not in file.parts:
                    tar.add(file, arcname="app/" + str(file.relative_to(source)))
            if service == "account":
                tar.add(ROOT / "experiments/livekit/infra/maintenance/data_backup.py", arcname="data_backup.py")
                for file in sorted((ROOT / "website/dist").rglob("*")):
                    if file.is_file(): tar.add(file, arcname="website/" + str(file.relative_to(ROOT / "website/dist")))
            else:
                tar.add(ROOT / "experiments/livekit/shared/legal_documents.json", arcname="voice-legal.json")
        with tarfile.open(archive) as tar:
            packed_files = tar.getnames()
        if not check:
            subprocess.run(config["ssh"] + ["install -d -m 700 " + stage], check=True, timeout=30)
            subprocess.run(["scp"] + config["ssh"][1:-1] + [str(archive), config["ssh"][-1] + ":" + stage + "/source.tar.gz"], check=True, timeout=90)
    script = f'''
import hashlib,json,os,pathlib,shutil,subprocess,tarfile,time,urllib.request
service={service!r}; app=pathlib.Path({app!r}); stage=pathlib.Path({stage!r}); unit={unit!r}
os.umask(0o077)
assert subprocess.run(['systemctl','show',unit,'-p','User','--value'],capture_output=True,text=True).stdout.strip()=={config['user']!r}
previous=stage/'previous'; previous.mkdir(mode=0o700)
shutil.copytree(app/'app',previous/'app')
nginx=pathlib.Path('/etc/nginx/conf.d/kiki.group.conf' if service=='account' else '/etc/nginx/sites-enabled/furby.top')
shutil.copy2(nginx,previous/'nginx.conf')
environment=pathlib.Path('/etc/kikitalk/server.env' if service=='account' else '/etc/livekit-lab/api.env')
shutil.copy2(environment,previous/'server.env');(previous/'server.env').chmod(0o600)
old_web=None
if service=='account':
 shutil.copy2('/opt/kiki-maintenance/data_backup.py',previous/'data_backup.py')
 old_web=os.readlink('/var/www/kikitalk/current');(previous/'website-target').write_text(old_web)
else: shutil.copy2('/opt/kiki-livekit-lab/shared/legal_documents.json',previous/'voice-legal.json')
subprocess.run(['systemctl','start','kiki-'+service+'-data-backup.service'],check=True,capture_output=True)
status=json.loads(pathlib.Path({config['data']!r},'backup-status.json').read_text())
if status.get('lastError') or not status.get('verifiedAt'): raise RuntimeError('Verified data backup required')
(previous/'backup-status.json').write_text(json.dumps(status))
payload=stage/'payload';payload.mkdir(mode=0o700)
with tarfile.open(stage/'source.tar.gz') as tar:
 for member in tar.getmembers():
  if not member.isfile() or not (payload/member.name).resolve().is_relative_to(payload): raise RuntimeError('Unsafe release')
 tar.extractall(payload)
def hashes(directory):
 return {{str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.rglob('*') if p.is_file() and p.suffix in ('.py','.json') and '__pycache__' not in p.parts}}
old_hashes,new_hashes=hashes(app/'app'),hashes(payload/'app')
changed=sorted(name for name in old_hashes.keys()|new_hashes.keys() if old_hashes.get(name)!=new_hashes.get(name))
(stage/'source-difference.json').write_text(json.dumps({{'changed':changed,'before':old_hashes,'after':new_hashes}},indent=2))
# Resolve imports against the actual production interpreter before any stop.
interpreter='/opt/kikitalk/venv/bin/python' if service=='account' else '/opt/kiki-livekit-lab/venv/bin/python'
subprocess.run([interpreter,'-c','import app.main'],cwd=payload,check=True,capture_output=True,
               env={{**os.environ,'PYTHONDONTWRITEBYTECODE':'1'}})
stopped=False
try:
 subprocess.run(['systemctl','stop',unit],check=True);stopped=True
 shutil.rmtree(app/'app');shutil.copytree(payload/'app',app/'app')
 for path in (app/'app').rglob('*'): path.chmod(0o755 if path.is_dir() else 0o644)
 (app/'app').chmod(0o755)
 if service=='account':
  shutil.copyfile(payload/'data_backup.py','/opt/kiki-maintenance/data_backup.py');pathlib.Path('/opt/kiki-maintenance/data_backup.py').chmod(0o755)
  release=pathlib.Path('/var/www/kikitalk/releases')/{stamp!r}
  shutil.copytree(payload/'website',release)
  for path in release.rglob('*'): path.chmod(0o755 if path.is_dir() else 0o644)
  release.chmod(0o755)
  link=pathlib.Path('/var/www/kikitalk/current.native-room-next')
  if link.is_symlink(): link.unlink()
  link.symlink_to(release);os.replace(link,'/var/www/kikitalk/current')
 else:
  shutil.copyfile(payload/'voice-legal.json','/opt/kiki-livekit-lab/shared/legal_documents.json')
  pathlib.Path('/opt/kiki-livekit-lab/shared/legal_documents.json').chmod(0o644)
 subprocess.run(['nginx','-t'],check=True,capture_output=True)
 subprocess.run(['systemctl','start',unit],check=True)
 health=None
 for attempt in range(30):
  try:
   with urllib.request.urlopen('http://127.0.0.1:{port}/health',timeout=3) as response: health=json.load(response)
   break
  except Exception: time.sleep(.5)
 if health is None: raise RuntimeError('New API did not become healthy')
 subprocess.run(['systemctl','reload','nginx'],check=True)
 if hashes(app/'app') != new_hashes: raise RuntimeError('Deployed source differs from prepared payload')
 if service=='account':
  current=pathlib.Path('/var/www/kikitalk/current')
  expected={{str(p.relative_to(payload/'website')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (payload/'website').rglob('*') if p.is_file()}}
  actual={{str(p.relative_to(current)):hashlib.sha256(p.read_bytes()).hexdigest() for p in current.rglob('*') if p.is_file()}}
  if actual != expected: raise RuntimeError('Website differs from prepared payload')
  legal=json.loads((app/'app/legal_documents.json').read_text())
 else: legal=json.loads(pathlib.Path('/opt/kiki-livekit-lab/shared/legal_documents.json').read_text())
 result={{'service':service,'health':health,'changedSourceFiles':changed,'sourceFilesVerified':len(new_hashes),'websiteFilesVerified':len(expected) if service=='account' else None,'legalVersion':legal['privacyVersion'],'legalHash':legal['documentHash'],'rollbackDirectory':str(previous),'apiState':subprocess.run(['systemctl','is-active',unit],capture_output=True,text=True).stdout.strip()}}
 (stage/'release-result.json').write_text(json.dumps(result,indent=2))
 print(json.dumps(result))
except Exception:
 if stopped:
  subprocess.run(['systemctl','stop',unit],check=False)
  shutil.rmtree(app/'app');shutil.copytree(previous/'app',app/'app')
  for path in (app/'app').rglob('*'): path.chmod(0o755 if path.is_dir() else 0o644)
  (app/'app').chmod(0o755)
  shutil.copyfile(previous/'nginx.conf',nginx)
  shutil.copyfile(previous/'server.env',environment);environment.chmod(0o600)
  if service=='account':
   shutil.copyfile(previous/'data_backup.py','/opt/kiki-maintenance/data_backup.py')
   link=pathlib.Path('/var/www/kikitalk/current.native-room-rollback')
   if link.is_symlink(): link.unlink()
   link.symlink_to(old_web);os.replace(link,'/var/www/kikitalk/current')
  else: shutil.copyfile(previous/'voice-legal.json','/opt/kiki-livekit-lab/shared/legal_documents.json')
  subprocess.run(['systemctl','start',unit],check=False)
  subprocess.run(['nginx','-t'],check=True,capture_output=True)
  subprocess.run(['systemctl','reload','nginx'],check=False)
 raise
'''
    compile(script, "<native-room-release>", "exec")
    if check:
        print(json.dumps({"service": service, "packedFiles": len(packed_files), "legalVersion": legal["privacyVersion"],
                          "legalHash": legal["documentHash"], "remoteScriptCompiled": True, "networkActions": False}))
        return
    subprocess.run(config["ssh"] + ["python3 -"], input=script.encode(), check=True, timeout=180)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=hosts.HOSTS)
    parser.add_argument("--check", action="store_true", help="Build and validate the release without SSH or deployment")
    args = parser.parse_args()
    deploy(args.service, check=args.check)
