-- Tiny HTTP / SSE client on libuv, so tests don't depend on curl.
local uv = vim.uv or vim.loop
local util = require("helpers.util")

local M = {}

local function connect(port, on_connect)
  local tcp = uv.new_tcp()
  tcp:connect("127.0.0.1", port, function(err)
    on_connect(err, tcp)
  end)
  return tcp
end

--- Synchronous request. Returns { status, headers (lowercased), body }.
function M.request(port, method, path, body)
  local res, buf, done, cerr = nil, "", false, nil
  connect(port, function(err, tcp)
    if err then
      cerr, done = err, true
      return
    end
    local req = ("%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(
      method,
      path,
      port,
      body and #body or 0,
      body or ""
    )
    tcp:write(req)
    tcp:read_start(function(rerr, chunk)
      if chunk then
        buf = buf .. chunk
        -- some servers (Chrome DevTools) keep the connection open
        local head, rest = buf:match("^(.-)\r\n\r\n(.*)$")
        local len = head and tonumber(head:lower():match("content%-length:%s*(%d+)"))
        if len and #rest >= len then
          tcp:close()
          done = true
        end
      else
        if not tcp:is_closing() then
          tcp:close()
        end
        done = true
      end
    end)
  end)
  util.wait(function()
    return done
  end, 5000, method .. " " .. path)
  if cerr then
    error("connect failed: " .. cerr)
  end
  local head, rest = buf:match("^(.-)\r\n\r\n(.*)$")
  res = { status = tonumber(head:match("^HTTP/%d%.%d (%d+)")), headers = {}, body = rest }
  for k, v in head:gmatch("\r\n([^:]+):%s*([^\r]*)") do
    res.headers[k:lower()] = v
  end
  return res
end

--- Open an SSE stream; returns a handle with .messages (decoded JSON) and :close().
function M.sse(port, path)
  local h = { messages = {}, raw = "", connected = false }
  local buf = ""
  h.tcp = connect(port, function(err, tcp)
    if err then
      return
    end
    tcp:write(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"):format(path))
    tcp:read_start(function(_, chunk)
      if not chunk then
        return
      end
      h.raw = h.raw .. chunk
      buf = buf .. chunk
      if not h.connected then
        local s = buf:find("\r\n\r\n", 1, true)
        if not s then
          return
        end
        h.connected = true
        buf = buf:sub(s + 4)
      end
      while true do
        local s, e = buf:find("\n\n", 1, true)
        if not s then
          break
        end
        local event = buf:sub(1, s - 1)
        buf = buf:sub(e + 1)
        local data = event:match("^data: (.*)$")
        if data then
          h.messages[#h.messages + 1] = vim.json.decode(data)
        end
      end
    end)
  end)
  function h:close()
    if not self.tcp:is_closing() then
      self.tcp:close()
    end
  end
  function h:of_type(t)
    return vim.tbl_filter(function(m)
      return m.type == t
    end, self.messages)
  end
  util.wait(function()
    return h.connected
  end, 3000, "SSE connect")
  return h
end

return M
