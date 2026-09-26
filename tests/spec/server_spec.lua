local Server = require("quarto-deck.server")
local util = require("helpers.util")
local http = require("helpers.http")

local dir = util.tmpdir()
util.write(dir .. "/slides.html", "<html><body><p>x</p></BODY></html>")
util.write(dir .. "/img/a.png", "PNGDATA")
util.write(dir .. "/../secret.txt", "secret")

local events = {}
local srv = Server.new({
  root = dir,
  index = "slides.html",
  client_js = "/*client*/",
  on_event = function(m)
    events[#events + 1] = m
  end,
  on_connect = function()
    return { { type = "goto", index = 3 } }
  end,
})
local port = assert(srv:start("127.0.0.1", 0))

test("binds an ephemeral loopback port", function()
  ok(port > 0)
end)

test("serves the deck at / with the client injected before </body>", function()
  local r = http.request(port, "GET", "/")
  eq(200, r.status)
  eq("text/html; charset=utf-8", r.headers["content-type"])
  ok(r.body:find('<p>x</p><script src="/__quarto_deck/client.js"></script>\n</BODY>', 1, true), r.body)
end)

test("inject appends when there is no </body>", function()
  eq('a<script src="/__quarto_deck/client.js"></script>', Server.inject("a"))
end)

test("serves the client script", function()
  local r = http.request(port, "GET", "/__quarto_deck/client.js")
  eq(200, r.status)
  eq("/*client*/", r.body)
end)

test("serves static assets with a content type; ignores query strings", function()
  local r = http.request(port, "GET", "/img/a.png?v=1")
  eq(200, r.status)
  eq("image/png", r.headers["content-type"])
  eq("PNGDATA", r.body)
end)

test("404 for missing files and directories", function()
  eq(404, http.request(port, "GET", "/nope.css").status)
  eq(404, http.request(port, "GET", "/img").status)
end)

test("refuses path traversal, including encoded", function()
  eq(403, http.request(port, "GET", "/../secret.txt").status)
  eq(403, http.request(port, "GET", "/img/%2e%2e/%2e%2e/secret.txt").status)
end)

test("POST /event delivers JSON to on_event", function()
  local r = http.request(port, "POST", "/__quarto_deck/event", '{"type":"slide","index":4}')
  eq(204, r.status)
  util.wait(function()
    return #events == 1
  end)
  eq({ type = "slide", index = 4 }, events[1])
end)

test("bad event requests are rejected", function()
  eq(400, http.request(port, "POST", "/__quarto_deck/event", "not json").status)
  eq(405, http.request(port, "GET", "/__quarto_deck/event").status)
  eq(405, http.request(port, "PUT", "/slides.html", "x").status)
end)

test("SSE: on_connect messages, then broadcasts to every client", function()
  local a = http.sse(port, "/__quarto_deck/events")
  local b = http.sse(port, "/__quarto_deck/events")
  util.wait(function()
    return #a.messages == 1 and #b.messages == 1
  end, 3000, "initial goto")
  eq({ type = "goto", index = 3 }, a.messages[1])
  ok(a.raw:find("Content-Type: text/event-stream", 1, true))
  eq(2, srv:client_count())
  srv:broadcast({ type = "reload" })
  util.wait(function()
    return #a.messages == 2 and #b.messages == 2
  end, 3000, "broadcast")
  eq({ type = "reload" }, b.messages[2])
  a:close()
  util.wait(function()
    return srv:client_count() == 1
  end, 3000, "closed client dropped")
  b:close()
end)

test("stop closes the listener", function()
  srv:stop()
  local refused = false
  local tcp = util.uv.new_tcp()
  tcp:connect("127.0.0.1", port, function(err)
    refused = err ~= nil
    tcp:close()
  end)
  util.wait(function()
    return tcp:is_closing()
  end)
  ok(refused, "connection should be refused")
end)
