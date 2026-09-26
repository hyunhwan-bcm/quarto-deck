-- Headless test runner:  nvim --headless --clean -l tests/run.lua tests/spec/x_spec.lua
-- Each spec file runs in its own nvim process (see Makefile), so plugin state
-- never leaks between files. STRICT=1 turns skips into failures.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
vim.cmd("runtime plugin/quarto-deck.lua")
vim.o.swapfile = false
io.stdout:setvbuf("no")

-- Tests must never open the user's real browser.
_G.REAL_BROWSER_OPENS = {}
vim.ui.open = function(url)
  table.insert(_G.REAL_BROWSER_OPENS, url)
  error("test tried to open a real browser: " .. tostring(url))
end

local SKIP = {}
local tests = {}

-- TEST_FILTER=substring runs only matching tests
_G.test = function(name, fn)
  if not vim.env.TEST_FILTER or name:find(vim.env.TEST_FILTER, 1, true) then
    tests[#tests + 1] = { name = name, fn = fn }
  end
end
_G.skip = function(reason)
  error(setmetatable({ reason = reason }, SKIP), 0)
end
_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end
_G.ok = function(cond, msg)
  if not cond then
    error(msg or "assertion failed", 2)
  end
end
_G.ROOT = root

local file = assert(_G.arg[1], "usage: run.lua <spec>")
dofile(file)

local strict = vim.env.STRICT == "1"
local pass, fail, skipped = 0, 0, 0
local label = vim.fn.fnamemodify(file, ":t:r")
for _, t in ipairs(tests) do
  local ok_, err = xpcall(t.fn, function(e)
    if getmetatable(e) == SKIP then
      return e
    end
    return debug.traceback(tostring(e), 2)
  end)
  if ok_ and #_G.REAL_BROWSER_OPENS > 0 then
    ok_, err = false, "opened a real browser: " .. table.concat(_G.REAL_BROWSER_OPENS, ", ")
    _G.REAL_BROWSER_OPENS = {}
  end
  if ok_ then
    pass = pass + 1
    io.stdout:write(("  PASS  %s: %s\n"):format(label, t.name))
  elseif getmetatable(err) == SKIP then
    skipped = skipped + 1
    io.stdout:write(("  SKIP  %s: %s (%s)\n"):format(label, t.name, err.reason))
  else
    fail = fail + 1
    io.stdout:write(("  FAIL  %s: %s\n%s\n"):format(label, t.name, err))
  end
  pcall(function()
    require("quarto-deck").stop()
  end)
end
io.stdout:write(("%s: %d passed, %d failed, %d skipped\n"):format(label, pass, fail, skipped))
io.stdout:flush()
os.exit((fail > 0 or (strict and skipped > 0)) and 1 or 0)
