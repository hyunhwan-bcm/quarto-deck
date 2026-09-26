-- Minimal HTTP server on libuv: serves the rendered deck, injects the sync
-- client into HTML pages, pushes commands over Server-Sent Events, and takes
-- browser events as JSON POSTs. Binds to loopback only.

local uv = vim.uv or vim.loop

local M = {}
M.__index = M

local PREFIX = "/__quarto_deck"

local MIME = {
  html = "text/html; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  mjs = "text/javascript; charset=utf-8",
  css = "text/css; charset=utf-8",
  json = "application/json",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  ico = "image/x-icon",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
  mp4 = "video/mp4",
  webm = "video/webm",
  pdf = "application/pdf",
  txt = "text/plain; charset=utf-8",
}

local STATUS = { [200] = "OK", [204] = "No Content", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed" }

local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.type ~= "file" then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---@class QuartoDeckServerOpts
---@field root string directory to serve
---@field index string file served for "/"
---@field client_js string
---@field on_event fun(msg: table) called on the main loop
---@field on_connect? fun(): table[] messages sent to a newly connected client
---@field log? fun(msg: string)

---@param opts QuartoDeckServerOpts
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = opts
  self.clients = {}
  self.log = opts.log or function() end
  return self
end

function M:start(host, port)
  self.tcp = uv.new_tcp()
  local ok, err = self.tcp:bind(host or "127.0.0.1", port or 0)
  if not ok then
    self.tcp:close()
    self.tcp = nil
    return nil, err
  end
  ok, err = self.tcp:listen(64, function(lerr)
    if lerr then
      return
    end
    local client = uv.new_tcp()
    self.tcp:accept(client)
    self:_handle(client)
  end)
  if not ok then
    self.tcp:close()
    self.tcp = nil
    return nil, err
  end
  self.port = self.tcp:getsockname().port
  self.ping = uv.new_timer()
  self.ping:start(15000, 15000, function()
    self:_send_raw(": ping\n\n")
  end)
  return self.port
end

function M:stop()
  if self.ping then
    self.ping:stop()
    self.ping:close()
    self.ping = nil
  end
  for c in pairs(self.clients) do
    if not c:is_closing() then
      c:close()
    end
  end
  self.clients = {}
  if self.tcp and not self.tcp:is_closing() then
    self.tcp:close()
  end
  self.tcp = nil
end

function M:client_count()
  local n = 0
  for c in pairs(self.clients) do
    if not c:is_closing() then
      n = n + 1
    end
  end
  return n
end

function M:_send_raw(chunk)
  for c in pairs(self.clients) do
    if c:is_closing() then
      self.clients[c] = nil
    else
      c:write(chunk, function(err)
        if err then
          self.clients[c] = nil
          if not c:is_closing() then
            c:close()
          end
        end
      end)
    end
  end
end

--- Send a message to every connected browser.
function M:broadcast(msg)
  self:_send_raw("data: " .. vim.json.encode(msg) .. "\n\n")
end

local function respond(client, code, headers, body)
  body = body or ""
  local out = { ("HTTP/1.1 %d %s"):format(code, STATUS[code] or "OK") }
  headers = headers or {}
  headers["Content-Length"] = #body
  headers["Connection"] = "close"
  headers["Cache-Control"] = headers["Cache-Control"] or "no-store"
  for k, v in pairs(headers) do
    out[#out + 1] = k .. ": " .. v
  end
  client:write(table.concat(out, "\r\n") .. "\r\n\r\n" .. body, function()
    if not client:is_closing() then
      client:shutdown(function()
        if not client:is_closing() then
          client:close()
        end
      end)
    end
  end)
end

function M:_handle(client)
  local buf = ""
  client:read_start(function(err, chunk)
    if err or not chunk then
      if not client:is_closing() then
        client:close()
      end
      self.clients[client] = nil
      return
    end
    if self.clients[client] then
      return -- SSE clients don't send anything we care about
    end
    buf = buf .. chunk
    local head_end = buf:find("\r\n\r\n", 1, true)
    if not head_end then
      if #buf > 65536 then
        respond(client, 400)
      end
      return
    end
    local head = buf:sub(1, head_end - 1)
    local method, target = head:match("^(%u+) (%S+) HTTP/%d%.%d")
    if not method then
      respond(client, 400)
      return
    end
    local len = tonumber(head:lower():match("\r\ncontent%-length:%s*(%d+)")) or 0
    local body = buf:sub(head_end + 4)
    if #body < len then
      return
    end
    client:read_stop()
    self:_route(client, method, target, body:sub(1, len))
  end)
end

function M:_route(client, method, target, body)
  local path = url_decode((target:gsub("[?#].*$", "")))

  if path == PREFIX .. "/events" then
    client:write(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
        .. "Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 1000\n\n"
    )
    self.clients[client] = true
    client:read_start(function(err, chunk)
      if err or not chunk then
        self.clients[client] = nil
        if not client:is_closing() then
          client:close()
        end
      end
    end)
    local on_connect = self.opts.on_connect
    if on_connect then
      vim.schedule(function()
        for _, msg in ipairs(on_connect() or {}) do
          if not client:is_closing() then
            client:write("data: " .. vim.json.encode(msg) .. "\n\n")
          end
        end
      end)
    end
    self.log("browser connected")
    return
  end

  if path == PREFIX .. "/event" then
    if method ~= "POST" then
      return respond(client, 405)
    end
    local ok, msg = pcall(vim.json.decode, body)
    if not ok or type(msg) ~= "table" then
      return respond(client, 400)
    end
    respond(client, 204)
    vim.schedule(function()
      self.opts.on_event(msg)
    end)
    return
  end

  if path == PREFIX .. "/client.js" then
    return respond(client, 200, { ["Content-Type"] = MIME.js }, self.opts.client_js)
  end

  if method ~= "GET" and method ~= "HEAD" then
    return respond(client, 405)
  end

  if path == "/" then
    path = "/" .. self.opts.index
  end
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      return respond(client, 403)
    end
  end
  local file = self.opts.root .. path
  local data = read_file(file)
  if not data then
    return respond(client, 404, { ["Content-Type"] = MIME.txt }, "not found")
  end
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if ext == "html" then
    data = M.inject(data)
  end
  respond(client, 200, { ["Content-Type"] = MIME[ext] or "application/octet-stream" }, method == "HEAD" and "" or data)
end

--- Insert the sync client before the last </body>.
function M.inject(html)
  local tag = '<script src="' .. PREFIX .. '/client.js"></script>'
  local lower = html:lower()
  local pos, last = 1, nil
  while true do
    local s = lower:find("</body>", pos, true)
    if not s then
      break
    end
    last, pos = s, s + 1
  end
  if last then
    return html:sub(1, last - 1) .. tag .. "\n" .. html:sub(last)
  end
  return html .. tag
end

M.PREFIX = PREFIX

return M
