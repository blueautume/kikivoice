#!/usr/bin/env python3
"""Publish Kiki application resources without touching shared services/config.

Only Kiki's API unit may restart. Nginx, maintenance code, credentials and the
independent companion console are protected by before/after verification.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("kiki_hosts", ROOT / "experiments/livekit/infra/maintenance/install_maintenance.py")
hosts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosts)


def files(directory, suffixes=None):
    return {str(p.relative_to(directory)): p for p in directory.rglob("*")
            if p.is_file() and "__pycache__" not in p.parts and (suffixes is None or p.suffix in suffixes)}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def deploy(service, check=False):
    config = hosts.HOSTS[service]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    stage = "/root/kiki-only-releases/" + stamp
    app = "/opt/kikitalk" if service == "account" else "/opt/kiki-livekit-lab/backend"
    unit = "kikitalk.service" if service == "account" else "livekit-lab-api.service"
    source = ROOT / ("backend/app" if service == "account" else "experiments/livekit/backend/app")
    payload = {"app/" + name: p for name, p in files(source, (".py", ".json", ".txt")).items()}
    if service == "account":
        payload.update({"website/" + name: p for name, p in files(ROOT / "website/dist").items()})
    else:
        payload["voice-legal.json"] = ROOT / "experiments/livekit/shared/legal_documents.json"
    expected = {name: digest(p) for name, p in payload.items()}
    baseline = {}
    for name, p in payload.items():
        result = subprocess.run(["git", "show", "HEAD:" + str(p.relative_to(ROOT))], cwd=ROOT, capture_output=True)
        if result.returncode == 0:
            baseline[name] = hashlib.sha256(result.stdout).hexdigest()
    manifest = {"expected": expected, "baseline": baseline}
    with tempfile.TemporaryDirectory(prefix="kiki-only-") as temporary:
        archive = Path(temporary) / "payload.tar.gz"
        manifest_path = Path(temporary) / "manifest.json"
        manifest_path.write_text(json.dumps(manifest))
        with tarfile.open(archive, "w:gz") as tar:
            for name, p in sorted(payload.items()):
                tar.add(p, arcname=name)
            tar.add(manifest_path, arcname="manifest.json")
        if not check:
            subprocess.run(config["ssh"] + ["install -d -m 700 " + stage], check=True, timeout=30)
            subprocess.run(["scp"] + config["ssh"][1:-1] + [str(archive), config["ssh"][-1] + ":" + stage + "/payload.tar.gz"], check=True, timeout=90)
    script = f'''
import hashlib,json,os,pathlib,shutil,sqlite3,subprocess,tarfile,time,urllib.request
service={service!r};app=pathlib.Path({app!r});stage=pathlib.Path({stage!r});unit={unit!r};user={config['user']!r}
os.umask(0o077)
def props(name):
 raw=subprocess.run(['systemctl','show',name,'-p','ActiveState','-p','SubState','-p','MainPID','-p','ExecMainStartTimestamp','-p','User'],check=True,capture_output=True,text=True).stdout
 return dict(x.split('=',1) for x in raw.splitlines() if '=' in x)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(p):return {{str(f.relative_to(p)):sha(f) for f in p.rglob('*') if f.is_file() and '__pycache__' not in f.parts and f.suffix in ('.py','.json','.txt')}}
def protected():
 paths=['/etc/nginx/nginx.conf','/opt/kiki-maintenance/data_backup.py',
 '/etc/nginx/conf.d/kiki.group.conf','/etc/kikitalk/server.env'] if service=='account' else [
 '/etc/nginx/nginx.conf','/etc/nginx/sites-enabled/furby.top','/etc/livekit-lab/api.env']
 result={{'nginx':props('nginx.service'),'hashes':{{p:sha(pathlib.Path(p)) for p in paths if pathlib.Path(p).is_file()}}}}
 if service=='account':
  result['companion']=props('batty-club.service')
  for p in ['/etc/systemd/system/batty-club.service','/etc/nginx/conf.d/batty-club.conf','/etc/batty-club/app.env']:
   result['hashes'][p]=sha(pathlib.Path(p))
  result['companionTarget']=str(pathlib.Path('/opt/batty-club/current').resolve())
  with urllib.request.urlopen('http://127.0.0.1:4318/api/health',timeout=8) as response:
   health=json.load(response)
  if health.get('ok') is not True:raise RuntimeError('Protected companion service is not healthy')
 return result
before=protected();(stage/'protected-before.json').write_text(json.dumps(before,indent=2))
assert props(unit)['User']==user and props(unit)['ActiveState']=='active'
payload=stage/'payload';payload.mkdir(mode=0o700)
with tarfile.open(stage/'payload.tar.gz') as tar:
 for member in tar.getmembers():
  if not member.isfile() or not (payload/member.name).resolve().is_relative_to(payload):raise RuntimeError('Unsafe release member')
 tar.extractall(payload)
manifest=json.loads((payload/'manifest.json').read_text())
for name,value in manifest['expected'].items():
 if sha(payload/name)!=value:raise RuntimeError('Payload hash mismatch: '+name)
current={{'app/'+name:value for name,value in tree(app/'app').items()}}
if service=='account':
 web=pathlib.Path('/var/www/kikitalk/current')
 current.update({{'website/'+str(p.relative_to(web)):sha(p) for p in web.rglob('*') if p.is_file()}})
else:current['voice-legal.json']=sha(pathlib.Path('/opt/kiki-livekit-lab/shared/legal_documents.json'))
unexpected=[name for name,value in current.items() if value not in (manifest['baseline'].get(name),manifest['expected'].get(name))]
if unexpected:raise RuntimeError('Unexpected online Kiki changes: '+','.join(unexpected))
changed=sorted(name for name,value in manifest['expected'].items() if current.get(name)!=value)
(stage/'difference.json').write_text(json.dumps({{'changed':changed,'before':current,'expected':manifest['expected']}},indent=2))
previous=stage/'previous';previous.mkdir(mode=0o700)
next_root=app/('.kiki-release-next-'+{stamp!r})
old_web=None;stopped=False;published=False
if changed:
 shutil.copytree(app/'app',previous/'app')
 if service=='account':
  old_web=os.readlink('/var/www/kikitalk/current');(previous/'website-target').write_text(old_web)
 else:shutil.copy2('/opt/kiki-livekit-lab/shared/legal_documents.json',previous/'voice-legal.json')
 # Consistent private Kiki database snapshots; no business DB is replaced on rollback.
 data=pathlib.Path({config['data']!r})
 for database in data.rglob('*'):
  if database.is_file() and database.suffix in ('.sqlite3','.sqlite','.db'):
   target=previous/'data'/database.relative_to(data);target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
   with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as src,sqlite3.connect(target) as dst:
    src.backup(dst)
    if dst.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise RuntimeError('Kiki backup integrity failed')
 next_root.mkdir(mode=0o755);next_root.chmod(0o755)
 shutil.copytree(payload/'app',next_root/'app')
 for p in next_root.rglob('*'):p.chmod(0o755 if p.is_dir() else 0o644)
 (next_root/'app').chmod(0o755)
 interpreter='/opt/kikitalk/venv/bin/python' if service=='account' else '/opt/kiki-livekit-lab/venv/bin/python'
 env={{**os.environ,'PYTHONDONTWRITEBYTECODE':'1'}}
 if service=='voice':
  shutil.copyfile(payload/'voice-legal.json',next_root/'legal.json');(next_root/'legal.json').chmod(0o644)
  env['LEGAL_DOCUMENTS_PATH']=str(next_root/'legal.json')
 preflight='import app.main'
 if service=='voice':preflight+=';import os;app.main.load_legal_manifest(os.environ["LEGAL_DOCUMENTS_PATH"])'
 else:preflight+=';app.main.load_legal_manifest()'
 subprocess.run(['runuser','-u',user,'--',interpreter,'-c',preflight],cwd=next_root,env=env,check=True,capture_output=True)
 try:
  subprocess.run(['systemctl','stop',unit],check=True);stopped=True
  shutil.rmtree(app/'app');shutil.copytree(next_root/'app',app/'app')
  for p in (app/'app').rglob('*'):p.chmod(0o755 if p.is_dir() else 0o644)
  (app/'app').chmod(0o755)
  if service=='account':
   release=pathlib.Path('/var/www/kikitalk/releases')/{stamp!r}
   shutil.copytree(payload/'website',release)
   for p in release.rglob('*'):p.chmod(0o755 if p.is_dir() else 0o644)
   release.chmod(0o755)
   link=pathlib.Path('/var/www/kikitalk/current.kiki-only-next');link.symlink_to(release);os.replace(link,'/var/www/kikitalk/current')
  else:
   shutil.copyfile(payload/'voice-legal.json','/opt/kiki-livekit-lab/shared/legal_documents.json');pathlib.Path('/opt/kiki-livekit-lab/shared/legal_documents.json').chmod(0o644)
  subprocess.run(['systemctl','start',unit],check=True);published=True
 except Exception:
  subprocess.run(['systemctl','stop',unit],check=False)
  if (app/'app').exists():shutil.rmtree(app/'app')
  shutil.copytree(previous/'app',app/'app')
  if service=='account':
   link=pathlib.Path('/var/www/kikitalk/current.kiki-only-rollback');link.symlink_to(old_web);os.replace(link,'/var/www/kikitalk/current')
  else:shutil.copy2(previous/'voice-legal.json','/opt/kiki-livekit-lab/shared/legal_documents.json')
  subprocess.run(['systemctl','start',unit],check=True)
  raise
try:
 health=None
 for attempt in range(30):
  try:
   with urllib.request.urlopen('http://127.0.0.1:'+('8000' if service=='account' else '8010')+'/health',timeout=3) as response:health=json.load(response)
   if health.get('ok') is True or health.get('status')=='ok':break
  except Exception:pass
  time.sleep(.5)
 if health is None or not (health.get('ok') is True or health.get('status')=='ok'):raise RuntimeError('Kiki health check failed')
 actual={{'app/'+name:value for name,value in tree(app/'app').items()}}
 if service=='account':
  web=pathlib.Path('/var/www/kikitalk/current');actual.update({{'website/'+str(p.relative_to(web)):sha(p) for p in web.rglob('*') if p.is_file()}})
 else:actual['voice-legal.json']=sha(pathlib.Path('/opt/kiki-livekit-lab/shared/legal_documents.json'))
 if actual!=manifest['expected']:raise RuntimeError('Deployed Kiki content differs')
 after=protected();(stage/'protected-after.json').write_text(json.dumps(after,indent=2))
 if before!=after:raise RuntimeError('Protected service/config changed during release')
 result={{'service':service,'unit':unit,'action':'published' if published else 'already-current','changedFiles':changed,
 'resourcesVerified':len(actual),'health':health,'apiState':props(unit)['ActiveState'],'protectedUnchanged':True,
 'nginxReloaded':False,'maintenanceChanged':False,'rollbackDirectory':str(previous) if changed else None}}
 (stage/'release-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
except Exception:
 if changed and stopped:
  subprocess.run(['systemctl','stop',unit],check=False)
  if (app/'app').exists():shutil.rmtree(app/'app')
  shutil.copytree(previous/'app',app/'app')
  if service=='account':
   link=pathlib.Path('/var/www/kikitalk/current.kiki-only-rollback');link.symlink_to(old_web);os.replace(link,'/var/www/kikitalk/current')
  else:shutil.copy2(previous/'voice-legal.json','/opt/kiki-livekit-lab/shared/legal_documents.json')
  subprocess.run(['systemctl','start',unit],check=True)
 raise
finally:
 if next_root.exists():shutil.rmtree(next_root)
'''
    compile(script, "<kiki-only-release>", "exec")
    if check:
        print(json.dumps({"service": service, "resources": len(expected), "scriptCompiled": True,
                          "nginxReloaded": False, "maintenanceChanged": False, "networkActions": False}))
        return
    subprocess.run(config["ssh"] + ["python3 -"], input=script.encode(), check=True, timeout=240)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=hosts.HOSTS)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    deploy(args.service, check=args.check)
