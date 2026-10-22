#!/usr/bin/env python3
"""Opt-in production experience acceptance with two disposable voice identities.

No Apple credentials, lab authentication, physical microphone or human account
is used. The account-to-voice signing key stays in the remote service process.
Short-lived voice responses cross SSH only through mode-0600 temporary files;
stdout and the optional report contain booleans/counts, never bearer tokens.
Run using the existing kiki-livekit-validation-venv (httpx/livekit 1.1.21).
Only --run-public performs production writes. Finally closes the fixture room,
deletes both identities through the signed bridge and audits data/media cleanup.
Deletion retains normal server tombstones and anonymized closed-room records.
"""
import argparse
import asyncio
import hashlib
import json
import logging
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
ACCOUNT = "https://kiki.group"
VOICE = "https://furby.top"
INITIAL = 100_000_000
SSH_ACCOUNT = ["ssh", "-i", str(Path.home()/".ssh/kikitalk_server.pem"),
               "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "UserKnownHostsFile="+str(Path.home()/".ssh/kikitalk_known_hosts"),
               "-o", "ConnectTimeout=10", "root@43.138.219.160"]
SSH_VOICE = ["ssh", "-F", str(ROOT/"experiments/livekit/infra/ssh_config"), "furby-livekit-lab"]


def remote_account(operation, identities, remote_file):
    script = r'''import hashlib,json,os,pwd,shlex,sys,time
from pathlib import Path
args=json.loads(PAYLOAD)
assert args['op'] in ('create','delete','remove-file')
assert len(args['ids'])==2 and len(set(args['ids']))==2
assert all(__import__('re').fullmatch(r'kiki_expsmoke_[a-f0-9]{24}_[01]',value) for value in args['ids'])
path=Path(args['file']);assert __import__('re').fullmatch(r'/tmp/kiki-experience-smoke-[a-f0-9]{24}\.json',str(path))
for raw in Path('/etc/kikitalk/server.env').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#'):
  key,value=line.split('=',1);parts=shlex.split(value,comments=False);os.environ[key]=parts[0] if len(parts)==1 else value
user=pwd.getpwnam('kikitalk');os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(user.pw_uid)
os.chdir('/opt/kikitalk');sys.path.insert(0,'/opt/kikitalk')
from app.main import Settings,load_legal_requirements
from app.voice_bridge import VoiceBridge
settings=Settings.from_environment();bridge=VoiceBridge(settings,None)
try:
 if args['op']=='create':
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'w') as stream:
   values=[]
   for index,identifier in enumerate(args['ids']):
    authorization=hashlib.sha256(('experience-smoke:'+identifier).encode()).hexdigest()
    profile={'id':identifier,'sdkUserID':identifier,'name':'体验验收'+str(index+1),
     'bio':'Disposable experience validation','avatarIndex':index,'avatarURL':None,
     'needsNickname':False,'notificationsEnabled':False}
    values.append(bridge.post('/internal/v1/account/session',{'authorizationID':authorization,
     'sourceExpiresAt':int(time.time())+1800,'user':profile,'legalConsent':load_legal_requirements(),
     'consentEpoch':1,'lastWithdrawalEpoch':0}))
   json.dump(values,stream)
  print(json.dumps({'created':len(values)}))
 elif args['op']=='delete':
  count=0
  for identifier in args['ids']:
   bridge.post('/internal/v1/account/delete',{'accountID':identifier});count+=1
  if path.exists():path.unlink()
  print(json.dumps({'deleted':count}))
 else:
  if path.exists():path.unlink()
  print(json.dumps({'removed':True}))
finally:bridge.close()
'''.replace("PAYLOAD", repr(json.dumps({"op": operation, "ids": identities, "file": remote_file})))
    result = subprocess.run(SSH_ACCOUNT+["/opt/kikitalk/venv/bin/python -"], input=script,
                            capture_output=True, text=True, timeout=70)
    if result.returncode:
        raise RuntimeError("Restricted fixture operation failed: "+operation)
    return json.loads(result.stdout)


def fetch_private_sessions(remote_file, destination):
    descriptor = os.open(destination, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    os.close(descriptor)
    result = subprocess.run(["scp", "-q"]+SSH_ACCOUNT[1:-1]+[
        SSH_ACCOUNT[-1]+":"+remote_file, str(destination)], capture_output=True, timeout=40)
    if result.returncode:
        raise RuntimeError("Private fixture transfer failed")
    destination.chmod(0o600)
    return json.loads(destination.read_text())


def audit_voice(identities, room_id):
    script = r'''import asyncio,json,os,pwd,shlex,sqlite3,sys
from pathlib import Path
args=json.loads(PAYLOAD);ids=args['ids']
assert len(ids)==2 and all(__import__('re').fullmatch(r'kiki_expsmoke_[a-f0-9]{24}_[01]',value) for value in ids)
for raw in Path('/etc/livekit-lab/api.env').read_text().splitlines():
 line=raw.strip()
 if line and not line.startswith('#'):
  key,value=line.split('=',1);parts=shlex.split(value,comments=False);os.environ[key]=parts[0] if len(parts)==1 else value
user=pwd.getpwnam('livekit-lab');os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(user.pw_uid)
os.chdir('/opt/kiki-livekit-lab/backend');sys.path.insert(0,'/opt/kiki-livekit-lab/backend')
from app.main import Settings
from app.rtc import LiveKitGateway
settings=Settings.from_environment();db=sqlite3.connect('file:'+settings.db_path+'?mode=ro',uri=True)
marks=','.join('?' for value in ids)
count=lambda sql:db.execute(sql,ids).fetchone()[0]
result={'activeUsers':count('SELECT COUNT(*) FROM users WHERE id IN ('+marks+') AND deleted=0'),
 'activeSessions':count('SELECT COUNT(*) FROM sessions WHERE user_id IN ('+marks+') AND revoked_at IS NULL'),
 'activeMembers':count('SELECT COUNT(*) FROM room_members WHERE user_id IN ('+marks+') AND active=1'),
 'activeRooms':count("SELECT COUNT(*) FROM rooms WHERE owner_id IN ("+marks+") AND status!='closed'"),
 'pendingMedia':count('SELECT COUNT(*) FROM media_cleanup WHERE user_id IN ('+marks+')')}
for table in ('experience_wallets','experience_entries','experience_inventory','experience_equipped','experience_requests',
              'experience_gift_inventory','experience_gift_grants','experience_gift_settlements'):
 result[table]=count('SELECT COUNT(*) FROM '+table+' WHERE user_id IN ('+marks+')')
for table in ('seat_request_states','room_presence','seat_requests'):
 result[table]=count('SELECT COUNT(*) FROM '+table+' WHERE user_id IN ('+marks+')')
result['giftEvents']=db.execute('SELECT COUNT(*) FROM experience_gift_events WHERE sender_user_id IN ('+marks+') OR recipient_user_id IN ('+marks+')',ids+ids).fetchone()[0]
async def media():
 gateway=LiveKitGateway(settings)
 try:result['sfuRooms']=int(args['roomID'] in await gateway.list_rooms()) if args['roomID'] else 0
 finally:await gateway.close()
asyncio.run(media());db.close();print(json.dumps(result))
'''.replace("PAYLOAD", repr(json.dumps({"ids": identities, "roomID": room_id})))
    result = subprocess.run(SSH_VOICE+["/opt/kiki-livekit-lab/venv/bin/python -"], input=script,
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise RuntimeError("Voice fixture cleanup audit failed")
    return json.loads(result.stdout)


def validate_legal(value):
    canonical = json.dumps({key: item for key, item in value.items() if key != "documentHash"},
                           ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    if (value.get("schemaVersion") != 1 or value.get("minimumAge") != 18
            or hashlib.sha256(canonical).hexdigest() != value.get("documentHash")
            or {item["id"] for item in value.get("documents", [])} != {"terms", "privacy", "sdk", "permissions"}
            or any(not item.get("sections") for item in value["documents"])):
        raise RuntimeError("Public legal document validation failed")


async def run(output=None, api_only=False):
    import httpx
    logging.getLogger("livekit").setLevel(logging.CRITICAL)
    if not api_only:
        from livekit import rtc
    os.umask(0o077)
    run_id = secrets.token_hex(12)
    identities = [f"kiki_expsmoke_{run_id}_{index}" for index in range(2)]
    remote_file = f"/tmp/kiki-experience-smoke-{run_id}.json"
    directory = Path(tempfile.mkdtemp(prefix="kiki-experience-smoke-"))
    directory.chmod(0o700)
    sessions, rooms, room_id = [], [], None
    fixture_requested = False
    room_ended = False
    result = {"schemaVersion": 1, "startedAt": int(time.time()), "passed": False,
              "scope": "Public dynamic legal and free experience API"+("" if api_only else " with two real RTC clients; no microphone/audio acceptance"),
              "checks": {}, "cleanup": {}}

    def check(name, condition):
        if not condition:
            raise RuntimeError("Acceptance failed: "+name)
        result["checks"][name] = True
        print(json.dumps({"passed": name}), flush=True)

    async with httpx.AsyncClient(timeout=30, trust_env=False, follow_redirects=False) as http:
        async def call(method, path, actor=None, payload=None, expected=200, origin=VOICE):
            headers = {"Authorization": "Bearer "+sessions[actor]["token"]} if actor is not None else {}
            response = await http.request(method, origin+path, headers=headers, json=payload)
            if response.status_code != expected:
                raise RuntimeError(f"HTTP {response.status_code} on {method} {path.split('?')[0]}")
            return response

        async def snapshot(actor):
            return (await call("GET", "/v1/me/experience", actor)).json()

        try:
            documents = []
            for origin in (ACCOUNT, VOICE):
                response = await call("GET", "/v1/legal/documents", origin=origin)
                check("anonymousLegalNoStore"+("Account" if origin == ACCOUNT else "Voice"),
                      response.headers.get("cache-control") == "no-store" and response.headers.get("content-type", "").startswith("application/json"))
                value = response.json(); validate_legal(value); documents.append(value)
            expected = json.loads((ROOT/"experiments/livekit/shared/legal_documents.json").read_text())
            check("currentLegalMatchesBothServicesAndRelease", documents[0] == documents[1] == expected)
            for path in ("/v1/me/experience", "/v1/me/wallet", "/v1/gifts/catalog", "/v1/decorations/users?ids=test"):
                await call("GET", path, expected=401)
            check("privateExperienceRequiresAuthentication", True)

            fixture_requested = True
            remote_account("create", identities, remote_file)
            sessions = fetch_private_sessions(remote_file, directory/"sessions.json")
            remote_account("remove-file", identities, remote_file)
            check("twoShortLivedSignedBridgeSessions", len(sessions) == 2 and all(
                value["user"]["id"] == identity and value["sdk"]["provider"] == "livekit"
                and value["expiresAt"] > int(time.time())+60 for value, identity in zip(sessions, identities)))
            catalog = (await call("GET", "/v1/gifts/catalog", 0)).json()
            check("fiveGiftsAndTwelvePermanentDecorations", len(catalog["gifts"]) == 5 and len(catalog["decorations"]) == 12 and catalog["initialGrant"] == INITIAL)
            original = [await snapshot(index) for index in range(2)]
            repeated = [await snapshot(index) for index in range(2)]
            check("oneHundredMillionGrantedExactlyOnce", all(value["wallet"]["balance"] == INITIAL and len(value["entries"]) == 1 and value["entries"][0]["kind"] == "initial_grant" for value in original)
                  and repeated == original)
            expected_package = {"heart": 10, "flower_rain": 3, "aurora_car": 1}
            check("oneTimeExperiencePackageTenHeartsThreeFlowersOneCar", all(
                {item["giftID"]: item["quantity"] for item in value["giftInventory"]} == expected_package
                for value in original) and repeated == original)
            purchase_id = str(uuid.uuid4())
            purchase = {"decorationID": "frame_violet", "requestID": purchase_id}
            acquired = (await call("POST", "/v1/me/decorations/purchase", 0, purchase)).json()
            duplicate = (await call("POST", "/v1/me/decorations/purchase", 0, purchase)).json()
            another = (await call("POST", "/v1/me/decorations/purchase", 0, {**purchase, "requestID": str(uuid.uuid4())})).json()
            check("purchaseAndOwnedRepurchaseNeverDoubleDebit", acquired == duplicate == another and acquired["wallet"]["balance"] == INITIAL-1999 and acquired["inventory"]["ownedIDs"] == ["frame_violet"])
            equipped = (await call("PUT", "/v1/me/decorations/equipped", 0, {"kind": "avatarFrame", "decorationID": "frame_violet"})).json()
            public = (await call("GET", "/v1/decorations/users?ids="+identities[0], 1)).json()
            check("equippedAppearancePublicWithoutPrivateWallet", equipped["equipped"]["avatarFrame"] == "frame_violet" and public == {"users": [{"userID": identities[0], "equipped": equipped["equipped"]}]})
            unequipped = (await call("PUT", "/v1/me/decorations/equipped", 0, {"kind": "avatarFrame", "decorationID": None})).json()
            check("unequipRetainsPermanentOwnership", unequipped["equipped"]["avatarFrame"] is None and unequipped["ownedIDs"] == ["frame_violet"])

            if not api_only:
                metadata = (await call("POST", "/v1/rooms", 0, {"title": "体验系统自动验收", "category": "闲聊", "isLive": False, "theme": 0})).json()
                room_id = metadata["id"]
                for index in range(2):
                    grant = (await call("POST", f"/v1/rooms/{room_id}/token", index)).json()
                    room = rtc.Room(); rooms.append(room)
                    await asyncio.wait_for(room.connect(grant["serverURL"], grant["participantToken"],
                        rtc.RoomOptions(single_peer_connection=False)), 35)
                async with asyncio.timeout(20):
                    while not all(room.isconnected() and len(room.remote_participants) == 1 for room in rooms):
                        await asyncio.sleep(.1)
                check("twoRealLiveKitClientsConnectedWithoutMicrophones", all(not room.local_participant.track_publications for room in rooms))
                await call("POST", f"/v1/rooms/{room_id}/actions", 1, {"action": "request_seat"})
                seated = (await call("POST", f"/v1/rooms/{room_id}/actions", 0,
                    {"action": "approve_request", "targetUserID": identities[1]})).json()
                recipient = next((member for member in seated["members"] if member["userID"] == identities[1]), None)
                check("syntheticRecipientOnlineAndActuallySeatedBeforeGift", recipient is not None
                      and recipient["online"] and recipient["seatIndex"] is not None
                      and any(seat["userID"] == identities[1] for seat in seated["seats"]))
                baseline = (await call("GET", f"/v1/rooms/{room_id}/gifts", 1)).json()
                check("newRoomDoesNotReplayHistory", baseline["events"] == [] and baseline["cursor"] == 0)
                body = {"giftID": "flower_rain", "quantity": 10, "recipientIDs": [identities[1]], "requestID": str(uuid.uuid4())}
                sent = (await call("POST", f"/v1/rooms/{room_id}/gifts", 0, body)).json()
                retried = (await call("POST", f"/v1/rooms/{room_id}/gifts", 0, body)).json()
                received = (await call("GET", f"/v1/rooms/{room_id}/gifts?after=0", 1)).json()
                check("confirmedGiftRetryHasOneDebitAndOneDelivery", sent == retried and sent["totalCost"] == 693
                      and sent["wallet"]["balance"] == INITIAL-1999-693 and len(sent["events"]) == 1
                      and received["events"] == sent["events"])
                check("backpackUsedBeforeSevenDiamondPurchasedFlowers", sent["inventoryUsed"] == 3
                      and sent["diamondQuantity"] == 7 and sent["totalQuantity"] == 10
                      and sent["events"][0]["quantity"] == 10
                      and {item["giftID"]: item["quantity"] for item in sent["giftInventory"]} == {"heart": 10, "aurora_car": 1})
                recipient = await snapshot(1)
                check("recipientHasNoDiamondIncomeOrTransferableGiftStock", recipient == original[1])
                sender = await snapshot(0)
                check("walletLedgerPersistsOnlyOneGiftAndDecorationDebit", [entry["kind"] for entry in sender["entries"]] == ["gift", "decoration", "initial_grant"]
                      and sender["entries"][0]["amount"] == -693 and sender["giftInventory"] == sent["giftInventory"])
                await call("PATCH", f"/v1/rooms/{room_id}", 0, {"status": "ended"})
                room_ended = True
                async with asyncio.timeout(20):
                    while any(room.isconnected() for room in rooms):
                        await asyncio.sleep(.1)
                check("endingFixtureRoomDisconnectsBothClients", True)
            result["passed"] = True
        except BaseException as error:
            result["passed"] = False
            result["failureType"] = type(error).__name__
            # Exact status/stage only: no SDK error text, candidates or tokens.
            if isinstance(error, RuntimeError):
                result["failureStage"] = str(error)
        finally:
            if room_id and sessions and not room_ended:
                try:
                    await call("PATCH", f"/v1/rooms/{room_id}", 0, {"status": "ended"})
                except Exception:
                    pass  # Signed account deletion below is the durable fallback.
            for room in rooms:
                try:
                    await asyncio.wait_for(room.disconnect(), 10)
                except Exception:
                    pass
            failures = []
            if fixture_requested:
                try:
                    remote_account("delete", identities, remote_file)
                except Exception:
                    failures.append("signedDeletion")
                try:
                    audit = audit_voice(identities, room_id)
                    result["cleanup"].update(audit)
                    if any(audit.values()):
                        failures.append("remainingFixtureData")
                except Exception:
                    failures.append("cleanupAudit")
                try:
                    remote_account("remove-file", identities, remote_file)
                except Exception:
                    failures.append("remotePrivateFileRemoval")
            shutil.rmtree(directory)
            sessions.clear()
            result["cleanup"]["verified"] = not failures
            result["cleanup"]["errors"] = failures
            result["passed"] = result["passed"] and not failures
            result["finishedAt"] = int(time.time())
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded+"\n")
    print(encoded, flush=True)
    return result["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-public", action="store_true", help="Create and delete only two namespaced production test identities")
    parser.add_argument("--api-only", action="store_true", help="Skip room creation and real RTC clients")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.run_public:
        parser.error("Production writes require --run-public")
    raise SystemExit(0 if asyncio.run(run(args.output, args.api_only)) else 1)
