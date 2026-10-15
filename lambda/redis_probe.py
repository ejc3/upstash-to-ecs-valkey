"""Every minute: one real round trip through each public Redis endpoint (PING plus a SET/GET of a probe key with a
short expiry), published as <METRIC_NAMESPACE> Up (1 or 0) and LatencyMs per endpoint. Alarms watch Up. Tokens come from the
SECRET_ID secret; nothing is logged but the endpoint, the outcome and the latency."""
import json
import os
import time
import urllib.request

import boto3

SECRET_ID = os.environ["SECRET_ID"]
ENDPOINTS = json.loads(os.environ["ENDPOINTS"])
NAMESPACE = os.environ.get("METRIC_NAMESPACE", "KV/Redis")  # {"prod": "https://...", "stage": "https://..."}

secrets = boto3.client("secretsmanager")
cloudwatch = boto3.client("cloudwatch")


def probe(url, token):
    key = "probe:%d" % int(time.time())
    body = json.dumps([["PING"], ["SET", key, "1", "EX", "120"], ["GET", key]]).encode()
    request = urllib.request.Request(url.rstrip("/") + "/pipeline", data=body, headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "redis-probe"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=10) as response:
        results = json.loads(response.read())
    elapsed = (time.time() - started) * 1000
    ok = [r.get("result") for r in results] == ["PONG", "OK", "1"]
    return ok, elapsed


def handler(event, context):
    tokens = json.loads(secrets.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    data = []
    for env, url in ENDPOINTS.items():
        try:
            ok, elapsed = probe(url, tokens["%s_token" % env])
        except Exception as error:  # noqa: BLE001 -- any failure is a down endpoint
            ok, elapsed = False, None
            print(json.dumps({"endpoint": env, "ok": False, "error": type(error).__name__}))
        else:
            print(json.dumps({"endpoint": env, "ok": ok, "latency_ms": round(elapsed)}))
        dims = [{"Name": "Endpoint", "Value": env}]
        data.append({"MetricName": "Up", "Dimensions": dims, "Value": 1 if ok else 0, "Unit": "Count"})
        if elapsed is not None:
            data.append({"MetricName": "LatencyMs", "Dimensions": dims, "Value": elapsed, "Unit": "Milliseconds"})
    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=data)
