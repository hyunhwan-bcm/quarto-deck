-- Drive headless Chrome over the DevTools protocol, from Lua, for end-to-end
-- tests. Includes a minimal WebSocket client (RFC 6455, text frames only).
local uv = vim.uv or vim.loop
local bit = require("bit")
local util = require("helpers.util")
local http = require("helpers.http")

local M = {}

local function ws_frame(payload)
  local len = #payload
  local head
  if len < 126 then
    head = string.char(0x81, 0x80 + len)
  elseif len < 65536 then
    head = string.char(0x81, 0x80 + 126, bit.rshift(len, 8), bit.band(len, 0xff))
  else
    head = string.char(0x81, 0x80 + 127, 0, 0, 0, 0,
      bit.band(bit.rshift(len, 24), 0xff), bit.band(bit.rshift(len, 16), 0xff),
      bit.band(bit.rshift(len, 8), 0xff), bit.band(len, 0xff))
  end
  local key = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  local out = {}
  for i = 1, len do
    out[i] = string.char(bit.bxor(payload:byte(i), key[(i - 1) % 4 + 1]))
  end
  return head .. string.char(unpack(key)) .. table.concat(out)
end

--- Parse as many complete frames as possible; returns messages, remaining buffer.
local function ws_parse(buf, partial)
  local msgs = {}
  while #buf >= 2 do
    local b1, b2 = buf:byte(1, 2)
    local fin = bit.band(b1, 0x80) ~= 0
    local op = bit.band(b1, 0x0f)
    local len = bit.band(b2, 0x7f)
    local off = 3
    if len == 126 then
      if #buf < 4 then break end
      len = buf:byte(3) * 256 + buf:byte(4)
      off = 5
    elseif len == 127 then
      if #buf < 10 then break end
      len = 0
      for i = 3, 10 do
        len = len * 256 + buf:byte(i)
      end
      off = 11
    end
    if #buf < off + len - 1 then break end
    local payload = buf:sub(off, off + len - 1)
    buf = buf:sub(off + len)
    if op == 0x1 or op == 0x0 then
      partial.data = (partial.data or "") .. payload
      if fin then
        msgs[#msgs + 1] = partial.data
        partial.data = nil
      end
    end
  end
  return msgs, buf
end

local Page = {}
Page.__index = Page

function Page:call(method, params)
  self.id = self.id + 1
  local id = self.id
  self.tcp:write(ws_frame(vim.json.encode({ id = id, method = method, params = (params and next(params)) and params or vim.empty_dict() })))
  util.wait(function()
    return self.responses[id] ~= nil
  end, 10000, "CDP " .. method)
  local r = self.responses[id]
  self.responses[id] = nil
  if r.error then
    error("CDP " .. method .. ": " .. vim.inspect(r.error))
  end
  return r.result
end

--- Evaluate a JS expression in the page and return its value.
function Page:eval(expr)
  local r = self:call("Runtime.evaluate", { expression = expr, returnByValue = true, awaitPromise = true })
  if r.exceptionDetails then
    error("JS error: " .. vim.inspect(r.exceptionDetails))
  end
  return r.result.value
end

--- Real key press, the way a user navigates the deck.
function Page:key(key, code, keycode)
  local base = { key = key, code = code, windowsVirtualKeyCode = keycode, nativeVirtualKeyCode = keycode }
  self:call("Input.dispatchKeyEvent", vim.tbl_extend("force", base, { type = "rawKeyDown" }))
  self:call("Input.dispatchKeyEvent", vim.tbl_extend("force", base, { type = "keyUp" }))
end

local function connect_ws(ws_url)
  local host, port, path = ws_url:match("^ws://([^:/]+):(%d+)(/.*)$")
  assert(host, "unexpected websocket url: " .. tostring(ws_url))
  local page = setmetatable({ id = 0, responses = {}, events = {} }, Page)
  local upgraded, buf, partial = false, "", {}
  page.tcp = uv.new_tcp()
  page.tcp:connect(host, tonumber(port), function(err)
    assert(not err, err)
    page.tcp:write(table.concat({
      "GET " .. path .. " HTTP/1.1",
      "Host: " .. host .. ":" .. port,
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n"))
    page.tcp:read_start(function(_, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      if not upgraded then
        local s = buf:find("\r\n\r\n", 1, true)
        if not s then
          return
        end
        assert(buf:match("^HTTP/1.1 101"), "websocket upgrade failed: " .. buf:sub(1, 80))
        upgraded = true
        buf = buf:sub(s + 4)
      end
      local msgs
      msgs, buf = ws_parse(buf, partial)
      for _, m in ipairs(msgs) do
        local ok, decoded = pcall(vim.json.decode, m)
        if ok then
          if decoded.id then
            page.responses[decoded.id] = decoded
          else
            page.events[#page.events + 1] = decoded
          end
        end
      end
    end)
  end)
  util.wait(function()
    return upgraded
  end, 5000, "websocket upgrade")
  return page
end

--- Launch headless Chrome on `url`; returns { page = Page, close = fn }.
function M.launch(chrome, url, size)
  local profile = util.tmpdir()
  local proc = vim.system({
    chrome,
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--remote-debugging-port=0",
    "--user-data-dir=" .. profile,
    "--window-size=" .. (size or "1280,720"),
    url,
  }, { text = true })
  local function kill()
    proc:kill(15)
    pcall(function()
      proc:wait(5000)
    end)
    vim.fn.delete(profile, "rf")
  end
  local ok, res = pcall(M._attach, proc, profile, url)
  if not ok then
    kill()
    error(res, 0)
  end
  local page = res
  return {
    page = page,
    port = page.devtools_port,
    --- Open another tab and return its Page (e.g. to composite frames).
    new_page = function(u)
      local r = http.request(page.devtools_port, "PUT", "/json/new?" .. (u or "about:blank"))
      return connect_ws(vim.json.decode(r.body).webSocketDebuggerUrl)
    end,
    close = function()
      if not page.tcp:is_closing() then
        page.tcp:close()
      end
      kill()
    end,
  }
end

function M._attach(proc, profile, url)
  local port
  util.wait(function()
    local s = util.read(profile .. "/DevToolsActivePort")
    port = s and tonumber(s:match("^(%d+)"))
    return port ~= nil
  end, 20000, "Chrome DevToolsActivePort")

  local ws
  for _ = 1, 50 do
    local r = http.request(port, "GET", "/json/list")
    for _, t in ipairs(vim.json.decode(r.body)) do
      if t.type == "page" and t.url:find(url, 1, true) == 1 then
        ws = t.webSocketDebuggerUrl
      end
    end
    if ws then
      break
    end
    vim.wait(200)
  end
  assert(ws, "no Chrome page target for " .. url)

  local page = connect_ws(ws)
  page.devtools_port = port
  return page
end

--- Screenshot as raw PNG bytes.
function Page:screenshot()
  local r = self:call("Page.captureScreenshot", { format = "png" })
  return vim.base64.decode(r.data)
end

return M
