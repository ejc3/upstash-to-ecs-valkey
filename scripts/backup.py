#!/usr/bin/env python3
"""Export every key of an Upstash (or any Upstash-REST) database to a JSON file, by type.

    KV_REST_API_URL=... KV_REST_API_TOKEN=... python3 backup.py out.json

Upstash serves DUMP over REST, but Valkey 8.1 rejects its payloads on RESTORE ("DUMP payload version or checksum are
wrong"), so each key is read with the command for its type (GET, HGETALL, SMEMBERS, LRANGE,
ZRANGE WITHSCORES, XRANGE) plus PTTL, values base64-encoded. It refuses to finish if a key has a type it cannot export.
For a stream it also records each consumer group's name and last-delivered ID (XINFO GROUPS), which restore.py recreates.
Pending entries (delivered, not acknowledged) cannot be exported over REST: pause the consumers and let them process or
claim what is pending first. Never XACK entries just to empty the list."""
import base64
import json
import os
import sys
import time

from kvrest import client

READ = {"string": lambda k: ["GET", k], "hash": lambda k: ["HGETALL", k], "set": lambda k: ["SMEMBERS", k],
        "list": lambda k: ["LRANGE", k, "0", "-1"], "zset": lambda k: ["ZRANGE", k, "0", "-1", "WITHSCORES"],
        "stream": lambda k: ["XRANGE", k, "-", "+"]}


def groups(call, key, d):
    """[{name, last_delivered_id, pending}] for a stream's consumer groups (XINFO GROUPS replies are flat field lists)."""
    out = []
    for info in call([["XINFO", "GROUPS", key]], encoding=True)[0] or []:
        fields = {d(info[i]): info[i + 1] for i in range(0, len(info), 2)}
        out.append({"name": d(fields["name"]), "last_delivered_id": d(fields["last-delivered-id"]), "pending": fields.get("pending", 0)})
    pending = [g["name"] for g in out if g["pending"]]
    if pending:
        print(f"warning: {key}: groups {pending} have pending entries, which are not exported", file=sys.stderr)
    return out


def main():
    out_path = sys.argv[1]
    call = client()
    d = lambda x: base64.b64decode(x).decode() if isinstance(x, str) else x
    keys, cur = [], "0"
    while True:
        cur, batch = call([["SCAN", cur, "COUNT", "1000"]], encoding=True)[0]
        cur = d(cur); keys += [d(k) for k in batch]
        if cur == "0":
            break
    data = {}
    for i in range(0, len(keys), 200):
        chunk = keys[i:i + 200]
        types = [d(t) for t in call([["TYPE", k] for k in chunk], encoding=True)]
        unknown = sorted({t for t in types if t not in READ})
        if unknown:
            raise SystemExit(f"no exporter for type(s) {unknown}: refusing an incomplete backup")
        res = call([c for k, t in zip(chunk, types) for c in (READ[t](k), ["PTTL", k])], encoding=True)
        for j, (k, t) in enumerate(zip(chunk, types)):
            data[k] = {"type": t, "value_b64": res[2 * j], "pttl": res[2 * j + 1], "captured_at_ms": int(time.time() * 1000)}
            if t == "stream":
                data[k]["groups"] = groups(call, k, d)
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    print(f"{out_path}: {len(data)} keys")


if __name__ == "__main__":
    main()
