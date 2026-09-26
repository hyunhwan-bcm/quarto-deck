local parser = require("quarto-deck.parser")
local Server = require("quarto-deck.server")
local herdr = require("quarto-deck.herdr")

local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  -- quarto executable; $QUARTO_PATH wins over PATH lookup
  quarto = vim.env.QUARTO_PATH or "quarto",
  render_args = { "--to", "revealjs" },
  host = "127.0.0.1",
  port = 0, -- 0 = pick a free port
  auto_render = true, -- re-render on :write and reload the browser
  -- where the deck opens on :QuartoDeck start
  --   "auto": herdr panes when running inside herdr, else the system browser
  --   "herdr" | "browser" | "none"
  open = "auto",
  -- nil: vim.ui.open(url); string[]: argv with "{url}"; or function(url)
  browser = nil,
  sync_insert = false, -- follow the browser while in insert mode
  herdr = {
    cmd = "herdr",
    -- argv run in the agent pane (top right); false = no agent pane,
    -- nil = first executable in agent_candidates
    agent_cmd = nil,
    agent_candidates = { { "claude" } },
    -- argv of a terminal browser for the page pane (bottom right); "{url}" is
    -- replaced; false = no page pane (system browser), nil = first found
    page_cmd = nil,
    page_candidates = {
      -- https://github.com/zenbu-labs/terminal-browser (kitty graphics)
      { "terminal-browser", "open", "{url}", "--no-merge" },
      { "carbonyl", "{url}" },
      { "awrit", "{url}" },
      { "browsh", "--startup-url", "{url}" },
    },
    ratio = 0.5, -- herdr --ratio for the nvim | right-column split
    agent_ratio = 0.5, -- herdr --ratio for the agent / page split
    close_agent = false, -- also close the agent pane on :QuartoDeck stop
  },
}

M.config = vim.deepcopy(defaults)

---@type table|nil
local state = nil

local function client_js()
  local dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
  local f = assert(io.open(dir .. "/client.js", "r"))
  local js = f:read("*a")
  f:close()
  return js
end

local function notify(msg, level)
  vim.notify("quarto-deck: " .. msg, level or vim.log.levels.INFO)
end

local function log(msg)
  if not state then
    return
  end
  local f = io.open(state.log_path, "a")
  if f then
    f:write(os.date("%H:%M:%S "), msg, "\n")
    f:close()
  end
end

local function parsed()
  local tick = vim.api.nvim_buf_get_changedtick(state.buf)
  if state.tick ~= tick then
    state.parsed = parser.parse(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
    state.tick = tick
  end
  return state.parsed
end

local function cursor_index()
  local win = vim.fn.bufwinid(state.buf)
  local lnum = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  return parser.index_at(parsed(), lnum)
end

local function url()
  return ("http://%s:%d/"):format(M.config.host, state.port)
end

local function quarto_bin()
  local q = vim.fn.exepath(vim.fn.expand(M.config.quarto))
  return q ~= "" and q or nil
end

local function open_browser(u)
  local b = M.config.browser
  if type(b) == "function" then
    b(u)
  elseif type(b) == "table" then
    local argv = vim.tbl_map(function(a)
      return (a:gsub("{url}", u))
    end, b)
    vim.system(argv, { detach = true })
  else
    vim.ui.open(u)
  end
  log("opened " .. u)
end

-- browser -> nvim ---------------------------------------------------------

local function follow(index)
  if not M.config.sync_insert and vim.api.nvim_get_mode().mode:match("^[iR]") then
    return
  end
  local p = parsed()
  local line = parser.line_of(p, index)
  if not line then
    return
  end
  local win = vim.fn.bufwinid(state.buf)
  if win == -1 then
    return
  end
  if parser.index_at(p, vim.api.nvim_win_get_cursor(win)[1]) ~= index then
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end
end

local function on_event(msg)
  if not state then
    return
  end
  if msg.type == "hello" then
    state.browser_count = msg.count
    local n = #parsed().visible
    log(("browser ready: %d slides (source: %d)"):format(msg.count or -1, n))
    if msg.count ~= n and state.warned_count ~= msg.count then
      state.warned_count = msg.count
      notify(
        ("browser has %d slides but %s parses to %d; sync may be off (includes/shortcodes?)"):format(
          msg.count or -1,
          vim.fn.fnamemodify(state.file, ":t"),
          n
        ),
        vim.log.levels.WARN
      )
    end
  elseif msg.type == "slide" and type(msg.index) == "number" then
    state.index = msg.index
    log("browser -> slide " .. msg.index)
    follow(msg.index)
  end
end

-- nvim -> browser ---------------------------------------------------------

local function on_cursor()
  if not state then
    return
  end
  local index = cursor_index()
  if index ~= state.index then
    state.index = index
    state.server:broadcast({ type = "goto", index = index })
  end
end

-- rendering ---------------------------------------------------------------

function M.render(on_done)
  if not state then
    return notify("not running; use :QuartoDeck start", vim.log.levels.WARN)
  end
  if state.rendering then
    state.render_pending = true
    return
  end
  local q = quarto_bin()
  if not q then
    local msg = ("quarto not found (%s); set `quarto` in setup() or $QUARTO_PATH"):format(M.config.quarto)
    log("render failed: " .. msg)
    return notify(msg, vim.log.levels.ERROR)
  end
  local cmd = { q, "render", state.file }
  vim.list_extend(cmd, M.config.render_args)
  state.rendering = true
  local t0 = uv.hrtime()
  log("render: " .. table.concat(cmd, " "))
  vim.system(cmd, { cwd = state.dir, text = true }, function(r)
    vim.schedule(function()
      if not state then
        return
      end
      state.rendering = false
      local secs = (uv.hrtime() - t0) / 1e9
      if r.code == 0 then
        state.last_render = { ok = true, secs = secs }
        log(("rendered in %.1fs"):format(secs))
        state.server:broadcast({ type = "reload" })
        if on_done then
          on_done(true)
        end
      else
        state.last_render = { ok = false, secs = secs }
        local err = vim.trim(r.stderr or "")
        log("render failed (exit " .. r.code .. "):\n" .. err)
        local tail = table.concat(vim.list_slice(vim.split(err, "\n"), math.max(1, #vim.split(err, "\n") - 5)), "\n")
        notify("render failed:\n" .. tail, vim.log.levels.ERROR)
        if on_done then
          on_done(false)
        end
      end
      if state.render_pending then
        state.render_pending = false
        M.render()
      end
    end)
  end)
end

-- lifecycle ---------------------------------------------------------------

function M.open(how)
  if not state then
    return notify("not running; use :QuartoDeck start", vim.log.levels.WARN)
  end
  how = how or M.config.open
  if how == "none" then
    return
  end
  if how == "auto" then
    how = herdr.available(M.config.herdr) and "herdr" or "browser"
  end
  if how == "herdr" then
    return M.layout()
  end
  open_browser(url())
end

function M.layout()
  if not state then
    return notify("not running; use :QuartoDeck start", vim.log.levels.WARN)
  end
  local cfg = M.config.herdr
  if not herdr.available(cfg) then
    return notify("not inside a herdr pane (HERDR_ENV/HERDR_PANE_ID unset or herdr missing)", vim.log.levels.WARN)
  end
  herdr.close(cfg, state.panes)
  local panes, err, page_cmd = herdr.open(cfg, url(), state.dir)
  state.panes = panes
  log("herdr panes: " .. vim.inspect(panes, { newline = " ", indent = "" }))
  if err then
    notify(err, vim.log.levels.ERROR)
  end
  if not page_cmd then
    if cfg.page_cmd ~= false then
      notify("no terminal browser found (terminal-browser/carbonyl/awrit/browsh); opening the system browser")
    end
    open_browser(url())
  end
end

function M.start()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  if not file:match("%.qmd$") then
    return notify("current buffer is not a .qmd file", vim.log.levels.ERROR)
  end
  if state then
    if state.buf == buf then
      return notify("already running at " .. url())
    end
    M.stop()
  end
  file = vim.fn.fnamemodify(file, ":p")
  local dir = vim.fn.fnamemodify(file, ":h")
  local html = vim.fn.fnamemodify(file, ":t:r") .. ".html"

  state = {
    buf = buf,
    file = file,
    dir = dir,
    html = html,
    index = nil,
    panes = {},
    log_path = vim.fn.tempname() .. "-quarto-deck.log",
  }
  state.index = cursor_index()

  state.server = Server.new({
    root = dir,
    index = html,
    client_js = client_js(),
    on_event = on_event,
    on_connect = function()
      return state and { { type = "goto", index = cursor_index() } } or {}
    end,
    log = log,
  })
  local port, err = state.server:start(M.config.host, M.config.port)
  if not port then
    state = nil
    return notify("could not start server: " .. tostring(err), vim.log.levels.ERROR)
  end
  state.port = port
  log("serving " .. dir .. " at " .. url())

  local group = vim.api.nvim_create_augroup("QuartoDeck", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, buffer = buf, callback = on_cursor })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      if M.config.auto_render then
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, { group = group, buffer = buf, callback = M.stop })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })

  local stat_html = uv.fs_stat(dir .. "/" .. html)
  local stat_qmd = uv.fs_stat(file)
  local stale = not stat_html or (stat_qmd and stat_qmd.mtime.sec > stat_html.mtime.sec)
  if stale then
    M.render(function(ok)
      if ok then
        M.open()
      end
    end)
  else
    M.open()
  end
  notify("serving " .. url())
end

function M.stop()
  if not state then
    return
  end
  local s = state
  herdr.close(M.config.herdr, s.panes, not M.config.herdr.close_agent)
  s.server:stop()
  pcall(vim.api.nvim_del_augroup_by_name, "QuartoDeck")
  log("stopped")
  state = nil
end

function M.status()
  if not state then
    return notify("not running")
  end
  local p = parsed()
  local lines = {
    "url:     " .. url(),
    "file:    " .. state.file,
    ("slide:   %d / %d (browser reports %s)"):format(
      (state.index or 0) + 1,
      #p.visible,
      state.browser_count and tostring(state.browser_count) or "?"
    ),
    "clients: " .. state.server:client_count(),
    "render:  " .. (state.rendering and "running" or state.last_render and (state.last_render.ok and ("ok (%.1fs)"):format(
      state.last_render.secs
    ) or "failed") or "not run"),
    "log:     " .. state.log_path,
  }
  notify(table.concat(lines, "\n"))
end

function M.log()
  if not state then
    return notify("not running")
  end
  vim.cmd("split " .. vim.fn.fnameescape(state.log_path))
  vim.bo.autoread = true
end

function M.url()
  return state and url() or nil
end

--- For tests and statuslines.
function M._state()
  return state
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

M.commands = {
  start = M.start,
  stop = M.stop,
  open = function()
    M.open(M.config.open == "none" and "browser" or nil)
  end,
  render = function()
    M.render()
  end,
  status = M.status,
  layout = M.layout,
  log = M.log,
  url = function()
    local u = M.url()
    if u then
      pcall(vim.fn.setreg, "+", u)
      notify(u .. " (copied)")
    end
  end,
}

return M
