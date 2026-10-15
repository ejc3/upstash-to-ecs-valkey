#!/usr/bin/env python3
"""Failover test for the ECS service: write a canary, break something, time the outage through the PUBLIC endpoint,
then check the canary and that no key without an expiry went missing.

    KV_REST_API_URL=... KV_REST_API_TOKEN=... python3 -u failover_test.py <cluster> <service> task-stop|process-exit

task-stop      ecs stop-task (a graceful stop: SIGTERM, as a deploy does)
process-exit   valkey-cli SHUTDOWN NOSAVE inside the task via ECS Exec (still flushes the append-only file: not abrupt) (needs session-manager-plugin on PATH); a signal
               sent to the container's PID 1 from inside is ignored unless the process handles it, so `kill` is not
               a crash test
Run with python3 -u: the timeline is printed as it happens."""
import subprocess
import sys
import time

from kvrest import client

cluster, service, mode = sys.argv[1:4]
call = client()
aws = lambda *a: subprocess.check_output(["aws", *a], text=True).strip()


def persistent():
    keys, cur = [], "0"
    while True:
        cur, batch = call([["SCAN", cur, "COUNT", "1000"]])[0]
        keys += batch
        if cur == "0":
            break
    ttls = call([["TTL", k] for k in keys]) if keys else []
    return {k for k, t in zip(keys, ttls) if t == -1}


t0 = time.time()
stamp = lambda: f"{time.time() - t0:6.1f}s"
canary = f"failover:canary:{int(t0)}"
call([["SET", canary, "survived"]])
before = persistent()
time.sleep(2)  # past appendfsync everysec
task = aws("ecs", "list-tasks", "--cluster", cluster, "--service-name", service, "--query", "taskArns[0]", "--output", "text")
zone = aws("ecs", "describe-tasks", "--cluster", cluster, "--tasks", task, "--query", "tasks[0].availabilityZone", "--output", "text")
print(f"{stamp()} {len(before)} keys without expiry; task {task.split('/')[-1][:8]} in {zone}")
if mode == "task-stop":
    aws("ecs", "stop-task", "--cluster", cluster, "--task", task, "--reason", "failover test")
else:
    subprocess.run(["aws", "ecs", "execute-command", "--cluster", cluster, "--task", task, "--container", "valkey",
                    "--interactive", "--command", "valkey-cli SHUTDOWN NOSAVE"], capture_output=True)
print(f"{stamp()} triggered {mode}")
down = up = None
while time.time() - t0 < 600:
    try:
        call([["PING"]], timeout=4)
        if down:
            up = time.time()
            break
    except BaseException:  # urllib errors and SystemExit from an error reply
        if not down:
            down = time.time()
            print(f"{stamp()} endpoint down")
    time.sleep(2)
value = call([["GET", canary]])[0]
missing = before - persistent()
call([["DEL", canary]])
new_task = aws("ecs", "list-tasks", "--cluster", cluster, "--service-name", service, "--query", "taskArns[0]", "--output", "text")
new_zone = aws("ecs", "describe-tasks", "--cluster", cluster, "--tasks", new_task, "--query", "tasks[0].availabilityZone", "--output", "text")
print(f"{stamp()} back: outage {round(up - down, 1) if down and up else 'none seen'} s; canary {value}; "
      f"missing {len(missing)}; task {new_task.split('/')[-1][:8]} in {new_zone}")
print("RESULT", "PASS" if value == "survived" and not missing else f"FAIL {sorted(missing)[:5]}")
