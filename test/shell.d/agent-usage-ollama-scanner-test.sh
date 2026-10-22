#!/bin/bash

# The Ollama Cloud collector's own parts: the ollama-cloud filter over pi and
# omp sessions with model tags merged, the configured model prefix, Ollama's
# balance and plan answers, and its key. Roots, forks, cloud-tagged models
# through the local daemon, both opencode stores, OPENCODE_DB and untrusted
# values are held by the shared and partition tests, as is the
# unused-machine record; the limits and scan caches go through the contract
# checks.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox

python3 - <<'PY'
from agent_usage_fixtures import *

# The checks below compare today's totals with rows stamped now.
freeze_today()
BALANCE = "ollama.com/api/balance"
ME = "ollama.com/api/me"
SESSION_RESET = iso_in(3 * 3600)
WEEKLY_RESET = iso_in(4 * 86400)
# A legacy plan's answer, as docs.ollama.com/api/balance documents it.
ROUTES = {
  BALANCE: {
    "included": {
      "session": {"remaining_percent": 75, "resets_at": SESSION_RESET},
      "weekly": {"remaining_percent": 40, "resets_at": WEEKLY_RESET},
    },
    "purchased": {"balance_usd": 25},
  },
  ME: {"Plan": "pro"},
}


def ollama(*args, routes=None, mode="up"):
  with FakeHttp(ROUTES if routes is None else routes, mode=mode) as http:
    record = collect("ollama", *(args or ("--force",)))
  ollama.requests = http.count
  return record


def sessions():
  return home() / ".pi" / "agent" / "sessions"


def prefix(value):
  if value is None:
    (config_home() / "omarchy" / "agents" / "ollama.json").unlink()
  else:
    write_json(config_home() / "omarchy" / "agents" / "ollama.json", {"modelPrefix": value})


# ------------------------------------------------------------ local stats

# pi and omp sessions on the ollama-cloud provider are the local stats; other
# providers and prompts in the same files stay out, and model version tags
# merge.
sandbox()
write_pi_session(sessions() / "project" / "pi.jsonl", [
  pi_reply("ollama-cloud", id="pi-1", model="deepseek-v4-pro:0813", usage={"input": 10, "output": 4, "cacheRead": 3, "cacheWrite": 2, "totalTokens": 19}),
  pi_reply("ollama-cloud", id="pi-2", model="deepseek-v4-pro:0731", usage={"input": 5, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 6}),
  pi_reply("anthropic", id="pi-3", model="claude-test", usage={"input": 999, "output": 999}),
  {"type": "message", "id": "pi-4", "timestamp": iso_in(0), "message": {"role": "user", "provider": "ollama-cloud", "model": "deepseek-v4-pro:0813", "usage": {"input": 999, "output": 999}}},
  pi_reply("ollama-cloud", id="pi-5", model="deepseek-v4-pro:0813", usage={"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0}),
])
write_pi_session(home() / ".omp" / "agent" / "sessions" / "project" / "omp.jsonl", [
  pi_reply("ollama-cloud", id="omp-1", model="kimi-k3", usage={"input": 20, "output": 5, "cacheRead": 4, "cacheWrite": 1, "totalTokens": 30}),
])
record = ollama()
expect("Ollama counts ollama-cloud usage from pi and omp, merging model tags", [record["name"], record["todayTotalTokens"], record["modelUsage"]], ["Ollama Cloud", 55, {
  "deepseek-v4-pro": {"inputTokens": 15, "outputTokens": 5, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 2},
  "kimi-k3": {"inputTokens": 20, "outputTokens": 5, "cacheReadInputTokens": 4, "cacheCreationInputTokens": 1},
}], record)

# In use here, but no key to ask for the account's limits.
expect("Ollama in use without a key waits for auth", [record["ready"], record["usageStatusText"], record["limitsStale"], ollama.requests],
       [True, "Waiting for auth", False, 0], record)

# A configured model prefix restricts the local stats to matching models, and
# a scan only answers for the filter it applied: the same filter reuses it,
# another scans again.
prefix("kimi")
expect("Ollama honors the configured model prefix", list(ollama()["modelUsage"]), ["kimi-k3"])
expect("Ollama reuses a scan made with the same model prefix", list(ollama("--limits-only")["modelUsage"]), ["kimi-k3"])
prefix(None)
expect("Ollama scans again when the model prefix changes", sorted(ollama("--limits-only")["modelUsage"]), ["deepseek-v4-pro", "kimi-k3"])

# ---------------------------------------------------------------- contract

sandbox()


def add_reply():
  add_reply.count = getattr(add_reply, "count", 0) + 1
  write_pi_session(sessions() / "grown" / f"{add_reply.count}.jsonl", [pi_reply("ollama-cloud", 5, id=f"grown-{add_reply.count}")])


# A probe asks for the balance and then the plan.
adapter = Adapter("ollama", plant=lambda: os.environ.update(OLLAMA_API_KEY="key"), answer=ROUTES, requests_per_probe=2,
                  grow=add_reply, pi_root=sessions)
fresh = check_limits_contract(adapter)
expect("Ollama's plan and a legacy plan's session and weekly use and resets come from its answers", {
  "tierLabel": fresh["tierLabel"], "limits": fresh["limits"],
}, {
  "tierLabel": "Pro", "limits": [
    {"label": "Session (5-hour)", "percent": 0.25, "resetsAt": SESSION_RESET},
    {"label": "Weekly (7-day)", "percent": 0.6, "resetsAt": WEEKLY_RESET},
  ],
}, fresh)
check_scan_cache(adapter)

# ---------------------------------------------------------------- the key

# A rejected key is a sign-in to redo, and says so.
record = ollama(mode=401)
check("Ollama explains a rejected key", "rejected" in record["authHelpText"], record)

# A plan lookup that fails keeps the plan last named.
record = ollama(routes={**ROUTES, ME: urllib.error.URLError(OSError("plan lookup timed out"))})
expect("Ollama keeps the cached plan when the plan lookup fails", [record["tierLabel"], record["limitsStale"]], ["Pro", False], record)

# An answer never rolls back one another run stamped while this one waited
# on the network.
def later_run(request):
  edit_limits_cache("ollama", fetched_ago=-60)
  return ROUTES[BALANCE]


ollama(routes={**ROUTES, BALANCE: later_run})
expect("Ollama never overwrites a newer cached answer with its own",
       [json.loads(path.read_text())["fetchedAtMs"] > ms_in(30) for path in limits_cache_files("ollama")], [True])
edit_limits_cache("ollama", fetched_ago=0)

# Another key never shows this one's numbers or plan.
os.environ["OLLAMA_API_KEY"] = "other-key"
record = ollama(mode="down")
expect("Ollama keeps each key's limits and plan apart", [record["limits"], record["tierLabel"], record["usageStatusText"]],
       [[], "", "Ollama limits unavailable"], record)

# Ollama's UserResponse struct tags the plan `plan` (api/types.go), as the
# server re-encodes it; the capitalized spelling still reads.
record = ollama(routes={**ROUTES, ME: {"id": "00000000-0000-0000-0000-000000000000", "email": "a@example.com", "name": "a", "plan": "pro"}})
expect("Ollama reads the plan under its JSON tag's lowercase spelling", record["tierLabel"], "Pro", record)

# ---------------------------------------------------------- the answer

# With nothing kept, a failed check says the limits are unavailable; only an
# unreachable endpoint asks for an early retry.
sandbox()
os.environ["OLLAMA_API_KEY"] = "key"
record = ollama(mode="down")
expect("Ollama offline with nothing kept says its limits are unavailable and advises a retry",
       [record["usageStatusText"], record.get("retryAdvised")], ["Ollama limits unavailable", True], record)
record = ollama(mode=500)
expect("Ollama advises no retry for a server's error status", [record["usageStatusText"], record.get("retryAdvised")],
       ["Ollama limits unavailable", None], record)

# A current plan's answer, as documented: the included credits are a monthly
# meter of what is spent, resetting when the period ends.
record = ollama(routes={BALANCE: {
  "included": {"balance_usd": 72.5, "allowance_usd": 100, "period": {"from": iso_in(-86400), "until": WEEKLY_RESET}},
  "purchased": {"balance_usd": 25},
}, ME: {"Plan": "pro"}})
expect("Ollama meters a current plan's included credits until the period ends", [record["limits"], record["usageStatusText"]],
       [[{"label": "Included credits", "title": "Monthly", "percent": 0.275, "resetsAt": WEEKLY_RESET}], ""], record)

# An answer with no usable windows explains itself instead of printing none.
sandbox()
os.environ["OLLAMA_API_KEY"] = "key"
record = ollama(routes={BALANCE: {"included": {"session": {"remaining_percent": "unknown"}, "weekly": None}, "purchased": {"balance_usd": 0}},
                        ME: {"Plan": "pro"}})
expect("Ollama reports a balance answer without usable limits", [record["limits"], record["usageStatusText"], "no limits" in record["authHelpText"]],
       [[], "Ollama limits unavailable", True], record)

# Values out of range or of the wrong type skip that window, never the rest:
# a negative remainder is dropped, one past 100 reads as untouched, and a
# reset that won't parse as none.
record = ollama(routes={BALANCE: {"included": {
  "session": {"remaining_percent": -20, "resets_at": SESSION_RESET},
  "weekly": {"remaining_percent": 140, "resets_at": "not a time"},
}}, ME: {"Plan": "pro"}})
expect("Ollama skips a window it can't read and keeps the rest in range",
       record["limits"], [{"label": "Weekly (7-day)", "percent": 0.0, "resetsAt": ""}], record)

# Without OLLAMA_API_KEY, the key pi or omp signed in with stands in, pi's
# first, and goes out as a Bearer token on both requests. A pi `$VAR` or
# `!command` entry is pi's to resolve, never a key to send.
sandbox()
pi_auth(home() / ".omp" / "agent", "ollama-cloud", "omp-key")
pi_auth(None, "ollama-cloud", "pi-key")
with FakeHttp(ROUTES) as http:
  record = collect("ollama", "--force")
expect("Ollama asks with pi's saved key before omp's, as a Bearer token",
       [sorted({request["headers"].get("authorization") for request in http.requests}), len(http.requests), len(record["limits"])],
       [["Bearer pi-key"], 2, 2], record)
pi_auth(None, "ollama-cloud", "$OLLAMA_KEY")
expect("Ollama passes over pi's $VAR entry to omp's key", load_collector("ollama").api_key(), "omp-key")
pi_auth(home() / ".omp" / "agent", "ollama-cloud", "!pass show ollama")
expect("Ollama never sends a pi $VAR or !command entry as a key", load_collector("ollama").api_key(), "")
PY
