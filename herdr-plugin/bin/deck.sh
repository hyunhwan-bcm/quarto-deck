#!/usr/bin/env bash
# Runs `:QuartoDeck <subcommand>` in the nvim of the pane that triggered the
# action. Refuses (exit 1, nothing sent) when that pane isn't running nvim.
set -eo pipefail
# herdr runs plugin commands with a minimal PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# stdin: `herdr pane process-info` JSON. True if nvim is in the foreground
# (process names only appear in its foreground_processes list).
foreground_is_nvim() {
  grep -Eq '"name":"n?vim"'
}

if [ "${1:-}" = "--self-test" ]; then
  fail() { echo "self-test failed: $1" >&2; exit 1; }
  echo '{"result":{"process_info":{"foreground_processes":[{"argv":["nvim","deck.qmd"],"name":"nvim","pid":1}]}}}' |
    foreground_is_nvim || fail "nvim not detected"
  echo '{"result":{"process_info":{"foreground_processes":[{"argv":["zsh"],"name":"zsh","pid":1}]}}}' |
    foreground_is_nvim && fail "zsh detected as nvim"
  echo '{"result":{"process_info":{"foreground_processes":[]}}}' |
    foreground_is_nvim && fail "empty list detected as nvim"
  echo "ok"
  exit 0
fi

sub="${1:-start}"
case "$sub" in
  start | stop | render | open | layout | status) ;;
  *) echo "unknown subcommand: $sub" >&2; exit 2 ;;
esac

herdr="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || { echo "no triggering pane (HERDR_PANE_ID unset)" >&2; exit 1; }

if ! "$herdr" pane process-info --pane "$pane" | foreground_is_nvim; then
  echo "pane $pane is not running nvim; open your .qmd in nvim first" >&2
  exit 1
fi

"$herdr" pane send-keys "$pane" esc
"$herdr" pane send-text "$pane" ":QuartoDeck $sub"
"$herdr" pane send-keys "$pane" enter
