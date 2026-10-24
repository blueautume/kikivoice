#!/usr/bin/env python3
"""Publish only API source, or synchronize public profile numbers.

Usage: deploy_public_numbers.py {voice,account,sync} [--check]
Publish voice before account, then sync. --check performs no network operations.
Rollback restores source only; retained SQLite snapshots are never restored by
this tool. Website, legal resources outside app/, environment, nginx and media
services are outside its release scope.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
from io import BytesIO
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "output/public-number-layout-2026-10-23"
spec = importlib.util.spec_from_file_location("maintenance_hosts", ROOT / "experiments/livekit/infra/maintenance/install_maintenance.py")
hosts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosts)
ALLOWED = {
    "account": {"main.py", "social.py", "social_content.py", "account_numbers.py"},
    "voice": {"main.py", "account_bridge.py", "safety.py"},
}
EXPECTED_ACCOUNT_COUNT = 4


def source_directory(service):
    return ROOT / ("backend/app" if service == "account" else "experiments/livekit/backend/app")


def source_hashes(service):
    source = source_directory(service)
    return {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(source.rglob("*")) if path.is_file() and path.suffix in {".py", ".json"}
            and "__pycache__" not in path.parts}


def context(service, stamp):
    config = hosts.HOSTS[service]
    return {"service": service, "unit": "kikitalk.service" if service == "account" else "livekit-lab-api.service",
            "user": config["user"], "data": config["data"],
            "application": "/opt/kikitalk" if service == "account" else "/opt/kiki-livekit-lab/backend",
            "interpreter": "/opt/kikitalk/venv/bin/python" if service == "account" else "/opt/kiki-livekit-lab/venv/bin/python",
            "databaseKey": "DATABASE_PATH" if service == "account" else "LAB_DB_PATH",
            "databaseFilename": "kikitalk.sqlite3" if service == "account" else "lab.sqlite3",
            "port": 8000 if service == "account" else 8010,
            "stage": "/root/kiki-public-number-releases/" + stamp + "-" + service,
            "allowedFiles": sorted(ALLOWED[service]), "expectedHashes": source_hashes(service),
            "expectedAccountCount": EXPECTED_ACCOUNT_COUNT}


REMOTE_COMMON = r'''
from contextlib import closing
import base64,hashlib,json,os,pathlib,re,shutil,sqlite3,subprocess,tarfile,time,urllib.request
from io import BytesIO
os.umask(0o077)
phase='preflight'
stage=pathlib.Path(context['stage'])
application=pathlib.Path(context['application'])

def run(command,**kwargs):
    kwargs.setdefault('timeout',90)
    return subprocess.run(command,check=True,capture_output=True,**kwargs)

def property_value(name):
    return run(['systemctl','show',context['unit'],'-p',name,'--value'],text=True).stdout.strip()

def private_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    path.chmod(0o600)

def hashes(directory):
    return {str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob('*') if p.is_file() and p.suffix in ('.py','.json') and '__pycache__' not in p.parts}

def resolve_process():
    if property_value('ActiveState')!='active' or property_value('User')!=context['user']:
        raise RuntimeError('Service process unavailable')
    pid=int(property_value('MainPID'))
    if pid<=0: raise RuntimeError('Service process unavailable')
    process=pathlib.Path('/proc')/str(pid)
    environment=dict(item.split(b'=',1) for item in (process/'environ').read_bytes().split(b'\0') if b'=' in item)
    cwd=pathlib.Path(os.readlink(process/'cwd')).resolve(strict=True)
    if cwd!=application.resolve(strict=True): raise RuntimeError('Unexpected application directory')
    standard=(pathlib.Path(context['data'])/context['databaseFilename']).resolve(strict=True)
    configured=os.fsdecode(environment.get(context['databaseKey'].encode(),str(standard).encode()))
    database=(cwd/configured).resolve(strict=True)
    if database!=standard: raise RuntimeError('Database outside verified backup scope')
    return database,{os.fsdecode(k):os.fsdecode(v) for k,v in environment.items()}

def readonly(database):
    db=sqlite3.connect(database.as_uri()+'?mode=ro',uri=True,timeout=15)
    db.execute('PRAGMA query_only=ON')
    return db

def private_snapshot(database,destination):
    with closing(readonly(database)) as source, closing(sqlite3.connect(destination)) as target:
        source.backup(target)
        if target.execute('PRAGMA quick_check').fetchall()!=[('ok',)]:
            raise RuntimeError('Private SQLite snapshot invalid')
        if target.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise RuntimeError('Private SQLite snapshot has invalid references')
    destination.chmod(0o600)

def verified_backup():
    started=time.time()
    run(['systemctl','start','kiki-'+context['service']+'-data-backup.service'],timeout=330)
    status=json.loads((pathlib.Path(context['data'])/'backup-status.json').read_text())
    if (status.get('service')!=context['service'] or status.get('lastError')
            or not isinstance(status.get('verifiedAt'),(int,float))
            or status['verifiedAt']<started-2 or status.get('lastSuccessAt')!=status['verifiedAt']):
        raise RuntimeError('Fresh verified backup required')
    return status

def identity_state(db):
    if context['service']=='account':
        identities=[tuple(row) for row in db.execute('SELECT account_id,login_id,sdk_user_id FROM accounts ORDER BY account_id')]
        columns={row[1] for row in db.execute('PRAGMA table_info(accounts)')}
        result={'accountCount':len(identities),'numberColumnPresent':'public_number' in columns}
        if 'public_number' in columns:
            numbers=[row[0] for row in db.execute('SELECT public_number FROM accounts ORDER BY created_at,account_id')]
            result.update(numberCount=sum(type(n) is int and 1<=n<=999999 for n in numbers),
                          distinctNumberCount=len(set(numbers)),initialSequence=numbers==list(range(1,len(numbers)+1)))
    else:
        identities=[tuple(row) for row in db.execute('SELECT id,deleted,created_at FROM users ORDER BY id')]
        result={'accountCount':len(identities),'deletedCount':sum(bool(row[1]) for row in identities),
                'numberColumnPresent':'display_id' in {row[1] for row in db.execute('PRAGMA table_info(users)')}}
    result['identityDigest']=hashlib.sha256(json.dumps(identities,separators=(',',':')).encode()).hexdigest()
    result['foreignKeyViolationCount']=sum(1 for _ in db.execute('PRAGMA foreign_key_check'))
    return result

def database_state(database):
    with closing(readonly(database)) as db:
        db.execute('BEGIN')
        return identity_state(db)

def wait_health():
    for attempt in range(40):
        try:
            with urllib.request.urlopen('http://127.0.0.1:'+str(context['port'])+'/health',timeout=3) as response:
                health=json.load(response)
            if (health.get('status')=='ok' if context['service']=='account' else health.get('ok') is True):
                return True
        except Exception: pass
        time.sleep(.5)
    raise RuntimeError('API health verification failed')

def set_source_permissions(directory):
    directory.chmod(0o755)
    for path in directory.rglob('*'):
        path.chmod(0o755 if path.is_dir() else 0o644)
'''

REMOTE_DEPLOY = r'''
stopped=False
previous=None
try:
    database,environment=resolve_process()
    before=database_state(database)
    if before['foreignKeyViolationCount']:
        raise RuntimeError('Existing invalid database references')
    if context['service']=='account' and before['accountCount']!=context['expectedAccountCount']:
        raise RuntimeError('Account count changed since read-only preflight')
    if any(path.is_symlink() or (path.is_file() and path.suffix not in ('.py','.json'))
           for path in (application/'app').rglob('*') if '__pycache__' not in path.parts):
        raise RuntimeError('Unexpected files in API source directory')
    old_hashes=hashes(application/'app')
    new_hashes=context['expectedHashes']
    changed=sorted(name for name in old_hashes.keys()|new_hashes.keys() if old_hashes.get(name)!=new_hashes.get(name))
    if set(changed)-set(context['allowedFiles']):
        raise RuntimeError('Source differences outside release scope')
    # JSON/legal files must remain byte-for-byte identical even inside app/.
    if any(name.endswith('.json') for name in changed):
        raise RuntimeError('Legal/resource changes outside release scope')
    stage.mkdir(mode=0o700,parents=True,exist_ok=False)
    stage.chmod(0o700)
    previous=stage/'previous';previous.mkdir(mode=0o700)
    shutil.copytree(application/'app',previous/'app')
    private_json(stage/'source-difference.json',{'changedFiles':changed,'before':old_hashes,'after':new_hashes})
    payload=stage/'payload';payload.mkdir(mode=0o700)
    archive=base64.b64decode(archive_base64,validate=True)
    with tarfile.open(fileobj=BytesIO(archive),mode='r:gz') as tar:
        members=tar.getmembers()
        if len(members)!=len(new_hashes): raise RuntimeError('Unexpected source archive entries')
        for member in members:
            destination=(payload/member.name).resolve()
            if (not member.isfile() or not destination.is_relative_to(payload.resolve())
                    or member.name not in {'app/'+name for name in new_hashes}):
                raise RuntimeError('Unsafe source archive')
        tar.extractall(payload)
    if hashes(payload/'app')!=new_hashes: raise RuntimeError('Source archive hash mismatch')
    phase='import_preflight'
    run([context['interpreter'],'-c','import app.main'],cwd=payload,
        env={**environment,'PYTHONDONTWRITEBYTECODE':'1'})
    phase='verified_backup'
    backup=verified_backup()
    private_json(previous/'backup-status.json',backup)
    phase='stop_api'
    run(['systemctl','stop',context['unit']]);stopped=True
    # Include all writes since the live verified backup in a stopped snapshot.
    before=database_state(database)
    if context['service']=='account' and before['accountCount']!=context['expectedAccountCount']:
        raise RuntimeError('Account count changed before API stop')
    phase='private_snapshot'
    private_snapshot(database,previous/'database.sqlite3')
    private_json(previous/'identity-state.json',before)
    phase='replace_source'
    shutil.rmtree(application/'app')
    shutil.copytree(payload/'app',application/'app')
    set_source_permissions(application/'app')
    phase='start_api'
    run(['systemctl','start',context['unit']])
    wait_health()
    phase='verify_release'
    if hashes(application/'app')!=new_hashes: raise RuntimeError('Installed source hash mismatch')
    resolve_process()
    after=database_state(database)
    if (after['identityDigest']!=before['identityDigest'] or after['accountCount']!=before['accountCount']
            or after['foreignKeyViolationCount'] or not after['numberColumnPresent']):
        raise RuntimeError('Database identity invariants failed')
    if context['service']=='account':
        if after['numberCount']!=after['accountCount'] or after['distinctNumberCount']!=after['accountCount']:
            raise RuntimeError('Public number assignment incomplete or invalid')
        if not before['numberColumnPresent'] and not after['initialSequence']:
            raise RuntimeError('First public number assignment order invalid')
    result={'service':context['service'],'success':True,'sourceOnly':True,'changedSourceFiles':changed,
            'sourceFilesVerified':len(new_hashes),'serviceState':property_value('ActiveState'),'healthVerified':True,
            'accountCount':after['accountCount'],'identitiesPreserved':True,'foreignKeyViolationCount':0,
            'numberColumnPresent':True,'rollbackDirectory':str(previous),'databaseSnapshotRetained':True,
            'databaseRestored':False,'backupVerified':True}
    if context['service']=='account':
        result.update(publicNumberCount=after['numberCount'],distinctPublicNumberCount=after['distinctNumberCount'])
    private_json(stage/'release-result.json',result)
    print(json.dumps(result))
except Exception as error:
    rollback=False
    rollback_health=False
    if stopped and previous is not None:
        try:
            run(['systemctl','stop',context['unit']])
            if (application/'app').exists(): shutil.rmtree(application/'app')
            shutil.copytree(previous/'app',application/'app')
            set_source_permissions(application/'app')
            if hashes(application/'app')!=old_hashes: raise RuntimeError('Restored source hash mismatch')
            run(['systemctl','start',context['unit']])
            rollback=True
            rollback_health=wait_health()
        except Exception: pass
    result={'service':context['service'],'success':False,'failedPhase':phase,'errorType':type(error).__name__,
            'sourceRolledBack':rollback,'rollbackHealthVerified':rollback_health,'databaseRestored':False}
    if stage.exists(): private_json(stage/'release-result.json',result)
    print(json.dumps(result))
    raise SystemExit(1)
'''

REMOTE_READ_MAPPING = r'''
try:
    database,_=resolve_process()
    if hashes(application/'app')!=context['expectedHashes']:
        raise RuntimeError('Account source release required before synchronization')
    with closing(readonly(database)) as db:
        db.execute('BEGIN')
        state=identity_state(db)
        if (state['accountCount']!=context['expectedAccountCount'] or state['foreignKeyViolationCount']
                or not state['numberColumnPresent'] or state['numberCount']!=state['accountCount']
                or state['distinctNumberCount']!=state['accountCount']):
            raise RuntimeError('Account public numbers unavailable')
        mapping={row[0]:'kiki_'+format(row[1],'06d') for row in db.execute('SELECT login_id,public_number FROM accounts')}
    # Captured directly by the caller, never logged or saved in local results.
    print(json.dumps(mapping))
except Exception:
    raise SystemExit(1)
'''

REMOTE_SYNC = r'''
sync_committed=False

def invariant_fingerprints(db):
    result={}
    for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"):
        columns=[row[1] for row in db.execute('PRAGMA table_info("'+table.replace('"','""')+'")')
                 if not (table=='users' and row[1]=='display_id')]
        selected=','.join('"'+name.replace('"','""')+'"' for name in columns)
        checksum=hashlib.sha256();count=0
        for row in db.execute('SELECT '+selected+' FROM "'+table.replace('"','""')+'" ORDER BY '+selected):
            checksum.update(repr(tuple(row)).encode());checksum.update(b'\n');count+=1
        result[table]=(count,checksum.hexdigest())
    return result

try:
    database,_=resolve_process()
    if hashes(application/'app')!=context['expectedHashes']:
        raise RuntimeError('Voice source release required before synchronization')
    if (len(mapping)!=context['expectedAccountCount'] or len(set(mapping.values()))!=len(mapping)
            or any(not re.fullmatch(r'kiki_[A-Za-z0-9_]{8,64}',key)
                   or not re.fullmatch(r'kiki_[0-9]{6}',value) or value=='kiki_000000'
                   for key,value in mapping.items())):
        raise RuntimeError('Invalid account number map')
    with closing(readonly(database)) as db:
        if 'display_id' not in {row[1] for row in db.execute('PRAGMA table_info(users)')}:
            raise RuntimeError('Voice number column unavailable')
        if db.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise RuntimeError('Existing invalid database references')
    stage.mkdir(mode=0o700,parents=True,exist_ok=False);stage.chmod(0o700)
    previous=stage/'previous';previous.mkdir(mode=0o700)
    phase='verified_backup'
    private_json(previous/'backup-status.json',verified_backup())
    phase='private_snapshot'
    private_snapshot(database,previous/'database.sqlite3')
    # Run writes as the API owner, preserving normal WAL/SHM ownership. Neither
    # the mapping nor any account credential is persisted in the release folder.
    phase='synchronize_display_numbers'
    import pwd
    owner=pwd.getpwnam(context['user'])
    os.setgroups([]);os.setgid(owner.pw_gid);os.setuid(owner.pw_uid)
    with closing(sqlite3.connect(database,timeout=15)) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('BEGIN IMMEDIATE')
        before=invariant_fingerprints(db)
        deleted_cleared=db.execute('UPDATE users SET display_id=NULL WHERE deleted=1 AND display_id IS NOT NULL').rowcount
        matched=changed=0
        for user_id,display_id in mapping.items():
            row=db.execute('SELECT display_id FROM users WHERE id=? AND deleted=0',(user_id,)).fetchone()
            if row is None: continue
            matched+=1
            if row[0]!=display_id:
                db.execute('UPDATE users SET display_id=? WHERE id=? AND deleted=0',(display_id,user_id));changed+=1
        after=invariant_fingerprints(db)
        if before!=after or db.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise RuntimeError('Synchronization changed stable identities or business records')
        for user_id,display_id in mapping.items():
            row=db.execute('SELECT display_id FROM users WHERE id=? AND deleted=0',(user_id,)).fetchone()
            if row is not None and row[0]!=display_id: raise RuntimeError('Public number cache verification failed')
        if db.execute('SELECT COUNT(*) FROM users WHERE deleted=1 AND display_id IS NOT NULL').fetchone()[0]:
            raise RuntimeError('Deleted profile cache still contains public numbers')
        user_count=db.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        db.commit()
        sync_committed=True
    phase='verify_sync_health'
    wait_health()
    print(json.dumps({'service':'sync','success':True,'accountMappingCount':len(mapping),
          'matchedActiveVoiceUsers':matched,'updatedVoiceUsers':changed,'deletedDisplayNumbersCleared':deleted_cleared,
          'voiceUserCount':user_count,'tablesVerifiedUnchangedExceptDisplayID':len(before),
          'stableIdentitiesAndBusinessRecordsPreserved':True,'foreignKeyViolationCount':0,
          'healthVerified':True,
          'rollbackDirectory':str(previous),'databaseSnapshotRetained':True,'databaseRestored':False}))
except Exception as error:
    print(json.dumps({'service':'sync','success':False,'failedPhase':phase,'errorType':type(error).__name__,
                      'displaySyncCommitted':sync_committed,
                      'databaseRestored':False}))
    raise SystemExit(1)
'''


def remote_script(config, body, **values):
    script = "context=" + repr(config) + "\n"
    script += "\n".join(name + "=" + repr(value) for name, value in values.items()) + "\n"
    script += REMOTE_COMMON + body
    compile(script, "<public-number-release>", "exec")
    return script


def execute_remote(service, script):
    result = subprocess.run(hosts.HOSTS[service]["ssh"] + ["python3 -"], input=script.encode(),
                            capture_output=True, timeout=900)
    # Do not echo command bodies, captured stderr, environment or private maps.
    if result.returncode:
        try:
            summary = json.loads(result.stdout)
        except (ValueError, UnicodeError):
            summary = {"success": False, "errorType": "RemoteExecutionError", "service": service}
        raise ReleaseError(summary)
    return json.loads(result.stdout)


class ReleaseError(Exception):
    def __init__(self, summary):
        self.summary = summary


def prepare_archive(service):
    source = source_directory(service)
    files = source_hashes(service)
    packed = BytesIO()
    with tarfile.open(fileobj=packed, mode="w:gz") as archive:
        for name in files:
            path = source / name
            if path.is_symlink():
                raise ValueError("Source archive cannot contain symbolic links")
            if path.suffix == ".py":
                compile(path.read_bytes(), str(path), "exec")
            else:
                json.loads(path.read_text())
            archive.add(path, arcname="app/" + name, recursive=False)
    with tarfile.open(fileobj=BytesIO(packed.getvalue()), mode="r:gz") as archive:
        names = archive.getnames()
        if set(names) != {"app/" + name for name in files} or len(names) != len(files):
            raise ValueError("Source archive contains unexpected files")
    return base64.b64encode(packed.getvalue()).decode(), names


def perform(operation, *, check=False):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    if operation == "sync":
        account_context = context("account", stamp)
        voice_context = context("voice", stamp + "-sync")
        read_script = remote_script(account_context, REMOTE_READ_MAPPING)
        # Compile the same writer with harmless placeholder mapping offline.
        writer = remote_script(voice_context, REMOTE_SYNC, mapping={})
        if check:
            return {"operation": "sync", "remoteScriptsCompiled": 2, "networkActions": False,
                    "writesOnly": "voice.users.display_id", "mappingLogged": False}
        mapping = execute_remote("account", read_script)
        result = execute_remote("voice", remote_script(voice_context, REMOTE_SYNC, mapping=mapping))
        mapping.clear()
        return result
    archive, names = prepare_archive(operation)
    script = remote_script(context(operation, stamp), REMOTE_DEPLOY, archive_base64=archive)
    if check:
        return {"operation": operation, "packedFiles": len(names), "packedFileNames": names,
                "allowedSourceChanges": sorted(ALLOWED[operation]), "sourceOnly": True,
                "remoteScriptCompiled": True, "networkActions": False,
                "databaseRollbackEnabled": False}
    return execute_remote(operation, script)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("voice", "account", "sync"))
    parser.add_argument("--check", action="store_true", help="Compile scripts and validate archives without SSH or database access")
    args = parser.parse_args()
    try:
        result = perform(args.operation, check=args.check)
        exit_code = 0
    except ReleaseError as error:
        result, exit_code = error.summary, 1
    OUTPUT.mkdir(parents=True, exist_ok=True)
    suffix = "check" if args.check else "result"
    (OUTPUT / (args.operation + "-release-" + suffix + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
