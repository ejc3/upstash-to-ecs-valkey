# Upstash Redis → Valkey on ECS (Fargate)

Moving a site's Redis off Upstash (here: a store created through the Vercel Marketplace) to Valkey you run yourself on
AWS ECS Fargate, **without changing the application's code**: the app keeps using `@upstash/redis` over HTTPS, because
[serverless-redis-http](https://github.com/hiett/serverless-redis-http) speaks Upstash's REST protocol in front of
Valkey. Everything here was done for real on a production site in October 2026; the numbers are measured, not
estimated, unless a row says otherwise.

- [`terraform/`](terraform/): the cluster, private registry, image build job, Redis service on EFS, per-minute probe,
  alarms and dashboard.
- [`patches/srh-auth-body64mb.patch`](patches/srh-auth-body64mb.patch): two fixes to serverless-redis-http you need
  (below).
- [`scripts/`](scripts/): backup, restore, reconcile and failover-test tools that talk Upstash REST.
- [`lambda/redis_probe.py`](lambda/redis_probe.py): the end-to-end probe behind the alarms.

## Why move at all

A Redis created through the **Vercel Marketplace** is billed and owned through the Vercel team. Vercel's resource
transfer between teams covers some integrations (Prisma, Neon, Supabase in the changelog) but not Upstash, and
deleting the team deletes the store. Retiring the team therefore means moving the data first.

## The options, compared

Workload used for the prices: about **1 million commands a month** (mostly a one-minute cron), **20 MB** of data,
**16 GB** a month of responses, AWS us-west-1. Prices October 2026; check your region.

| Option | Monthly cost | Failover | Reachable from Cloudflare Workers / Vercel / CI | Upkeep | Max request |
|---|---|---|---|---|---|
| **Upstash free** | $0 | managed | yes (HTTPS) | none | 10 MB |
| | ✗ 500k commands/month cap: this workload is ~2× over | | | | |
| **Upstash pay-as-you-go** | **~$2** ($0.20 per 100k commands; storage and bandwidth within allowance) | managed, replicated | yes | none | 10 MB (20 MB from the $100/month Fixed 5 GB plan, 50 MB at $400/month) |
| **Upstash via AWS Marketplace** | same usage billed on the AWS invoice | managed | yes | none (one console subscription to link accounts) | 10 MB |
| **ElastiCache (Valkey), one node** | ~$12 (cache.t4g.micro), **plus** a proxy | none automatic: no replica to fail over to | **no**: VPC only, so you still need serverless-redis-http and a tunnel in front | the proxy is yours | proxy's |
| **ElastiCache (Valkey), Multi-AZ** | ~$24 (primary and a replica in another zone), **plus** a proxy | managed automatic failover | same | the proxy is yours | proxy's |
| **One EC2 instance** (t4g.micro, Docker) | ~$11 | none: down until restarted | via a tunnel | OS, images, patches | 64 MB (patched) |
| **ECS Fargate + EFS** (this repo) | **~$21–25** (0.5 vCPU / 1 GB ARM task $16.60, public IPv4 $3.65, EFS cents, logs and Container Insights a few dollars) | automatic task replacement, any zone; **74 s** measured for a stopped task | via a tunnel | images (built by a job), no hosts | 64 MB (patched) |

Latency, measured from an EC2 instance in us-west-1 (PING + GET of a 260 KB key, 20 runs):

| | p50 | p90 |
|---|---|---|
| Self-hosted Valkey in us-west-1 behind a Cloudflare tunnel | **59 ms** | 78 ms |
| The Marketplace Upstash store (region chosen by the integration) | 194 ms | 258 ms |

Pick an Upstash region close to your callers and the gap shrinks; this is not a fair Upstash benchmark, only what this
migration saw.

**Choosing.** If you just want it to work: Upstash pay-as-you-go, ideally in your callers' region. It is cheaper,
managed and replicated. Self-host when you need requests above 10 MB, want the data in your own account, or want to
reuse the cluster for other services, and accept one copy of the data (up to about a second of writes lost if the
process dies abruptly), a gap of a minute or more on a failure or deploy, and owning the images.

## Architecture

```
callers (Workers, Vercel, Lambda, CI) --HTTPS--> Cloudflare edge --tunnel--> cloudflared --127.0.0.1--> srh-prod  (db 0) -+
                                                                                          srh-stage (db 1) -+-> valkey --> EFS
                                         one Fargate task, no inbound ports ----------------------------------------^
```

- **One task, one Valkey node.** Its append-only file (`appendfsync everysec`) lives on EFS, which is replicated across
  zones, so a replacement task in any zone has the data. A graceful stop flushes it and loses nothing acknowledged; an
  abrupt failure (no SIGTERM) can lose about the last second of acknowledged writes. Use `appendfsync always` or a
  replicated store if that is not acceptable. There is no hot standby: two Valkeys on one append-only file
  would corrupt it, so the service never runs two copies (`deployment_minimum_healthy_percent = 0`, maximum 100).
- **No inbound rule.** cloudflared dials out; the REST bearer token is the credential, exactly as with Upstash.
- **Images come from a private ECR**, mirrored or built once by a CodeBuild job, never pulled from Docker Hub at start.
- **Monitored end to end.** A Lambda does PING/SET/GET through each public hostname every minute; alarms fire after 3
  failed minutes (missing data counts as failure), on no running task, CPU and memory. Container Insights adds per
  container metrics.

## Things that broke, and the fix for each

1. **serverless-redis-http refuses requests over 8 MB with an empty 500.** It hard-codes Plug's default body limit.
   A job writing an 8.9 MB hash failed with `UpstashJSONParseError: Unable to parse response body`. The patch raises
   the limit to 64 MB.
2. **...and it parses the body before checking the token.** Raising the limit alone lets an anonymous caller make it
   decode 64 MB per request. The patch adds a plug that compares the bearer token (constant time) *before*
   `Plug.Parsers`; an unauthenticated request gets 401 without its body being read.
3. **Two serverless-redis-http containers in one Fargate task collide.** In `awsvpc` mode every container shares one
   hostname, and both Elixir releases default to the node name `prod@<host>`: the second exits with
   `the name prod@ip-... seems to be in use by another Erlang node`, taking the task down. Set `RELEASE_NODE` per
   container.
4. **Building the Elixir image on a 1 GB instance gets OOM-killed** (the build VM grew past 650 MB). Build in
   CodeBuild (ARM) instead, as `terraform/images.tf` does.
5. **Cloudflare blocks Python's default user agent** (`403`, Browser Integrity Check, error 1010). Every script here
   sets its own.
6. **Restore the data before the consumers get the new credentials.** A cron that starts on an empty store sees no
   subscribers and no "already sent" records.
7. **Writes keep reaching the old store after your final backup**: the old platform keeps serving DNS-cached clients
   and in-flight jobs. Export the old store again after the switch and reconcile three-way (`scripts/reconcile.py`).
   Compare hash values, not `HGETALL` output: its field order is not stable.
8. **A `dependsOn` chain costs you on the way down, not just up.** With `valkey ← srh ← cloudflared` gated on
   `HEALTHY`, startup waited for each check (every 15 s), and on stop Fargate stopped the containers in reverse order at
   **about 12 s per step even though each exited within a second of SIGTERM**: a 2 s `stopTimeout` changed nothing.
   The replacement task is placed only after the last container stops. Nothing needed the order: serverless-redis-http
   starts without Valkey, answers `SRH: Unable to connect to the Redis server` until it is up, serves within a second of
   it and recovers by itself after a Valkey restart; cloudflared answers 502 until the REST servers listen. Drop
   `dependsOn`, keep the health checks (every 5 s) so ECS still replaces a container that stops answering, and keep
   start periods generous: a start period only forgives early failures, and the first success ends it.
9. **`kill 1` inside a container is not a crash test**: signals sent to PID 1 from inside its namespace are ignored
   unless the process handles them. Use `valkey-cli SHUTDOWN NOSAVE` or stop the task.
10. **DUMP is not served over Upstash REST.** Export by type (`scripts/backup.py`); it refuses to finish if a key has
    a type it cannot export. For streams it also records each consumer group's last-delivered ID, and
    `scripts/restore.py` recreates the group there (tested: a group that had read two of three entries reads only the
    third after the restore). Pending entries cannot be carried over REST: pause consumers and let them process or
    claim what is pending first; never `XACK` just to empty the list.

## Failover, measured

Each run: write a canary, stop the running task (`ecs stop-task`: a graceful stop, as a deploy does; an abrupt host
failure takes the same replacement path but was not timed),
poll the public endpoint every 2 s, then check the canary and that no key without an expiry is missing
(`scripts/failover_test.py`). Every run passed the data check; the replacement often started in another zone.

| Configuration | Outage (stopped → endpoint answering) |
|---|---|
| `dependsOn` chain, health checks every 15 s, 30 s start periods | **108 s** |
| same chain, checks every 5 s | **84 s** |
| + 2 s stop timeout on the stateless containers | 89 s (no change: the timeout was not what was slow) |
| **no `dependsOn`**, checks every 5 s (this repo) | **74 s** |

Where the 74 s goes, from the task's timestamps and container logs:

| Phase | 108 s run | 74 s run |
|---|---|---|
| Old task's containers stop | 25 s, one after another | **2 s**, together |
| Fargate tears the old task down before the replacement is placed | 36 s | 38 s |
| New task: network interface, image pull (107 MB), EFS mount, start | ~23 s, then ~25 s of health-gated chain | ~36 s, no chain |

No task setting moved the two Fargate phases, and they vary between runs, so ~75 s is what one task achieved here, not
a guarantee. Going lower needs a hot standby (a replica with its own storage and a promotion step), which is what a
managed service sells.

The Valkey process exiting by itself (`valkey-cli SHUTDOWN NOSAVE` through ECS Exec) also replaced the task with the
canary intact; that run's timing was not captured.

## How to do it

1. **Create the tunnel and tokens** (outside this module): a Cloudflare tunnel with one public hostname per
   environment pointing at `http://127.0.0.1:8079` (prod) and `:8078` (stage), and a Secrets Manager secret
   `{"tunnel_token": ..., "prod_token": <random 48 chars>, "stage_token": <random 48 chars>}`.
2. **Apply the module with `running = false`**: everything exists, no task runs. The probe starts reporting (and
   alarming) right away. Subscribe yourself to the alert topic.
3. **Build the images**: `aws codebuild start-build --project-name <name>-images`.
4. **Final export from Upstash** (`scripts/backup.py`), after pausing scheduled writers if you can.
5. **Apply with `running = true`**, wait for the endpoint to answer, **restore** (`scripts/restore.py`).
6. **Switch consumers** to the new URL and token (app secrets, CI secrets, Lambdas). Do it right after the restore.
7. **Fence the old store**: rotate or revoke its credentials (or pause every writer), so nothing can write to it after
   the next step. A diff taken while old writers can still write misses whatever lands after it.
8. **Reconcile once**: export the old store again, `scripts/reconcile.py final.json after.json`, then `apply`.
9. **Run the failover tests** (`scripts/failover_test.py <cluster> <service> task-stop`), and keep the old store,
   read-only, until a day of traffic is clean; then delete it.

All scripts read `KV_REST_API_URL` and `KV_REST_API_TOKEN` from the environment (never a command line), and write
backups with mode 0600.
