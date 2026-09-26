local uv = vim.uv or vim.loop

local M = {}

-- A deadline loop rather than vim.wait(ms, cond): conditions here often wait
-- themselves (CDP calls), and a nested vim.wait inside a vim.wait condition
-- doesn't honor the outer timeout.
function M.wait(cond, ms, what)
  local deadline = uv.now() + (ms or 5000)
  while true do
    if cond() then
      return
    end
    uv.update_time()
    if uv.now() > deadline then
      error("timed out waiting for " .. (what or "condition"), 2)
    end
    vim.wait(20)
  end
end

function M.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

function M.write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

function M.read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

function M.fixture(name)
  return M.read(ROOT .. "/tests/fixtures/" .. name)
end

--- Copy a fixture deck into a fresh temp dir; returns the .qmd path.
function M.deck(name)
  local d = M.tmpdir()
  local path = d .. "/" .. name
  M.write(path, M.fixture(name))
  return path
end

function M.quarto()
  for _, c in ipairs({ vim.env.QUARTO_PATH or "", "quarto" }) do
    if c ~= "" and vim.fn.executable(c) == 1 then
      return vim.fn.exepath(c)
    end
  end
end

function M.chrome()
  local candidates = {
    vim.env.CHROME_PATH or "",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
  }
  for _, c in ipairs(candidates) do
    if c ~= "" and vim.fn.executable(c) == 1 then
      return vim.fn.exepath(c)
    end
  end
end

function M.render(quarto, qmd)
  local r = vim.system({ quarto, "render", qmd, "--to", "revealjs" }, { cwd = vim.fn.fnamemodify(qmd, ":h"), text = true }):wait(120000)
  if r.code ~= 0 then
    error("quarto render failed: " .. (r.stderr or ""))
  end
  return M.read((qmd:gsub("%.qmd$", ".html")))
end

--- Leaf slides of a Quarto revealjs page, in DOM order, as Reveal.getSlides()
--- sees them: the title slide plus every section with the `slide` class.
function M.html_slides(html)
  local out = {}
  local pos = 1
  while true do
    local s, e, attrs = html:find("<section([^>]*)>", pos)
    if not s then
      break
    end
    local class = attrs:match('class="([^"]*)"') or ""
    local id = attrs:match('id="([^"]*)"')
    if id == "title-slide" or (" " .. class .. " "):find(" slide ", 1, true) then
      local rest = html:sub(e + 1, e + 400)
      local heading = rest:match("^%s*<h%d[^>]*>(.-)</h%d>") or ""
      heading = vim.trim((heading:gsub("<[^>]+>", "")))
      out[#out + 1] = { id = id, title = heading }
    end
    pos = e + 1
  end
  return out
end

M.uv = uv

return M
