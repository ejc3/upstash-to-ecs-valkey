#!/usr/bin/env python3
"""Catch the writes that reached the OLD store after the final backup (writers are not stopped instantly, and DNS-cached
clients keep using the old platform for its TTL).

    KV_REST_API_URL=<new> KV_REST_API_TOKEN=<new> python3 reconcile.py final.json after.json [apply]

final.json is the backup that was restored; after.json is a second backup.py export of the old store taken after the
switch. Three-way per key: changed only in the old store -> copy it (apply); deleted only in the old store -> delete it;
changed in both -> reported, decided by hand. Hashes are compared field by field (HGETALL order is not stable)."""
import base64
import json
import sys

from kvrest import client

READ = {"string": "GET", "hash": "HGETALL", "set": "SMEMBERS", "list": "LRANGE", "zset": "ZRANGE"}


def norm(e):
    if e is None:
        return None
    v = e["value_b64"]
    if e["type"] == "hash":
        dec = [base64.b64decode(x).decode() for x in v]
        return ("hash", tuple(sorted(zip(dec[0::2], dec[1::2]))))
    if e["type"] == "set":
        return ("set", tuple(sorted(v)))
    return (e["type"], json.dumps(v))


def main():
    final, after = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
    apply = len(sys.argv) > 3 and sys.argv[3] == "apply"
    call = client()
    changed = [k for k in set(final) | set(after) if norm(final.get(k)) != norm(after.get(k))]
    current = {}
    for k in changed:
        t = (final.get(k) or after.get(k))["type"]
        cmd = {"string": ["GET", k], "hash": ["HGETALL", k], "set": ["SMEMBERS", k], "list": ["LRANGE", k, "0", "-1"],
               "zset": ["ZRANGE", k, "0", "-1", "WITHSCORES"]}.get(t)
        if cmd:
            exists = call([["EXISTS", k]])[0]
            current[k] = None if not exists else {"type": t, "value_b64": call([cmd], encoding=True)[0]}
    copy, delete, conflict = [], [], []
    for k in changed:
        new_untouched = norm(current.get(k)) == norm(final.get(k))
        if not new_untouched:
            conflict.append(k)
        elif after.get(k) is None:
            delete.append(k)
        else:
            copy.append(k)
    print(f"changed after the backup: {len(changed)}; copy {len(copy)}, delete {len(delete)}, changed on both sides {len(conflict)}")
    if conflict:
        print("decide by hand:", conflict[:20])
    if apply:
        if delete:
            call([["DEL", k] for k in delete])
        if copy:
            import subprocess, tempfile, os
            subset = {k: after[k] for k in copy}
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(subset, f)
            subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "restore.py"), f.name], check=True)
            os.unlink(f.name)


if __name__ == "__main__":
    main()
