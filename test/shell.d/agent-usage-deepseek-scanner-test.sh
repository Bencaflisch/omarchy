#!/bin/bash

# The DeepSeek collector's local stats: pi, omp and opencode usage on the
# deepseek provider, DeepSeek Harness's own session logs, and the key dsh
# keeps. How pi and opencode stores are read (roots, forks, both opencode
# stores, OPENCODE_DB, opencode-v2.db, untrusted values) is held centrally by
# the shared and partition tests, the unused-machine record by the partition
# test, and the scan cache by the contract check. The balance is
# agent-usage-deepseek-balance-test.sh's.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox

python3 - <<'PY'
import shutil

from agent_usage_fixtures import *


def deepseek(*args):
  with FakeHttp():
    return collect("deepseek", *(args or ("--force",)))


def sessions():
  return home() / ".pi" / "agent" / "sessions"


# ------------------------------------------------- pi, omp and opencode

# Only the deepseek provider counts, from pi, omp and opencode alike, with
# reasoning folded into output and cache kept apart. A day active in more
# than one of them is still one active day. Local usage alone puts DeepSeek
# in use; without a key there is no plan and no balance section.
sandbox()
write_pi_session(sessions() / "project" / "pi.jsonl", [
  pi_reply("deepseek", id="pi-1", model="deepseek-pi", usage={"input": 10, "output": 4, "cacheRead": 3, "cacheWrite": 2, "totalTokens": 19}),
  pi_reply("anthropic", id="pi-2", model="claude-test", usage={"input": 999, "output": 999}),
  pi_reply("openai-codex", id="pi-3", model="gpt-test", usage={"input": 999, "output": 999}),
])
write_pi_session(home() / ".omp" / "agent" / "sessions" / "project" / "omp.jsonl", [
  pi_reply("deepseek", id="omp-1", model="deepseek-omp", usage={"input": 20, "output": 5, "cacheRead": 4, "cacheWrite": 1, "totalTokens": 30}),
])
opencode_db(tables=("message",), message=[
  ("m-1", "ses_1", oc_v1("deepseek", {"input": 100, "output": 20, "reasoning": 5, "cache": {"read": 30, "write": 2}}, model="deepseek-model")),
  ("m-2", "ses_1", oc_v1("openai", {"input": 999, "output": 999}, model="gpt-model")),
  ("m-3", "ses_1", oc_v1("anthropic", {"input": 999, "output": 999}, model="claude-model")),
  ("m-4", "ses_1", oc_v1("deepseek-proxy", {"input": 999, "output": 999}, model="deepseek-model")),
])
record = deepseek()
expect("DeepSeek counts its own provider's usage from pi, omp and opencode, one active day across them", {
  key: record[key] for key in ("todayTotalTokens", "todayPrompts", "todaySessions", "totalSessions", "activeDays", "modelUsage")
}, {
  "todayTotalTokens": 206, "todayPrompts": 3, "todaySessions": 3, "totalSessions": 3, "activeDays": 1, "modelUsage": {
    "deepseek-pi": {"inputTokens": 10, "outputTokens": 4, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 2},
    "deepseek-omp": {"inputTokens": 20, "outputTokens": 5, "cacheReadInputTokens": 4, "cacheCreationInputTokens": 1},
    "deepseek-model": {"inputTokens": 100, "outputTokens": 25, "cacheReadInputTokens": 30, "cacheCreationInputTokens": 2},
  },
}, record)
expect("DeepSeek in use without a key prints a valid record with no plan and no balance",
       {key: record.get(key) for key in ("id", "ready", "tierLabel", "hasPromptStats", "usageStatusText", "authHelpText")} | {"balance": "balance" in record},
       {"id": "deepseek", "ready": True, "tierLabel": "", "hasPromptStats": True, "usageStatusText": "", "authHelpText": "", "balance": False}, record)

# -------------------------------------------------------- DeepSeek Harness

# dsh keeps one event log per session under $DSH_HOME/sessions, Zstandard-
# compressed by default. Only its DeepSeek routes count; a retry's settled
# answer replaces the streamed sample of the same step; a fork's inherited
# history is its parent's; a torn final record is dropped; and only the
# newest generation of a session is read.
sandbox()
os.environ["DSH_HOME"] = str(home() / "dsh")
now = ms_in(0)

try:
  from compression import zstd
except ImportError:
  zstd = None


def header(session, seeded=False):
  return {"type": "session", "version": 4, "id": session, "createdAt": now, "isSeeded": seeded, "delegationDepth": 0}


def route(provider, model, seq=1):
  return {"type": "request/header", "seq": seq, "time": now, "data": {"header": {"config": {"provider": provider, "model": model}}, "reason": "initial"}}


def message(turn, step, usage, seq=2, kind="assistant/message"):
  data = {"turn": turn, "step": step, "stream": []}
  if kind == "assistant/message":
    data["usage"] = usage
  else:
    data["stream"] = [{"type": "chunk", "chunk": {"type": "usage", "usage": usage}}]
  return {"type": kind, "seq": seq, "time": now, "data": data}


def usage(input, output=0, read=0, write=0):
  return {"inputTokens": input, "outputTokens": output, "cacheReadTokens": read, "cacheWriteTokens": write}


def write_log(path, records, compressed, torn=b""):
  path.parent.mkdir(parents=True, exist_ok=True)
  lines = [(json.dumps(record) + "\n").encode() for record in records]
  if compressed:
    path.write_bytes(b"".join(zstd.compress(line) for line in lines) + torn)
  else:
    path.write_bytes(b"".join(lines) + torn)


compressed = zstd is not None
suffix = ".jsonl.zstd" if compressed else ".jsonl"
project = home() / "dsh" / "sessions" / "--home-me-code--"

# A DeepSeek session: one step streamed a sample, then settled with the real
# count; a retry of step 2 adds a second billed attempt.
write_log(project / "s1" / ("session.v4" + suffix), [
  header("s1"),
  route("deepseek-official", "deepseek-v4-pro"),
  message(1, 1, usage(1, 1), kind="assistant/attempt"),
  message(1, 1, usage(100, 10, 20, 0)),
  message(1, 2, usage(5, 1), kind="assistant/attempt"),
  {"type": "llm/retry-started", "seq": 9, "time": now, "data": {"turn": 1, "step": 2}},
  message(1, 2, usage(7, 3)),
], compressed, torn=b'{"type":"assistant/mess' if not compressed else b"\x28\xb5\x2f\xfd")
# An older generation of the same session is migration history only.
write_log(project / "s1" / "session.jsonl", [header("s1"), route("deepseek-official", "deepseek-v4-pro"), message(1, 1, usage(999999))], False)
# A route billed by someone else.
write_log(project / "s2" / ("session.v4" + suffix), [header("s2"), route("pi-ai:anthropic", "claude-opus-5"), message(1, 1, usage(888888))], compressed)
# A fork of s1: its copy of the parent's step is inherited, and only what
# follows its seed marker was spent in it.
write_log(project / "s3" / ("session.v4" + suffix), [
  header("s3", seeded=True),
  route("deepseek-official", "deepseek-v4-pro"),
  message(1, 1, usage(100, 10, 20, 0)),
  {"type": "session/end-seed", "seq": 4, "time": now, "data": {"inherited": True}},
  route("deepseek-account", "deepseek-v4-flash", seq=5),
  message(2, 1, usage(4000, 6, 0, 1)),
], compressed)
# A root written with compression off reads the same, torn tail and all.
write_log(project / "s4" / "session.v4.jsonl", [header("s4"), route("deepseek-official", "deepseek-chat"), message(1, 1, usage(30000))], False,
          torn=b'{"type":"assistant/mess')

record = deepseek()
expect("DeepSeek counts DeepSeek Harness sessions on its DeepSeek routes",
       {key: record[key] for key in ("todayTotalTokens", "totalPrompts", "totalSessions", "modelUsage")}, {
  "todayTotalTokens": 34153, "totalPrompts": 5, "totalSessions": 3, "modelUsage": {
    "deepseek-v4-pro": {"inputTokens": 112, "outputTokens": 14, "cacheReadInputTokens": 20, "cacheCreationInputTokens": 0},
    "deepseek-v4-flash": {"inputTokens": 4000, "outputTokens": 6, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 1},
    "deepseek-chat": {"inputTokens": 30000, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0},
  },
}, record)

# A line nested too deep to parse costs only that line (or, as the header,
# that log), never the rest of the scan.
DEEP = b'{"type":"assistant/message","data":' + b"[" * 100000 + b"]" * 100000 + b"}\n"
deep = project / "s5" / "session.v4.jsonl"
write_log(deep, [header("s5"), route("deepseek-official", "deepseek-deep")], False)
with deep.open("ab") as handle:
  handle.write(DEEP + (json.dumps(message(1, 1, usage(50))) + "\n").encode())
(project / "s6").mkdir()
(project / "s6" / "session.v4.jsonl").write_bytes(DEEP + (json.dumps(message(1, 1, usage(70))) + "\n").encode())
record = deepseek()
expect("DeepSeek skips a dsh line nested too deep to parse, keeping the rest of the scan",
       [record["todayTotalTokens"], record["modelUsage"].get("deepseek-deep", {}).get("inputTokens")], [34203, 50], record)
shutil.rmtree(project / "s5")
shutil.rmtree(project / "s6")

# A frame that inflates past the cap (64 MiB, far beyond any real log) is
# never read in full: the log counts nothing, and the scan, incomplete, isn't
# kept for the next run.
if compressed:
  bomb = project / "s7" / "session.v4.jsonl.zstd"
  bomb.parent.mkdir()
  opening = "".join(json.dumps(line) + "\n" for line in (header("s7"), route("deepseek-official", "deepseek-bomb"), message(1, 1, usage(60))))
  bomb.write_bytes(zstd.compress(opening.encode() + b" " * (65 << 20)))
  for path in scan_cache_files("deepseek"):
    path.unlink()
  with contextlib.redirect_stderr(io.StringIO()):
    record = deepseek()
  expect("DeepSeek stops a dsh log that inflates past its cap, and doesn't cache the scan",
         [record["todayTotalTokens"], "deepseek-bomb" in record["modelUsage"], scan_cache_files("deepseek")], [34153, False, []], record)
  shutil.rmtree(project / "s7")
else:
  print("ok - DeepSeek stops a dsh log that inflates past its cap # SKIP no Zstandard support")

# A session directory the walk can't list has logs the scan missed, so the
# scan isn't kept: once it's readable again, the next plain run counts it.
if os.geteuid() != 0:
  locked = project / "s8"
  write_log(locked / "session.v4.jsonl", [header("s8"), route("deepseek-official", "deepseek-locked"), message(1, 1, usage(80))], False)
  for path in scan_cache_files("deepseek"):
    path.unlink()
  locked.chmod(0)
  try:
    record = deepseek()
  finally:
    locked.chmod(0o755)
  expect("DeepSeek doesn't cache a dsh scan that couldn't list every session directory",
         ["deepseek-locked" in record["modelUsage"], scan_cache_files("deepseek")], [False, []], record)
  record = deepseek("--limits-only")
  expect("DeepSeek counts the dsh session once its directory is readable again", record["modelUsage"].get("deepseek-locked", {}).get("inputTokens"), 80, record)
  shutil.rmtree(locked)
else:
  print("ok - DeepSeek doesn't cache a dsh scan that couldn't list every session directory # SKIP root reads anything")

# dsh keeps its key in its managed .credentials.yaml, or a .env beside it.
(home() / "dsh" / ".credentials.yaml").write_text("""# managed by dsh
version: 1
refs:
  OTHER_KEY: nope
  DEEPSEEK_API_KEY: "sk-from-dsh" # stored by the Models page
""")
collector = load_collector("deepseek")
first = collector.api_key()
(home() / "dsh" / ".credentials.yaml").unlink()
(home() / "dsh" / ".env").write_text("export DEEPSEEK_API_KEY='sk-from-env-file'\n")
expect("DeepSeek reads the key dsh stores, from its credentials or its .env", [first, collector.api_key()], ["sk-from-dsh", "sk-from-env-file"])
del os.environ["DSH_HOME"]

# ---------------------------------------------------------------- contract

sandbox()


def add_reply():
  add_reply.count = getattr(add_reply, "count", 0) + 1
  write_pi_session(sessions() / "grown" / f"{add_reply.count}.jsonl", [pi_reply("deepseek", 5, id=f"grown-{add_reply.count}")])


check_scan_cache(Adapter("deepseek", grow=add_reply, pi_root=sessions))
PY
