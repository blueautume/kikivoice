#!/usr/bin/env python3
"""Install fixed-host daily data snapshots without changing API/media services."""
import argparse
import base64
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[4]
HOSTS = {
    "account": {"ssh": ["ssh", "-i", str(Path.home()/".ssh/kikitalk_server.pem"),
                        "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                        "-o", "UserKnownHostsFile="+str(Path.home()/".ssh/kikitalk_known_hosts"),
                        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "root@43.138.219.160"],
                "user": "kikitalk", "data": "/var/lib/kikitalk", "backup": "/var/lib/kikitalk-backups", "time": "03:30:00"},
    "voice": {"ssh": ["ssh", "-F", str(ROOT/"experiments/livekit/infra/ssh_config"), "furby-livekit-lab"],
              "user": "livekit-lab", "data": "/var/lib/kiki-livekit-lab", "backup": "/var/lib/kiki-livekit-backups", "time": "03:40:00"},
}


def install(service):
    config = HOSTS[service]
    payload = base64.b64encode(Path(__file__).with_name("data_backup.py").read_bytes()).decode("ascii")
    unit = "kiki-" + service + "-data-backup"
    service_text = f"""[Unit]
Description=Kiki {service} consistent backup and isolated restore verification
After=local-fs.target

[Service]
Type=oneshot
User={config['user']}
Group={config['user']}
ExecStart=/usr/bin/python3 /opt/kiki-maintenance/data_backup.py {service}
UMask=0077
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={config['data']} {config['backup']}
TimeoutStartSec=300
"""
    timer_text = f"""[Unit]
Description=Daily Kiki {service} data snapshot

[Timer]
OnCalendar=*-*-* {config['time']} Asia/Shanghai
RandomizedDelaySec=600
Persistent=true
Unit={unit}.service

[Install]
WantedBy=timers.target
"""
    script = f"""
import base64,json,os,pathlib,pwd,subprocess
account=pwd.getpwnam({config['user']!r})
code=pathlib.Path('/opt/kiki-maintenance')
code.mkdir(mode=0o755,exist_ok=True)
path=code/'data_backup.py'
path.write_bytes(base64.b64decode({payload!r}))
path.chmod(0o755)
directory=pathlib.Path({config['backup']!r})
directory.mkdir(mode=0o700,parents=True,exist_ok=True)
directory.chmod(0o700)
os.chown(directory,account.pw_uid,account.pw_gid)
for name,content in [({unit+'.service'!r},{service_text!r}),({unit+'.timer'!r},{timer_text!r})]:
 path=pathlib.Path('/etc/systemd/system')/name
 path.write_text(content)
 path.chmod(0o644)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now',{unit+'.timer'!r}],check=True,capture_output=True)
subprocess.run(['systemctl','start',{unit+'.service'!r}],check=True,capture_output=True)
status=json.loads(pathlib.Path({config['data']+'/backup-status.json'!r}).read_text())
print(json.dumps({{'service':{service!r},'status':status,'timer':subprocess.run(['systemctl','is-active',{unit+'.timer'!r}],capture_output=True,text=True).stdout.strip()}}))
"""
    subprocess.run(config["ssh"]+["python3 -"], input=script.encode(), check=True, timeout=360)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=HOSTS)
    install(parser.parse_args().service)
