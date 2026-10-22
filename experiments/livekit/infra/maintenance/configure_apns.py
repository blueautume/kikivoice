#!/usr/bin/env python3
"""Stage private APNs keys on the fixed account host, or enable staged keys.

Only reads local private-directory metadata; no private material is printed,
written into a checkout, or passed as command-line arguments. Does not restart
services. Stage disabled first, then enable immediately before the API release.
"""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import subprocess

from install_maintenance import HOSTS

TEAM = "A82X46N3WS"
TOPIC = "com.kikitalk.demo"
PRIVATE = Path.home() / ".config/kikitalk/secrets/apns"


def local_payload():
    result = {}
    for environment in ("sandbox", "production"):
        metadata = PRIVATE / (environment + ".json")
        if metadata.is_symlink() or not metadata.is_file():
            raise RuntimeError("Missing private APNs metadata")
        item = json.loads(metadata.read_text())
        if (item["environment"] != environment or item["teamID"] != TEAM or
                item["topic"] != TOPIC or not re.fullmatch(r"[A-Z0-9]{10}", item["keyID"])):
            raise RuntimeError("Unexpected APNs identity configuration")
        key = PRIVATE / item["keyFile"]
        if (key.parent != PRIVATE or key.is_symlink() or not key.is_file() or
                stat.S_IMODE(key.stat().st_mode) != 0o600):
            raise RuntimeError("Private key must be a local 0600 regular file")
        public = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout",
                                 "-text_pub", "-noout"], check=True, capture_output=True).stdout
        if b"prime256v1" not in public:
            raise RuntimeError("APNs requires an EC P-256 private key")
        result[environment] = {"keyID": item["keyID"],
                               "key": base64.b64encode(key.read_bytes()).decode("ascii")}
    return result


def remote_program(payload, enabled):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    script = f'''import base64,json,os,pathlib,pwd,re,shutil,subprocess
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
os.umask(0o077)
payload={payload!r}
enabled={enabled!r}
environment=pathlib.Path('/etc/kikitalk/server.env')
assert environment.is_file() and not environment.is_symlink()
assert subprocess.run(['systemctl','show','kikitalk.service','-p','User','--value'],capture_output=True,text=True,check=True).stdout.strip()=='kikitalk'
backup=pathlib.Path('/root/kiki-apns-releases')/{stamp!r}
backup.mkdir(parents=True,mode=0o700)
shutil.copy2(environment,backup/'server.env');(backup/'server.env').chmod(0o600)
directory=pathlib.Path('/etc/kikitalk/apns')
if directory.exists():
 assert directory.is_dir() and not directory.is_symlink()
 shutil.copytree(directory,backup/'apns')
 for p in (backup/'apns').rglob('*'):p.chmod(0o700 if p.is_dir() else 0o600)
directory.mkdir(mode=0o750,exist_ok=True)
account=pwd.getpwnam('kikitalk');os.chown(directory,0,account.pw_gid);directory.chmod(0o750)
updates={{'APNS_ENABLED':'1' if enabled else '0','APNS_TEAM_ID':{TEAM!r}}}
for name,item in payload.items():
 assert name in ('sandbox','production') and re.fullmatch(r'[A-Z0-9]{{10}}',item['keyID'])
 data=base64.b64decode(item['key'],validate=True)
 key=serialization.load_pem_private_key(data,password=None)
 assert isinstance(key,ec.EllipticCurvePrivateKey) and isinstance(key.curve,ec.SECP256R1)
 path=directory/(name+'.p8')
 if enabled:
  assert path.is_file() and not path.is_symlink() and path.read_bytes()==data
 else:
  temporary=directory/(name+'.next')
  if temporary.exists() or temporary.is_symlink():raise RuntimeError('Unexpected staged key file')
  fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640)
  with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
  os.chown(temporary,0,account.pw_gid);temporary.chmod(0o640);os.replace(temporary,path)
 prefix='APNS_'+name.upper()
 updates[prefix+'_KEY_ID']=item['keyID'];updates[prefix+'_PRIVATE_KEY_PATH']=str(path)
old=environment.read_text().splitlines()
lines=[line for line in old if line.partition('=')[0] not in updates and line.partition('=')[0]!='APNS_TOPIC']
lines.extend(k+'='+v for k,v in updates.items())
temporary=environment.with_name('server.env.apns-next')
if temporary.exists() or temporary.is_symlink():raise RuntimeError('Unexpected staged environment file')
fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as stream:stream.write('\\n'.join(lines)+'\\n');stream.flush();os.fsync(stream.fileno())
os.chown(temporary,0,0);temporary.chmod(0o600);os.replace(temporary,environment)
print(json.dumps({{'service':'account','enabledInEnvironment':enabled,'restartPerformed':False,'teamID':{TEAM!r},'topic':{TOPIC!r},'keyDirectory':str(directory),'directoryMode':'0750','keyMode':'0640','rollbackDirectory':str(backup)}}))
'''
    compile(script, "<apns-private-configuration>", "exec")
    return script


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check-local", "stage", "enable"))
    action = parser.parse_args().action
    payload = local_payload()
    script = remote_program(payload, action == "enable")
    if action == "check-local":
        print(json.dumps({"localPrivateKeysValid": True, "environments": list(payload),
                          "remoteScriptCompiles": True, "sshPerformed": False}))
        return
    # The encrypted SSH stdin contains private material; never print script,
    # payload, captured stderr, or subprocess exceptions with remote bodies.
    completed = subprocess.run(HOSTS["account"]["ssh"] + ["/opt/kikitalk/venv/bin/python -"],
                               input=script.encode(), capture_output=True, timeout=60)
    if completed.returncode:
        raise RuntimeError("Private APNs configuration failed; inspect the fixed host privately")
    print(completed.stdout.decode().strip())


if __name__ == "__main__":
    main()
