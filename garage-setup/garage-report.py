#!/usr/bin/env python3
"""Report on a Garage S3 store: buckets, sizes, keys, and pgBackRest backups.

    ./garage-setup/garage-report.py                     full report, all buckets
    ./garage-setup/garage-report.py --bucket my-bucket  one bucket
    ./garage-setup/garage-report.py --no-scan           admin stats only (fast, no S3 listing)
    ./garage-setup/garage-report.py --json              machine-readable output
    ./garage-setup/garage-report.py --fail-on-warn      exit 1 if any warning (for cron/CI)

Two sources:
  * Garage's admin API (`garage json-api` via kubectl exec): every bucket's
    object count, size, keys, quotas and unfinished uploads, plus cluster
    health and layout capacity. Needs no S3 credentials.
  * An S3 listing (boto3) of each bucket the key in Secret <release>-garage can
    read: object ages, the largest prefixes, and any pgBackRest repos found
    (backup.info is parsed for backup counts, types, sizes and errors; WAL
    archive freshness is checked).

The S3 connection opens its own `kubectl port-forward` on a random local port,
so it cannot hit a different Garage that happens to be forwarded on :3900.
Pass --endpoint to use an existing one instead.

Requires kubectl and boto3 (pip install boto3). Settings default to the same
environment variables as setup-garage-s3.sh (NS, GARAGE_RELEASE).
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
except ImportError:
    boto3 = None

# pgBackRest layout: <repo-path>/backup/<stanza>/backup.info and
# <repo-path>/archive/<stanza>/<pg-version>-<db-id>/<timeline+log>/<segment>-<sha1>.gz
BACKUP_INFO_RE = re.compile(r"^(?P<root>.*?)/?backup/(?P<stanza>[^/]+)/backup\.info$")
BACKUP_LABEL_RE = re.compile(r"^\d{8}-\d{6}F(_\d{8}-\d{6}[DI])?$")
WAL_RE = re.compile(r"/(?P<seg>[0-9A-F]{24})(-[0-9a-f]{40})?(\.\w+)?$")
TYPE_NAMES = {"full": "full", "diff": "differential", "incr": "incremental"}


# ------------------------------------------------------------------ helpers ---
def human_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def human_age(dt, now):
    if dt is None:
        return "never"
    secs = int((now - dt).total_seconds())
    if secs < 0:
        return "in the future"
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d {h}h ago"
    if h:
        return f"{h}h {m}m ago"
    return f"{m}m ago"


def fmt_time(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC") if dt else "-"


def kubectl(args, ns):
    return subprocess.run(["kubectl", "-n", ns, *args], check=True,
                          capture_output=True, text=True).stdout


# ---------------------------------------------------------------- admin API ---
class Garage:
    """Runs `garage json-api` in the Garage pod."""

    def __init__(self, ns, pod):
        self.ns, self.pod = ns, pod

    def api(self, endpoint, body=None):
        cmd = ["exec", self.pod, "--", "garage", "json-api", endpoint]
        if body is not None:
            cmd.append(json.dumps(body))
        return json.loads(kubectl(cmd, self.ns))


def admin_stats(garage, only_buckets):
    health = garage.api("GetClusterHealth")
    status = garage.api("GetClusterStatus")
    keys = {k["id"]: k["name"] for k in garage.api("ListKeys")}
    buckets = []
    for b in garage.api("ListBuckets"):
        info = garage.api("GetBucketInfo", {"id": b["id"]})
        name = (info["globalAliases"] or [b["id"][:16]])[0]
        if only_buckets and name not in only_buckets:
            continue
        buckets.append({
            "name": name,
            "id": info["id"],
            "created": info["created"],
            "objects": info["objects"],
            "bytes": info["bytes"],
            "quotas": info["quotas"],
            "website": info["websiteAccess"],
            "unfinished_uploads": info["unfinishedUploads"],
            "unfinished_multipart_bytes": info["unfinishedMultipartUploadBytes"],
            "keys": [{"id": k["accessKeyId"], "name": k["name"],
                      "perms": "".join(c for c, p in (("R", "read"), ("W", "write"), ("O", "owner"))
                                       if k["permissions"][p])}
                     for k in info["keys"]],
        })
    capacity = sum((n.get("role") or {}).get("capacity") or 0 for n in status["nodes"])
    return {
        "health": health,
        "layout_version": status["layoutVersion"],
        "nodes": [{"hostname": n["hostname"], "up": n["isUp"], "version": n["garageVersion"],
                   "zone": (n.get("role") or {}).get("zone"),
                   "capacity": (n.get("role") or {}).get("capacity")} for n in status["nodes"]],
        "capacity": capacity,
        "keys": keys,
        "buckets": sorted(buckets, key=lambda b: b["name"]),
    }


# --------------------------------------------------------------- S3 access ---
class PortForward:
    """`kubectl port-forward svc/<svc> :3900` on a random free local port."""

    def __init__(self, ns, svc):
        self.proc = subprocess.Popen(
            ["kubectl", "-n", ns, "port-forward", f"svc/{svc}", ":3900"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline()  # "Forwarding from 127.0.0.1:54321 -> 3900"
        m = re.search(r"127\.0\.0\.1:(\d+)", line)
        if not m:
            self.close()
            raise RuntimeError(f"port-forward failed: {line or self.proc.stderr.read()}".strip())
        self.endpoint = f"http://127.0.0.1:{m.group(1)}"

    def close(self):
        self.proc.terminate()
        self.proc.wait()


def s3_client(endpoint, ns, secret):
    def val(key):
        out = kubectl(["get", "secret", secret, "-o", f"jsonpath={{.data.{key}}}"], ns)
        return base64.b64decode(out).decode()

    # Credentials are passed explicitly, so an AWS_PROFILE pointing at a profile
    # this machine doesn't have must not stop boto3 from starting.
    for var in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE"):
        os.environ.pop(var, None)
    return boto3.client(
        "s3", endpoint_url=endpoint, region_name="garage",
        aws_access_key_id=val("access-key"), aws_secret_access_key=val("secret-key"),
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}))


def list_objects(s3, bucket):
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        yield from page.get("Contents", [])


def parse_backup_info(text):
    """backup.info is INI-like with JSON values; [backrest] appears twice, so
    configparser can't read it."""
    sections, cur = defaultdict(dict), None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1]
        elif "=" in line and cur:
            k, v = line.split("=", 1)
            try:
                sections[cur][k] = json.loads(v)
            except json.JSONDecodeError:
                sections[cur][k] = v
    return sections


def scan_bucket(s3, bucket, depth):
    objs = list(list_objects(s3, bucket))
    stats = {
        "objects": len(objs),
        "bytes": sum(o["Size"] for o in objs),
        "oldest": min((o["LastModified"] for o in objs), default=None),
        "newest": max((o["LastModified"] for o in objs), default=None),
        "prefixes": [],
        "pgbackrest": [],
    }

    by_prefix = defaultdict(lambda: [0, 0])
    for o in objs:
        parts = o["Key"].split("/")
        p = "/".join(parts[:depth]) + ("/" if len(parts) > depth else "")
        by_prefix[p][0] += 1
        by_prefix[p][1] += o["Size"]
    stats["prefixes"] = [{"prefix": p, "objects": c, "bytes": s}
                         for p, (c, s) in sorted(by_prefix.items(), key=lambda kv: -kv[1][1])]

    for o in objs:
        m = BACKUP_INFO_RE.match(o["Key"])
        if m:
            stats["pgbackrest"].append(
                scan_pgbackrest(s3, bucket, objs, m.group("root"), m.group("stanza")))
    return stats


def scan_pgbackrest(s3, bucket, objs, root, stanza):
    base = f"{root}/" if root else ""
    backup_dir, archive_dir = f"{base}backup/{stanza}/", f"{base}archive/{stanza}/"
    body = s3.get_object(Bucket=bucket, Key=f"{backup_dir}backup.info")["Body"].read()
    info = parse_backup_info(body.decode())

    backups = []
    for label, b in info.get("backup:current", {}).items():
        backups.append({
            "label": label,
            "type": b.get("backup-type"),
            "start": datetime.fromtimestamp(b["backup-timestamp-start"], timezone.utc),
            "stop": datetime.fromtimestamp(b["backup-timestamp-stop"], timezone.utc),
            "db_size": b.get("backup-info-size"),
            "repo_size": b.get("backup-info-repo-size"),
            "repo_delta": b.get("backup-info-repo-size-delta"),
            "error": bool(b.get("backup-error")),
            "prior": b.get("backup-prior"),
        })
    backups.sort(key=lambda b: b["start"])
    known = {b["label"] for b in backups}

    # Backup folders in the bucket that backup.info doesn't list: in progress,
    # or left behind by an interrupted backup.
    orphans = defaultdict(lambda: [0, 0])
    wal = {"segments": 0, "bytes": 0, "first": None, "last": None, "newest": None}
    for o in objs:
        k = o["Key"]
        if k.startswith(backup_dir):
            label = k[len(backup_dir):].split("/", 1)[0]
            if BACKUP_LABEL_RE.match(label) and label not in known:
                orphans[label][0] += 1
                orphans[label][1] += o["Size"]
        elif k.startswith(archive_dir):
            wal["bytes"] += o["Size"]
            m = WAL_RE.search(k)
            if m:
                seg = m.group("seg")
                wal["segments"] += 1
                wal["first"] = min(wal["first"] or seg, seg)
                wal["last"] = max(wal["last"] or seg, seg)
                if wal["newest"] is None or o["LastModified"] > wal["newest"]:
                    wal["newest"] = o["LastModified"]

    db = info.get("db", {})
    return {
        "path": f"/{base}".rstrip("/") or "/",
        "stanza": stanza,
        "pg_version": db.get("db-version"),
        "system_id": db.get("db-system-id"),
        "pgbackrest_version": info.get("backrest", {}).get("backrest-version"),
        "backups": backups,
        "orphans": [{"label": l, "objects": c, "bytes": s} for l, (c, s) in sorted(orphans.items())],
        "wal": wal,
    }


# ----------------------------------------------------------------- warnings ---
def find_warnings(report, args, now):
    w = []
    h = report["admin"]["health"]
    if h["status"] != "healthy":
        w.append(f"cluster status is {h['status']} ({h['storageNodesUp']}/{h['storageNodes']} storage nodes up)")
    cap = report["admin"]["capacity"]
    used = sum(b["bytes"] for b in report["admin"]["buckets"])
    if cap and used / cap > args.usage_warn / 100:
        w.append(f"buckets use {used / cap:.0%} of the {human_bytes(cap)} layout capacity")
    for b in report["admin"]["buckets"]:
        if b["unfinished_uploads"]:
            w.append(f"{b['name']}: {b['unfinished_uploads']} unfinished uploads "
                     f"({human_bytes(b['unfinished_multipart_bytes'])}); "
                     f"'garage bucket cleanup-incomplete-uploads' removes old ones")
        scan = report["scan"].get(b["name"])
        if not scan or "error" in scan:
            continue
        for r in scan["pgbackrest"]:
            where = f"{b['name']}{r['path']} [{r['stanza']}]"
            bks = r["backups"]
            if not bks:
                w.append(f"{where}: no backups in backup.info")
                continue
            for x in bks:
                if x["error"]:
                    w.append(f"{where}: backup {x['label']} has backup-error set (page checksum errors)")
            last = bks[-1]["stop"]
            if (now - last).total_seconds() > args.max_backup_age * 3600:
                w.append(f"{where}: newest backup finished {human_age(last, now)}")
            fulls = [x for x in bks if x["type"] == "full"]
            if fulls and (now - fulls[-1]["stop"]).days >= args.max_full_age:
                w.append(f"{where}: newest full backup finished {human_age(fulls[-1]['stop'], now)}")
            if r["wal"]["newest"] and (now - r["wal"]["newest"]).total_seconds() > args.max_wal_age * 3600:
                w.append(f"{where}: newest WAL archived {human_age(r['wal']['newest'], now)}")
            for o in r["orphans"]:
                w.append(f"{where}: folder {o['label']} is not in backup.info "
                         f"({o['objects']} objects, {human_bytes(o['bytes'])}); in progress or interrupted")
    return w


# ------------------------------------------------------------------- output ---
def print_text(report, args, now):
    a = report["admin"]
    h = a["health"]
    used = sum(b["bytes"] for b in a["buckets"])
    out = print
    out(f"Garage report  ·  namespace {args.namespace}  ·  {fmt_time(now)}")
    out("=" * 72)
    out(f"Cluster   {h['status']}, {h['storageNodesUp']}/{h['storageNodes']} storage nodes up, "
        f"layout v{a['layout_version']}")
    for n in a["nodes"]:
        out(f"  node    {n['hostname']}  zone {n['zone']}  {n['version']}  "
            f"capacity {human_bytes(n['capacity'])}  {'up' if n['up'] else 'DOWN'}")
    if a["capacity"]:
        out(f"Usage     {human_bytes(used)} of {human_bytes(a['capacity'])} ({used / a['capacity']:.1%})")
    out(f"Buckets   {len(a['buckets'])}    Keys {len(a['keys'])}")

    for b in a["buckets"]:
        out("")
        out(f"Bucket {b['name']}")
        out("-" * 72)
        out(f"  objects    {b['objects']:,}   size {human_bytes(b['bytes'])}   created {b['created'][:10]}")
        q = b["quotas"]
        if q["maxSize"] or q["maxObjects"]:
            out(f"  quotas     size {human_bytes(q['maxSize']) if q['maxSize'] else '-'}, "
                f"objects {q['maxObjects'] or '-'}")
        out(f"  keys       " + (", ".join(f"{k['name'] or k['id']} ({k['perms']})" for k in b["keys"]) or "none"))
        if b["unfinished_uploads"]:
            out(f"  unfinished {b['unfinished_uploads']} uploads, {human_bytes(b['unfinished_multipart_bytes'])}")

        scan = report["scan"].get(b["name"])
        if scan is None:
            continue
        if "error" in scan:
            out(f"  scan       skipped: {scan['error']}")
            continue
        out(f"  oldest     {fmt_time(scan['oldest'])}   newest {fmt_time(scan['newest'])} "
            f"({human_age(scan['newest'], now)})")
        if scan["prefixes"]:
            out(f"  largest prefixes (depth {args.depth}):")
            for p in scan["prefixes"][:args.top]:
                out(f"    {human_bytes(p['bytes']):>10}  {p['objects']:>7,} obj  {p['prefix']}")

        for r in scan["pgbackrest"]:
            bks = r["backups"]
            counts = defaultdict(int)
            for x in bks:
                counts[x["type"]] += 1
            out("")
            out(f"  pgBackRest repo {r['path']}  stanza {r['stanza']}  "
                f"PostgreSQL {r['pg_version']}  pgBackRest {r['pgbackrest_version']}")
            by_type = ", ".join(f"{counts[t]} {TYPE_NAMES.get(t, t)}"
                                for t in ("full", "diff", "incr") if counts[t])
            out(f"    backups  {len(bks)}" + (f"  ({by_type})" if by_type else ""))
            if bks:
                out(f"    newest   {bks[-1]['label']}  {human_age(bks[-1]['stop'], now)}")
                out(f"    oldest   {bks[0]['label']}  {fmt_time(bks[0]['start'])}")
                out(f"    stored   {human_bytes(sum(x['repo_delta'] or 0 for x in bks))} of backup data "
                    f"(database size {human_bytes(bks[-1]['db_size'])})")
            wal = r["wal"]
            out(f"    WAL      {wal['segments']:,} segments, {human_bytes(wal['bytes'])}, "
                f"newest {human_age(wal['newest'], now)}")
            if wal["first"]:
                out(f"             {wal['first']} .. {wal['last']}")
            if bks:
                out(f"    {'label':<34} {'type':<5} {'finished':<21} {'took':>6} {'db size':>10} {'stored':>10}")
                for x in bks:
                    took = int((x["stop"] - x["start"]).total_seconds())
                    flag = "  ERROR" if x["error"] else ""
                    out(f"    {x['label']:<34} {x['type']:<5} {fmt_time(x['stop']):<21} {took:>5}s "
                        f"{human_bytes(x['db_size']):>10} {human_bytes(x['repo_delta']):>10}{flag}")
            for o in r["orphans"]:
                out(f"    not in backup.info: {o['label']} ({o['objects']} objects, {human_bytes(o['bytes'])})")

    out("")
    if report["warnings"]:
        out(f"Warnings ({len(report['warnings'])})")
        for w in report["warnings"]:
            out(f"  ! {w}")
    else:
        out("No warnings.")


def to_json(obj):
    if isinstance(obj, datetime):
        return obj.isoformat()
    raise TypeError(type(obj))


# --------------------------------------------------------------------- main ---
def main():
    release = os.environ.get("GARAGE_RELEASE", "objstore")
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("-n", "--namespace", default=os.environ.get("NS", "crunchy-postgres"))
    p.add_argument("--release", default=release, help="Garage Helm release (default %(default)s)")
    p.add_argument("--bucket", action="append", help="only this bucket (repeatable)")
    p.add_argument("--endpoint", help="use this S3 endpoint instead of opening a port-forward")
    p.add_argument("--secret", help="Secret with access-key/secret-key (default <release>-garage)")
    p.add_argument("--no-scan", action="store_true", help="skip the S3 listing; admin stats only")
    p.add_argument("--depth", type=int, default=4, help="prefix depth for the size breakdown (default 4)")
    p.add_argument("--top", type=int, default=10, help="prefixes to show per bucket (default 10)")
    p.add_argument("--max-backup-age", type=float, default=26, metavar="HOURS",
                   help="warn if the newest backup is older (default 26)")
    p.add_argument("--max-full-age", type=int, default=8, metavar="DAYS",
                   help="warn if the newest full backup is older (default 8)")
    p.add_argument("--max-wal-age", type=float, default=24, metavar="HOURS",
                   help="warn if no WAL has been archived for this long (default 24)")
    p.add_argument("--usage-warn", type=float, default=80, metavar="PCT",
                   help="warn above this share of layout capacity (default 80)")
    p.add_argument("--json", action="store_true", help="print JSON instead of text")
    p.add_argument("--fail-on-warn", action="store_true", help="exit 1 if there are warnings")
    args = p.parse_args()

    now = datetime.now(timezone.utc)
    garage = Garage(args.namespace, f"{args.release}-garage-0")
    try:
        report = {"admin": admin_stats(garage, set(args.bucket or [])), "scan": {}}
    except subprocess.CalledProcessError as e:
        sys.exit(f"ERROR: garage json-api failed: {e.stderr.strip()}")
    except FileNotFoundError:
        sys.exit("ERROR: kubectl not found")
    missing = set(args.bucket or []) - {b["name"] for b in report["admin"]["buckets"]}
    if missing:
        sys.exit(f"ERROR: no such bucket: {', '.join(sorted(missing))}")

    if not args.no_scan:
        if boto3 is None:
            sys.exit("ERROR: boto3 is not installed (pip install boto3), or use --no-scan")
        pf = None
        try:
            if args.endpoint:
                endpoint = args.endpoint
            else:
                pf = PortForward(args.namespace, f"{args.release}-garage")
                endpoint = pf.endpoint
            s3 = s3_client(endpoint, args.namespace, args.secret or f"{args.release}-garage")
            for b in report["admin"]["buckets"]:
                try:
                    report["scan"][b["name"]] = scan_bucket(s3, b["name"], args.depth)
                except ClientError as e:
                    report["scan"][b["name"]] = {"error": e.response["Error"].get("Code", str(e))}
        finally:
            if pf:
                pf.close()

    report["warnings"] = find_warnings(report, args, now)
    if args.json:
        print(json.dumps({"generated": now, "namespace": args.namespace, **report},
                         default=to_json, indent=2))
    else:
        print_text(report, args, now)
    if args.fail_on_warn and report["warnings"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
