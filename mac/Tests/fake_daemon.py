#!/usr/bin/env python3
"""Fake pdrcloned for developing/testing the macOS app without the Go daemon.

Speaks docs/PROTOCOL.md: newline-delimited JSON-RPC 2.0 over a unix socket.
Stdlib only.

    python3 mac/Tests/fake_daemon.py --socket /tmp/pdr.sock            # demo data, two jobs syncing
    python3 mac/Tests/fake_daemon.py --socket /tmp/pdr.sock --idle     # nothing running (RSS measurement)
    PDRCLONE_SOCKET=/tmp/pdr.sock "mac/dist/PigmentDev rClone.app/Contents/MacOS/PigmentDevRClone"
"""
import argparse
import asyncio
import json
import os
import random
import signal
import sys
import time
import zipfile
from datetime import datetime, timedelta, timezone


def now(offset_sec=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=offset_sec)).strftime("%Y-%m-%dT%H:%M:%SZ")


def rid(prefix):
    return prefix + "_" + "".join(random.choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(6))


HOME = os.path.expanduser("~")

PROVIDERS = [
    {"id": "drive", "name": "Google Drive", "auth": "oauth", "category": "cloud", "popular": True, "fields": [
        {"name": "client_id", "label": "Client ID", "help": "Leave empty to use rclone's shared client.", "type": "string", "required": False, "default": None, "options": [], "advanced": True},
        {"name": "client_secret", "label": "Client secret", "help": "", "type": "password", "required": False, "default": None, "options": [], "advanced": True},
        {"name": "scope", "label": "Access", "help": "What PigmentDev rClone may touch.", "type": "select", "required": False, "default": "drive",
         "options": [{"value": "drive", "label": "Full access"}, {"value": "drive.file", "label": "Only files it creates"}], "advanced": False}]},
    {"id": "onedrive", "name": "OneDrive", "auth": "oauth", "category": "cloud", "popular": True, "fields": []},
    {"id": "dropbox", "name": "Dropbox", "auth": "oauth", "category": "cloud", "popular": True, "fields": []},
    {"id": "box", "name": "Box", "auth": "oauth", "category": "cloud", "popular": False, "fields": []},
    {"id": "pcloud", "name": "pCloud", "auth": "oauth", "category": "cloud", "popular": False, "fields": []},
    {"id": "s3", "name": "S3 compatible", "auth": "fields", "category": "object", "popular": True, "fields": [
        {"name": "provider", "label": "Provider", "help": "", "type": "select", "required": True, "default": "AWS",
         "options": [{"value": "AWS", "label": "Amazon S3"}, {"value": "Cloudflare", "label": "Cloudflare R2"}, {"value": "Wasabi", "label": "Wasabi"}, {"value": "Minio", "label": "MinIO"}], "advanced": False},
        {"name": "access_key_id", "label": "Access key ID", "help": "", "type": "string", "required": True, "default": None, "options": [], "advanced": False},
        {"name": "secret_access_key", "label": "Secret access key", "help": "", "type": "password", "required": True, "default": None, "options": [], "advanced": False},
        {"name": "endpoint", "label": "Endpoint", "help": "Only for non-AWS providers.", "type": "string", "required": False, "default": None, "options": [], "advanced": False},
        {"name": "region", "label": "Region", "help": "", "type": "string", "required": False, "default": "us-east-1", "options": [], "advanced": True}]},
    {"id": "b2", "name": "Backblaze B2", "auth": "fields", "category": "object", "popular": False, "fields": []},
    {"id": "azureblob", "name": "Azure Blob", "auth": "fields", "category": "object", "popular": False, "fields": []},
    {"id": "gcs", "name": "Google Cloud Storage", "auth": "oauth", "category": "object", "popular": False, "fields": []},
    {"id": "sftp", "name": "SFTP", "auth": "fields", "category": "server", "popular": True, "fields": [
        {"name": "host", "label": "Host", "help": "", "type": "string", "required": True, "default": None, "options": [], "advanced": False},
        {"name": "user", "label": "User", "help": "", "type": "string", "required": True, "default": None, "options": [], "advanced": False},
        {"name": "port", "label": "Port", "help": "", "type": "int", "required": False, "default": 22, "options": [], "advanced": False},
        {"name": "pass", "label": "Password", "help": "Leave empty to use your SSH agent or key.", "type": "password", "required": False, "default": None, "options": [], "advanced": False},
        {"name": "key_file", "label": "Private key file", "help": "", "type": "string", "required": False, "default": None, "options": [], "advanced": True}]},
    {"id": "ftp", "name": "FTP / FTPS", "auth": "fields", "category": "server", "popular": False, "fields": []},
    {"id": "webdav", "name": "WebDAV / Nextcloud", "auth": "fields", "category": "server", "popular": True, "fields": []},
    {"id": "mega", "name": "MEGA", "auth": "fields", "category": "cloud", "popular": False, "fields": []},
    {"id": "protondrive", "name": "Proton Drive", "auth": "fields", "category": "cloud", "popular": False, "fields": []},
    {"id": "local", "name": "Local disk / NAS", "auth": "fields", "category": "local", "popular": False, "fields": []},
]

GB = 1_000_000_000


def default_job(**kw):
    job = {
        "id": rid("job"), "name": "Job", "enabled": True, "localPath": HOME + "/Documents", "accountId": "", "remotePath": "",
        "direction": "upload", "deletePolicy": "archive", "archiveRetentionDays": 30, "conflictPolicy": "keepBoth",
        "filters": {"presets": ["vcs", "ide", "deps", "osjunk"], "rules": [], "maxSizeMB": None, "minAgeSec": 0,
                    "excludeIfPresent": [".nosync"], "respectGitignore": False, "skipSymlinks": False},
        "triggers": {"onChange": True, "debounceSec": 10, "intervalMin": None, "daily": None, "weekly": None, "cron": None, "onWake": True, "manual": True},
        "network": {"allowCellular": False, "allowExpensive": False, "wifiOnly": False, "ssidAllow": [], "ssidDeny": [], "pauseOnBattery": False, "minBatteryPercent": None},
        "limits": {"bwUpKBps": None, "bwDownKBps": None, "transfers": 4, "checkers": 8},
        "safety": {"maxDeletePercent": 25, "dryRunFirst": True, "checksum": False},
        "createdAt": now(-86400 * 12), "updatedAt": now(-3600),
        "status": {"state": "idle", "reason": None, "lastRun": None, "nextRun": None, "progress": None},
    }
    for k, v in kw.items():
        if isinstance(v, dict) and isinstance(job.get(k), dict):
            job[k].update(v)
        else:
            job[k] = v
    return job


def run_summary(ok=True, files=120, bytes_=3_400_000_000, ago=1800, dry=False, error=None, conflicts=0, deletes=0):
    return {"id": rid("run"), "startedAt": now(-ago - 240), "endedAt": now(-ago), "ok": ok, "error": error, "bytes": bytes_,
            "files": files, "deletes": deletes, "conflicts": conflicts, "dryRun": dry}


class State:
    def __init__(self, idle):
        self.accounts = [
            {"id": "acc_drive1", "provider": "drive", "name": "Work Drive", "remote": "pd_acc_drive1", "status": "ok", "error": None,
             "createdAt": now(-86400 * 30), "quota": {"total": 2000 * GB, "used": 1210 * GB, "free": 790 * GB, "trashed": 3 * GB}},
            {"id": "acc_s3", "provider": "s3", "name": "Wasabi Archive", "remote": "pd_acc_s3", "status": "ok", "error": None,
             "createdAt": now(-86400 * 20), "quota": None},
            {"id": "acc_dbx", "provider": "dropbox", "name": "Studio Dropbox", "remote": "pd_acc_dbx", "status": "ok", "error": None,
             "createdAt": now(-86400 * 10), "quota": {"total": 2000 * GB, "used": 420 * GB, "free": 1580 * GB, "trashed": 0}},
            {"id": "acc_od", "provider": "onedrive", "name": "Personal OneDrive", "remote": "pd_acc_od", "status": "needsAuth",
             "error": "Token expired — sign in again.", "createdAt": now(-86400 * 60), "quota": {"total": 1000 * GB, "used": 912 * GB, "free": 88 * GB, "trashed": 1 * GB}},
            {"id": "acc_sftp", "provider": "sftp", "name": "Hetzner Box", "remote": "pd_acc_sftp", "status": "ok", "error": None,
             "createdAt": now(-86400 * 5), "quota": {"total": 1000 * GB, "used": 260 * GB, "free": 740 * GB, "trashed": None}},
        ]
        self.jobs = [
            default_job(id="job_projects", name="Projects", localPath=HOME + "/Projects", accountId="acc_drive1", remotePath="Backups/Projects",
                        filters={"presets": ["vcs", "ide", "deps", "build", "osjunk"]},
                        status={"state": "idle", "lastRun": run_summary(ago=3600), "nextRun": None}),
            default_job(id="job_photos", name="Photo Library Archive", localPath=HOME + "/Pictures/Exports", accountId="acc_s3", remotePath="photos-2026",
                        deletePolicy="never", triggers={"onChange": False, "daily": "02:30"},
                        status={"state": "idle", "lastRun": run_summary(ago=7200, files=840, bytes_=12 * GB), "nextRun": now(5 * 3600)}),
            default_job(id="job_design", name="Design Docs", localPath=HOME + "/Design", accountId="acc_dbx", remotePath="Studio/Design",
                        direction="twoWay", conflictPolicy="ask",
                        status={"state": "idle", "lastRun": run_summary(ago=600, files=14, bytes_=88_000_000, conflicts=1), "nextRun": None}),
            default_job(id="job_server", name="Server Backups", localPath=HOME + "/Backups/server", accountId="acc_sftp", remotePath="backups/daily",
                        direction="download", network={"wifiOnly": True}, triggers={"onChange": False, "intervalMin": 60},
                        status={"state": "waiting", "reason": "Waiting for Wi-Fi — you're on a phone hotspot", "lastRun": run_summary(ago=86400), "nextRun": now(1800)}),
            default_job(id="job_notes", name="Notes", localPath=HOME + "/Notes", accountId="acc_od", remotePath="Notes",
                        direction="twoWay", status={"state": "paused", "reason": "Paused until you resume", "lastRun": run_summary(ago=3 * 86400)}),
        ]
        self.actions = [
            {"id": "act_conf1", "jobId": "job_design", "kind": "conflict", "severity": "warning", "title": "Both copies of a file changed",
             "message": "“Brand Guidelines.fig” was edited on this Mac and in Dropbox since the last sync.", "path": "Brand/Brand Guidelines.fig",
             "createdAt": now(-540), "resolved": False,
             "choices": [{"id": "keepLocal", "label": "Keep this Mac's"}, {"id": "keepRemote", "label": "Keep Dropbox's"}, {"id": "keepBoth", "label": "Keep both"}]},
            {"id": "act_auth1", "jobId": "job_notes", "kind": "authExpired", "severity": "error", "title": "OneDrive sign-in expired",
             "message": "Personal OneDrive needs you to sign in again before Notes can sync.", "path": None, "createdAt": now(-7200),
             "resolved": False, "choices": [{"id": "reconnect", "label": "Reconnect"}, {"id": "dismiss", "label": "Later"}]},
            {"id": "act_del1", "jobId": "job_projects", "kind": "maxDeleteAbort", "severity": "warning", "title": "Run stopped: too many deletions",
             "message": "This run would delete 31% of files in Backups/Projects (limit 25%).", "path": None, "createdAt": now(-86400),
             "resolved": True, "choices": [{"id": "runAnyway", "label": "Run anyway"}, {"id": "dismiss", "label": "Dismiss"}]},
            {"id": "act_info1", "jobId": "job_photos", "kind": "info", "severity": "info", "title": "Photo Library Archive finished",
             "message": "840 files · 12 GB uploaded.", "path": None, "createdAt": now(-7200), "resolved": True, "choices": []},
        ]
        self.settings = {
            "defaults": {"direction": "upload", "conflictPolicy": "keepBoth", "deletePolicy": "archive", "debounceSec": 10, "minAgeSec": 0,
                         "maxDeletePercent": 25, "dryRunFirst": True, "presets": ["vcs", "ide", "deps", "osjunk"]},
            "network": {"allowCellular": False, "allowExpensive": False,
                        "bwSchedule": [{"days": [1, 2, 3, 4, 5], "from": "09:00", "to": "18:00", "upKBps": 2048, "downKBps": None}], "proxy": None},
            "logs": {"level": "info", "retentionDays": 30}, "engine": {"transfers": 4, "checkers": 8, "tpsLimit": 0}}
        self.runs = {}  # jobId -> run progress dict
        self.logs = []
        self.started = time.time()
        self.oauth_sessions = {}
        for i in range(60):
            self.log("info", random.choice(["job_projects", "job_photos", "job_design"]), f"Copied (new)", f"src/module_{i}/index.ts", ago=i * 50)
        self.log("warn", "job_server", "Skipped run: network rule (hotspot)", None, ago=40)
        self.log("error", "job_notes", "OneDrive: token expired (401)", None, ago=7200)
        if not idle:
            self.start_run("job_projects", total_files=1840, total_bytes=int(6.4 * GB), done=0.42)
            self.start_run("job_photos", total_files=320, total_bytes=int(9.1 * GB), done=0.18)

    def log(self, level, job, msg, path=None, ago=0):
        line = {"ts": now(-ago), "level": level, "jobId": job, "runId": None, "msg": msg, "path": path}
        self.logs.insert(0, line)
        return line

    def job(self, jid):
        for j in self.jobs:
            if j["id"] == jid:
                return j
        return None

    def start_run(self, jid, total_files=400, total_bytes=2 * GB, done=0.0, dry=False):
        j = self.job(jid)
        if not j:
            return None
        run_id = rid("run")
        self.runs[jid] = {"runId": run_id, "files": int(total_files * done), "totalFiles": total_files, "bytes": int(total_bytes * done),
                          "totalBytes": total_bytes, "started": now(), "dry": dry,
                          "names": [f"{'raw' if 'photo' in jid else 'src'}/{random.choice(['assets', 'lib', 'docs', 'media'])}/file_{k:04d}.{random.choice(['ts', 'png', 'mov', 'md', 'psd'])}" for k in range(total_files)]}
        j["status"]["state"] = "running"
        j["status"]["reason"] = None
        return run_id

    def progress(self, jid):
        r = self.runs[jid]
        speed = random.uniform(8, 26) * 1_000_000
        cur = r["files"]
        transferring = []
        for k in range(min(3, r["totalFiles"] - cur)):
            size = random.randint(2_000_000, 400_000_000)
            got = int(size * random.random())
            transferring.append({"name": r["names"][min(cur + k, len(r["names"]) - 1)], "size": size, "bytes": got,
                                 "percent": round(got / size * 100, 1), "speed": speed / 3})
        pct = r["bytes"] / r["totalBytes"] * 100 if r["totalBytes"] else 0
        eta = (r["totalBytes"] - r["bytes"]) / speed if speed else None
        return {"bytes": r["bytes"], "totalBytes": r["totalBytes"], "files": r["files"], "totalFiles": r["totalFiles"], "speed": speed,
                "eta": eta, "percent": round(pct, 2), "checks": r["files"] + 40, "totalChecks": r["totalFiles"] + 40, "errors": 0,
                "transferring": transferring}


class Server:
    def __init__(self, path, idle, loop_runs):
        self.path = path
        self.state = State(idle)
        self.clients = set()
        self.loop_runs = loop_runs

    async def broadcast(self, method, params, topic=None):
        topic = topic or method
        msg = (json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n").encode()
        for c in list(self.clients):
            if c["hello"] and (topic in c["topics"] or method == "overall.progress"):
                try:
                    c["writer"].write(msg)
                    await c["writer"].drain()
                except Exception:
                    self.clients.discard(c)

    async def ticker(self):
        while True:
            await asyncio.sleep(0.25)
            st = self.state
            if not st.runs:
                continue
            total_b = total_t = 0
            speed_sum = 0.0
            for jid in list(st.runs):
                r = st.runs[jid]
                inc = int(random.uniform(2, 6) * 1_000_000)
                r["bytes"] = min(r["totalBytes"], r["bytes"] + inc)
                r["files"] = min(r["totalFiles"], int(r["totalFiles"] * r["bytes"] / r["totalBytes"]))
                p = st.progress(jid)
                speed_sum += p["speed"]
                total_b += r["bytes"]
                total_t += r["totalBytes"]
                await self.broadcast("job.progress", {"jobId": jid, "runId": r["runId"], "progress": p})
                if random.random() < 0.15:
                    line = st.log("info", jid, "Copied (new)", p["transferring"][0]["name"] if p["transferring"] else None)
                    await self.broadcast("log.line", {"line": line})
                if r["bytes"] >= r["totalBytes"]:
                    j = st.job(jid)
                    j["status"] = {"state": "idle", "reason": None, "progress": None, "nextRun": j["status"].get("nextRun"),
                                   "lastRun": {"id": r["runId"], "startedAt": r["started"], "endedAt": now(), "ok": True, "error": None,
                                               "bytes": r["totalBytes"], "files": r["totalFiles"], "deletes": 0, "conflicts": 0, "dryRun": r["dry"]}}
                    del st.runs[jid]
                    await self.broadcast("job.state", {"jobId": jid, "status": j["status"]})
                    if self.loop_runs:
                        asyncio.get_running_loop().call_later(4, lambda jid=jid: asyncio.ensure_future(self.restart(jid)))
            await self.broadcast("overall.progress", {"running": len(st.runs), "bytes": total_b, "totalBytes": total_t,
                                                      "percent": round(total_b / total_t * 100, 2) if total_t else 0, "speed": speed_sum,
                                                      "eta": (total_t - total_b) / speed_sum if speed_sum else None})
            if not st.runs:
                await self.broadcast("overall.progress", {"running": 0, "bytes": 0, "totalBytes": 0, "percent": 0, "speed": 0, "eta": None})

    async def restart(self, jid):
        if jid in self.state.runs:
            return
        self.state.start_run(jid, total_files=random.randint(200, 2000), total_bytes=random.randint(1, 8) * GB)
        await self.broadcast("job.state", {"jobId": jid, "status": self.state.job(jid)["status"]})

    # ---- methods -------------------------------------------------------------

    async def dispatch(self, client, method, params):
        st = self.state
        p = params or {}
        if method == "hello":
            client["hello"] = True
            return {"daemonVersion": "0.1.0-fake", "rcloneVersion": "v1.75.0", "protocol": 1, "os": "darwin", "arch": "arm64",
                    "dataDir": os.path.dirname(self.path), "pid": os.getpid(), "startedAt": now(-int(time.time() - st.started))}
        if not client["hello"]:
            raise RPCError(-32001, "hello required")
        if method == "subscribe":
            client["topics"] = set(p.get("topics", []))
            return {"ok": True}
        if method == "daemon.info":
            return {"daemonVersion": "0.1.0-fake", "rcloneVersion": "v1.75.0", "protocol": 1, "os": "darwin", "arch": "arm64",
                    "dataDir": os.path.dirname(self.path), "pid": os.getpid(), "startedAt": now(-int(time.time() - st.started)),
                    "jobsRunning": len(st.runs), "uptimeSec": int(time.time() - st.started), "rssBytes": 31_000_000, "goroutines": 42}
        if method == "daemon.shutdown":
            asyncio.get_running_loop().call_later(0.2, lambda: os.kill(os.getpid(), signal.SIGTERM))
            return {"ok": True}
        if method == "system.state":
            client["system"] = p
            print("system.state", json.dumps(p), file=sys.stderr, flush=True)
            return {"ok": True}
        # accounts
        if method == "accounts.providers":
            return {"providers": PROVIDERS}
        if method == "accounts.list":
            return {"accounts": st.accounts}
        if method == "accounts.add.start":
            prov = next((x for x in PROVIDERS if x["id"] == p.get("provider")), None)
            if not prov:
                raise RPCError(-32602, "unknown provider")
            if prov["auth"] == "oauth":
                sid = rid("sess")
                st.oauth_sessions[sid] = {"polls": 0, "provider": prov["id"], "name": p.get("name") or prov["name"]}
                return {"state": "needsOAuth", "sessionId": sid, "authUrl": "https://example.com/fake-oauth?session=" + sid}
            return {"state": "done", "account": self.add_account(prov["id"], p.get("name") or prov["name"])}
        if method == "accounts.add.continue":
            s = st.oauth_sessions.get(p.get("sessionId"))
            if not s:
                raise RPCError(-32010, "no such session")
            s["polls"] += 1
            if s["polls"] < 3:
                return {"state": "needsOAuth", "sessionId": p["sessionId"], "authUrl": "https://example.com/fake-oauth"}
            del st.oauth_sessions[p["sessionId"]]
            return {"state": "done", "account": self.add_account(s["provider"], s["name"])}
        if method == "accounts.add.cancel":
            st.oauth_sessions.pop(p.get("sessionId"), None)
            return {"ok": True}
        if method == "accounts.test":
            acc = next((a for a in st.accounts if a["id"] == p.get("id")), None)
            if not acc:
                raise RPCError(-32010, "not found")
            await asyncio.sleep(0.4)
            if acc["status"] == "needsAuth":
                return {"ok": False, "error": "Token expired", "latencyMs": 210}
            return {"ok": True, "latencyMs": random.randint(40, 180)}
        if method == "accounts.quota":
            acc = next((a for a in st.accounts if a["id"] == p.get("id")), None)
            return {"quota": acc and acc["quota"]}
        if method == "accounts.rename":
            for a in st.accounts:
                if a["id"] == p.get("id"):
                    a["name"] = p.get("name", a["name"])
            return {"ok": True}
        if method == "accounts.remove":
            used = [j for j in st.jobs if j["accountId"] == p.get("id")]
            if used and not p.get("force"):
                raise RPCError(-32011, f"{len(used)} jobs use this account")
            st.jobs = [j for j in st.jobs if j["accountId"] != p.get("id")]
            st.accounts = [a for a in st.accounts if a["id"] != p.get("id")]
            return {"ok": True}
        # remote
        if method == "remote.list":
            path = p.get("path", "").strip("/")
            if p.get("accountId") is None:
                base = os.path.join("/", path) if path else HOME
                try:
                    names = sorted(os.listdir(base))[:300]
                except OSError as e:
                    raise RPCError(-32010, str(e))
                ents = []
                for n in names:
                    full = os.path.join(base, n)
                    if n.startswith("."):
                        continue
                    isdir = os.path.isdir(full)
                    if p.get("dirsOnly", True) and not isdir:
                        continue
                    ents.append({"name": n, "path": full.lstrip("/"), "isDir": isdir, "size": 0, "modTime": now()})
                return {"path": path, "entries": ents}
            depth = len([x for x in path.split("/") if x])
            names = ["Backups", "Projects", "Shared", "Photos", "Clients", "Archive"] if depth == 0 else [f"Folder {i}" for i in range(1, 6 - min(depth, 4))]
            return {"path": path, "entries": [{"name": n, "path": (path + "/" + n).strip("/"), "isDir": True, "size": 0, "modTime": now(-3600)} for n in names]}
        if method == "remote.mkdir":
            return {"ok": True}
        # jobs
        if method == "jobs.list":
            return {"jobs": [self.with_progress(j) for j in st.jobs]}
        if method == "jobs.get":
            j = st.job(p.get("id"))
            if not j:
                raise RPCError(-32010, "not found")
            return {"job": self.with_progress(j)}
        if method == "jobs.create":
            spec = p.get("job") or {}
            if not spec.get("localPath") or not spec.get("accountId"):
                raise RPCError(-32602, "localPath and accountId are required")
            j = default_job()
            j.update(spec)
            j["id"] = rid("job")
            j["createdAt"] = j["updatedAt"] = now()
            j["status"] = {"state": "needsBaseline" if spec.get("direction") == "twoWay" else "idle", "reason": None, "lastRun": None, "nextRun": None, "progress": None}
            st.jobs.append(j)
            await self.broadcast("job.state", {"jobId": j["id"], "status": j["status"]})
            return {"job": j}
        if method == "jobs.update":
            j = st.job(p.get("id"))
            if not j:
                raise RPCError(-32010, "not found")
            for k, v in (p.get("patch") or {}).items():
                if k not in ("id", "status", "createdAt"):
                    j[k] = v
            j["updatedAt"] = now()
            return {"job": self.with_progress(j)}
        if method == "jobs.delete":
            st.jobs = [j for j in st.jobs if j["id"] != p.get("id")]
            st.runs.pop(p.get("id"), None)
            return {"ok": True}
        if method == "jobs.run":
            j = st.job(p.get("id"))
            if not j:
                raise RPCError(-32010, "not found")
            if p.get("id") in st.runs:
                raise RPCError(-32011, "job already running")
            run_id = st.start_run(p["id"], total_files=random.randint(50, 900), total_bytes=random.randint(1, 5) * GB, dry=bool(p.get("dryRun")))
            await self.broadcast("job.state", {"jobId": p["id"], "status": j["status"]})
            return {"runId": run_id}
        if method in ("jobs.pause", "jobs.cancel"):
            j = st.job(p.get("id"))
            if not j:
                raise RPCError(-32010, "not found")
            st.runs.pop(p["id"], None)
            j["status"]["state"] = "paused" if method == "jobs.pause" else "idle"
            j["status"]["reason"] = "Paused until you resume" if method == "jobs.pause" else None
            j["status"]["progress"] = None
            await self.broadcast("job.state", {"jobId": p["id"], "status": j["status"]})
            return {"ok": True}
        if method == "jobs.resume":
            j = st.job(p.get("id"))
            j["status"]["state"] = "idle"
            j["status"]["reason"] = None
            await self.broadcast("job.state", {"jobId": p["id"], "status": j["status"]})
            return {"ok": True}
        if method == "jobs.pauseAll":
            for j in st.jobs:
                st.runs.pop(j["id"], None)
                j["status"].update({"state": "paused", "reason": "Paused for a while" if p.get("untilSec") else "Paused until you resume", "progress": None})
                await self.broadcast("job.state", {"jobId": j["id"], "status": j["status"]})
            return {"ok": True}
        if method == "jobs.resumeAll":
            for j in st.jobs:
                if j["status"]["state"] == "paused":
                    j["status"].update({"state": "idle", "reason": None})
                    await self.broadcast("job.state", {"jobId": j["id"], "status": j["status"]})
            return {"ok": True}
        if method == "jobs.explain":
            path = p.get("path", "")
            for pat, rule in ((".git/", "- .git/** (vcs)"), ("node_modules/", "- node_modules/** (deps)"), (".DS_Store", "- .DS_Store (osjunk)"), (".claude/", "- .claude/** (ide)")):
                if pat in path:
                    return {"included": False, "rule": rule}
            return {"included": True, "rule": None}
        if method == "jobs.history":
            return {"runs": [run_summary(ago=3600 * (i + 1) * 6, files=random.randint(3, 900), bytes_=random.randint(1, 900) * 10_000_000,
                                         ok=i != 2, error="Dropbox: too_many_requests" if i == 2 else None, dry=i == 4) for i in range(int(p.get("limit", 20)) // 2)]}
        if method == "jobs.preview":
            await asyncio.sleep(0.8)
            return {"adds": 1243, "updates": 37, "deletes": 0, "excluded": 18420, "bytes": int(4.2 * GB),
                    "sample": {"adds": ["README.md", "src/app/main.swift", "src/app/views/Dashboard.swift", "assets/logo.svg", "docs/index.html"],
                               "updates": ["package.json", "notes/todo.md"], "deletes": [],
                               "excluded": [{"path": ".git/objects/pack/pack-1a2b.pack", "rule": "- .git/** (vcs)"},
                                            {"path": "node_modules/react/index.js", "rule": "- node_modules/** (deps)"},
                                            {"path": ".claude/settings.json", "rule": "- .claude/** (ide)"},
                                            {"path": ".DS_Store", "rule": "- .DS_Store (osjunk)"}]}}
        # actions
        if method == "actions.list":
            acts = st.actions if p.get("includeResolved") else [a for a in st.actions if not a["resolved"]]
            return {"actions": acts}
        if method == "actions.resolve":
            for a in st.actions:
                if a["id"] == p.get("id"):
                    a["resolved"] = True
                    await self.broadcast("action.updated", {"action": a})
                    return {"action": a}
            raise RPCError(-32010, "not found")
        if method == "actions.dismissAll":
            for a in st.actions:
                if not a["resolved"]:
                    a["resolved"] = True
                    await self.broadcast("action.updated", {"action": a})
            return {"ok": True}
        # logs
        if method == "log.query":
            lines = st.logs
            levels = ["debug", "info", "notice", "warn", "error"]
            if p.get("level") in levels:
                lines = [l for l in lines if levels.index(l["level"]) >= levels.index(p["level"])]
            if p.get("jobId"):
                lines = [l for l in lines if l["jobId"] == p["jobId"]]
            if p.get("search"):
                s = p["search"].lower()
                lines = [l for l in lines if s in l["msg"].lower() or s in (l["path"] or "").lower()]
            if p.get("since"):
                lines = [l for l in lines if l["ts"] >= p["since"]]
            return {"lines": lines[: int(p.get("limit", 500))]}
        if method == "log.export":
            with open(p["dest"], "w") as f:
                for l in st.logs:
                    f.write(json.dumps(l) + "\n" if p.get("format") == "json" else f"{l['ts']} [{l['level']}] {l['msg']} {l['path'] or ''}\n")
            return {"path": p["dest"]}
        if method == "diag.bundle":
            with zipfile.ZipFile(p["dest"], "w") as z:
                z.writestr("logs.txt", "\n".join(json.dumps(l) for l in st.logs))
                z.writestr("versions.txt", "pdrcloned 0.1.0-fake\nrclone v1.75.0\n")
            return {"path": p["dest"]}
        # settings
        if method == "settings.get":
            return {"settings": st.settings}
        if method == "settings.set":
            for k, v in (p.get("patch") or {}).items():
                st.settings[k] = v
            return {"settings": st.settings}
        raise RPCError(-32601, "method not found: " + method)

    def add_account(self, provider, name):
        acc = {"id": rid("acc"), "provider": provider, "name": name, "remote": "pd_" + rid("acc"), "status": "ok", "error": None,
               "createdAt": now(), "quota": {"total": 15 * GB, "used": 2 * GB, "free": 13 * GB, "trashed": 0}}
        self.state.accounts.append(acc)
        return acc

    def with_progress(self, j):
        if j["id"] in self.state.runs:
            j = dict(j)
            j["status"] = dict(j["status"], state="running", progress=self.state.progress(j["id"]))
        return j

    async def handle(self, reader, writer):
        client = Client(writer=writer, hello=False, topics={"job.state", "job.progress", "action.new", "action.updated", "daemon.health"})
        self.clients.add(client)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                except json.JSONDecodeError:
                    writer.write((json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}) + "\n").encode())
                    continue
                rid_ = req.get("id")
                try:
                    result = await self.dispatch(client, req.get("method"), req.get("params"))
                    resp = {"jsonrpc": "2.0", "id": rid_, "result": result}
                except RPCError as e:
                    resp = {"jsonrpc": "2.0", "id": rid_, "error": {"code": e.code, "message": e.message}}
                if rid_ is not None:
                    writer.write((json.dumps(resp) + "\n").encode())
                    await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            self.clients.discard(client)
            writer.close()

    async def main(self):
        if os.path.exists(self.path):
            os.unlink(self.path)
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        server = await asyncio.start_unix_server(self.handle, path=self.path)
        os.chmod(self.path, 0o600)
        print(f"fake pdrcloned listening on {self.path}", file=sys.stderr, flush=True)
        asyncio.ensure_future(self.ticker())
        async with server:
            await server.serve_forever()


class Client(dict):
    """Per-connection state; hashable by identity so it can live in a set."""
    __hash__ = object.__hash__
    __eq__ = object.__eq__


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default=os.environ.get("PDRCLONE_SOCKET", "/tmp/pdrclone-fake.sock"))
    ap.add_argument("--idle", action="store_true", help="start with no running jobs")
    ap.add_argument("--no-loop", action="store_true", help="don't restart demo runs after they finish")
    ap.add_argument("--demo", action="store_true", help="accepted for pdrcloned compatibility")
    a = ap.parse_args()
    srv = Server(a.socket, a.idle, not a.no_loop)
    try:
        asyncio.run(srv.main())
    except KeyboardInterrupt:
        pass
    finally:
        if os.path.exists(a.socket):
            os.unlink(a.socket)
