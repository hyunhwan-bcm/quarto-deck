-- Maps a Quarto revealjs .qmd source onto the ordered list of slides that
-- Reveal.getSlides() returns in the browser. The rules mirror what Quarto
-- (Pandoc) actually emits; tests/spec/quarto_parity_spec.lua checks them
-- against real `quarto render` output.
--
-- Rules:
--   * a front-matter `title:` produces the title slide (index 0)
--   * a heading with level <= slide-level starts a slide, even inside ::: divs
--   * `visibility="hidden"` slides are dropped from the output
--   * a horizontal rule starts a slide, unless the next block is a slide heading
--   * content before the first slide break becomes its own untitled slide
--   * fenced code blocks and HTML comments are ignored

local M = {}

local function front_matter(lines)
  if lines[1] ~= "---" then
    return nil
  end
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then
      return i
    end
  end
  return nil
end

local function is_blank(s)
  return s:match("^%s*$") ~= nil
end

local function atx(line)
  local hashes, rest = line:match("^ ? ? ?(#+)(.*)$")
  if not hashes or #hashes > 6 then
    return nil
  end
  if rest ~= "" and not rest:match("^%s") then
    return nil -- "#tag" is not a heading
  end
  return #hashes, rest
end

-- Returns "-" / "*" / "_" when the line is a thematic break.
local function rule_char(line)
  local c = line:match("^ ? ? ?([-*_])")
  if not c then
    return nil
  end
  local stripped = line:gsub("%s", "")
  if #stripped >= 3 and stripped:match("^%" .. c .. "+$") then
    return c
  end
  return nil
end

local function fence_open(line)
  local indent, marks = line:match("^( ? ? ?)(```+)")
  if not marks then
    indent, marks = line:match("^( ? ? ?)(~~~+)")
  end
  return marks
end

local function clean_title(text)
  local attrs = text:match("%s*(%b{})%s*$")
  local title = text
  if attrs then
    title = text:sub(1, #text - #text:match("%s*%b{}%s*$"))
  end
  title = title:gsub("%s+#+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return title, attrs or ""
end

local function plain_text(line)
  -- a line that could be the text of a setext heading
  return not is_blank(line)
    and not line:match("^%s*[-*+] ")
    and not line:match("^%s*%d+[.)] ")
    and not line:match("^%s*[|<>:]")
    and not atx(line)
    and not rule_char(line)
    and not fence_open(line)
end

---@param lines string[]
function M.parse(lines)
  local fm_end = front_matter(lines)
  local slide_level = 2
  local has_title = false
  if fm_end then
    for i = 2, fm_end - 1 do
      local lvl = lines[i]:match("^%s*slide%-level:%s*(%d)")
      if lvl then
        slide_level = tonumber(lvl)
      end
      local t = lines[i]:match("^title:%s*(.-)%s*$")
      if t and t ~= "" and t ~= '""' and t ~= "''" then
        has_title = true
      end
    end
  end

  local slides = {}
  local function add(line, kind, title, level, hidden)
    slides[#slides + 1] = { line = line, kind = kind, title = title or "", level = level, hidden = hidden or false }
  end
  if has_title then
    add(1, "title", "")
  end

  local started = false -- has any body slide begun?
  local pending_rule = nil
  local function content(line)
    if pending_rule then
      add(pending_rule, "rule")
      pending_rule = nil
      started = true
    elseif not started then
      add(line, "content")
      started = true
    end
  end

  local fence, in_comment = nil, false
  local i = (fm_end or 0) + 1
  local prev_blank = true
  while i <= #lines do
    local line = lines[i]
    if in_comment then
      if line:find("-->", 1, true) then
        in_comment = false
      end
    elseif fence then
      local marks = line:match("^%s*(" .. fence:sub(1, 1):rep(3) .. "+)%s*$")
      if marks and #marks >= #fence then
        fence = nil
      end
    elseif is_blank(line) then
      -- nothing
    elseif line:match("^%s*<!%-%-") then
      local rest = line:match("^%s*<!%-%-(.*)$")
      if not rest:find("-->", 1, true) then
        in_comment = true
      end
    elseif fence_open(line) then
      fence = fence_open(line)
      content(i)
    else
      local level, rest = atx(line)
      local setext = nil
      local nxt = lines[i + 1]
      if not level and prev_blank and nxt and plain_text(line) then
        if nxt:match("^ ? ? ?=+%s*$") then
          setext = 1
        elseif nxt:match("^ ? ? ?%-+%s*$") then
          setext = 2
        end
      end
      if setext then
        level, rest = setext, line
      end

      if level and level <= slide_level then
        local title, attrs = clean_title(rest)
        local hidden = attrs:match("visibility%s*=%s*[\"']?hidden") ~= nil
        pending_rule = nil -- a rule right before a slide heading is dropped
        add(i, "heading", title, level, hidden)
        started = true
        if setext then
          i = i + 1
        end
      elseif level then
        content(i)
        if setext then
          i = i + 1
        end
      elseif rule_char(line) then
        if pending_rule then
          add(pending_rule, "rule")
        end
        pending_rule = i
        started = true
      else
        content(i)
      end
    end
    prev_blank = is_blank(line)
    i = i + 1
  end
  if pending_rule then
    add(pending_rule, "rule")
  end

  local visible = {}
  for _, s in ipairs(slides) do
    if not s.hidden then
      visible[#visible + 1] = s
      s.index = #visible - 1
    end
  end

  return { slides = slides, visible = visible, slide_level = slide_level, has_title_slide = has_title }
end

--- 0-based index into Reveal.getSlides() of the slide containing `lnum`.
function M.index_at(parsed, lnum)
  local found = nil
  for _, s in ipairs(parsed.slides) do
    if s.line > lnum then
      break
    end
    if not s.hidden then
      found = s
    end
  end
  return found and found.index or 0
end

--- 1-based line where the slide with 0-based `index` starts.
function M.line_of(parsed, index)
  local s = parsed.visible[index + 1]
  return s and s.line or nil
end

return M
