"""Tiny Upstash-REST client shared by the scripts. The endpoint and token come from the environment, never argv:
    KV_REST_API_URL=https://...  KV_REST_API_TOKEN=...   (the names Vercel's Upstash integration uses)"""
import json
import os
import urllib.request


def client(prefix="KV"):
    url = os.environ[f"{prefix}_REST_API_URL"].rstrip("/")
    token = os.environ[f"{prefix}_REST_API_TOKEN"]

    def call(commands, encoding=False, timeout=60):
        headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
                   # Cloudflare's Browser Integrity Check answers Python's default user agent with 403 (error 1010).
                   "User-Agent": "kv-migration"}
        if encoding:
            headers["Upstash-Encoding"] = "base64"
        request = urllib.request.Request(url + "/pipeline", data=json.dumps(commands).encode(), headers=headers)
        out = json.load(urllib.request.urlopen(request, timeout=timeout))
        errors = [o["error"] for o in out if "error" in o]
        if errors:
            raise SystemExit(f"errors: {errors[:3]}")
        return [o.get("result") for o in out]

    return call
