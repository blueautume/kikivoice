#!/usr/bin/env python3
"""Publish reviewed P0 code to the two fixed hosts, preserving private rollback copies.

Deploy voice before account. This does not alter capacity, TLS keys, credentials,
Apple configuration, business records, or the LiveKit SFU service.
"""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tarfile
import tempfile

from install_maintenance import ROOT, HOSTS


def deploy(service):
    config = HOSTS[service]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    staging = "/root/kiki-p0-releases/" + stamp
    if service == "voice":
        application = "/opt/kiki-livekit-lab/backend"
        unit = "livekit-lab-api.service"
        legal = "/opt/kiki-livekit-lab/shared/legal_documents.json"
        port = 8010
        source = ROOT / "experiments/livekit/backend/app"
    else:
        application = "/opt/kikitalk"
        unit = "kikitalk.service"
        legal = ""
        port = 8000
        source = ROOT / "backend/app"
    with tempfile.TemporaryDirectory(prefix="kiki-p0-source-") as temporary:
        archive = Path(temporary) / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for path in sorted(source.rglob("*")):
                if path.is_file() and path.suffix in {".py", ".json"} and "__pycache__" not in path.parts:
                    tar.add(path, arcname="app/" + str(path.relative_to(source)))
            if service == "voice":
                tar.add(ROOT / "experiments/livekit/shared/legal_documents.json", arcname="voice-legal.json")
            else:
                for path in sorted((ROOT / "website/dist").rglob("*")):
                    if path.is_file():
                        tar.add(path, arcname="website/" + str(path.relative_to(ROOT / "website/dist")))
        subprocess.run(config["ssh"]+["install -d -m 700 " + staging], check=True, timeout=30)
        subprocess.run(["scp"]+config["ssh"][1:-1]+[str(archive),config["ssh"][-1]+":"+staging+"/source.tar.gz"], check=True, timeout=90)
    script = f"""
import json,os,pathlib,shutil,subprocess,tarfile,time,urllib.request
service={service!r}; app=pathlib.Path({application!r}); stage=pathlib.Path({staging!r}); unit={unit!r}
os.umask(0o077)
assert app.is_dir()
assert subprocess.run(['systemctl','show',unit,'-p','User','--value'],capture_output=True,text=True).stdout.strip()=={config['user']!r}
backup=stage/'previous';backup.mkdir(mode=0o700)
shutil.copytree(app/'app',backup/'app')
environment=pathlib.Path('/etc/livekit-lab/api.env' if service=='voice' else '/etc/kikitalk/server.env')
shutil.copy2(environment,backup/'server.env');(backup/'server.env').chmod(0o600)
nginx_path=pathlib.Path('/etc/nginx/sites-enabled/furby.top' if service=='voice' else '/etc/nginx/conf.d/kiki.group.conf')
old_web=None
if service=='voice':
 shutil.copy2({legal!r},backup/'voice-legal.json')
 shutil.copy2(nginx_path,backup/'nginx.conf')
else:
 old_web=os.readlink('/var/www/kikitalk/current')
 (backup/'website-target').write_text(old_web)
 shutil.copy2(nginx_path,backup/'nginx.conf')
subprocess.run(['systemctl','start','kiki-'+service+'-data-backup.service'],check=True,capture_output=True)
payload=stage/'payload';payload.mkdir(mode=0o700)
with tarfile.open(stage/'source.tar.gz') as tar:
 for member in tar.getmembers():
  target=(payload/member.name).resolve()
  if not target.is_relative_to(payload) or not member.isfile(): raise RuntimeError('Unsafe release member')
 tar.extractall(payload)
stopped=False
try:
 subprocess.run(['systemctl','stop',unit],check=True);stopped=True
 shutil.rmtree(app/'app');shutil.copytree(payload/'app',app/'app')
 for path in (app/'app').rglob('*'): path.chmod(0o755 if path.is_dir() else 0o644)
 (app/'app').chmod(0o755)
 if service=='voice':
  shutil.copyfile(payload/'voice-legal.json',{legal!r});pathlib.Path({legal!r}).chmod(0o644)
  config=nginx_path.read_text();needle='location = /internal/admin/v2/dashboard'
  start=config.index(needle);left=config.index('{{',start);depth=1;end=left+1
  while depth:
   depth+=(config[end]=='{{')-(config[end]=='}}');end+=1
  block=config[start:end]
  if 'allow 43.138.219.160;' not in block or 'deny all;' not in block: raise RuntimeError('Unexpected bridge boundary')
  additions=[]
  for path in ['/internal/admin/v2/moderation/query','/internal/admin/v2/moderation/action',
               '/internal/admin/v2/incidents/query','/internal/v1/account/incident',
               '/internal/v1/account/social-policy','/internal/v1/account/social-block']:
   if 'location = '+path not in config:
    additions.append(block.replace('/internal/admin/v2/dashboard',path).replace('client_max_body_size 1k;','client_max_body_size 16k;'))
  if additions: nginx_path.write_text(config[:end]+'\\n    '+'\\n    '.join(additions)+config[end:])
  nginx_path.chmod(0o644)
 else:
  release=pathlib.Path('/var/www/kikitalk/releases')/{stamp!r}
  shutil.copytree(payload/'website',release)
  for path in release.rglob('*'): path.chmod(0o755 if path.is_dir() else 0o644)
  release.chmod(0o755)
  link=pathlib.Path('/var/www/kikitalk/current.p0-next')
  if link.is_symlink(): link.unlink()
  link.symlink_to(release);os.replace(link,'/var/www/kikitalk/current')
  config=nginx_path.read_text();needle='location = /v1/me/avatar'
  start=config.index(needle);left=config.index('{{',start);depth=1;end=left+1
  while depth:
   depth+=(config[end]=='{{')-(config[end]=='}}');end+=1
  block=config[start:end]
  if 'client_max_body_size 2m;' not in block or 'proxy_pass http://127.0.0.1:8000;' not in block: raise RuntimeError('Unexpected media upload boundary')
  if 'location = /v1/social/media' not in config:
   nginx_path.write_text(config[:end]+'\\n    '+block.replace('/v1/me/avatar','/v1/social/media')+config[end:])
  nginx_path.chmod(0o644)
 subprocess.run(['nginx','-t'],check=True,capture_output=True)
 subprocess.run(['systemctl','start',unit],check=True)
 health=None
 for attempt in range(20):
  try:
   with urllib.request.urlopen('http://127.0.0.1:{port}/health',timeout=3) as response:
    health=json.load(response)
   break
  except Exception: time.sleep(.5)
 if health is None: raise RuntimeError('New API did not become healthy')
 subprocess.run(['systemctl','reload','nginx'],check=True)
 print(json.dumps({{'service':service,'health':health,'rollbackDirectory':str(backup),'apiState':subprocess.run(['systemctl','is-active',unit],capture_output=True,text=True).stdout.strip()}}))
except Exception:
 if stopped:
  subprocess.run(['systemctl','stop',unit],check=False)
  shutil.rmtree(app/'app');shutil.copytree(backup/'app',app/'app')
  if service=='voice':
   shutil.copyfile(backup/'voice-legal.json',{legal!r});shutil.copyfile(backup/'nginx.conf',nginx_path)
  elif old_web is not None:
   shutil.copyfile(backup/'nginx.conf',nginx_path)
   link=pathlib.Path('/var/www/kikitalk/current.p0-rollback')
   if link.is_symlink():link.unlink()
   link.symlink_to(old_web);os.replace(link,'/var/www/kikitalk/current')
  subprocess.run(['systemctl','start',unit],check=False)
  subprocess.run(['nginx','-t'],check=True,capture_output=True)
  subprocess.run(['systemctl','reload','nginx'],check=False)
 raise
"""
    compile(script, "<remote-deployment-preflight>", "exec")
    subprocess.run(config["ssh"]+["python3 -"], input=script.encode(), check=True, timeout=180)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=HOSTS)
    deploy(parser.parse_args().service)
