local parser = require("quarto-deck.parser")
local util = require("helpers.util")

local function parse(s)
  return parser.parse(vim.split(s, "\n", { plain = true }))
end

local function lines_of(p)
  return vim.tbl_map(function(s)
    return s.line
  end, p.visible)
end

test("fixture deck: slide starts and titles", function()
  local p = parse(util.fixture("deck.qmd"))
  eq({ 1, 7, 9, 23, 34, 42, 47, 49, 57 }, lines_of(p))
  eq(
    { "", "Introduction", "First slide", "Columns", "", "Setext heading", "Second section", "Slide with notes", "Last slide" },
    vim.tbl_map(function(s)
      return s.title
    end, p.visible)
  )
  eq(true, p.has_title_slide)
end)

test("index_at maps every line to its slide", function()
  local p = parse(util.fixture("deck.qmd"))
  eq(0, parser.index_at(p, 1)) -- front matter = title slide
  eq(0, parser.index_at(p, 6))
  eq(1, parser.index_at(p, 7))
  eq(2, parser.index_at(p, 15)) -- inside a code block with '#' lines
  eq(2, parser.index_at(p, 20)) -- hidden slide folds into the previous one
  eq(3, parser.index_at(p, 30)) -- inside ::: columns
  eq(4, parser.index_at(p, 39)) -- commented-out heading
  eq(5, parser.index_at(p, 43))
  eq(8, parser.index_at(p, 59))
  eq(8, parser.index_at(p, 10000))
end)

test("line_of is the inverse of index_at at slide starts", function()
  local p = parse(util.fixture("deck.qmd"))
  for i, s in ipairs(p.visible) do
    eq(s.line, parser.line_of(p, i - 1))
    eq(i - 1, parser.index_at(p, s.line))
  end
  eq(nil, parser.line_of(p, 99))
end)

test("no title: leading content slide, dropped and kept rules", function()
  local p = parse(util.fixture("edge.qmd"))
  eq(false, p.has_title_slide)
  -- content(5), heading(9), B(13), Big(17 setext h1), D(20), rule(22), rule(24)
  eq({ 5, 9, 13, 17, 20, 22, 24 }, lines_of(p))
end)

test("slide-level from front matter", function()
  local p = parse(util.fixture("level1.qmd"))
  eq(1, p.slide_level)
  eq({ 1, 8, 14 }, lines_of(p))
end)

test("headings: closing hashes, attributes, and non-headings", function()
  local p = parse(table.concat({
    "## Title ##",
    "#hashtag is text",
    "## With attrs {#id .cls data-x=\"1\"}",
    "  ## indented up to three",
    "    ## four spaces is code",
  }, "\n"))
  eq({ "Title", "With attrs", "indented up to three" }, vim.tbl_map(function(s)
    return s.title
  end, p.visible))
end)

test("tilde fences and longer closing fences", function()
  local p = parse(table.concat({
    "## A",
    "~~~~",
    "## inside",
    "~~~",
    "## still inside",
    "~~~~~",
    "## B",
  }, "\n"))
  eq({ 1, 7 }, lines_of(p))
end)

test("single-line comments and empty title value", function()
  local p = parse(table.concat({
    "---",
    'title: ""',
    "---",
    "<!-- ## nope -->",
    "## A",
  }, "\n"))
  eq(false, p.has_title_slide)
  eq({ 5 }, lines_of(p))
end)

test("empty buffer", function()
  local p = parse("")
  eq({}, lines_of(p))
  eq(0, parser.index_at(p, 1))
end)
