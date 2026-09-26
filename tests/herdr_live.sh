#!/usr/bin/env bash
# Live test against a real, isolated, headless herdr server.
#
# Isolation (same trick as alastairsounds/herdr-plugins' justfile): herdr's
# config, sessions and sockets live under XDG_CONFIG_HOME / XDG_STATE_HOME, so
# pointing both at a temp dir and clearing the HERDR_* pane variables gives a
# private server. The user's real herdr session is never contacted.
#
#   QD_TERMINAL_BROWSER=1  also check sync through a real terminal-browser
#   QUARTO_PATH            quarto binary (default: quarto on PATH)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
QUARTO="${QUARTO_PATH:-$(command -v quarto || true)}"
PLUGIN_ID="hyunhwan-bcm.quarto-deck"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  PASS  herdr_live: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  herdr_live: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
skip_all() { echo "  SKIP  herdr_live: $1"; echo "herdr_live: 0 passed, 0 failed, 1 skipped"; [ "${STRICT:-}" = 1 ] && exit 1; exit 0; }

command -v herdr >/dev/null || skip_all "herdr not found"
[ -n "$QUARTO" ] || skip_all "quarto not found (set QUARTO_PATH)"
command -v python3 >/dev/null || skip_all "python3 not found"
command -v curl >/dev/null || skip_all "curl not found"

# unix socket paths are limited to ~104 bytes, so keep the root short
ROOT="$(mktemp -d /tmp/qdt.XXXX)"
unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID \
  HERDR_TAB_ID HERDR_STARTUP_CWD HERDR_BIN_PATH
export XDG_CONFIG_HOME="$ROOT/c" XDG_STATE_HOME="$ROOT/s"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$ROOT/deck"

h() { herdr --session qdtest "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
panes() { h pane list --workspace "$1" | json '" ".join(p["pane_id"] for p in d["result"]["panes"])'; }
ruler() { h pane read "$1" --source visible | grep -oE '[0-9]+,[0-9]+ +(All|Top|Bot|[0-9]+%)' | tail -1 | cut -d, -f1; }
wait_for() { # cmd, timeout-seconds
  local end=$((SECONDS + $2))
  while [ $SECONDS -lt $end ]; do eval "$1" && return 0; sleep 0.3; done
  return 1
}

cleanup() {
  [ -n "${SSE_PID:-}" ] && kill "$SSE_PID" 2>/dev/null
  h server stop >/dev/null 2>&1
  rm -rf "$ROOT"
}
trap cleanup EXIT

(herdr --session qdtest server >"$ROOT/server.log" 2>&1 &)
wait_for 'h status >/dev/null 2>&1' 10 || { bad "isolated herdr server starts"; exit 1; }
ok "isolated herdr server starts"

# --- plugin ---------------------------------------------------------------
check "deck.sh --self-test" 'bash "$REPO/herdr-plugin/bin/deck.sh" --self-test >/dev/null'
h plugin link "$REPO/herdr-plugin" >/dev/null 2>&1
actions_linked() {
  h plugin action list | python3 -c '
import json, sys
d = json.load(sys.stdin)
ids = sorted(a["action_id"] for a in d["result"]["actions"] if a["plugin_id"] == sys.argv[1])
sys.exit(ids != ["render", "start", "stop"])' "$PLUGIN_ID"
}
check "plugin links and lists start/stop/render" actions_linked

# --- nvim with the plugin, inside a herdr pane ------------------------------
cp "$REPO/tests/fixtures/deck.qmd" "$ROOT/deck/"
if [ "${QD_TERMINAL_BROWSER:-}" = 1 ]; then
  PAGE_CMD='{ "terminal-browser", "open", "{url}", "--no-merge" }'
else
  PAGE_CMD='{ "sh", "-c", "echo PAGE {url}; exec sleep 600" }'
fi
cat >"$ROOT/init.lua" <<LUA
vim.opt.rtp:prepend("$REPO")
vim.cmd("runtime plugin/quarto-deck.lua")
vim.o.ruler = true
require("quarto-deck").setup({
  quarto = "$QUARTO",
  herdr = {
    agent_cmd = { "sh", "-c", "echo AGENT-READY; exec sleep 600" },
    page_cmd = $PAGE_CMD,
    agent_ratio = 0.3,
  },
})
LUA

WS_JSON=$(h workspace create --cwd "$ROOT/deck")
NVIM_PANE=$(echo "$WS_JSON" | json 'd["result"]["root_pane"]["pane_id"]')
WS=${NVIM_PANE%%:*}
sleep 1
h pane run "$NVIM_PANE" "nvim --clean -u $ROOT/init.lua deck.qmd"
check "nvim runs in the pane" 'wait_for "h pane process-info --pane $NVIM_PANE | grep -q \"\\\"name\\\":\\\"nvim\\\"\"" 15'

# --- action: start --------------------------------------------------------
h plugin action invoke start --plugin "$PLUGIN_ID" >/dev/null 2>&1
check "start action splits nvim | agent / page" 'wait_for "[ \$(panes $WS | wc -w) -eq 3 ]" 60'

read -r _ AGENT PAGE <<<"$(panes "$WS")"
LAYOUT=$(h pane layout --pane "$NVIM_PANE")
geom() { echo "$LAYOUT" | json "next(p['rect'] for p in d['result']['layout']['panes'] if p['pane_id']=='$1')$2"; }
check "nvim keeps the full-height left column" \
  '[ "$(geom $NVIM_PANE "[\"x\"]")" = 0 ] && [ "$(geom $NVIM_PANE "[\"height\"]")" = "$(echo "$LAYOUT" | json "d[\"result\"][\"layout\"][\"area\"][\"height\"]")" ]'
check "agent sits above the page on the right" \
  '[ "$(geom $AGENT "[\"x\"]")" = "$(geom $PAGE "[\"x\"]")" ] && [ "$(geom $AGENT "[\"y\"]")" -lt "$(geom $PAGE "[\"y\"]")" ] && [ "$(geom $AGENT "[\"height\"]")" -lt "$(geom $PAGE "[\"height\"]")" ]'
check "agent pane runs the agent" 'wait_for "h pane read $AGENT --source recent-unwrapped --lines 20 | grep -q AGENT-READY" 10'

URL=$(h plugin action list >/dev/null; h pane read "$NVIM_PANE" --source recent-unwrapped --lines 5 | grep -oE 'http://127\.0\.0\.1:[0-9]+/' | tail -1)
if [ -z "$URL" ]; then # the notify line may already be gone; ask nvim
  h pane send-text "$NVIM_PANE" ":QuartoDeck status"; h pane send-keys "$NVIM_PANE" enter; sleep 1
  URL=$(h pane read "$NVIM_PANE" --source visible | grep -oE 'http://127\.0\.0\.1:[0-9]+/' | tail -1)
fi
check "server in the nvim pane serves the deck with the client injected" \
  'wait_for "curl -s $URL | grep -q __quarto_deck/client.js" 60'

if [ "${QD_TERMINAL_BROWSER:-}" != 1 ]; then
  check "page pane runs the page command with the deck URL" \
    'wait_for "h pane read $PAGE --source recent-unwrapped --lines 20 | grep -qF \"PAGE $URL\"" 10'
fi

# --- sync through herdr keystrokes ----------------------------------------
curl -sN "${URL}__quarto_deck/events" >"$ROOT/sse.log" 2>/dev/null &
SSE_PID=$!
sleep 1
h pane send-keys "$NVIM_PANE" esc
h pane send-text "$NVIM_PANE" "49G"
check "cursor move in nvim reaches the browser channel (goto 7)" \
  'wait_for "grep -q \"\\\"index\\\":7\" $ROOT/sse.log" 5'

curl -s -X POST -H 'Content-Type: application/json' -d '{"type":"slide","index":4}' "${URL}__quarto_deck/event" >/dev/null
check "browser navigation moves the nvim cursor (line 34)" 'wait_for "[ \"\$(ruler $NVIM_PANE)\" = 34 ]" 5'

if [ "${QD_TERMINAL_BROWSER:-}" = 1 ]; then
  command -v terminal-browser >/dev/null || bad "terminal-browser installed"
  tb() { terminal-browser action --browser "$TB" -- eval "$1" 2>/dev/null | tail -1; }
  wait_for 'TB=$(terminal-browser ls --all 2>/dev/null | grep -F -B3 "$URL" | awk "/^[0-9]+-[0-9]+/{print \$1}" | tail -1); [ -n "$TB" ]' 30
  tb_slide() { tb 'Reveal.getSlides().filter(s=>s.id==="title-slide"||s.classList.contains("slide")).indexOf(Reveal.getCurrentSlide())'; }
  check "terminal-browser loaded the deck" '[ -n "$TB" ] && wait_for "[ \"\$(tb \"Reveal.isReady()\")\" = true ]" 30'
  h pane send-text "$NVIM_PANE" "23G"
  check "terminal-browser follows nvim (slide 3)" 'wait_for "[ \"\$(tb_slide)\" = 3 ]" 10'
  tb 'Reveal.next()' >/dev/null
  check "nvim follows terminal-browser (line 34)" 'wait_for "[ \"\$(ruler $NVIM_PANE)\" = 34 ]" 10'
fi

# --- action: stop ---------------------------------------------------------
h plugin action invoke stop --plugin "$PLUGIN_ID" >/dev/null 2>&1
check "stop closes the page pane and keeps the agent" \
  'wait_for "[ \"\$(panes $WS)\" = \"$NVIM_PANE $AGENT\" ]" 10'
check "stop shuts the server down" 'wait_for "! curl -s -o /dev/null $URL" 5'

# --- action on a pane that isn't nvim ---------------------------------------
WS2_JSON=$(h workspace create --cwd "$ROOT")
SHELL_PANE=$(echo "$WS2_JSON" | json 'd["result"]["root_pane"]["pane_id"]')
sleep 1
HERDR_PANE_ID="$SHELL_PANE" bash "$REPO/herdr-plugin/bin/deck.sh" start >/dev/null 2>"$ROOT/refuse.err"
code=$?
check "start refuses a pane that isn't running nvim" \
  '[ $code -ne 0 ] && grep -q "not running nvim" "$ROOT/refuse.err" && [ "$(panes ${SHELL_PANE%%:*} | wc -w)" -eq 1 ]'

echo "herdr_live: $pass passed, $fail failed, 0 skipped"
[ $fail -eq 0 ]
