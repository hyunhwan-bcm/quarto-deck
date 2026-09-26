-- herdr layout, against a fake herdr CLI (tests/bin/herdr) that records calls.
-- The user's real herdr session is never touched.
local deck = require("quarto-deck")
local util = require("helpers.util")

local FAKE_HERDR = ROOT .. "/tests/bin/herdr"

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local function calls()
  return vim.split(vim.trim(util.read(vim.env.FAKE_HERDR_LOG) or ""), "\n", { trimempty = true })
end

local function start(herdr_opts, extra)
  vim.env.HERDR_ENV = "1"
  vim.env.HERDR_PANE_ID = "w1:p1"
  vim.env.FAKE_HERDR_LOG = vim.fn.tempname()
  notes = {}
  local qmd = util.deck("deck.qmd")
  util.write((qmd:gsub("%.qmd$", ".html")), "<html><body></body></html>")
  deck.setup(vim.tbl_deep_extend("force", {
    open = "auto",
    browser = function() end,
    quarto = ROOT .. "/tests/bin/fake-quarto",
    herdr = vim.tbl_extend("force", { cmd = FAKE_HERDR }, herdr_opts),
  }, extra or {}))
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  return assert(deck._state())
end

test("auto layout inside herdr: nvim | agent / page", function()
  local st = start({ agent_cmd = { "claude" }, page_cmd = { "carbonyl", "{url}" } })
  local url = deck.url()
  eq({
    "pane split w1:p1 --direction right --ratio 0.5 --cwd " .. st.dir .. " --no-focus",
    "pane run w1:p2 'claude'",
    "pane split w1:p2 --direction down --ratio 0.5 --cwd " .. st.dir .. " --no-focus",
    "pane run w1:p4 'carbonyl' '" .. url .. "'",
  }, calls())
  eq({ agent = "w1:p2", page = "w1:p4" }, st.panes)
end)

test("stop closes the page pane but keeps the agent (its session is yours)", function()
  start({ agent_cmd = { "claude" }, page_cmd = { "carbonyl", "{url}" } })
  vim.cmd("QuartoDeck stop")
  local c = calls()
  eq("pane close w1:p4", c[#c])
  eq(0, #vim.tbl_filter(function(l)
    return l == "pane close w1:p2"
  end, c))
end)

test("close_agent = true closes both panes", function()
  start({ agent_cmd = { "claude" }, page_cmd = { "carbonyl", "{url}" }, close_agent = true })
  vim.cmd("QuartoDeck stop")
  local c = calls()
  local closes = vim.tbl_filter(function(l)
    return l:match("^pane close")
  end, c)
  table.sort(closes)
  eq({ "pane close w1:p2", "pane close w1:p4" }, closes)
end)

test("no terminal browser: agent pane only, deck opens in the system browser", function()
  local opened
  start({ agent_cmd = { "claude" }, page_cmd = false }, { browser = function(u)
    opened = u
  end })
  eq({ "pane split w1:p1 --direction right --ratio 0.5 --cwd " .. deck._state().dir .. " --no-focus", "pane run w1:p2 'claude'" }, calls())
  eq(deck.url(), opened)
end)

test("page only (agent_cmd = false)", function()
  start({ agent_cmd = false, page_cmd = { "carbonyl", "{url}" } })
  local c = calls()
  eq(2, #c)
  eq("pane run w1:p2 'carbonyl' '" .. deck.url() .. "'", c[2])
end)

test("neither pane: no split at all, system browser", function()
  local opened
  start({ agent_cmd = false, page_cmd = false }, { browser = function(u)
    opened = u
  end })
  eq({}, calls())
  eq(deck.url(), opened)
end)

test("candidates are auto-detected from PATH", function()
  start({ agent_cmd = nil, agent_candidates = { { "definitely-not-installed-x" }, { "sh", "-c", "true" } }, page_cmd = false })
  eq("pane run w1:p2 'sh' '-c' 'true'", calls()[2])
end)

test("outside herdr: falls back to the system browser", function()
  local opened
  vim.env.HERDR_ENV = nil
  vim.env.FAKE_HERDR_LOG = vim.fn.tempname()
  local qmd = util.deck("deck.qmd")
  util.write((qmd:gsub("%.qmd$", ".html")), "<html><body></body></html>")
  deck.setup({ open = "auto", quarto = ROOT .. "/tests/bin/fake-quarto", herdr = { cmd = FAKE_HERDR }, browser = function(u)
    opened = u
  end })
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  eq(deck.url(), opened)
  eq({}, calls())
end)

test("a failing herdr call is reported", function()
  vim.env.FAKE_HERDR_FAIL = "pane run"
  start({ agent_cmd = { "claude" }, page_cmd = false })
  vim.env.FAKE_HERDR_FAIL = nil
  local found = false
  for _, n in ipairs(notes) do
    if n.msg:find("herdr pane run failed: boom", 1, true) and n.level == vim.log.levels.ERROR then
      found = true
    end
  end
  ok(found, vim.inspect(notes))
end)

test("terminal-browser is the preferred page command", function()
  local c = require("quarto-deck").config.herdr.page_candidates[1]
  eq({ "terminal-browser", "open", "{url}", "--no-merge" }, c)
  start({ agent_cmd = false, page_cmd = c })
  eq("pane run w1:p2 'terminal-browser' 'open' '" .. deck.url() .. "' '--no-merge'", calls()[2])
end)
