#!/usr/bin/env bash
# Records demo/quarto-deck-demo.{gif,mp4} with VHS: a real herdr client
# running nvim with the plugin, and carbonyl (Chromium in the terminal) in the
# page pane. herdr runs isolated (XDG dirs in a temp root, HERDR_* cleared), so
# your own herdr session is never touched.
#
# terminal-browser is the preferred page pane in real use, but it draws with
# kitty graphics, which VHS can't record. carbonyl draws with text cells.
#
# Needs: vhs, herdr, nvim, carbonyl, quarto (or $QUARTO_PATH).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
for t in vhs herdr nvim carbonyl; do
  command -v "$t" >/dev/null || { echo "demo: $t not found" >&2; exit 1; }
done
QUARTO="${QUARTO_PATH:-$(command -v quarto || true)}"
[ -n "$QUARTO" ] || { echo "demo: quarto not found (set QUARTO_PATH)" >&2; exit 1; }

# unix socket paths are limited to ~104 bytes: keep the root short
ROOT="$(mktemp -d /tmp/qdv.XXXX)"
unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID \
  HERDR_TAB_ID HERDR_STARTUP_CWD HERDR_BIN_PATH
export XDG_CONFIG_HOME="$ROOT/c" XDG_STATE_HOME="$ROOT/s" QD_ROOT="$ROOT" QD_INIT="$ROOT/deck/.demo-init.lua"
cleanup() {
  herdr --session qdemo server stop >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT/deck" "$XDG_CONFIG_HOME/herdr"
# skip herdr's first-run setup dialog, which would swallow the typed keys
printf 'onboarding = false\n' >"$XDG_CONFIG_HOME/herdr/config.toml"
cp demo/demo.qmd "$ROOT/deck/"
cat >"$QD_INIT" <<LUA
vim.opt.rtp:prepend("$REPO")
vim.cmd("runtime plugin/quarto-deck.lua")
vim.o.number = true
vim.o.cursorline = true
vim.o.termguicolors = true
vim.o.swapfile = false
vim.opt.shortmess:append("I")
vim.cmd("filetype indent off")
vim.api.nvim_create_autocmd("FileType", { callback = function()
  vim.bo.autoindent = false
  vim.bo.indentexpr = ""
end })
require("quarto-deck").setup({
  quarto = "$QUARTO",
  herdr = { agent_cmd = false, page_cmd = { "carbonyl", "{url}" }, ratio = 0.5 },
})
LUA

vhs demo/demo.tape
echo "demo: wrote demo/quarto-deck-demo.gif and demo/quarto-deck-demo.mp4"
