#!/usr/bin/env python3
"""A pretend Hermes gateway with made-up bots and chats, for running the app without a real one.

    python3 Tools/fake-gateway.py            # listens on 127.0.0.1:9119, token "demo"
    python3 Tools/fake-gateway.py 9120 queue # another port; a message to a busy bot waits its turn
    python3 Tools/fake-gateway.py 9120 authority # chats go through the session authority
    python3 Tools/fake-gateway.py 9120 no-rewind # no undo and no reactions, as an older gateway
    python3 Tools/fake-gateway.py 9120 unsaved   # a description or soul is answered as not saved
    (in any mode, a message saying "ask me approve", "ask me clarify secret", … gets questions: see REQUESTS)
    HERMES_URL=127.0.0.1:9119 HERMES_TOKEN=demo swift run HermesBot

It answers only what the app asks for: the bot list, making, renaming and deleting a bot, its
description and soul, how full its open chat is, its
routines, its model and reasoning level (Orbit Max asks to be agreed to; the Reading List's
reasoning is fixed by an administrator; mode "no-models" offers neither, and "unscoped" reads and
writes reasoning for the main bot whichever is named, as Hermes before 0.21.6), starting its chat, opening
a chat, sending and stopping over the socket, slash commands (made-up readouts, /undo and /retry
rewinding the chat, /btw answered on the side, /yolo; mode "no-commands" lists none, "commands-fail" fails to), and stored
chat messages over HTTP. A message gets a canned reply, typed out slowly
enough to watch; a message containing "slow" takes long enough to stop, and one containing
"quick" skips the pauses. "late" makes it slow to say it has the message. "then a page" has a
page in the chat talk to the bot after the answer (a hidden turn). Undo, Retry's cut and
reactions are kept as the real gateway keeps them. A message sent while
a bot is answering turns the answer to it, as the real gateway does by default, and every app with
the chat open sees every answer. Nothing here is real
data; keep it that way, since screenshots of it get shared.
"""
import base64, hashlib, json, os, re, socketserver, struct, sys, threading, time, uuid
from urllib.parse import urlparse, parse_qs, unquote

TOKEN = "demo"
NOW = time.time()
STALE_RESUME = set()  # chats whose next opening hands back an approval already answered, after its turn's end
STILL_ASKED = set()   # chats whose every opening holds that approval: it is still asked
RESUMES = {}          # chat id -> how many times it was opened
FAIL_RESUMES = {}     # chat id -> openings still to refuse after the late one; the first says another turn ended
OPEN = {}       # chat id -> the sockets that have it open; a bot's answer goes to all of them
BUSY = {}       # chat id -> a lock held while the bot answers, so a second message waits its turn
STOPS = {}      # chat id -> set to stop the answer under way
INTERRUPTS = 0  # how many times a bot was told to stop, for tests to read from /api/status
TAKEN = {}      # chat id -> messages taken and not yet finished with
DROPS = {}      # chat id -> goes up with each stop; a message that was waiting then is dropped
REDIRECT_TO = 0
VERSION = "0.23.4"  # as /api/status says it; mode "old-hermes" says one from before 0.21.6
BUSY_MODE = "interrupt"  # or "queue": what a message sent to a busy bot does, as display.busy_input_mode
TURNING = threading.Lock()  # held to change TURNED, which a stop and an answer both do
TURNED = {}     # chat id -> messages sent mid-answer that the answer under way should turn to
REDRAWN = 0     # how many times the script beside the water chart was written again
LATE = {}       # chat id -> pictures whose upload lost its connection, queued after the next count there
ROW_IDS = iter(range(1000, 1 << 30))  # a new row's id; as in the real store, one taken back is never reused
REWOUND = set()  # chats cut since their last message; "refuse a retry" is refused once asked again after a cut
REVISION = {}   # "authority" mode: chat id -> its revision, which moves whenever its transcript does
REFRESHES = []  # "bot chat" for each chat told to build its instructions afresh, for tests to read from /api/status
USAGE = {}      # chat id -> [model calls, tokens] since the chat was opened here
ORDER = []      # "refresh" and "submit" as each happens, for tests to read from /api/status


def user_row(rows, text, hidden=False):
    """The person's message as it is stored: hidden when it was sent with display_kind
    "hidden" (as a page in a chat sends one) and waited or ran on its own. Like the real
    gateway, one steered into an answer under way is stored without it."""
    row = {"id": next(ROW_IDS), "role": "user", "content": text, "timestamp": time.time()}
    if hidden:
        row["display_kind"] = "hidden"
    return row


def chat(*rows):
    out, stamp = [], NOW - 3 * 86400
    for index, (role, gap, content, tools) in enumerate(rows):
        stamp += gap
        # A message no one sees, as a page in the chat sends one.
        hidden = role == "hidden"
        row = {"id": index + 1, "role": "user" if hidden else role, "content": content, "timestamp": stamp}
        if hidden:
            row["display_kind"] = "hidden"
        if tools:
            row["tool_calls"] = [{"function": {"name": name, "arguments": "{}"}} for name in tools]
        out.append(row)
    return out


CHATS = {
    "chat-main": chat(
        ("user", 0, "morning. anything I should know about today?", None),
        ("assistant", 4, "", ["calendar", "weather"]),
        ("tool", 1, "…", None),
        ("assistant", 3, "Two things. Your **dentist** is at 3:30 PM, and it will rain from about 2, so leave ten minutes early.\n\nNothing else is on the calendar.", None),
        ("user", 86400, "can you move the bakery order to friday", None),
        ("assistant", 5, "", ["web_search", "browser", "email", "calendar", "notes"]),
        ("assistant", 9, "Done. The order is now for **Friday at 9 AM**. I replied on the same thread, so the confirmation is in your inbox under `Bakery order #2041`.", None),
        ("user", 86400 * 2 - 600, "thanks", None),
        ("assistant", 3, "Anytime.", None),
    ),
    "chat-trips": chat(
        ("user", 0, "plan lisbon for me, three days", None),
        ("assistant", 8, "## Lisbon, three days\n\nHere is a first pass. Tell me what to change.\n\n### Day one\n1. Arrive and drop bags at the **Alfama** flat\n2. Walk up to the castle\n   - go before 10, it gets busy\n   - tickets are cheaper online\n3. Dinner near the river\n\n### Worth knowing\n- Trams take cards, buses mostly do not\n- Sunday museums are free\n\n> The flat's host says the lift is out until Friday.\n\nTo see the booking again, run:\n\n```sh\ntrip show lisbon --nights 3\ntrip export lisbon --format ics > lisbon.ics\n```\n\n| Day | Plan | Cost |\n|---|---|---|\n| Fri | Castle, then a long walk along the river to Belem and lunch at the market | 15 |\n| Sat | Sintra | 32 |\n\n---\n\nWant me to book the Sintra train?", None),
    ),
    "chat-garden": chat(
        ("user", 0, "show me the bed layout", None),
        ("assistant", 6, "Here is the layout I drew.\n\nMEDIA:/demo/beds.png\n\nAnd the planting calendar to print: MEDIA:/demo/planting calendar.pdf.\n\nThe old sketch is gone: MEDIA:/demo/missing.png", None),
        ("user", 600, "how did each bed do last year?", None),
        ("assistant", 5, "Here is the water each bed took, week by week:\n\n::preview{file=\"/demo/charts/water.html\"}\n\nAnd what each bed gave.\n\n::preview{file=\"/demo/yield.html\"}\n\nBed C had the tomatoes.", None),
        ("hidden", 40, "Sort the beds by yield", None),
        ("assistant", 6, "", ["write_file"]),
        ("user", 3000, "when should I plant the tomatoes?", None),
        ("assistant", 6, "After your last frost, which for you is usually the second week of May. Start them indoors now.", None),
    ),
}


# The bot reacted to "thanks", as a bot given Hermes's reaction tool can.
CHATS["chat-main"][7]["display_metadata"] = {"reactions": [{"emoji": "👍", "author": "agent", "at": NOW}]}


def is_persons(row):
    """A turn of the person's, as the gateway's own undo counts them: not a hidden turn."""
    return row["role"] == "user" and row.get("display_kind") in (None, "", "steer")


def cut(chat_id, row_id, empty_ok, deep_ok):
    """Takes the chat back to before the person's row `row_id`, as the gateway's rewind does.
    Returns an error to send, or None when it was done."""
    rows = CHATS[chat_id]
    at = next((i for i, row in enumerate(rows) if row["id"] == row_id and is_persons(row)), None)
    if at is None:
        return {"code": 4018, "message": "target turn not found"}
    if at == 0 and not empty_ok:
        return {"code": 4028, "message": "truncation would erase the entire session transcript"}
    # Enforced here, as the gateway's next release will: one turn only, unless asked.
    if sum(1 for row in rows[at:] if is_persons(row)) > 1 and not deep_ok:
        return {"code": 4033, "message": "truncation would archive later user turns"}
    del rows[at:]
    REWOUND.add(chat_id)
    REVISION[chat_id] = REVISION.get(chat_id, 0) + 1
    changed(chat_id)
    return None


def changed(chat_id):
    """The roster's view of a chat follows what it now holds."""
    rows = CHATS[chat_id]
    for row in BOTS:
        if (row.get("canonical_session") or {}).get("id") == chat_id:
            last = rows[-1] if rows else None
            row["canonical_session"].update(preview=(last["content"] if last else "")[:80], last_active=time.time(), message_count=len(rows))


def bot(name, title, chat_id, default=False, look=None):
    rows = CHATS.get(chat_id, [])
    last = rows[-1] if rows else None
    meta = {"hermes-bots": {"title": title}}
    if look:
        meta["hermes-bot"] = {"avatar": look}
    row = {"name": name, "is_default": default, "model": "orbit-mini", "provider": "northwind", "description": "", "display_name": "", "ui_meta": meta}
    if last:
        row["canonical_session"] = {"id": chat_id, "title": "Bot Chat", "preview": last["content"][:80], "last_active": last["timestamp"], "message_count": len(rows)}
    return row


BOTS = [
    bot("default", "Hermes", "chat-main", default=True),
    bot("garden", "Garden", "chat-garden", look={"shape": "flower", "color": "green"}),
    bot("books", "Reading List", None, look={"shape": "tablet", "color": "violet"}),
    bot("trips", "Trips", "chat-trips", look={"shape": "wedge", "color": "orange"}),
]


ROUTINES = {
    "default": [
        {"job_id": "r1", "name": "[bot:default] Morning brief", "schedule": "0 7 * * *", "enabled": True},
        {"job_id": "r2", "name": "Inbox sweep", "schedule": "every 30m", "enabled": True},
        {"job_id": "r3", "name": "Friday wrap-up", "schedule": "0 16 * * 5", "enabled": False},
    ],
    "garden": [{"job_id": "r4", "name": "Watering reminder", "schedule": "0 8 * * 1-5", "enabled": True}],
}


# Made-up providers and models for the model picker; none of these names is real.
PROVIDERS = [
    {"slug": "northwind", "name": "Northwind", "authenticated": True,
     "models": ["orbit-mini", "orbit-pro", "orbit-max", "orbit-lite"],
     "featured_models": ["orbit-pro", "orbit-mini"],
     "capabilities": {"orbit-mini": {"fast": True, "reasoning": True, "can_disable_reasoning": True},
                      "orbit-pro": {"fast": False, "reasoning": True, "can_disable_reasoning": True},
                      "orbit-max": {"fast": False, "reasoning": True, "can_disable_reasoning": False},
                      "orbit-lite": {"fast": True, "reasoning": False}}},
    {"slug": "lumen", "name": "Lumen", "authenticated": True,
     "models": ["lumen-6", "lumen-6-think", "lumen-4-small"],
     "featured_models": ["lumen-6"],
     # As for most providers, Hermes does not say whether lumen-6's thinking can be turned off.
     "capabilities": {"lumen-6": {"fast": False, "reasoning": True},
                      "lumen-6-think": {"fast": False, "reasoning": True, "can_disable_reasoning": False},
                      "lumen-4-small": {"fast": True, "reasoning": False}}},
    # Many models, as a router of other people's has.
    {"slug": "relay", "name": "Relay", "authenticated": True,
     "models": [f"{maker}/{family}-{n}" for maker in ("acme", "zephyr", "kite") for family in ("chat", "coder", "vision") for n in range(1, 21)],
     "unavailable_models": ["kite/vision-20"]},
    # Not signed in: never offered.
    {"slug": "nimbus", "name": "Nimbus", "authenticated": False, "models": ["nimbus-1"]},
]
# Picking this one asks the person to agree first, as Hermes does for a costly model.
COSTLY = ("northwind", "orbit-max")
REASONING = {}  # bot name -> its saved reasoning level, "medium" when never set
MANAGED = {"books"}  # an administrator has fixed these bots' reasoning

# What each bot is for, and its soul, as Hermes keeps them beside the bot.
PERSONALITY = {
    "default": {"description": "Everyday help", "soul": "You are Hermes, a calm and practical assistant.\n\nKeep replies short. Say plainly when you are unsure."},
    "garden": {"description": "Beds, sowing and watering", "soul": "You look after a small garden.\n\nGive one clear next step rather than a list of options."},
    "trips": {"description": "", "soul": ""},
}
for _row in BOTS:
    _row["description"] = PERSONALITY.get(_row["name"], {}).get("description", "")


# The slash commands offered, as `commands.catalog` lists them (with others this app does not offer).
COMMANDS = [(name, "") for name in (
    "model", "reasoning", "fast", "personality", "retry", "undo", "compress", "btw", "stop", "status",
    "context", "usage", "insights", "goal", "learn", "refine", "skills", "plan", "approvals", "yolo",
    "new", "resume", "branch", "help")]
YOLO = {}       # chat id -> approvals turned off for it
STATUS_DOWN = False  # /api/status-down: the open status read fails until /api/status-up
EVICTED = {}    # "evicts" mode: chat id -> its open chat has been let go of once
APPROVALS = {}  # chat id -> the approval mode set with /approvals

SOCKETS = set()  # every app connected, for what is told to all of them


def tell_all_sessions_changed():
    """As the real gateway does when any chat changes: a bare notice to every connection."""
    frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": "sessions.changed", "session_id": "", "payload": {}}}
    for socket in list(SOCKETS):
        try:
            socket.send(frame)
        except OSError:
            SOCKETS.discard(socket)


def speak_unasked(name):
    """A bot says something nobody asked for, as when a routine of its runs."""
    row = next((row for row in BOTS if row["name"] == name), None)
    if row is None:
        return
    chat_id = (row.get("canonical_session") or {}).get("id") or "chat-" + name
    rows = CHATS.setdefault(chat_id, [])
    said = "Your routine ran. Nothing needs you."
    rows.append({"id": next(ROW_IDS), "role": "assistant", "content": said, "timestamp": time.time()})
    row["canonical_session"] = {"id": chat_id, "title": "Bot Chat", "preview": said, "last_active": time.time(), "message_count": len(rows)}
    tell_all_sessions_changed()


# Questions a bot puts mid-answer, as the real gateway does with requests to the app (and,
# in "authority" mode, with approval.request / clarify.request events for leave and single
# questions). A message with "ask me" in it asks for those it names: "approve" (a command), "folder", "site",
# "clarify", "secret", "sudo", "stale" (leave asked for and then withdrawn), and "bridges"
# (every request the app should refuse at once), "ghost" (a question for a chat no app has
# opened), "connect" (a connection card, played through Hermes's own states, see
# connection_card). "short" makes the gateway wait 4 s, not 60.
# Requests go only to apps that said they answer them (client.capabilities), as on the real
# older route; the session authority sends them to every app with the chat open.
REQUESTS = {}       # id -> what was asked and, once answered, the answer
AUTO = {}           # ids of requests that belong to no chat -> their method
APPROVALS_HUNG = []  # "approvals-hang-once": whether the first reading of approvals.mode was left unanswered
ANSWERS = []        # what apps answered, for tests to read from /api/status; never a secret's value
LATE_READY = 0  # seconds the greeting waits after a connection opens
GENERATION = 7  # the execution generation every chat here is in
APPROVAL_MODES = {}  # bot -> its approvals.mode, as config.get / config.set see it
PRETEND_SECRET = "pretend-secret-123"  # what a test types: the answer is checked against it, never kept
QUESTION_WORDS = ("approve", "folder", "site", "clarify", "secret", "sudo", "stale", "bridges", "ghost", "connect")
CONNECTIONS = {}  # op id -> a connection card: its chat, its rows, and what wakes the bot when it settles


def connection_resolves(row):
    """`contract.resolves`: connected or skipped, and a failed catalog row."""
    return row["state"] in ("connected", "skipped") or (row["state"] == "failed" and row["kind"] in ("plugin", "skill"))


def connection_all_resolved(op):
    return bool(op["targets"]) and all(connection_resolves(r) for r in op["targets"])


def connection_rows(op):
    """Each row as `Target.snapshot` gives it: with `resolved`, and never the values approved."""
    return [{**{k: v for k, v in row.items() if k != "declared_env"}, "resolved": connection_resolves(row)} for row in op["targets"]]


def connection_view(op):
    return {"op_id": op["op_id"], "seq": op["seq"], "deadline_at": op["deadline_at"], "settled": bool(op.get("settled")),
            "settled_at": op.get("settled_at"), "settled_by": op.get("settled_by"), "targets": connection_rows(op)}


def connection_request_payload(op, display=None):
    """`request_payload`: also the resume snapshot's `pending_connection`."""
    card = CONNECTIONS.get(op["op_id"]) or {}
    display = display if display is not None else card.get("display")
    payload = {"op_id": op["op_id"], "seq": op["seq"], "deadline_at": op["deadline_at"], "timeout_seconds": 300,
               "targets": connection_rows(op)}
    if display is not None:
        payload["display"] = display
    return payload


def note_answer(method, result):
    """Keeps what was answered, without anything secret."""
    if method in ("secret", "sudo", "display.install.sudo", "vault.code", "vault.save_login", "vault.unlock_prompt"):
        value = (result or {}).get("value") if isinstance(result, dict) else None
        ANSWERS.append({"method": method, "given": bool(value), "matches": value == PRETEND_SECRET})
    else:
        ANSWERS.append({"method": method, "result": result})


USED_PASSES = set()
QUEUED = {}  # chat id -> pictures attached and waiting to go with its next message
HELD = {}    # "authority" mode: where a held picture is -> its kind, until a message names it
HELD_COUNT = iter(range(1, 1 << 30))  # names each held picture, never the same twice


def picture(width, height):
    """A small made-up PNG: garden beds as coloured blocks on a pale ground."""
    import zlib
    beds = [(20, 20, 150, 90, (116, 170, 106)), (190, 20, 320, 90, (214, 160, 84)), (20, 120, 320, 190, (128, 148, 196))]
    rows = b""
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            colour = (238, 234, 222)
            for left, top, right, bottom, fill in beds:
                if left <= x < right and top <= y < bottom:
                    colour = fill
            row += bytes(colour)
        rows += bytes(row)
    def piece(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + piece(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + piece(b"IDAT", zlib.compress(rows)) + piece(b"IEND", b"")


# A page a bot placed in its chat with ::preview: a small chart drawn by its own script in
# the colours the app hands it, a link, and one thing kept on the internet, which a page
# in a chat cannot reach.
PAGE = """<!doctype html>
<html>
<head>
<style>
  .bars { display: flex; align-items: flex-end; gap: 14px; height: 150px; padding: 12px 0 0; border-bottom: 1px solid var(--border); }
  .bar { flex: 1; max-width: 72px; background: var(--accent); border-radius: 5px 5px 0 0; }
  .names { display: flex; gap: 14px; padding: 6px 0 10px; color: var(--muted-foreground); font-size: 12px; }
  .names span { flex: 1; max-width: 72px; text-align: center; }
  .note { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; font-size: 13px; }
  a { color: inherit; }
</style>
</head>
<body>
<div class="bars" id="bars"></div>
<div class="names" id="names"></div>
<div class="note">NOTE <a href="https://example.com/beds">How this was counted</a> <button data-hermes-send="Show the yields in pounds">In pounds</button></div>
<img src="https://example.com/pixel.png" alt="" hidden>
<script>
  var beds = [["A", 12], ["B", 19], ["C", 31], ["D", 8]];
  beds.forEach(function (bed) {
    var bar = document.createElement("div");
    bar.className = "bar";
    bar.style.height = (bed[1] / 31 * 100) + "%";
    bar.title = bed[1] + " kg";
    document.getElementById("bars").appendChild(bar);
    var name = document.createElement("span");
    name.textContent = "Bed " + bed[0];
    document.getElementById("names").appendChild(name);
  });
</script>
</body>
</html>
"""

# A page drawn by a script and a stylesheet the bot saved beside it, as a real bot does
# with a charting library. The script holds words that would end the element it is put
# in if it were written into the page as HTML.
CHART_SCRIPT = """/* line.js: draws a line. Not to be ended early by "</script>" or "<!--" or "</style>". */
window.drawLine = function (holder, points) {
  var ns = "http://www.w3.org/2000/svg", most = Math.max.apply(null, points);
  var svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 " + (points.length - 1) * 40 + " 100");
  svg.setAttribute("class", "line");
  svg.setAttribute("preserveAspectRatio", "xMinYMid meet");
  var line = document.createElementNS(ns, "polyline");
  line.setAttribute("points", points.map(function (p, i) { return i * 40 + "," + (100 - p / most * 90); }).join(" "));
  svg.appendChild(line);
  holder.appendChild(svg);
  window.drawnWith = "</script><script>window.brokeOut = true</script>";
};
"""
CHART_STYLE = """/* </style><script>window.brokeOut = true</script> */
.line { display: block; width: 100%; height: 120px; }
.line polyline { fill: none; stroke: var(--foreground); stroke-width: 2; }
.caption { color: var(--muted-foreground); font-size: 12px; padding: 4px 0 8px; }
"""
CHART_PAGE = """<!doctype html>
<html><head>
<link rel="stylesheet" href="look/water.css">
<script src="./lib/line.js"></script>
</head><body>
<div id="chart"></div>
<div class="caption">Litres a week, all beds</div>
<script>drawLine(document.getElementById("chart"), [40, 55, 38, 70, 82, 64, 90]);</script>
</body></html>
"""
def page(note="Kilograms by bed, last year."):
    return ("text/html", PAGE.replace("NOTE", note).encode())


FILES = {
    "/demo/beds.png": ("image/png", picture(340, 210)),
    "/demo/planting calendar.pdf": ("application/pdf", b"%PDF-1.4\n% a made-up file for the pretend gateway\n"),
    "/demo/yield.html": page(),
    "/demo/charts/water.html": ("text/html", CHART_PAGE.encode()),
    "/demo/charts/lib/line.js": ("text/javascript", CHART_SCRIPT.encode()),
    "/demo/charts/look/water.css": ("text/css", CHART_STYLE.encode()),
}
SIGN_INS = {}           # cookie handle -> a sign-in begun: its challenge, where to come back to, its code
ACCESS_TOKENS = {}      # access token -> when it runs out
REFRESH_TOKENS = set()  # each works once
SOCKET_PASSES = set()
# Named as a gateway's own web app names it, with a short name for the gateway after it:
# a client that looks only for the bare name would not send it back.
PKCE_COOKIE = "hermes_session_pkce_0123456789abcdef"
SESSION_LASTS = 43200


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = self.rfile.readline().decode("latin-1").split()
        headers = {}
        while (line := self.rfile.readline().decode("latin-1").strip()):
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        if len(request) < 2:
            return
        url = urlparse(request[1])
        query = parse_qs(url.query)
        # Ways of not being a gateway to send a token to, for the address check.
        if BUSY_MODE == "redirects" and url.path.startswith("/api/"):
            # Sends every asker on to another address, as a proxy or a hostile host might.
            self.wfile.write(f"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{REDIRECT_TO}{request[1]}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
            return
        if BUSY_MODE == "not-hermes" and url.path == "/api/status":
            # Another service that happens to answer with JSON holding a version.
            return self.reply(404, {"version": "9.9", "detail": "Not found"})
        if BUSY_MODE == "lookalike" and url.path == "/api/status":
            return self.reply(200, {"version": "1.2.3", "name": "Some other app"})
        if BUSY_MODE in ("password-only", "password"):
            # Signs in with a username and password ("tester" and "hunter2"), as a real
            # gateway does for Hermes's own desktop app. "password" takes the token as well.
            ways = ["basic"] + (["session-token"] if BUSY_MODE == "password" else [])
            if url.path == "/api/status":
                return self.reply(200, {"version": VERSION, "auth_required": True, "auth_providers": ways, "auth_flows": ["cookie", "native_pkce"], "interrupts": INTERRUPTS, "refreshes": REFRESHES, "order": ORDER})
            if url.path == "/api/auth/providers":
                return self.reply(200, {"providers": [{"name": "basic", "display_name": "Username & Password", "supports_password": True}]})
            body = {}
            if request[0] == "POST" and int(headers.get("content-length", "0") or 0):
                try:
                    body = json.loads(self.rfile.read(int(headers["content-length"])))
                except ValueError:
                    body = {}
            if url.path == "/auth/native/authorize":
                if query.get("provider") != ["basic"]:
                    return self.reply(404, {"detail": "Unknown provider"})
                if query.get("code_challenge_method") != ["S256"] or not query.get("redirect_uri", [""])[0].startswith("http://127.0.0.1:"):
                    return self.reply(400, {"detail": "Bad request"})
                handle = f"begun-{len(SIGN_INS) + 1}"
                SIGN_INS[handle] = {"challenge": query["code_challenge"][0], "redirect": query["redirect_uri"][0], "state": query.get("state", [""])[0]}
                self.wfile.write(f"HTTP/1.1 302 Found\r\nLocation: /login\r\nSet-Cookie: {PKCE_COOKIE}={handle}; HttpOnly; Max-Age=600; Path=/; SameSite=lax\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
                return
            if url.path == "/auth/password-login":
                cookies = dict(part.strip().split("=", 1) for part in headers.get("cookie", "").split(";") if "=" in part)
                begun = SIGN_INS.get(cookies.get(PKCE_COOKIE))
                if body.get("provider") != "basic":
                    return self.reply(404, {"detail": "Unknown provider"})
                if (body.get("username"), body.get("password")) != ("tester", "hunter2"):
                    return self.reply(401, {"detail": "Invalid credentials"})
                if begun is None:
                    # Signed in as a browser would be: not what a native app can use.
                    return self.reply(200, {"ok": True, "next": "/"})
                begun["code"] = f"code-{len(SIGN_INS)}-{time.time()}"
                return self.reply(200, {"ok": True, "next": f"{begun['redirect']}?code={begun['code']}&state={begun['state']}"})
            if url.path == "/auth/native/token":
                begun = next((b for b in SIGN_INS.values() if b.get("code") and b["code"] == body.get("code")), None)
                made = base64.urlsafe_b64encode(hashlib.sha256(str(body.get("code_verifier", "")).encode()).digest()).rstrip(b"=").decode()
                if begun is None or made != begun["challenge"]:
                    return self.reply(400, {"detail": "Invalid or expired authorization code."})
                del begun["code"]  # works once
                return self.reply(200, self.new_session())
            if url.path == "/auth/native/refresh":
                if body.get("refresh_token") not in REFRESH_TOKENS:
                    return self.reply(401, {"error": "session_expired"})
                REFRESH_TOKENS.discard(body["refresh_token"])
                return self.reply(200, self.new_session())
            bearer = headers.get("authorization", "").removeprefix("Bearer ")
            signed_in = ACCESS_TOKENS.get(bearer, 0) > time.time()
            if url.path == "/api/auth/ws-ticket":
                if not signed_in:
                    return self.reply(401, {"detail": "Unauthorized"})
                ticket = f"socket-pass-{len(SOCKET_PASSES) + 1}-{time.time()}"
                SOCKET_PASSES.add(ticket)
                return self.reply(200, {"ticket": ticket, "ttl_seconds": 30})
            if url.path == "/api/ws" and "ticket" in query:
                # A pass opens one socket; the lasting token never rides in an address.
                if "token" in query or query["ticket"][0] not in SOCKET_PASSES:
                    return self.reply(403, {"detail": "Forbidden"})
                SOCKET_PASSES.discard(query["ticket"][0])
                return self.socket(headers)
            if url.path.startswith("/api/") and url.path != "/api/ws" and "authorization" in headers:
                if not signed_in:
                    return self.reply(401, {"detail": "Unauthorized"})
                return self.read(url)
            if BUSY_MODE == "password-only":
                return self.reply(403 if url.path == "/api/ws" else 401, {"detail": "Unauthorized"})
        if url.path == "/api/drop":
            # Every app's socket is closed, as when the network goes for a moment; nothing
            # asked or said is forgotten.
            for handler in list(SOCKETS):
                try:
                    handler.connection.shutdown(2)
                except OSError:
                    pass
            return self.reply(200, {"dropped": True})
        if url.path in ("/api/status-down", "/api/status-up"):
            # The open status read fails until it is up again, as on a moment's network trouble.
            global STATUS_DOWN
            STATUS_DOWN = url.path == "/api/status-down"
            return self.reply(200, {"status_down": STATUS_DOWN})
        if url.path == "/api/status" and STATUS_DOWN:
            return self.reply(503, {"detail": "Service Unavailable"})
        if url.path == "/api/stale-resume":
            # The next opening of this chat is answered late: its turn's end comes first, then
            # a snapshot taken before that end, holding an approval another app has answered.
            # With `keep=1` the approval is still asked, in every opening.
            chat = query.get("chat", ["chat-garden"])[0]
            STALE_RESUME.add(chat)
            if query.get("keep", ["0"])[0] == "1":
                STILL_ASKED.add(chat)
            # With `failrecheck=1` the two openings after it are refused, and before the first
            # refusal another turn of that chat ends.
            if query.get("failrecheck", ["0"])[0] == "1":
                FAIL_RESUMES[chat] = 2
            return self.reply(200, {"stale": True})
        if url.path == "/api/let-go":
            # Every open chat let go of, as a gateway closes idle ones: no app hears what is
            # asked in them until it opens them again.
            OPEN.clear()
            return self.reply(200, {"let_go": True})
        if url.path == "/api/ask":
            # Runs a routine-like turn in a bot's chat that asks the requested question, even
            # when no app has opened that chat yet. `push=1` also sends the frame directly to
            # connected sockets so tests can exercise unclaimed live frames.
            bot_name = query.get("bot", ["garden"])[0]
            kind = query.get("kind", ["approve"])[0]
            push = query.get("push", ["0"])[0] == "1"
            short = query.get("short", ["0"])[0] == "1"
            replace = query.get("replace", ["0"])[0] == "1"
            # `fresh=1`: the bot's chat is brand new under an id no app has read yet.
            fresh = query.get("fresh", ["0"])[0] == "1"
            row = next((r for r in BOTS if r["name"] == bot_name), None)
            if row is None:
                return self.reply(404, {"detail": "Bot not found"})
            if replace:
                # Simulates chat compaction / canonical session replacement under a fresh id.
                old = (row.get("canonical_session") or {}).get("id") or "chat-" + bot_name
                chat_id = f"chat-{bot_name}-{next(ROW_IDS)}"
                CHATS[chat_id] = list(CHATS.get(old, []))
                row["canonical_session"] = {"id": old, "resolved_id": chat_id, "title": "Bot Chat", "preview": "", "last_active": time.time(), "message_count": len(CHATS[chat_id])}
            elif fresh:
                chat_id = f"chat-{bot_name}-{next(ROW_IDS)}"
                CHATS[chat_id] = []
                row["canonical_session"] = {"id": chat_id, "title": "Bot Chat", "preview": "", "last_active": time.time(), "message_count": 0}
            else:
                chat_id = (row.get("canonical_session") or {}).get("resolved_id") or (row.get("canonical_session") or {}).get("id") or "chat-" + bot_name
                rows = CHATS.setdefault(chat_id, [])
                if not row.get("canonical_session"):
                    row["canonical_session"] = {"id": chat_id, "title": "Bot Chat", "preview": "", "last_active": time.time(), "message_count": len(rows)}
            text = f"ask me {kind} quick" + (" short" if short else "")
            self.start_routine_ask(chat_id, row, text, push=push)
            return self.reply(200, {"started": True, "bot": bot_name, "chat_id": chat_id})
        if url.path == "/api/status":
            return self.reply(200, {"version": VERSION, "auth_required": True, "auth_providers": ["session-token"], "interrupts": INTERRUPTS, "refreshes": REFRESHES, "order": ORDER, "answers": ANSWERS, "open_requests": len(REQUESTS), "resumes": RESUMES})
        if url.path == "/api/auth/providers":
            # Like a real gateway that takes only a token: no ways of signing in are listed.
            return self.reply(200, {"providers": []})
        if url.path == "/api/ws":
            if BUSY_MODE == "tickets":
                # Hermes on the same Mac: no token, a pass named as a second protocol.
                named = [name.strip() for name in headers.get("sec-websocket-protocol", "").split(",")]
                passes = [name.removeprefix("hermes-gateway-ticket.") for name in named if name.startswith("hermes-gateway-ticket.")]
                # A token sent as well is refused, so a test would notice one being sent.
                if "token" in query or "hermes-gateway-v1" not in named or len(passes) != 1 or not self.takes(passes[0], "interactive", ""):
                    return self.reply(401, {"detail": "Unauthorized"})
                return self.socket(headers, protocol="hermes-gateway-v1")
            if query.get("token") != [TOKEN]:
                return self.reply(401, {"detail": "Unauthorized"})
            return self.socket(headers)
        if BUSY_MODE == "tickets":
            if "x-hermes-session-token" in headers or not self.takes(headers.get("x-hermes-gateway-ticket", ""), "native-http", query.get("profile", [""])[0]):
                return self.reply(401, {"detail": "Unauthorized"})
        elif headers.get("x-hermes-session-token") != TOKEN:
            return self.reply(401, {"detail": "Unauthorized"})
        self.read(url)

    def read(self, url):
        """What an authorised HTTP read gets."""
        parts = [unquote(part) for part in url.path.strip("/").split("/")]
        if len(parts) == 4 and parts[:2] == ["api", "sessions"] and parts[3] == "messages" and parts[2] in CHATS:
            return self.reply(200, {"session_id": parts[2], "messages": CHATS[parts[2]]})
        if url.path == "/api/fs/download":
            # Files a bot hands over with MEDIA:, made up here. Asked for by bot, and by
            # chat when one is named, as the real route is.
            asked = parse_qs(url.query)
            wanted = asked.get("path", [""])[0]
            if "profile" not in asked:
                return self.reply(400, {"detail": "No profile"})
            if "session_id" in asked and asked["session_id"][0] not in CHATS:
                return self.reply(404, {"detail": "Session not found"})
            if wanted == "/demo/kept.env":
                return self.reply(403, {"detail": "Path is outside the managed read boundary"})
            if wanted.split("?")[0] == "/demo/endless.bin":
                # Really endless: pieces are sent until the client goes away, with no size said.
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
                try:
                    while True:
                        self.wfile.write(b"x" * 10_000)
                        self.wfile.flush()
                        time.sleep(0.005)
                except OSError:
                    pass
                return
            if wanted == "/demo/streamed.bin":
                # Finite, but sent without saying how large it is, a piece at a time.
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
                for _ in range(20):
                    self.wfile.write(b"x" * 10_000)
                    self.wfile.flush()
                    time.sleep(0.005)
                return
            if wanted == "/demo/charts/slow.js":
                # A file beside a page that takes its time.
                time.sleep(3)
                return self.reply(404, {"detail": "File not found"})
            if wanted not in FILES:
                return self.reply(404, {"detail": "File not found"})
            kind, data = FILES[wanted]
            name = wanted.rsplit("/", 1)[-1]
            self.wfile.write(f"HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\nContent-Disposition: attachment; filename=\"{name}\"\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
            return
        self.reply(404, {"detail": "Not found"})

    def new_session(self):
        """A new pair of tokens, lasting SESSION_LASTS seconds."""
        number = len(ACCESS_TOKENS) + 1
        access, refresh = f"access-{number}-{time.time()}", f"refresh-{number}-{time.time()}"
        ACCESS_TOKENS[access] = time.time() + abs(SESSION_LASTS)
        REFRESH_TOKENS.add(refresh)
        # A length given as less than nothing is kept to all the same, while the app is
        # told the token lasts half a day: a gateway whose clock is ahead of the Mac's.
        said = ACCESS_TOKENS[access] if SESSION_LASTS > 0 else time.time() + 43200
        return {"access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_at": said, "provider": "basic", "user_id": "tester"}

    def takes(self, ticket, purpose, profile):
        """A pass from the pretend hermes command: right purpose, right bot, never used before."""
        parts = ticket.split(".")
        if len(parts) != 4 or parts[0] != "pass" or parts[1] != purpose or ticket in USED_PASSES:
            return False
        if purpose == "native-http" and parts[2] != profile:
            return False
        USED_PASSES.add(ticket)
        return True

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.wfile.write(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)

    def socket(self, headers, protocol=None):
        self.writing = threading.Lock()
        chosen = f"Sec-WebSocket-Protocol: {protocol}\r\n" if protocol else ""
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.wfile.write(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n{chosen}\r\n".encode())
        # "authority": chats go through the gateway's session authority, as on a gateway that
        # hosts its own listener.
        ready = {"session_authority": True} if BUSY_MODE == "authority" else {}
        # "+late-ready" after a mode: the greeting comes a moment after the connection opens.
        if LATE_READY:
            time.sleep(LATE_READY)
        self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": ready}})
        SOCKETS.add(self)
        while True:
            head = self.rfile.read(2)
            if len(head) < 2 or head[0] & 0x0F == 8:
                SOCKETS.discard(self)
                return
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4)
            data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(self.rfile.read(length)))
            if head[0] & 0x0F == 9:  # ping
                self.wfile.write(bytes([0x8A, len(data)]) + data)
            if head[0] & 0x0F != 1:
                continue
            frame = json.loads(data)
            if "method" not in frame and isinstance(frame.get("id"), str) and ("result" in frame or "error" in frame):
                # An app answering one of our questions.
                entry = REQUESTS.get(frame["id"])
                if entry is not None and entry["kind"] == "request" and not entry["event"].is_set():
                    entry["result"] = frame.get("result") if "error" not in frame else {"error": frame["error"]}
                    entry["event"].set()
                elif entry is None and frame["id"].startswith("srq-auto-"):
                    note_answer(AUTO.pop(frame["id"], "?"), frame.get("result") if "error" not in frame else {"error": frame["error"]})
                continue
            method, params = frame.get("method"), frame.get("params") or {}
            chat_id = str(params.get("session_id", "")).removeprefix("live-")
            if method == "profiles.list":
                if getattr(self, "fail_lists", False):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5001, "message": "could not list profiles"}})
                elif BUSY_MODE == "approvals-stale-bookend" and getattr(self, "read_approvals", False):
                    # Holds the post-readback list snapshot while a newer refresh can overtake it.
                    self.read_approvals = False
                    snapshot = list(BOTS)
                    threading.Thread(target=lambda frame=frame, snapshot=snapshot: (time.sleep(0.8), self.result(frame, {"profiles": snapshot})), daemon=True).start()
                else:
                    self.result(frame, {"profiles": BOTS})
            elif method == "client.capabilities":
                self.answers = bool(params.get("server_requests"))
                self.result(frame, {"server_requests": ["approval", "clarify", "secret", "sudo"], "declines_not_shown": True, "canonical_clarify_batch": True})
            elif method == "session.active_list":
                # The chats whose bots are at work: waiting on a person when a question is open.
                rows = []
                for chat_id, lock in BUSY.items():
                    if not lock.locked():
                        continue
                    # The session authority lists one bot's chats: the one named, else the main bot's.
                    owner = next((row["name"] for row in BOTS if chat_id in ((row.get("canonical_session") or {}).get("id"), (row.get("canonical_session") or {}).get("resolved_id"))), "default")
                    if BUSY_MODE == "authority" and owner != (params.get("profile") or "default"):
                        continue
                    asking = any(e["chat"] == chat_id and not e["event"].is_set() for e in REQUESTS.values()) \
                        or any(c["chat"] == chat_id and not c["op"].get("settled") for c in CONNECTIONS.values())
                    rows.append({"id": "live-" + chat_id, "session_key": chat_id, "status": "waiting" if asking else "working", "title": "Bot Chat"})
                if BUSY_MODE == "active-slow":
                    # "active-slow": the list is as it was when asked, and comes 4 s later, so
                    # more can happen meanwhile; the connection is not held up for it.
                    threading.Thread(target=lambda frame=frame, rows=rows: (time.sleep(4), self.result(frame, {"sessions": rows})), daemon=True).start()
                else:
                    self.result(frame, {"sessions": rows})
            elif method in ("connection.respond", "connectors.connect", "connectors.operation.status"):
                owner = params.get("owner") or {}
                if method != "connectors.connect":
                    card = CONNECTIONS.get(params.get("op_id"))
                else:
                    card = next((c for c in CONNECTIONS.values() if "live-" + c["chat"] == owner.get("session_id") and not c["op"].get("settled")), None)
                if card is None or card["op"].get("settled") or owner.get("session_id") != "live-" + card["chat"]:
                    # As the real gateway: a closed or unknown operation is UNKNOWN_OPERATION.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {
                        "code": 4004, "message": "No open operation with that op_id.", "data": {"reason": "UNKNOWN_OPERATION"}
                    }})
                    continue
                if method == "connectors.operation.status":
                    self.result(frame, connection_view(card["op"]))
                    continue
                if method == "connectors.connect":
                    refusal = self.connection_retry(card, params.get("connectors") or [], params.get("reconnect"))
                    if refusal:
                        code, reason, message = refusal
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {
                            "code": code, "message": message, "data": {"reason": reason}
                        }})
                    else:
                        self.result(frame, connection_view(card["op"]))
                    continue
                settled = self.connection_respond(card, params.get("result") or {})
                self.result(frame, {"status": "ok", "settled": settled})
            elif method == "clarify.lock":
                # One answer of a set, locked before the rest; the set's own answer comes later.
                entry = REQUESTS.get(params.get("request_id"))
                if entry is None or entry["method"] != "clarify":
                    self.result(frame, {"status": "expired"})
                else:
                    ANSWERS.append({"method": "clarify.lock", "question": params.get("question_id"), "answer": params.get("answer")})
                    self.result(frame, {"status": "ok", "remaining": []})
            elif method in ("approval.respond", "clarify.respond") and BUSY_MODE == "authority":
                entry = REQUESTS.get(params.get("prompt_id"))
                field = "choice" if method == "approval.respond" else "answer"
                if entry is None or entry["kind"] != "prompt":
                    self.result(frame, {"status": "already_resolved", "prompt_id": params.get("prompt_id")})
                elif params.get("execution_generation") != entry["generation"] or field not in params:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4001, "message": "invalid_params"}})
                else:
                    entry["result"] = {field: params[field]}
                    # As the real session authority does: the prompt is published as settled
                    # while the answer is handled, before the reply to it goes out.
                    entry["settled"] = True
                    entry["emit"](entry["method"] + ".settled", {"prompt_id": entry["id"], "execution_generation": GENERATION})
                    entry["event"].set()
                    self.result(frame, {"status": "resolved", "prompt_id": params["prompt_id"]})
            elif method in ("profiles.configure", "cli.exec") and BUSY_MODE == "no-edits":
                # A gateway that lists bots but cannot change or delete them.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
            elif method == "profiles.describe" and BUSY_MODE != "no-describe":
                row = next((row for row in BOTS if row["name"] == params.get("name")), None)
                if row is None:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4004, "message": "profile not found"}})
                else:
                    kept = PERSONALITY.get(row["name"], {"description": "", "soul": ""})
                    self.result(frame, {"name": row["name"], "description": kept["description"], "soul": kept["soul"],
                                        "model": {"provider": "demo", "default": "demo-model"}, "skills": [], "toolsets": [], "mcp_servers": []})
            elif method == "session.stats" and chat_id in CHATS and BUSY_MODE == "authority":
                # The session authority's own name for it, with the counts named as it names them.
                calls, tokens = USAGE.get(chat_id, [0, 0])
                used = min(200000, 61000 + 3500 * calls) if calls else 0
                self.result(frame, {"api_calls": calls, "total_tokens": tokens, "input_tokens": tokens - 400 * calls, "output_tokens": 400 * calls,
                                    "context_tokens": used, "context_length": 200000, "last_prompt_tokens": used, "model": "demo-model", "provider": "demo"})
            elif method == "session.usage" and chat_id in CHATS and BUSY_MODE not in ("no-usage", "authority"):
                calls, tokens = USAGE.get(chat_id, [0, 0])
                if calls == 0:
                    # As the real gateway does before the agent has called the model.
                    self.result(frame, {"model": "demo-model", "calls": 0, "input": 0, "output": 0, "total": 0, "context_max": 200000})
                else:
                    used = min(200000, 61000 + 3500 * calls)
                    self.result(frame, {"model": "demo-model", "calls": calls, "input": tokens - 400 * calls, "output": 400 * calls, "total": tokens,
                                        "context_used": used, "context_max": 200000, "context_percent": round(used / 2000)})
            elif method == "cli.exec" and (params.get("argv") or [])[2:4] == ["sessions", "refresh-prompts"]:
                argv = params["argv"]
                if BUSY_MODE == "no-refresh":
                    self.result(frame, {"blocked": False, "code": 2, "output": "hermes: error: invalid choice: 'refresh-prompts'\n"})
                else:
                    def refreshed(frame=frame, argv=argv):
                        # "slow-refresh": the command takes a while, as a real one starting Python does.
                        if BUSY_MODE == "slow-refresh":
                            time.sleep(1)
                        REFRESHES.append(f"{argv[1]} {argv[5]}")
                        ORDER.append("refresh")
                        self.result(frame, {"blocked": False, "code": 0, "output": json.dumps({"epoch": len(REFRESHES), "session_id": argv[5], "sessions": 1})})
                    threading.Thread(target=refreshed, daemon=True).start()
            elif method == "cron.manage":
                jobs = ROUTINES.get(params.get("profile"), [])
                self.result(frame, {"success": True, "jobs": jobs, "count": len(jobs), "scoped": params.get("profile")})
            elif method == "cli.exec":
                argv = params.get("argv") or []
                row = next((row for row in BOTS if argv[:2] == ["profile", "delete"] and len(argv) > 2 and row["name"] == argv[2]), None)
                if row is None or row["is_default"]:
                    self.result(frame, {"blocked": False, "code": 1, "output": "No such profile, or it is the default one.\n"})
                else:
                    BOTS.remove(row)
                    CHATS.pop((row.get("canonical_session") or {}).get("id"), None)
                    if BUSY_MODE == "untidy-delete":
                        # As a real gateway did: the bot is gone, but clearing up after it failed.
                        self.result(frame, {"blocked": False, "code": 1, "output": "Profile: x\n\nThis will permanently delete:\n  everything\nError: Could not remove profile directory: Directory not empty.\n\ninstall out of sync\n"})
                    elif BUSY_MODE == "approvals-uncertain-delete":
                        # Uncertain delete followed by failing profiles.list while socket stays open.
                        self.fail_lists = True
                        self.result(frame, {"blocked": False, "code": 1, "output": "Error: cleanup timed out\n"})
                    else:
                        self.result(frame, {"blocked": False, "code": 0, "output": "Deleted.\n"})
            elif method == "profiles.create" and BUSY_MODE == "no-bots":
                # A gateway that cannot make bots, to see the app stop offering to.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
            elif method == "profiles.create":
                name = str(params.get("name", ""))
                if not name or any(row["name"] == name for row in BOTS):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4000, "message": f"Profile {name!r} already exists"}})
                else:
                    BOTS.append({"name": name, "is_default": False, "model": "orbit-mini", "provider": "northwind", "description": "", "display_name": "", "ui_meta": {}})
                    # As Hermes does (hermes_cli/config_defaults.py), a new bot starts at the default mode.
                    APPROVAL_MODES[name] = "smart"
                    self.result(frame, {"ok": True, "name": name, "path": "/pretend/" + name, "mirrored": {}})
            elif method in ("model.options", "config.get", "config.set") and BUSY_MODE == "no-models":
                # A gateway that cannot list models or read a bot's settings.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
            elif method == "model.options":
                # "unscoped": as Hermes before 0.21.6, the main bot's model whichever is named.
                asked = "default" if BUSY_MODE == "unscoped" else (params.get("profile") or "default")
                row = next((row for row in BOTS if row["name"] == asked), None)
                current = {"model": row["model"], "provider": row["provider"]} if row else {}
                self.result(frame, {"providers": PROVIDERS, **current})
            elif method in ("config.get", "config.set") and BUSY_MODE != "unscoped" and params.get("profile") \
                    and not any(row["name"] == params["profile"] for row in BOTS):
                # A bot that is not there is refused, as Hermes since 0.21.6 does.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4064, "message": f"Profile '{params['profile']}' does not exist."}})
            elif method == "config.get" and params.get("key") == "reasoning":
                # "unscoped": as Hermes before 0.21.6, which takes no notice of the bot named.
                name = "default" if BUSY_MODE == "unscoped" else params.get("profile") or "default"
                self.result(frame, {"value": REASONING.get(name, "medium"), "display": "show"})
            elif method == "config.set" and params.get("key") == "reasoning":
                name, value = params.get("profile") or "default", str(params.get("value", "")).lower()
                if BUSY_MODE == "unscoped":
                    name = "default"
                if name in MANAGED:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4030, "message": "Cannot set 'agent.reasoning_effort': it is managed by your administrator (/etc/hermes/managed.yaml) and cannot be changed. Contact your administrator to modify it."}})
                elif value not in ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": f"unknown reasoning value: {value}"}})
                else:
                    REASONING[name] = value
                    self.result(frame, {"key": "reasoning", "value": value})
            elif method in ("config.get", "config.set") and params.get("key") == "approvals.mode" and BUSY_MODE == "no-config":
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "unknown config key: approvals.mode"}})
            elif method == "config.get" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-readback-fails" and APPROVAL_MODES:
                # "approvals-readback-fails": a change goes through, and reading it back then fails.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5001, "message": "could not read config"}})
            elif method == "config.get" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-readback-unsupported" and APPROVAL_MODES:
                # "approvals-readback-unsupported": a change goes through, and reading it back is refused as unsupported.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "unknown config key: approvals.mode"}})
            elif method == "config.set" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-set-refused":
                # "approvals-set-refused": every change of it is refused, as a pinned key is.
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4030, "message": "approvals.mode is managed"}})
            elif method == "config.set" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-drop-on-set":
                # "approvals-drop-on-set": the first write drops the socket before answering.
                ANSWERS.append({"method": "config.set", "profile": params.get("profile") or "default", "value": params.get("value")})
                SOCKETS.discard(self)
                return
            elif method == "config.set" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-hang-on-set":
                # "approvals-hang-on-set": never answers config.set, so a client's timeout fires.
                ANSWERS.append({"method": "config.set", "profile": params.get("profile") or "default", "value": params.get("value")})
                continue
            elif method == "config.set" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-refuse-then-hang":
                # "approvals-refuse-then-hang": the first write is refused as a pinned key is, and
                # every later one is never answered, so a change stops after a refusal.
                APPROVALS_HUNG.append(True)
                if len(APPROVALS_HUNG) == 1:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4030, "message": "approvals.mode is managed"}})
                continue
            elif method == "config.get" and params.get("key") == "approvals.mode" and BUSY_MODE == "approvals-hang-once" and not APPROVALS_HUNG:
                # "approvals-hang-once": the first reading of it is never answered, as a gateway
                # that passes out for a moment; every later one is.
                APPROVALS_HUNG.append(True)
                continue
            elif method in ("config.get", "config.set") and params.get("key") == "approvals.mode":
                name = "default" if BUSY_MODE == "unscoped" else (params.get("profile") or "default")
                if BUSY_MODE == "approvals-slow":
                    # "approvals-slow": each reading or change pauses, so another can come meanwhile.
                    time.sleep(0.5)
                if method == "config.set":
                    if params.get("value") not in ("manual", "smart", "off"):
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "unknown approval mode"}})
                        continue
                    APPROVAL_MODES[name] = params["value"]
                    if BUSY_MODE == "approvals-slow":
                        # Which writes came, in order, so a test can tell none was made twice or out of turn.
                        ANSWERS.append({"method": "config.set", "profile": name, "value": params["value"]})
                elif BUSY_MODE == "approvals-stale-bookend":
                    self.read_approvals = True
                self.result(frame, {"key": "approvals.mode", "value": APPROVAL_MODES.get(name, "manual")})
            elif method == "profiles.configure":
                row = next((row for row in BOTS if row["name"] == params.get("name")), None)
                if row is None:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4004, "message": "profile not found"}})
                elif BUSY_MODE == "not-kept":
                    # A gateway that answers but says it kept none of it, as a real one can.
                    self.result(frame, {"ok": True, "applied": {"ui_meta": False}})
                else:
                    applied = {}
                    # Merged key by key, as the real gateway does: one app's key leaves another's alone.
                    if isinstance(params.get("ui_meta"), dict):
                        row["ui_meta"].update(params["ui_meta"])
                    model, provider = params.get("model"), params.get("provider")
                    if model and provider:
                        known = any(p["slug"] == provider and p.get("authenticated") and model in p["models"] for p in PROVIDERS)
                        if (provider, model) == COSTLY and not params.get("confirm_expensive_model"):
                            self.result(frame, {"ok": True, "applied": applied, "confirm_required": True,
                                                "confirm_message": "Orbit Max costs about five times as much per reply as Orbit Mini."})
                            continue
                        if known:
                            row["model"], row["provider"] = model, provider
                        applied["model"] = known
                    kept = PERSONALITY.setdefault(row["name"], {"description": "", "soul": ""})
                    for part in ("description", "soul"):
                        if isinstance(params.get(part), str):
                            # "unsaved": a gateway that answers success having saved nothing, as
                            # the real one does when it could not write the file.
                            applied[part] = BUSY_MODE != "unsaved"
                            if applied[part]:
                                kept[part] = params[part].strip() if part == "description" else params[part]
                                if part == "description":
                                    row["description"] = kept[part]
                    self.result(frame, {"ok": all(applied.values()), "applied": applied})
            elif method == "session.create":
                row = next((row for row in BOTS if row["name"] == params.get("profile")), None)
                if row is None:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4004, "message": "profile not found"}})
                elif row.get("canonical_session"):
                    # One chat per bot under the one title; a second is refused when it is titled.
                    self.pending_title_refusal = True
                    self.result(frame, {"session_id": "live-stray", "stored_session_id": "stray", "message_count": 0, "messages": []})
                else:
                    new_id = "chat-" + row["name"]
                    CHATS[new_id] = []
                    row["canonical_session"] = {"id": new_id, "title": params.get("title") or "", "preview": "", "last_active": time.time(), "message_count": 0}
                    OPEN.setdefault(new_id, set()).add(self)
                    self.result(frame, {"session_id": "live-" + new_id, "stored_session_id": new_id, "message_count": 0, "messages": []})
            elif method == "session.title":
                if getattr(self, "pending_title_refusal", False):
                    self.pending_title_refusal = False
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4000, "message": "title already in use"}})
                else:
                    self.result(frame, {"ok": True})
            elif method == "session.resume" and chat_id in CHATS and FAIL_RESUMES.get(chat_id, 0) > 0 and chat_id not in STALE_RESUME:
                RESUMES[chat_id] = RESUMES.get(chat_id, 0) + 1
                if FAIL_RESUMES[chat_id] == 2:
                    self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "message.complete", "session_id": "live-" + chat_id, "payload": {"text": "", "status": "complete"}}})
                FAIL_RESUMES[chat_id] -= 1
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5000, "message": "busy"}})
            elif method == "session.resume" and chat_id in CHATS:
                OPEN.setdefault(chat_id, set()).add(self)
                waiting = [entry for entry in REQUESTS.values() if entry["chat"] == chat_id and not entry["event"].is_set()]
                reply = {"session_id": "live-" + chat_id, "message_count": len(CHATS[chat_id]), "messages": [], "running": chat_id in BUSY and BUSY[chat_id].locked(),
                         "revision": REVISION.get(chat_id, 0), "execution_generation": GENERATION,
                         "open_requests": [{"id": e["id"], "method": e["method"], "params": e["params"]} for e in waiting if e["kind"] == "request"]}
                if BUSY_MODE == "authority":
                    reply.update(prompts=[e["prompt"] for e in waiting if e["kind"] == "prompt"])
                card = next((c for c in CONNECTIONS.values() if c["chat"] == chat_id and not c["op"].get("settled")), None)
                if card is not None:
                    reply["pending_connection"] = connection_request_payload(card["op"])
                RESUMES[chat_id] = RESUMES.get(chat_id, 0) + 1
                stale = {"id": "srq-stale", "method": "approval", "params": {"session_id": "live-" + chat_id, "request_id": "a-stale", "command": "echo answered elsewhere"}}
                if chat_id in STALE_RESUME:
                    STALE_RESUME.discard(chat_id)
                    self.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "message.complete", "session_id": "live-" + chat_id, "payload": {"text": "", "status": "complete"}}})
                    reply["open_requests"] = reply["open_requests"] + [stale]
                elif chat_id in STILL_ASKED:
                    reply["open_requests"] = reply["open_requests"] + [stale]
                self.result(frame, reply)
            elif method == "image.attach_bytes" and chat_id in CHATS:
                # A picture queued for the next message in this chat, as the real gateway does.
                if BUSY_MODE == "no-attachments":
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
                    continue
                data = base64.b64decode(params.get("content_base64", ""))
                if len(data) > 25 * 1024 * 1024:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4013, "message": "image too large"}})
                    continue
                number = len(FILES) + 1
                if BUSY_MODE == "authority":
                    # Only held, as the session authority does: nothing waits in the chat. Its
                    # kind is by the name's ending, and a BMP is not one it takes.
                    ending = str(params.get("filename", "")).rsplit(".", 1)[-1].lower()
                    kind = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}.get(ending)
                    if kind is None:
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "invalid_params"}})
                        continue
                    path = f"/demo/cache/images/upload_{next(HELD_COUNT)}.{ending}"
                    HELD[path] = (kind, data)
                    self.result(frame, {"attached": True, "path": path, "mime": kind, "name": path.rsplit("/", 1)[-1], "count": 1, "text": f"[User attached image: {path.rsplit('/', 1)[-1]}]"})
                    continue
                path = f"/demo/images/upload_{number}.png"
                FILES[path] = ("image/png", data)
                if "late" in str(params.get("filename", "")):
                    # The connection goes while the gateway is still at work on it, and the
                    # picture is queued only after whoever asks next has been told the count.
                    LATE.setdefault(chat_id, []).append(path)
                    SOCKETS.discard(self)
                    return
                QUEUED.setdefault(chat_id, []).append(path)
                if "lost" in str(params.get("filename", "")):
                    # Taken, but the sender never hears so.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5000, "message": "lost on the way back"}})
                    continue
                self.result(frame, {"attached": True, "path": path, "name": path.rsplit("/", 1)[-1], "count": len(QUEUED[chat_id]), "text": f"[User attached image: upload_{number}.png]"})
            elif method == "image.detach" and chat_id in CHATS:
                if BUSY_MODE in ("no-attachments", "authority"):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
                    continue
                def detach(frame=frame, params=params, chat_id=chat_id):
                    before = len(QUEUED.get(chat_id, []))
                    QUEUED[chat_id] = [p for p in QUEUED.get(chat_id, []) if p != params.get("path")]
                    self.result(frame, {"detached": len(QUEUED[chat_id]) != before, "count": len(QUEUED[chat_id])})
                    QUEUED[chat_id] += LATE.pop(chat_id, [])
                # Slowly, and not in turn, when asked: a message sent meanwhile gets ahead.
                if BUSY_MODE == "slow-detach":
                    threading.Timer(0.4, detach).start()
                else:
                    detach()
            elif method == "session.close" and chat_id in CHATS:
                if BUSY_MODE == "no-attachments":
                    # Here nothing waits, so nothing should need the chat closed.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5000, "message": "would not close"}})
                    continue
                # The open chat is gone, and what waited in it. A picture still on its way
                # lands in the closed one, which nobody opens again.
                QUEUED.pop(chat_id, None)
                LATE.pop(chat_id, None)
                self.result(frame, {"closed": True})
            elif method == "file.attach" and chat_id in CHATS:
                # Any other file, put in the chat's workspace; the message then names it.
                name = str(params.get("name", "file"))
                if BUSY_MODE == "no-attachments":
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
                    continue
                if "refuse" in name:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5028, "message": "could not store the file"}})
                    continue
                head, _, body = str(params.get("data_url", "")).partition(",")
                FILES[f"/demo/attachments/{name}"] = (head.removeprefix("data:").split(";")[0] or "application/octet-stream", base64.b64decode(body))
                reference = f"attachments/{name}"
                # In backticks when it has a space in it, as Hermes writes it.
                quoted = f"`{reference}`" if " " in reference else reference
                reply = {"attached": True, "name": name, "path": f"/demo/attachments/{name}", "ref_path": reference, "ref_text": f"@file:{quoted}", "uploaded": True}
                if BUSY_MODE == "slow-attach":
                    # A file that takes a while to go, answered off the reading thread.
                    threading.Thread(target=lambda frame=frame, reply=reply: (time.sleep(1), self.result(frame, reply)), daemon=True).start()
                else:
                    self.result(frame, reply)
            elif method == "prompt.submit" and chat_id in CHATS:
                ORDER.append("submit")
                text = str(params.get("text", ""))
                hidden = params.get("display_kind") == "hidden"
                if "refuse a retry" in text and chat_id in REWOUND and BUSY_MODE == "authority":
                    # Asked again after its cut, and refused: the cut stands, the message is gone.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5000, "message": "the gateway would not take the message"}})
                    continue
                REWOUND.discard(chat_id)
                if "refuse this message" in text:
                    # Refused outright: what was queued for it stays queued, as on the real gateway.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5000, "message": "the gateway would not take the message"}})
                    continue
                truncating = {key for key in params if key.startswith("truncate_before") or key.startswith("confirm_")}
                if truncating and BUSY_MODE == "authority":
                    # The session authority's submit has no such fields; its cut is session.mutate.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "invalid_params"}})
                    continue
                if truncating:
                    if not params.get("confirm_truncate") or "truncate_before_row_id" not in params:
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4029, "message": "truncation parameters require confirm_truncate=true"}})
                        continue
                    if TAKEN.get(chat_id, 0):
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4009, "message": "session busy"}})
                        continue
                    refused = cut(chat_id, params["truncate_before_row_id"], params.get("confirm_empty_truncate"), params.get("confirm_deep_truncate"))
                    if refused:
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": refused})
                        continue
                held = []
                if BUSY_MODE == "authority":
                    # The session authority wants an id on every message, and takes pictures only
                    # as named on it, each held here before and of the kind it was held as.
                    wanted = params.get("attachments")
                    if not params.get("submission_id") or (wanted is not None and (
                            not isinstance(wanted, list) or not wanted or any(
                                not isinstance(item, dict) or set(item) != {"path", "mime"}
                                or HELD.get(item["path"], (None,))[0] != item["mime"] for item in wanted))):
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "invalid_params"}})
                        continue
                    for item in wanted or []:
                        # Kept by its contents somewhere else, as the real one does.
                        kept = f"/demo/native-inputs/{len(FILES) + 1}/{item['path'].rsplit('/', 1)[-1]}"
                        FILES[kept] = HELD.pop(item["path"])
                        held.append(kept)
                # Stored as the real gateway stores it: the words and references, then what
                # it adds for the bot, with where the queued pictures are.
                pictures = QUEUED.pop(chat_id, [])
                if "@file:" in text or pictures or held:
                    import re
                    named = re.findall(r"@file:(?:`[^`]+`|\S+)", text)
                    added = "".join(f"\n\n📄 {ref} (3 tokens)\n```\n(contents)\n```" for ref in named)
                    text += ("\n\n--- Attached Context ---" + added if named else "") + "".join(f"\n@image:{path}" for path in pictures) + "\n[screenshot]" * len(pictures)
                    # The session authority's way: after a gap, a line saying where each is.
                    if held:
                        text += "\n\n" + "\n".join(f"[Image attached at: {path}]" for path in held) + "\n[screenshot]" * len(held)
                self.batch = bool(params.get("clarify_batch"))
                lock = BUSY.setdefault(chat_id, threading.Lock())
                with TURNING:
                    # Decided and recorded in one step, so the bot cannot go idle in between.
                    turning = bool(TAKEN.get(chat_id, 0)) and not params.get("queued") and BUSY_MODE != "queue"
                    if turning:
                        # As the real gateway does by default: the answer under way turns to this.
                        # It is stored when the bot turns to it, after what the bot had said so far.
                        TURNED.setdefault(chat_id, []).append(text)
                if turning:
                    self.result(frame, {"status": "redirected"})
                    continue
                # As the real gateway does: the message is stored when it is taken, not when it runs.
                REVISION[chat_id] = REVISION.get(chat_id, 0) + 1
                CHATS[chat_id].append(user_row(CHATS[chat_id], text, hidden))
                # The session authority answers every message it takes as queued, idle or not.
                status = "queued" if TAKEN.get(chat_id, 0) or BUSY_MODE == "authority" else "streaming"
                TAKEN[chat_id] = TAKEN.get(chat_id, 0) + 1
                threading.Thread(target=self.take, args=(frame, chat_id, text, status, lock, DROPS.get(chat_id, 0), hidden), daemon=True).start()
            elif method == "session.undo" and chat_id in CHATS and BUSY_MODE not in ("authority", "no-rewind"):
                # The gateway's own undo: the person's latest turn and everything after it.
                if TAKEN.get(chat_id, 0):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4009, "message": "session busy — stop the reply first"}})
                    continue
                rows = CHATS[chat_id]
                at = next((i for i in range(len(rows) - 1, -1, -1) if is_persons(rows[i])), None)
                removed = 0 if at is None else len(rows) - at
                if at is not None:
                    del rows[at:]
                    changed(chat_id)
                    tell_all_sessions_changed()
                self.result(frame, {"removed": removed})
            elif method == "session.mutate" and chat_id in CHATS and BUSY_MODE == "authority":
                payload = params.get("payload") or {}
                if params.get("operation") != "rewind" or set(payload) != {"target_message_id"} or not params.get("request_id"):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4002, "message": "invalid_params"}})
                elif params.get("expected_revision") != REVISION.get(chat_id, 0) or params.get("expected_generation") != 7:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4090, "message": "revision_conflict"}})
                elif TAKEN.get(chat_id, 0):
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4009, "message": "session_busy"}})
                else:
                    refused = cut(chat_id, payload["target_message_id"], True, True)
                    if refused:
                        self.send({"jsonrpc": "2.0", "id": frame["id"], "error": refused})
                    else:
                        tell_all_sessions_changed()
                        self.result(frame, {"session_id": params["session_id"], "operation": "rewind", "revision": REVISION[chat_id]})
            elif method == "message.react" and chat_id in CHATS and BUSY_MODE != "no-rewind":
                # One reaction to each author; the same one again takes it off, and none clears it.
                row = next((row for row in CHATS[chat_id] if row["id"] == params.get("row_id")), None)
                if row is None:
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4040, "message": "message not found in this session"}})
                    continue
                author = params.get("author") or "user"
                meta = row.setdefault("display_metadata", {})
                kept = [r for r in meta.get("reactions", []) if r["author"] != author]
                had = next((r["emoji"] for r in meta.get("reactions", []) if r["author"] == author), None)
                emoji = params.get("emoji")
                if emoji and emoji != had:
                    kept.append({"emoji": emoji, "author": author, "at": time.time()})
                meta["reactions"] = kept
                self.result(frame, {"row_id": row["id"], "reactions": kept})
            elif method == "commands.catalog":
                if BUSY_MODE == "no-commands":
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})
                elif BUSY_MODE == "commands-fail":
                    # A list that could not be had just now, as when a skill directory errors.
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 5020, "message": "commands.catalog failed"}})
                else:
                    self.result(frame, {"pairs": [[f"/{name}", about] for name, about in COMMANDS], "categories": [], "skills": {}, "warning": ""})
            elif method == "slash.exec" and chat_id in CHATS:
                if BUSY_MODE == "evicts" and not EVICTED.get(chat_id):
                    # The open chat let go of once, as a gateway closes an idle one.
                    EVICTED[chat_id] = True
                    self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4001, "message": "session not found"}})
                    continue
                self.slash(frame, chat_id, str(params.get("command", "")))
            elif method == "prompt.btw" and chat_id in CHATS:
                question = str(params.get("text", ""))
                task = f"btw-{time.time()}"
                self.result(frame, {"task_id": task})
                said = "error: no model for side questions" if "fail" in question else f"On the side: “{question}”. Nothing was added to the chat."
                event = {"jsonrpc": "2.0", "method": "event", "params": {
                    "type": "btw.complete", "session_id": "live-" + chat_id, "payload": {"task_id": task, "question": question, "text": said}}}
                threading.Timer(0.6, self.send, args=(event,)).start()
            elif method == "config.set" and params.get("key") == "yolo" and chat_id in CHATS:
                on = {"on": True, "off": False}.get(str(params.get("value", "")).lower(), not YOLO.get(chat_id, False))
                YOLO[chat_id] = on
                self.result(frame, {"key": "yolo", "value": "1" if on else "0", "scope": "session"})
            elif method == "session.interrupt" and chat_id in CHATS:
                global INTERRUPTS
                INTERRUPTS += 1
                if TAKEN.get(chat_id, 0):  # with nothing under way there is nothing to stop
                    DROPS[chat_id] = DROPS.get(chat_id, 0) + 1
                    with TURNING:
                        TURNED.pop(chat_id, None)  # a stop also drops what the bot was about to turn to
                    STOPS.setdefault(chat_id, threading.Event()).set()
                self.result(frame, {"ok": True})
            elif method in ("session.resume", "prompt.submit", "session.interrupt"):
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": 4001, "message": "session not found"}})
            else:
                self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32601, "message": "unknown method"}})

    def take(self, frame, chat_id, text, status, lock, drops, hidden=False):
        """Says the message was taken, then answers it once the bot is free."""
        def taken():
            try:
                self.result(frame, {"status": status})
            except OSError:
                pass

        if status == "queued":
            taken()  # at once; the answer waits for the bot to be free
        with lock:
            if status != "queued":
                if "late" in text.lower():
                    time.sleep(1)  # a gateway slow to say it has the message
                taken()
            stopped = STOPS.setdefault(chat_id, threading.Event())
            # As the real gateway does: a stop drops a message that was waiting, without a word.
            try:
                if not (status == "queued" and DROPS.get(chat_id, 0) != drops):
                    self.answer(chat_id, text, stopped, hidden)
                while True:
                    # A message the bot was turned to in its last moments still gets its answer;
                    # the bot is free only when none is left.
                    with TURNING:
                        late = TURNED[chat_id].pop(0) if TURNED.get(chat_id) else None
                        if late is None:
                            TAKEN[chat_id] -= 1
                            break
                    CHATS[chat_id].append(user_row(CHATS[chat_id], late))
                    self.answer(chat_id, late, stopped)
            except BaseException:
                with TURNING:
                    TAKEN[chat_id] -= 1
                raise
            finally:
                if not TAKEN.get(chat_id, 0):
                    stopped.clear()

    def answer(self, chat_id, text, stopped, hidden=False):
        """Plays a bot's turn: a tool or two, then a reply a few words at a time."""
        rows = CHATS[chat_id]
        slow = "slow" in text.lower()
        reply = "Still thinking about that one. " * 12 if slow else f"You said “{text}”. I'm a pretend bot, so that's all I have, but **everything arrived**."
        # Asked in words to change its page: the bot writes the same file again and shows it
        # again in its reply, as a real bot does.
        if not hidden and chat_id == "chat-garden" and "hand me the page file" in text.lower():
            FILES["/demo/yield.html"] = page("Handed over now.")
            reply = "Here is the file.\n\nMEDIA:/demo/yield.html"
        if not hidden and chat_id == "chat-garden" and "add a button" in text.lower():
            FILES["/demo/yield.html"] = page("With a button now.")
            reply = 'Here it is again, with a button.\n\n::preview{file="/demo/yield.html"}'
        # Sent by a page: the bot writes the page again and says only a little.
        if hidden:
            reply = "Done."

        def emit(kind, payload):
            frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": "live-" + chat_id, "payload": payload}}
            dests = list(SOCKETS) if (getattr(self, "_push_unclaimed", False) and kind in ("connection.request", "approval.request", "clarify.request")) else list(OPEN.get(chat_id, ()))
            for socket in dests:
                try:
                    socket.send(frame)
                except OSError:
                    OPEN.get(chat_id, set()).discard(socket)  # that app went away

        emit("message.start", {})
        said, status = "", "complete"
        pause = 0.05 if "quick" in text.lower() else 1.2
        if not stopped.wait(pause):
            emit("tool.start", {"tool_id": "t1", "name": "notes"})
            rows.append({"id": next(ROW_IDS), "role": "assistant", "content": "", "timestamp": time.time(), "tool_calls": [{"function": {"name": "notes", "arguments": "{}"}}]})
        if not stopped.wait(pause):
            emit("tool.complete", {"tool_id": "t1", "name": "notes"})
        lowered = text.lower()
        if "ask me" in lowered and any(word in lowered for word in QUESTION_WORDS):
            heard = self.ask_questions(chat_id, lowered, emit, stopped)
            reply = "Asked, and heard: " + "; ".join(heard) + "."
        words = reply.split(" ")
        turned = None
        while words:
            if stopped.wait(0.25 if slow else 0.06):
                break
            with TURNING:
                turned = TURNED[chat_id].pop(0) if TURNED.get(chat_id) else None
            if turned is not None:
                # Turned to something sent mid-answer. As the real gateway was seen to do: this
                # turn ends where it is, and a fresh one answers the new message.
                break
            word = words.pop(0)
            said += word + " "
            emit("message.delta", {"text": word + " "})
        if stopped.is_set() or turned is not None:
            status = "interrupted"
        elif hidden and chat_id == "chat-garden" and "line" in text.lower():
            # Only the script beside the water chart is written again; the page stays as it was.
            global REDRAWN
            REDRAWN += 1
            FILES["/demo/charts/lib/line.js"] = ("text/javascript", (CHART_SCRIPT + 'window.drawLine = (function (draw) { return function (holder, points) { draw(holder, points); var note = document.createElement("div"); note.textContent = "Drawn again %d"; holder.appendChild(note); }; })(window.drawLine);\n' % REDRAWN).encode())
        elif hidden and chat_id == "chat-garden":
            FILES["/demo/yield.html"] = page(f"Updated for “{text}”.")
        if said.strip():
            rows.append({"id": next(ROW_IDS), "role": "assistant", "content": said.strip(), "timestamp": time.time()})
        for row in BOTS:
            if (row.get("canonical_session") or {}).get("id") == chat_id:
                row["canonical_session"].update(preview=(said.strip() or text)[:80], last_active=time.time(), message_count=len(rows))
        counted = USAGE.setdefault(chat_id, [0, 0])
        counted[0] += 2
        counted[1] += 61000 + 1200 * len(said.split())
        emit("message.complete", {"text": said.strip(), "status": status})
        tell_all_sessions_changed()
        # "then a page" makes a page in the chat talk to the bot after the answer: a hidden
        # turn, which is not the person's, and the bot's answer to it.
        if "then a page" in text.lower() and not stopped.is_set():
            rows.append({"id": next(ROW_IDS), "role": "user", "display_kind": "hidden", "content": "[The page said: the chart was clicked]", "timestamp": time.time()})
            rows.append({"id": next(ROW_IDS), "role": "assistant", "content": "Noted the click on the chart.", "timestamp": time.time()})
            changed(chat_id)
            tell_all_sessions_changed()
        # "nudge garden" makes the Garden bot speak unasked, to see a chat change that
        # is not the one on screen.
        words_sent = text.lower().split()
        if "nudge" in words_sent[:-1]:
            speak_unasked(words_sent[words_sent.index("nudge") + 1])
        if turned is not None and not stopped.is_set():
            rows.append(user_row(rows, turned))
            self.answer(chat_id, turned, stopped)

    def start_routine_ask(self, chat_id, row, text, push=False):
        """Runs a turn in a bot's chat as a routine does, updating the roster and notifying apps."""
        lock = BUSY.setdefault(chat_id, threading.Lock())
        stopped = STOPS.setdefault(chat_id, threading.Event())
        CHATS[chat_id].append(user_row(CHATS[chat_id], "Routine check"))
        row["canonical_session"].update(preview="Routine check", last_active=time.time(), message_count=len(CHATS[chat_id]))
        def run():
            with lock:
                self._push_unclaimed = push
                try:
                    if not push:
                        tell_all_sessions_changed()
                    self.answer(chat_id, text, stopped)
                finally:
                    self._push_unclaimed = False
        threading.Thread(target=run, daemon=True).start()

    def ask(self, chat_id, method, params, wait, emit, stopped, withdraw_after=None):
        """Puts a question to the apps with the chat open and waits for the first answer."""
        rid = "srq-" + uuid.uuid4().hex[:12]
        full = {"session_id": "live-" + chat_id, **params}
        attached = list(OPEN.get(chat_id, ()))
        if getattr(self, "_push_unclaimed", False):
            targets = [s for s in list(SOCKETS) if BUSY_MODE == "authority" or getattr(s, "answers", False)]
        else:
            targets = [s for s in attached if BUSY_MODE == "authority" or getattr(s, "answers", False)]
            if attached and not targets:
                # As the real older route does for an app that never said it answers: no answer, at once.
                ANSWERS.append({"method": method, "result": "unsent"})
                return None
        entry = {"id": rid, "chat": chat_id, "method": method, "params": full, "kind": "request", "event": threading.Event(), "result": None}
        REQUESTS[rid] = entry
        for socket in targets:
            try:
                socket.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": full})
            except OSError:
                pass
        return self.wait_for(entry, wait, emit, stopped, withdraw_after)

    def prompt(self, chat_id, kind, fields, wait, emit, stopped):
        """The session authority's way for leave and single questions: an event, answered by method."""
        pid = "p-" + uuid.uuid4().hex[:10]
        prompt = {"kind": kind, "prompt_id": pid, "execution_generation": GENERATION, "timeout_s": wait, **fields}
        entry = {"id": pid, "chat": chat_id, "method": kind, "params": {}, "prompt": prompt, "kind": "prompt", "event": threading.Event(), "result": None, "generation": GENERATION, "emit": emit}
        REQUESTS[pid] = entry
        emit(kind + ".request", prompt)
        result = self.wait_for(entry, wait, emit, stopped, None)
        if not entry.get("settled"):
            emit(kind + ".settled", {"prompt_id": pid, "execution_generation": GENERATION})
        return result

    def wait_for(self, entry, wait, emit, stopped, withdraw_after):
        deadline = time.time() + (withdraw_after or wait)
        while not entry["event"].wait(0.1):
            if stopped.is_set() or time.time() >= deadline:
                REQUESTS.pop(entry["id"], None)
                if entry["kind"] == "request":
                    reason = "interrupted" if stopped.is_set() else "resolved" if withdraw_after else "timeout"
                    emit("request.cancel", {"id": entry["id"], "method": entry["method"], "reason": reason})
                ANSWERS.append({"method": entry["method"], "result": "unanswered"})
                return None
        REQUESTS.pop(entry["id"], None)
        if entry["kind"] == "request":
            # As the session authority does once someone answered: other apps close the card.
            if BUSY_MODE == "authority":
                emit("request.cancel", {"id": entry["id"], "method": entry["method"], "reason": "resolved"})
            note_answer(entry["method"], entry["result"])
        else:
            ANSWERS.append({"method": entry["method"], "result": entry["result"]})
        return entry["result"]

    def ask_questions(self, chat_id, text, emit, stopped):
        """Plays the questions the message asks for, in turn. Returns what was heard."""
        wait = 4 if "short" in text else 60
        heard = []
        authority = BUSY_MODE == "authority"
        if "approve" in text:
            command, description = "rm -rf /pretend/tmp/build-cache && df -h /pretend", "Clear stale build files before checking disk space"
            if authority:
                got = self.prompt(chat_id, "approval", {"command": command, "description": description, "choices": ["once", "session", "always", "deny"]}, wait, emit, stopped)
            else:
                got = self.ask(chat_id, "approval", {"request_id": "a1", "command": command, "description": description, "allow_permanent": True}, wait, emit, stopped)
            heard.append(f"approval {json.dumps(got)}")
        if "folder" in text and not authority:
            got = self.ask(chat_id, "approval", {"request_id": "a2", "kind": "access", "path": "~/Documents/Pretend", "access": "read_write", "risk": "Can read, edit and delete files in this folder.", "choices": ["once", "session", "always", "deny"]}, wait, emit, stopped)
            heard.append(f"folder {json.dumps(got)}")
        if "site" in text and not authority:
            got = self.ask(chat_id, "approval", {"request_id": "a3", "kind": "network", "host": "api.example.com", "label": "Example API", "risk": "Sends requests to a site not on your allow list.", "choices": ["once", "session", "deny"]}, wait, emit, stopped)
            heard.append(f"site {json.dumps(got)}")
        if "stale" in text:
            got = self.ask(chat_id, "approval", {"request_id": "a4", "command": "echo stale"}, wait, emit, stopped, withdraw_after=2)
            heard.append(f"stale {json.dumps(got)}")
        if "clarify" in text:
            questions = [
                {"qid": "q1", "question": "Which backup should I check first?", "choices": ["Time Machine", "The pretend NAS (Recommended)", "Cloud bucket"], "multi_select": False},
                {"qid": "q2", "question": "What should the check cover?", "choices": ["Disk health", "Containers", "Sync age"], "multi_select": True},
            ]
            if authority and not getattr(self, "batch", False):
                for question in questions:
                    got = self.prompt(chat_id, "clarify", {"question": question["question"], "choices": question["choices"], "multi_select": question["multi_select"]}, wait, emit, stopped)
                    heard.append(f"clarify {json.dumps(got)}")
            else:
                got = self.ask(chat_id, "clarify", {"questions": questions}, wait, emit, stopped)
                heard.append(f"clarify {json.dumps(got)}")
        if "secret" in text:
            got = self.ask(chat_id, "secret", {"env_var": "PRETEND_API_KEY", "prompt": "Paste your pretend weather key so I can fetch forecasts.", "metadata": {}}, wait, emit, stopped)
            value = (got or {}).get("value") if isinstance(got, dict) else None
            heard.append("secret " + ("given" if value else "not given"))
        if "sudo" in text:
            got = self.ask(chat_id, "sudo", {"command": "sudo systemctl restart pretend"}, wait, emit, stopped)
            value = (got or {}).get("value") if isinstance(got, dict) else None
            heard.append("password " + ("given" if value else "not given"))
        if "connect" in text:
            heard.append(self.connection_card(chat_id, text, emit, stopped))
        if "ghost" in text:
            # A question for a chat nobody opened, to every app that answers questions: it should
            # be refused, not left to its deadline.
            rid = "srq-ghost-" + uuid.uuid4().hex[:8]
            entry = {"id": rid, "chat": "ghost", "method": "secret", "params": {}, "kind": "request", "event": threading.Event(), "result": None}
            REQUESTS[rid] = entry
            for socket in [s for s in list(SOCKETS) if getattr(s, "answers", False)]:
                try:
                    socket.send({"jsonrpc": "2.0", "id": rid, "method": "secret", "params": {"session_id": "live-ghost", "env_var": "GHOST", "prompt": "boo"}})
                except OSError:
                    pass
            answered = entry["event"].wait(wait)
            REQUESTS.pop(rid, None)
            ANSWERS.append({"method": "ghost", "result": entry["result"] if answered else "unanswered"})
            heard.append("ghost " + ("answered" if answered else "unanswered"))
        if "bridges" in text:
            for method, params in (("preview.read", {}), ("preview.act", {"action": "click"}), ("terminal.read", {}), ("window.read", {}),
                                   ("tour", {"action": "start"}), ("theme.apply", {"mode": "dark"}), ("theme.pick", {"picker": "accent"}),
                                   ("setup_beat", {"beat": "name", "card": {}}), ("vault.code", {}), ("vault.unlock_prompt", {"backend": "x", "display_name": "X"}),
                                   ("vault.save_login", {"origin": "https://example.com", "site": "Example"}), ("made.up.method", {})):
                got = self.ask(chat_id, method, params, 5, emit, stopped)
                heard.append(f"{method} answered" if got is not None else f"{method} unanswered")
            # And one that belongs to no chat.
            rid = "srq-auto-" + uuid.uuid4().hex[:8]
            AUTO[rid] = "display.install.sudo"
            self.send({"jsonrpc": "2.0", "id": rid, "method": "display.install.sudo", "params": {"session_id": "", "profile_key": "default"}})
        return heard

    def connection_card(self, chat_id, text, emit, stopped):
        """Plays a manage_connections card through Hermes's own states (tools/connectors:
        contract.py, operation.py, mcp.py, managed.py, catalog.py, display.py). Which card comes
        from the words in the message:

        - (none): a hosted app and an MCP server to install. The hosted row arrives `initiated`
          with its link, minted before the card is drawn, and no name of its own; the MCP row
          `pending` with the values it needs, and goes `initiated` (no link) while it installs,
          then `connected`. One missing a required value stays `pending`, saying what it waits for.
        - "signin": the hosted app's sign-in finishes by itself 3 s in, as the watcher sees it.
        - "expire": the hosted app's link runs out 2 s in (`expired`); Try again mints a fresh one.
        - "fail": the hosted app fails 2 s in, keeping its dead link on the row, as Hermes does.
        - "reissuefail": like "fail", and retrying the hosted app is refused with 5034 (`CONNECTOR_REQUEST_FAILED`).
        - "installfail": the MCP install fails, and asks for its values again.
        - "authorize": an MCP server to authorize: its sign-in link is minted before the card
          ("authorizefail": it fails 2 s in, and approving it again mints a fresh link, as
          `_RETRY` does; its name, `calendar.work`, is one `connectors.connect` refuses).
        - "catalog": a catalog plugin and a skill to install ("catalogfail": the plugin fails,
          which counts as resolved for a catalog row).
        - "directory": the directory card, with no rows; only Continue settles it.
        - "launchless": the MCP row comes with no launch line.
        - "short": the card's deadline is 6 s, not 300.
        """
        wait = 6 if "short" in text else 300
        hosted = {"name": "notion", "kind": "connector", "action": "connect", "state": "initiated",
                  "connect_url": "https://auth.example.com/oauth/authorize?client=pretend&attempt=1"}
        if "alias" in text:
            hosted["alias"] = "work"
        filesystem = {"name": "filesystem", "kind": "mcp", "action": "install", "state": "pending",
                      "instructions": "Read and search files inside one allowed folder.",
                      "required_env": [{"name": "ALLOWED_ROOT", "required": True, "secret": False, "default": "/pretend/docs"},
                                       {"name": "FS_INDEX_KEY", "required": True, "secret": True, "default": ""}]}
        if "launchless" not in text:
            filesystem["launch"] = {"kind": "stdio", "target": "npx -y @pretend/server-filesystem /pretend/docs",
                                    "cwd": "/pretend/work", "env": ["ALLOWED_ROOT", "FS_INDEX_KEY"]}
        if "directory" in text:
            targets, display = [], {"suggested": ["notion", "linear"]}
        elif "catalog" in text:
            display = None
            targets = [
                {"name": "pretend-charts", "kind": "plugin", "action": "install", "state": "pending", "display": "Pretend Charts",
                 "description": "Draws charts from tables.", "tier": "verified", "repo": "github.com/pretend/charts",
                 "sha": "0123456789abcdef0123456789abcdef01234567", "subdir": "plugin", "target_profile": "default",
                 "platforms": ["macos", "linux"], "requires_hermes": ">=0.20", "has_desktop_half": False, "app_state": "unknown",
                 "required_env": [{"name": "CHARTS_TOKEN", "required": False, "secret": True, "default": ""}]},
                {"name": "@pretend/notes-skill", "kind": "skill", "action": "install", "state": "pending", "display": "Notes",
                 "description": "Keeps tidy notes.", "tier": "community", "target_profile": "default"},
            ]
        elif "authorize" in text:
            display = None
            targets = [{"name": "calendar.work", "kind": "mcp", "action": "authorize", "state": "initiated",
                        "connect_url": "https://auth.example.com/mcp/authorize?server=calendar&attempt=1",
                        "launch": {"kind": "remote", "target": "https://mcp.example.com/calendar"}}]
        else:
            display = None
            targets = [hosted, filesystem]
        op = {"op_id": "op-" + uuid.uuid4().hex[:10], "seq": 1 if targets and targets[0]["state"] == "initiated" else 0,
              "deadline_at": time.time() + wait, "settled_at": None, "settled_by": None, "targets": targets}
        card = {"chat": chat_id, "op": op, "event": threading.Event(), "emit": emit, "display": display, "text": text,
                "lock": threading.Lock(), "approved_env": {}}
        CONNECTIONS[op["op_id"]] = card
        emit("connection.request", connection_request_payload(op, display))
        def later(delay, step):
            def run():
                time.sleep(delay)
                with card["lock"]:
                    if not op.get("settled"):
                        step()
            threading.Thread(target=run, daemon=True).start()
        if targets and targets[0]["kind"] == "mcp" and targets[0]["action"] == "authorize" and "authorizefail" in text:
            row = targets[0]
            later(2, lambda: row["state"] == "initiated" and self.connection_move(card, row, "failed", detail="The authorization was refused."))
        if targets and targets[0]["kind"] == "connector":
            row = targets[0]
            if "signin" in text:
                later(3, lambda: row["state"] == "initiated" and self.connection_move(card, row, "connected", tools=["search_pages", "get_page"]))
            elif "expire" in text:
                later(2, lambda: row["state"] == "initiated" and self.connection_move(card, row, "expired", detail="The sign-in link ran out."))
            elif "fail" in text and "installfail" not in text:
                later(2, lambda: row["state"] == "initiated" and self.connection_move(card, row, "failed", detail="The vendor refused the sign-in."))
        while not card["event"].wait(0.1):
            if stopped.is_set() or time.time() >= op["deadline_at"]:
                with card["lock"]:
                    self.connection_settle(card, "interrupt" if stopped.is_set() else "deadline")
                break
        return "connection " + ", ".join(f"{row['name']} {row['state']}" for row in op["targets"])

    def connection_emit(self, card, change=None):
        """One connection.update: the whole snapshot, as `_connection_update` sends it (no `display`)."""
        payload = {**connection_view(card["op"]), "owner": {"type": "session", "session_id": "live-" + card["chat"]}}
        if change:
            payload.update(change)
        card["emit"]("connection.update", payload)

    def connection_move(self, card, row, to, detail=None, **extra):
        """One transition of one row, as `ConnectionOperation.transition`; settles when all are resolved."""
        change = {"target": row["name"], "from": row["state"], "to": to}
        row["state"] = to
        if detail is not None:
            row["detail"] = detail
        row.update(extra)
        card["op"]["seq"] += 1
        self.connection_emit(card, change)
        if connection_all_resolved(card["op"]):
            self.connection_settle(card, "all_resolved")

    def connection_settle(self, card, by):
        op = card["op"]
        if op.get("settled"):
            return
        for row in op["targets"]:
            if not connection_resolves(row):
                row["state"] = "not_connected"
        op["settled"], op["settled_at"], op["settled_by"] = True, time.time(), by
        op["seq"] += 1
        self.connection_emit(card)
        card["event"].set()

    def connection_start(self, card, row, env):
        """Approve (or Try again) on an MCP or catalog row, as `_start_install` / `approve`."""
        if row["kind"] == "mcp" and row["action"] == "authorize":
            if row["state"] in ("failed", "expired"):
                # `_RETRY` runs `_start_oauth` again: a fresh attempt with a fresh sign-in link.
                attempt = int(row["connect_url"].rsplit("=", 1)[-1]) + 1 if "attempt=" in (row.get("connect_url") or "") else 2
                row["detail"] = ""
                self.connection_move(card, row, "initiated", connect_url=f"https://auth.example.com/mcp/authorize?server=calendar&attempt={attempt}")
            return  # a pending one has nothing to approve: its link is the step (`_nothing`)
        approved = {**card["approved_env"].get(row["name"], {}), **env}
        declared = row.get("declared_env") or row.get("required_env") or []
        missing = [f for f in declared if f.get("required", True) and not approved.get(f["name"])]
        if missing and row["kind"] == "mcp":
            # Stays pending, asking again for what is missing (`operation.refresh`).
            row["required_env"], row["declared_env"] = missing, declared
            row["detail"] = "waiting for " + ", ".join(f["name"] for f in missing)
            card["op"]["seq"] += 1
            self.connection_emit(card)
            return
        card["approved_env"][row["name"]] = approved
        row["declared_env"] = declared
        row["required_env"] = []
        row.pop("detail", None)
        self.connection_move(card, row, "initiated", detail="", **({"phase": "downloading"} if row["kind"] in ("plugin", "skill") else {}))
        fails = ("installfail" in card["text"] and row["kind"] == "mcp") or ("catalogfail" in card["text"] and row["kind"] == "plugin")
        def finish():
            if row["state"] != "initiated":
                return
            row.pop("phase", None)
            if fails:
                # A failed install asks for its fields again (`_fail_install`); a catalog row keeps its reason.
                if row["kind"] == "mcp":
                    row["required_env"] = declared
                self.connection_move(card, row, "failed", detail="The install did not finish: npm could not reach the registry.")
            else:
                self.connection_move(card, row, "connected", tools=["read_file", "list_dir", "search_files"] if row["kind"] == "mcp" else [])
        def run():
            time.sleep(0.8)
            with card["lock"]:
                if not card["op"].get("settled"):
                    finish()
        threading.Thread(target=run, daemon=True).start()

    def connection_respond(self, card, answer):
        """`connection.respond`: skips, approvals and Continue, as `mcp.apply_answer` folds them."""
        heard = {"method": "connection.respond", "moves": {}, "values": []}
        with card["lock"]:
            op = card["op"]
            for move in answer.get("targets") or []:
                row = next((r for r in op["targets"] if r["name"] == move.get("name")), None)
                if row is None or op.get("settled"):
                    continue
                status = move.get("status")
                heard["moves"][row["name"]] = status
                if status == "skipped":
                    if row["state"] not in ("connected", "skipped"):
                        self.connection_move(card, row, "skipped")
                elif status == "approved" and row["kind"] != "connector" and row["state"] in ("pending", "failed", "expired"):
                    env = move.get("env") or {}
                    # Kept only as which names came and whether the secret one was the pretend one.
                    heard["values"] = sorted(env)
                    heard["secret_matches"] = env.get("FS_INDEX_KEY") == PRETEND_SECRET
                    heard["secret_sent"] = "FS_INDEX_KEY" in env
                    if env.get("ref"):
                        heard["ref"] = env["ref"]
                    self.connection_start(card, row, env)
            if op.get("settled"):
                pass
            elif answer.get("settled_by") == "continue" or answer.get("said"):
                self.connection_settle(card, "continue")
            elif connection_all_resolved(op):
                self.connection_settle(card, "all_resolved")
            ANSWERS.append(heard)
            return bool(op.get("settled"))

    def connection_retry(self, card, names, reconnect):
        """`connectors.connect` with `reconnect`: Try again on failed or expired rows (`run.reissue`)."""
        ANSWERS.append({"method": "connectors.connect", "connectors": names, "reconnect": bool(reconnect)})
        if not reconnect:
            return (4000, "INVALID_PARAMS", "Connector parameters are invalid.")
        if any(not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", str(name)) for name in names):
            # The contract's `ConnectorSlug`: an MCP server's name with a dot is refused.
            return (4000, "INVALID_PARAMS", "string_pattern_mismatch: connectors")
        with card["lock"]:
            rows = [next((r for r in card["op"]["targets"] if r["name"] == name), None) for name in names]
            if any(r is None for r in rows):
                return (4004, "UNKNOWN_TARGET", "No such target on the open operation.")
            if any(r["state"] not in ("failed", "expired") for r in rows):
                return (4002, "LINK_STILL_VALID", "Reopen the stored link.")
            if "reissuefail" in card["text"]:
                return (5034, "CONNECTOR_REQUEST_FAILED", "Connector request failed. Try again explicitly.")
            for row in rows:
                if row["kind"] == "connector":
                    attempt = int(row["connect_url"].rsplit("=", 1)[-1]) + 1 if row.get("connect_url") else 2
                    row["detail"] = ""
                    self.connection_move(card, row, "initiated", connect_url=f"https://auth.example.com/oauth/authorize?client=pretend&attempt={attempt}")
                else:
                    self.connection_start(card, row, {})
        return None

    def slash(self, frame, chat_id, command):
        """A slash command, as Hermes's slash.exec answers one: words it printed, or a message
        to send or to put back in the box. Made-up readouts; nothing here is real."""
        name, _, arg = command.strip().lstrip("/").partition(" ")
        name, arg, rows = name.lower(), arg.strip(), CHATS[chat_id]
        def said(text):
            self.result(frame, {"output": text})
        def refuse(code, text):
            self.send({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": code, "message": text}})
        def last_turn():
            """Takes out the last thing the person said and all after it, as Hermes rewinds."""
            at = max((i for i, row in enumerate(rows) if row["role"] == "user"), default=None)
            if at is None:
                return None
            text = rows[at]["content"]
            del rows[at:]
            return text
        busy = bool(TAKEN.get(chat_id, 0))
        readouts = {
            "status": "Session: Bot Chat\nModel: orbit-mini (Northwind)\nReasoning: medium\nApprovals: %s\nMessages: %d" % ("skipped (yolo)" if YOLO.get(chat_id) else APPROVALS.get(chat_id, "manual"), len(rows)),
            "context": "Context window: 128k tokens\n  System prompt   3.1k\n  Messages       12.4k\n  Free          112.5k\nUsed: 12%",
            "usage": "This chat: 18,204 tokens in, 2,911 out\nToday: 41,377 tokens\nRate limit: plenty left",
            "insights": "Last %s days: 12 chats, 148 messages\nBusiest day: Tuesday" % (arg or "30"),
            "skills": "Installed skills:\n  bakery-orders   Places and moves bakery orders\n  garden-planner  Lays out beds",
        }
        if name in readouts:
            return said(readouts[name])
        if name in ("undo", "retry", "compress") and busy:
            return refuse(4009, f"session busy — /{name} waits for the current turn to finish")
        if name == "undo":
            text = last_turn()
            if text is None:
                return refuse(4004, "undo: no user messages to undo")
            tell_all_sessions_changed()
            return self.result(frame, {"type": "prefill", "message": text, "notice": "↶ Undid 1 turn. Edit and resubmit, or send a new message."})
        if name == "retry":
            text = last_turn()
            if text is None:
                return refuse(4018, "no previous user message to retry")
            return self.result(frame, {"type": "send", "message": text})
        if name == "compress":
            return said(f"Compressed {len(rows)} messages into a summary.")
        if name == "fast":
            return said("Fast mode: " + (arg or "on"))
        if name == "personality":
            return said(f"Personality set to {arg}." if arg else "Personalities:\n  concise\n  friendly\n  formal")
        if name == "approvals":
            if arg:
                APPROVALS[chat_id] = arg
                if arg in ("manual", "smart", "off"):
                    owner = next((row["name"] for row in BOTS if (row.get("canonical_session") or {}).get("id") == chat_id), "default")
                    APPROVAL_MODES[owner] = arg
                return said(f"Approval mode set to {arg}.")
            return said(f"Approval mode: {APPROVALS.get(chat_id, 'manual')}")
        if name == "goal":
            if not arg:
                return said("No active goal.")
            return self.result(frame, {"type": "send", "message": f"quick goal: {arg}", "notice": f"⊙ Goal set: {arg}"})
        if name in ("learn", "plan"):
            return self.result(frame, {"type": "send", "message": f"quick {name}: {arg}"})
        if name == "refine":
            return said("Saved 2 lessons to memory.")
        refuse(4018, f"not a quick/plugin/bundle/skill command: {name}")

    def result(self, frame, value):
        self.send({"jsonrpc": "2.0", "id": frame["id"], "result": value})

    def send(self, value):
        data = json.dumps(value).encode()
        head = bytes([0x81]) + (bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack(">H", len(data)) if len(data) < 65536 else bytes([127]) + struct.pack(">Q", len(data)))
        with self.writing:
            self.wfile.write(head + data)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9119
    BUSY_MODE = sys.argv[2] if len(sys.argv) > 2 else "interrupt"
    if BUSY_MODE == "old-hermes":
        VERSION = "v2026.9.21"
    if BUSY_MODE == "approvals-mixed":
        APPROVAL_MODES["garden"] = "smart"
    REDIRECT_TO = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    if BUSY_MODE.endswith("+late-ready"):
        BUSY_MODE, LATE_READY = BUSY_MODE[:-len("+late-ready")], 0.3
    # For the modes that sign in, the extra word is how many seconds a session lasts.
    if BUSY_MODE in ("password", "password-only") and len(sys.argv) > 3:
        SESSION_LASTS = int(sys.argv[3])
    server = Server(("127.0.0.1", port), Handler)
    # Port 0 is the system's choice, which tests use so one cannot collide with a gateway
    # another test has not yet reaped. Say the real one only once it is bound. The tests
    # discard stdout, so they read it from this file instead.
    port = server.server_address[1]
    port_file = os.environ.get("HERMES_PRETEND_PORT_FILE")
    if port_file:
        with open(port_file, "w") as written:
            written.write(str(port))
    print(f"Pretend gateway on http://127.0.0.1:{port}, token: {TOKEN}. Leave this running; Ctrl-C stops it.", flush=True)
    server.serve_forever()
