#!/bin/bash

# The Claude collector's local stats: Claude Code's own transcripts, read
# through a per-file index that only reads what was appended, its
# history.jsonl fallback, and its own filter over pi and opencode sessions
# (the anthropic provider). How the shared pi and opencode readers work, and
# the unused-machine record, are held centrally by the shared and partition
# tests, and the scan cache by the contract check. Claude's limits and plan
# have tests of their own.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox
require_command rg

python3 - <<'PY'
from agent_usage_fixtures import *

STAMP = today_stamp()


def projects():
  return home() / ".claude" / "projects" / "example"


def message(message_id, input=0, output=0, cache_write=0, cache_read=0, model="claude-test", timestamp=STAMP, event=None):
  line = {"timestamp": timestamp, "type": "assistant", "sessionId": "session-1",
          "message": {"id": message_id, "role": "assistant", "model": model,
                      "usage": {"input_tokens": input, "cache_creation_input_tokens": cache_write, "cache_read_input_tokens": cache_read, "output_tokens": output}}}
  if event:
    line["uuid"] = event
  return line


def transcript(*lines, name="session.jsonl", mode="w"):
  path = projects() / name
  path.parent.mkdir(parents=True, exist_ok=True)
  with path.open(mode) as handle:
    for line in lines:
      handle.write(json.dumps(line) + "\n")
  return path


def claude(*args):
  return collect("claude", *(args or ("--force",)))


def rescan():
  return collect("claude", "--cache-seconds", "0")


# ------------------------------------------------------------- transcripts

# A message repeated across events counts once, its token kinds apart, and a
# Claude Code home with usage but no sign-in asks for one.
sandbox()
session = transcript(
  message("message-1", 2, 231, cache_write=28857, event="event-1"),
  message("message-1", 2, 231, cache_write=28857, event="event-2"),
  message("message-2", 2, 390, cache_write=454, cache_read=28857, event="event-3"),
)
record = claude()
expect("Claude counts each API message once, its token kinds kept apart, and asks a signed-out home to sign in", {
  "today": record["todayTotalTokens"], "usage": record["modelUsage"]["claude-test"], "status": record["usageStatusText"],
}, {
  "today": 58793, "usage": {"cacheCreationInputTokens": 29311, "cacheReadInputTokens": 28857, "inputTokens": 4, "outputTokens": 621}, "status": "Waiting for auth",
}, record)

# Transcripts only ever grow, so a refresh reads what was appended since the
# last one and takes the rest from the index.
transcript(message("message-3", 1, 6, cache_read=200, event="event-4"), mode="a")
record = rescan()
expect("Claude picks up lines appended since the last scan", record["todayTotalTokens"], 59000, record)
index = next(iter(cache_root().glob("claude-index-*.json")), None)
check("Claude keeps one record per API message in the index",
      index and len(next(iter(json.loads(index.read_text())["files"].values()))["records"]) == 3, index and index.read_text())

# An unchanged file is not opened again: its records come from the index.
if os.geteuid() != 0:
  session.chmod(0)
  with contextlib.redirect_stderr(io.StringIO()) as err:
    record = rescan()
  session.chmod(0o644)
  # Opening the file would fail and be reported; the index answers first.
  expect("Claude serves an unchanged transcript from the index, never opening it",
         [record["todayTotalTokens"], "unreadable" in err.getvalue()], [59000, False], record)

# A file that shrank was rewritten, not appended to; it is read from the start.
session.write_text(session.read_text().splitlines(keepends=True)[0])
record = rescan()
expect("Claude rereads a transcript that shrank", record["todayTotalTokens"], 29090, record)

# A transcript replaced by a larger one, rewritten in place with more than it
# had, or rewritten at its end or in its middle with both ends matching, is a
# new file rather than an append, read from its start.
sandbox()


def replaced(*lines):
  transcript(*lines, name="session.jsonl.new")
  (projects() / "session.jsonl.new").replace(projects() / "session.jsonl")


transcript(message("old-1", 1000))
rescan()
replaced(message("new-1", 20), message("new-2", 30))
record = rescan()
expect("Claude reads a transcript replaced by a larger one from its start", [record["todayTotalTokens"], record["totalPrompts"]], [50, 2], record)
transcript(message("other-1", 7), message("other-2", 8), message("other-3", 9))
record = rescan()
expect("Claude reads a transcript rewritten in place from its start", [record["todayTotalTokens"], record["totalPrompts"]], [24, 3], record)

transcript(*(message(f"long-{i}", 100) for i in range(1, 61)))
rescan()
transcript(*(message(f"long-{i}", 100) for i in range(1, 60)), message("long-60", 5000), message("long-61", 1))
record = rescan()
expect("Claude rereads a transcript whose end was rewritten in place", record["todayTotalTokens"], 10901, record)

transcript(*(message(f"mid-{i}", 100) for i in range(1, 201)))
rescan()
replaced(*(message(f"mid-{i}", 900 if i == 100 else 100) for i in range(1, 201)), message("mid-201", 1))
record = rescan()
expect("Claude rereads a larger replacement whose ends match", record["todayTotalTokens"], 20801, record)

# The index holds local days, so a new timezone reads every transcript again
# rather than keep the days another one gave them.
zone_stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT01:00:00Z")
transcript(message("zone-1", 5, timestamp=zone_stamp))
saved_tz = os.environ.get("TZ")
try:
  os.environ["TZ"] = "UTC"
  time.tzset()
  rescan()
  os.environ["TZ"] = "America/Los_Angeles"
  time.tzset()
  record = rescan()
  expected_day = datetime.fromisoformat(zone_stamp.replace("Z", "+00:00")).astimezone().date().isoformat()
finally:
  if saved_tz is None:
    os.environ.pop("TZ", None)
  else:
    os.environ["TZ"] = saved_tz
  time.tzset()
expect("Claude recomputes indexed days after a timezone change", record["activeDates"], [expected_day], record)

# A streamed response is several lines under one message id: the first line's
# output is a placeholder, so a message counts from its highest output. One
# that fell back to another model mid-stream keeps its final line whole rather
# than a maximum per field.
sandbox()
transcript(
  message("message-1", 8, 1, cache_write=100, cache_read=2000, event="event-1"),
  message("message-1", 8, 1, cache_write=100, cache_read=2000, event="event-2"),
  message("message-1", 8, 260, cache_write=100, cache_read=2000, event="event-3"),
  message("message-2", 10, 1, cache_write=300, cache_read=4000, event="event-4"),
  message("message-2", 10, 40, cache_read=3500, model="claude-fallback", event="event-5"),
)
record = claude()
expect("Claude counts a streamed message from its final usage line, whole after a fallback", {
  "test": record["modelUsage"]["claude-test"], "fallback": record["modelUsage"]["claude-fallback"], "prompts": record["totalPrompts"],
}, {
  "test": {"cacheCreationInputTokens": 100, "cacheReadInputTokens": 2000, "inputTokens": 8, "outputTokens": 260},
  "fallback": {"cacheCreationInputTokens": 0, "cacheReadInputTokens": 3500, "inputTokens": 10, "outputTokens": 40},
  "prompts": 2,
}, record)

# A stream still being written when the index was taken finishes in lines
# appended later, and the indexed message takes the higher count from them.
rescan()
transcript(message("message-2", 10, 90, cache_read=3500, model="claude-fallback", event="event-6"), mode="a")
record = rescan()
expect("Claude takes a streamed message's final count from appended lines",
       [record["modelUsage"]["claude-fallback"]["outputTokens"], record["totalPrompts"]], [90, 2], record)

# A line of JSON that isn't an object skips that line, never the transcript.
sandbox()
transcript(message("listed-1", 10), [message("listed-x", 99)], message("listed-2", 20))
record = claude()
expect("Claude skips a transcript line that isn't an object and keeps the rest",
       [record["totalPrompts"], record["todayTotalTokens"]], [2, 30], record)

# Only a missing time is today's: a time of 0, false or "" is untrusted and
# counts nowhere.
sandbox()
transcript(message("stamped", 10), *(message(f"falsy-{n}", 99, timestamp=stamp) for n, stamp in enumerate((0, False, ""))))
record = claude()
expect("Claude counts a transcript line with a falsy time nowhere",
       [record["totalPrompts"], record["todayTotalTokens"]], [1, 10], record)

# Unreadable transcripts are expected when an agent ran as another user, so
# they make one bounded warning rather than a line each.
sandbox()
for n in range(1, 6):
  transcript(name=f"unreadable-{n}.jsonl")
module = load_collector("claude")
real_open = Path.open


def deny_unreadable(path, *args, **kwargs):
  if path.name.startswith("unreadable-"):
    raise PermissionError("permission denied")
  return real_open(path, *args, **kwargs)


module.Path.open = deny_unreadable
try:
  with contextlib.redirect_stderr(io.StringIO()) as warnings:
    module.scan_projects(projects().parent)
finally:
  module.Path.open = real_open
lines = [line for line in warnings.getvalue().splitlines() if line.startswith("Ignoring ")]
check("Claude bounds unreadable transcripts to one warning with their count",
      len(lines) == 1 and lines[0].startswith("Ignoring 5 unreadable Claude project files"), warnings.getvalue())

# ---------------------------------------------------------------- sources

# A machine with no transcripts and no stats-cache still gets today's counts
# from history.jsonl.
sandbox()
(home() / ".claude").mkdir()
(home() / ".claude" / "history.jsonl").write_text("".join(json.dumps(line) + "\n" for line in (
  {"timestamp": 86400000, "sessionId": "old", "display": "ancient"},
  {"timestamp": ms_in(0), "sessionId": "s1", "display": "one"},
  {"timestamp": ms_in(0), "sessionId": "s2", "display": "two"},
)))
record = claude()
expect("Claude falls back on history.jsonl without a stats-cache", [record["todayPrompts"], record["todaySessions"]], [2, 2], record)

# A stats-cache or history line of the wrong shape costs that field or line,
# never the record.
sandbox()
(home() / ".claude").mkdir()
for cache in ([1, 2], {"dailyModelTokens": 5, "dailyActivity": 7, "modelUsage": [1]},
              {"dailyModelTokens": [{"date": datetime.now().date().isoformat(), "tokensByModel": ["x"]}]}):
  write_json(home() / ".claude" / "stats-cache.json", cache)
  (home() / ".claude" / "history.jsonl").write_text(json.dumps([1]) + "\n" + json.dumps({"timestamp": ms_in(0), "sessionId": "s1"}) + "\n")
  record = claude()
  expect(f"a stats-cache shaped {json.dumps(cache)[:40]} and a list history line read as nothing",
         [record["todayPrompts"], record["todayTokensByModel"], record["modelUsage"]], [1, {}, {}], record)

# pi and opencode replies count on the anthropic provider alone: not another
# provider driving Anthropic's API, and not a prompt.
sandbox()
write_pi_session(home() / ".pi" / "agent" / "sessions" / "project" / "pi.jsonl", [
  pi_reply("anthropic", 10, id="pi-1", model="claude-pi", api="anthropic-messages"),
  pi_reply("kimi-coding", 999, id="kimi-1", model="k3", api="anthropic-messages"),
])
opencode_db(message=[
  ("msg_1", "ses_1", oc_v1("anthropic", 100, model="claude-opus-5")),
  ("msg_2", "ses_1", oc_v1("anthropic", 999, model="claude-opus-5", role="user")),
])
record = claude()
expect("Claude counts pi and opencode replies on the anthropic provider alone",
       [record["todayTotalTokens"], sorted(record["modelUsage"])], [110, ["claude-opus-5", "claude-pi"]], record)

# A Claude Code home without a sign-in is in use, and the sign-in is missing.
sandbox()
(home() / ".claude").mkdir()
record = claude()
expect("Claude asks a signed-out Claude Code home to sign in", [record["ready"], record["usageStatusText"]], [False, "Waiting for auth"], record)

# ---------------------------------------------------------------- contract

sandbox()


def add_message():
  add_message.count = getattr(add_message, "count", 0) + 1
  transcript(message(f"grown-{add_message.count}", 10), mode="a")


check_scan_cache(Adapter("claude", grow=add_message, pi_root=lambda: home() / ".pi" / "agent" / "sessions"))
PY
