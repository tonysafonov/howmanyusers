#!/usr/bin/env python3
"""Signed Telegram Mini App `initData` for test users, signed the way Telegram signs it. Stdlib only.

    BOT_TOKEN=123:fake-bench-token python3 -I tg_initdata.py 3000 > perf/k6/data/users.json
    BOT_TOKEN=123:fake-bench-token python3 -I tg_initdata.py 60000 --first-id 8100000000 > perf/k6/data/new_users.json

Use a FAKE bot token that only the stand knows (the stand's app must be configured with the same token). Never sign
with a production token: these strings are valid logins for as long as the server doesn't check auth_date.
Output: a JSON array of initData strings, for lib.js's api() with AUTH_HEADER=initData (or whatever your app reads).
"""

import argparse
import hashlib
import hmac
import json
import os
import random
import sys
import time
from urllib.parse import urlencode


def init_data(tg_id: int, secret: bytes, auth_date: int, lang: str) -> str:
    user = {
        "id": tg_id,
        "first_name": f"Bench{tg_id % 100000}",
        "username": f"bench_{tg_id}",
        "language_code": lang,
        "allows_write_to_pm": True,
    }
    fields = {"auth_date": str(auth_date), "query_id": f"bench{tg_id}", "user": json.dumps(user, separators=(",", ":"))}
    check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
    fields["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    return urlencode(fields)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("count", type=int)
    ap.add_argument("--first-id", type=int, default=8_000_000_000, help="first fake Telegram user id")
    ap.add_argument("--langs", default="en", help="comma list to draw language_code from, e.g. en,en,ru")
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()
    token = os.environ.get("BOT_TOKEN")
    if not token:
        sys.exit("set BOT_TOKEN to the stand's fake bot token")
    secret = hmac.digest(b"WebAppData", token.encode(), hashlib.sha256)
    rnd, now, langs = random.Random(a.seed), int(time.time()), a.langs.split(",")
    json.dump([init_data(a.first_id + i, secret, now, rnd.choice(langs)) for i in range(a.count)], sys.stdout)
    print(f"{a.count} users, ids {a.first_id}..{a.first_id + a.count - 1}", file=sys.stderr)


if __name__ == "__main__":
    main()
