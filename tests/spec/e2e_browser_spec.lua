-- Full loop with real tools: quarto renders the deck, headless Chrome runs
-- reveal.js with the injected client, and CDP plays the user (key presses).
local deck = require("quarto-deck")
local util = require("helpers.util")
local cdp = require("helpers.cdp")

vim.notify = function(msg, level)
  io.stdout:write("    notify: " .. msg .. "\n")
end

local CURRENT = "Reveal.getSlides().indexOf(Reveal.getCurrentSlide())"
local TITLE = "(Reveal.getCurrentSlide().querySelector('h1,h2')||{}).textContent||''"

local function cursor()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function move(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

test("nvim <-> headless Chrome sync, including live re-render", function()
  local quarto, chrome = util.quarto(), util.chrome()
  if not quarto then
    skip("quarto not found (set QUARTO_PATH)")
  end
  if not chrome then
    skip("Chrome/Chromium not found (set CHROME_PATH)")
  end

  local qmd = util.deck("deck.qmd")
  local opened
  deck.setup({ quarto = quarto, open = "browser", browser = function(u)
    opened = u
  end })
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  local st = assert(deck._state())
  util.wait(function()
    return opened ~= nil
  end, 120000, "initial quarto render")

  local browser = cdp.launch(chrome, opened)
  local page = browser.page
  local ok_, err = pcall(function()
    local function page_at(i, what)
      util.wait(function()
        local okk, v = pcall(page.eval, page, CURRENT)
        return okk and v == i
      end, 10000, what or ("browser on slide " .. i))
    end

    -- the client says hello with the DOM slide count, which matches the parser
    util.wait(function()
      return st.browser_count ~= nil
    end, 20000, "client hello")
    eq(9, st.browser_count, "browser slide count")
    page_at(0, "browser starts on the title slide")

    -- nvim -> browser, into a vertical stack (h/v navigation)
    move(23) -- "## Columns"
    page_at(3)
    eq("Columns", page:eval(TITLE))
    eq({ h = 1, v = 2 }, page:eval("(({h,v}) => ({h,v}))(Reveal.getIndices())"))

    move(49) -- "## Slide with notes" in the second stack
    page_at(7)
    eq("Slide with notes", page:eval(TITLE))

    -- browser -> nvim, driven by real key presses
    move(23)
    page_at(3)
    page:key("ArrowRight", "ArrowRight", 39)
    util.wait(function()
      return cursor() == 34
    end, 5000, "cursor on the rule slide (line 34)")
    page:key("ArrowRight", "ArrowRight", 39)
    util.wait(function()
      return cursor() == 42
    end, 5000, "cursor on 'Setext heading' (line 42)")
    page:key("ArrowLeft", "ArrowLeft", 37)
    util.wait(function()
      return cursor() == 34
    end, 5000, "cursor back on line 34")
    -- the browser stayed where the user put it (no echo bounced it back)
    vim.wait(300)
    eq(4, page:eval(CURRENT))

    -- edit + :write -> quarto re-renders -> page reloads on nvim's slide
    vim.api.nvim_buf_set_lines(0, 56, 56, false, { "## Inserted live", "", "new content", "" })
    move(57)
    vim.cmd("silent write")
    util.wait(function()
      local okk, n = pcall(page.eval, page, "Reveal.getSlides().length")
      return okk and n == 10
    end, 120000, "page reloaded with 10 slides")
    page_at(8, "reloaded page on the inserted slide")
    eq("Inserted live", page:eval(TITLE))
    eq(10, st.browser_count)
  end)
  browser.close()
  if not ok_ then
    error(err, 0)
  end
end)

test("narrow viewport (Reveal scroll view, as in a terminal-browser pane)", function()
  local quarto, chrome = util.quarto(), util.chrome()
  if not quarto then
    skip("quarto not found (set QUARTO_PATH)")
  end
  if not chrome then
    skip("Chrome/Chromium not found (set CHROME_PATH)")
  end

  local warnings = {}
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then
      warnings[#warnings + 1] = msg
    end
  end
  local qmd = util.deck("deck.qmd")
  local opened
  deck.setup({ quarto = quarto, open = "browser", browser = function(u)
    opened = u
  end })
  vim.cmd.edit(qmd)
  vim.cmd("QuartoDeck start")
  local st = assert(deck._state())
  util.wait(function()
    return opened ~= nil
  end, 120000, "initial quarto render")

  local browser = cdp.launch(chrome, opened)
  local page = browser.page
  local ok_, err = pcall(function()
    page:call("Emulation.setDeviceMetricsOverride", { width = 380, height = 700, deviceScaleFactor = 1, mobile = false })
    st.browser_count = nil
    page:call("Page.reload", { ignoreCache = true })
    util.wait(function()
      local okk, v = pcall(page.eval, page, "Reveal.isScrollView && Reveal.isScrollView()")
      return okk and v == true
    end, 10000, "Reveal scroll view active")
    util.wait(function()
      return st.browser_count ~= nil
    end, 20000, "client hello")
    eq(9, st.browser_count, "slide count in scroll view")
    eq({}, warnings, "no mismatch warning")

    move(49)
    util.wait(function()
      local okk, v = pcall(page.eval, page, TITLE)
      return okk and v == "Slide with notes"
    end, 10000, "browser on 'Slide with notes'")

    page:eval("Reveal.prev()")
    util.wait(function()
      return cursor() == 47
    end, 5000, "cursor on 'Second section' (line 47)")
  end)
  browser.close()
  if not ok_ then
    error(err, 0)
  end
end)
