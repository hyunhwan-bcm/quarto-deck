-- The plugin end to end, without a browser: an SSE client plays the browser.
local deck = require("quarto-deck")
local util = require("helpers.util")
local http = require("helpers.http")

local FAKE_QUARTO = ROOT .. "/tests/bin/fake-quarto"
local EVENTS = "/__quarto_deck/events"

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end
local function noted(pat, level)
  for _, n in ipairs(notes) do
    if n.msg:find(pat) and (not level or n.level == level) then
      return true
    end
  end
  return false
end

-- A deck whose html is already up to date, so start doesn't render.
local function fresh_deck(opts)
  local qmd = util.deck("deck.qmd")
  util.write((qmd:gsub("%.qmd$", ".html")), "<html><body>deck</body></html>")
  deck.setup(vim.tbl_extend("force", { open = "none", quarto = FAKE_QUARTO }, opts or {}))
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  local st = assert(deck._state(), "plugin did not start")
  return st, qmd
end

local function move(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

local function post(port, msg)
  eq(204, http.request(port, "POST", "/__quarto_deck/event", vim.json.encode(msg)).status)
end

test("start serves the deck with the client injected", function()
  local st = fresh_deck()
  local r = http.request(st.port, "GET", "/")
  eq(200, r.status)
  ok(r.body:find("/__quarto_deck/client.js", 1, true))
  eq("http://127.0.0.1:" .. st.port .. "/", deck.url())
end)

test("a new browser is sent to the cursor's slide", function()
  local st = fresh_deck()
  move(42) -- "Setext heading", slide 5
  local sse = http.sse(st.port, EVENTS)
  util.wait(function()
    return #sse.messages >= 1
  end)
  eq({ type = "goto", index = 5 }, sse.messages[1])
  sse:close()
end)

test("cursor moves send goto only when the slide changes", function()
  local st = fresh_deck()
  local sse = http.sse(st.port, EVENTS)
  util.wait(function()
    return #sse.messages >= 1
  end)
  move(9) -- First slide
  move(11) -- same slide
  move(15) -- same slide (inside code block)
  move(57) -- Last slide
  util.wait(function()
    return #sse:of_type("goto") >= 3
  end)
  vim.wait(150)
  eq({ 0, 2, 8 }, vim.tbl_map(function(m)
    return m.index
  end, sse:of_type("goto")))
  sse:close()
end)

test("browser navigation moves the cursor, without echoing back", function()
  local st = fresh_deck()
  local sse = http.sse(st.port, EVENTS)
  util.wait(function()
    return #sse.messages >= 1
  end)
  post(st.port, { type = "slide", index = 6 })
  util.wait(function()
    return vim.api.nvim_win_get_cursor(0)[1] == 47
  end, 3000, "cursor on 'Second section'")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
  vim.wait(150)
  eq(1, #sse:of_type("goto"), "no goto echoed back to the browser")
  eq(6, st.index)
  sse:close()
end)

test("browser navigation within the cursor's slide leaves the cursor alone", function()
  local st = fresh_deck()
  move(51) -- inside "Slide with notes", slide 7
  post(st.port, { type = "slide", index = 7 })
  vim.wait(150)
  eq(51, vim.api.nvim_win_get_cursor(0)[1])
end)

test("out-of-range browser index is ignored", function()
  local st = fresh_deck()
  move(9)
  post(st.port, { type = "slide", index = 99 })
  vim.wait(150)
  eq(9, vim.api.nvim_win_get_cursor(0)[1])
end)

test("slide-count mismatch from the browser warns once", function()
  local st = fresh_deck()
  notes = {}
  post(st.port, { type = "hello", count = 12, index = 0 })
  post(st.port, { type = "hello", count = 12, index = 0 })
  util.wait(function()
    return noted("browser has 12 slides")
  end)
  vim.wait(100)
  local n = #vim.tbl_filter(function(x)
    return x.msg:find("browser has 12")
  end, notes)
  eq(1, n)
  notes = {}
  post(st.port, { type = "hello", count = 9, index = 0 })
  vim.wait(150)
  ok(not noted("browser has"), "matching count must not warn")
end)

test(":write re-renders and reloads the browser", function()
  local log = vim.fn.tempname()
  vim.env.FAKE_QUARTO_LOG = log
  local st, qmd = fresh_deck()
  local sse = http.sse(st.port, EVENTS)
  vim.cmd("silent write")
  util.wait(function()
    return #sse:of_type("reload") == 1
  end, 5000, "reload")
  eq("render " .. st.file .. " --to revealjs", vim.trim(util.read(log)))
  ok(st.last_render.ok)
  vim.env.FAKE_QUARTO_LOG = nil
  sse:close()
end)

test("render failure is reported and does not reload", function()
  local st = fresh_deck()
  local sse = http.sse(st.port, EVENTS)
  notes = {}
  vim.env.FAKE_QUARTO_FAIL = "1"
  deck.render()
  util.wait(function()
    return noted("render failed", vim.log.levels.ERROR)
  end, 5000, "error notification")
  ok(noted("fake render failure"), "stderr is shown")
  eq(false, st.last_render.ok)
  vim.wait(100)
  eq(0, #sse:of_type("reload"))
  ok(util.read(st.log_path):find("fake render failure", 1, true), "stderr is logged")
  vim.env.FAKE_QUARTO_FAIL = nil
  sse:close()
end)

test("missing quarto is an error, never a success", function()
  local st = fresh_deck({ quarto = "/nonexistent/quarto" })
  notes = {}
  deck.render()
  ok(noted("quarto not found", vim.log.levels.ERROR))
  eq(nil, st.last_render)
end)

test("renders a missing html first, then opens the browser", function()
  local qmd = util.deck("deck.qmd")
  local opened
  deck.setup({ open = "browser", quarto = FAKE_QUARTO, browser = function(u)
    opened = u
  end })
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  ok(opened == nil, "must not open before the render finishes")
  util.wait(function()
    return opened ~= nil
  end, 5000, "browser open")
  eq(deck.url(), opened)
  ok(vim.fn.filereadable((qmd:gsub("%.qmd$", ".html"))) == 1)
end)

test("refuses non-qmd buffers", function()
  notes = {}
  vim.cmd.edit(vim.fn.tempname() .. ".md")
  vim.cmd("QuartoDeck start")
  eq(nil, deck._state())
  ok(noted("not a .qmd", vim.log.levels.ERROR))
end)

test("stop shuts the server down; wiping the buffer stops too", function()
  local st = fresh_deck()
  local port = st.port
  vim.cmd("QuartoDeck stop")
  eq(nil, deck._state())
  local refused
  local tcp = util.uv.new_tcp()
  tcp:connect("127.0.0.1", port, function(err)
    refused = err ~= nil
    tcp:close()
  end)
  util.wait(function()
    return refused ~= nil
  end)
  ok(refused)

  fresh_deck()
  vim.cmd("bwipeout!")
  eq(nil, deck._state())
end)

test("command completion lists subcommands", function()
  local c = vim.fn.getcompletion("QuartoDeck st", "cmdline")
  table.sort(c)
  eq({ "start", "status", "stop" }, c)
end)
