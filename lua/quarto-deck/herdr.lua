-- herdr integration: put a coding agent and the rendered page next to the
-- nvim pane.
--
--   +------------------+------------------+
--   |                  |  agent           |
--   |  nvim            |  (claude, ...)   |
--   |                  +------------------+
--   |                  |  page            |
--   |                  |  (terminal       |
--   |                  |   browser)       |
--   +------------------+------------------+
--
-- Either pane can be turned off; with neither, nothing is split.

local M = {}

function M.available(cfg)
  return vim.env.HERDR_ENV == "1" and vim.env.HERDR_PANE_ID ~= nil and vim.fn.executable(cfg.cmd) == 1
end

local function run(cfg, args)
  local cmd = { cfg.cmd }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then
    return nil, ("herdr %s %s failed: %s"):format(args[1], args[2] or "", vim.trim(r.stderr or ""))
  end
  return r.stdout or ""
end

local function split(cfg, pane, direction, ratio, cwd)
  local out, err = run(cfg, {
    "pane", "split", pane,
    "--direction", direction,
    "--ratio", tostring(ratio),
    "--cwd", cwd,
    "--no-focus",
  })
  if not out then
    return nil, err
  end
  local ok, value = pcall(vim.json.decode, out)
  local id = ok and type(value) == "table" and vim.tbl_get(value, "result", "pane", "pane_id")
  if type(id) ~= "string" then
    return nil, "herdr pane split: unexpected output: " .. out
  end
  return id
end

--- First candidate argv whose program is executable.
function M.detect(candidates)
  for _, c in ipairs(candidates or {}) do
    if vim.fn.executable(c[1]) == 1 then
      return c
    end
  end
  return nil
end

local function shell_join(argv, url)
  local parts = {}
  for _, a in ipairs(argv) do
    parts[#parts + 1] = vim.fn.shellescape((a:gsub("{url}", url)))
  end
  return table.concat(parts, " ")
end

--- Resolve a pane command setting: false = off, table = argv, nil = detect.
local function resolve(setting, candidates)
  if setting == false then
    return nil
  end
  if type(setting) == "table" then
    return setting
  end
  return M.detect(candidates)
end

---@return table panes { agent = id?, page = id? }
---@return string|nil err
---@return table|nil page_cmd the terminal browser used, if any
function M.open(cfg, url, cwd)
  local panes = {}
  local agent_cmd = resolve(cfg.agent_cmd, cfg.agent_candidates)
  local page_cmd = resolve(cfg.page_cmd, cfg.page_candidates)
  if not agent_cmd and not page_cmd then
    return panes, nil, nil
  end

  local right, err = split(cfg, vim.env.HERDR_PANE_ID, "right", cfg.ratio, cwd)
  if not right then
    return panes, err, page_cmd
  end

  local page_pane = right
  if agent_cmd then
    panes.agent = right
    local _, rerr = run(cfg, { "pane", "run", right, shell_join(agent_cmd, url) })
    if rerr then
      return panes, rerr, page_cmd
    end
    if page_cmd then
      page_pane, err = split(cfg, right, "down", cfg.agent_ratio, cwd)
      if not page_pane then
        return panes, err, page_cmd
      end
    end
  end

  if page_cmd then
    panes.page = page_pane
    local _, rerr = run(cfg, { "pane", "run", page_pane, shell_join(page_cmd, url) })
    if rerr then
      return panes, rerr, page_cmd
    end
  end
  return panes, nil, page_cmd
end

function M.close(cfg, panes, keep_agent)
  for role, id in pairs(panes or {}) do
    if not (keep_agent and role == "agent") then
      run(cfg, { "pane", "close", id })
    end
  end
end

return M
