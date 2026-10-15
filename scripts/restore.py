#!/usr/bin/env python3
"""Restore a backup.py export into an Upstash-REST endpoint (the new Valkey behind serverless-redis-http).

    KV_REST_API_URL=<new> KV_REST_API_TOKEN=<new> python3 restore.py backup.json

Each key is deleted and rewritten. A key's remaining TTL is reduced by the time since it was captured, and a key whose
TTL has run out in the meantime is skipped, so nothing lives longer than it would have. Then it verifies the count and
every key's type. Restore BEFORE giving consumers the new credentials (a cron that starts on an empty store sees no
subscribers and no "already sent" records)."""
import base64
import json
import sys
import time

from kvrest import client


def main():
    data = json.load(open(sys.argv[1]))
    call = client()
    d = lambda x: base64.b64decode(x).decode()
    now = int(time.time() * 1000)
    cmds, kept = [], []
    for k, e in data.items():
        t, v, pttl = e["type"], e["value_b64"], e["pttl"]
        remaining = pttl - (now - e.get("captured_at_ms", now)) if isinstance(pttl, int) and pttl > 0 else None
        if remaining is not None and remaining <= 0:
            continue
        kept.append(k)
        cmds.append(["DEL", k])
        if t == "string":
            cmds.append(["SET", k, d(v)])
        elif t == "hash" and v:
            cmds.append(["HSET", k] + [d(x) for x in v])
        elif t == "set" and v:
            cmds.append(["SADD", k] + [d(x) for x in v])
        elif t == "list" and v:
            cmds.append(["RPUSH", k] + [d(x) for x in v])
        elif t == "zset" and v:
            vals = [d(x) for x in v]
            cmds.append(["ZADD", k] + [x for i in range(0, len(vals), 2) for x in (vals[i + 1], vals[i])])
        elif t == "stream":
            for entry in v:
                entry_id, fields = d(entry[0]), [d(x) for x in entry[1]]
                cmds.append(["XADD", k, entry_id] + fields)
        if remaining is not None:
            cmds.append(["PEXPIRE", k, str(remaining)])
    for i in range(0, len(cmds), 300):
        call(cmds[i:i + 300])
    types = []
    for i in range(0, len(kept), 300):
        types += call([["TYPE", k] for k in kept[i:i + 300]])
    bad = sum(1 for k, t in zip(kept, types) if t != data[k]["type"])
    print(f"restored {len(kept)} keys ({len(data) - len(kept)} expired meanwhile); type mismatches {bad}")


if __name__ == "__main__":
    main()
