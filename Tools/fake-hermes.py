#!/usr/bin/env python3
"""A pretend `hermes` command, for trying "This Mac" without a real Hermes.

    python3 Tools/fake-hermes.py http://127.0.0.1:9129 gateway tickets --serve --json

Says where the pretend gateway is, then answers each line on its input with a made-up
single-use pass, as the real `hermes gateway tickets --serve` does. Run the pretend
gateway in its "tickets" mode to have it take them. With "none" for the address it ends
at once, like a Mac where Hermes is not running. With "silent" it says nothing at all,
and with "gone:" in front of the address it says where the gateway is and then ends.
"""
import json
import secrets
import sys

origin, command = sys.argv[1], sys.argv[2:]
if command[:3] != ["gateway", "tickets", "--serve"] or origin == "none":
    sys.exit(3)
if origin == "silent":
    sys.stdin.read()
    sys.exit(0)
gone = origin.startswith("gone:")
origin = origin.removeprefix("gone:")
print(json.dumps({"type": "hello", "protocol": 1, "endpoint": {"api_origin": origin, "profile_id": "/pretend"}}), flush=True)
if gone:
    sys.exit(0)
count = 0
for line in sys.stdin:
    try:
        asked = json.loads(line)
    except ValueError:
        continue
    count += 1
    purpose = asked.get("purpose")
    if purpose not in ("interactive", "native-http"):
        print(json.dumps({"id": asked.get("id"), "ok": False, "error": "unknown purpose"}), flush=True)
        continue
    # Made up, and shaped so the pretend gateway can tell what each was asked for.
    ticket = f"pass.{purpose}.{asked.get('profile', '')}.{count}-{secrets.token_hex(6)}"
    print(json.dumps({"id": asked.get("id"), "ok": True, "ticket": ticket, "expires_in": 30}), flush=True)
