-- The parser must agree with what Quarto actually renders: same number of
-- slides, same order, same titles. Needs a real `quarto`.
local parser = require("quarto-deck.parser")
local util = require("helpers.util")

-- Pandoc applies smart quotes and markdown formatting to titles; compare the
-- words only.
local function norm(s)
  return (s:gsub("<[^>]+>", " "):gsub("[^%w]", ""):lower())
end

for _, name in ipairs({ "deck.qmd", "edge.qmd", "level1.qmd" }) do
  test("parser matches quarto render: " .. name, function()
    local quarto = util.quarto()
    if not quarto then
      skip("quarto not found (set QUARTO_PATH)")
    end
    local qmd = util.deck(name)
    local html = util.render(quarto, qmd)
    local rendered = util.html_slides(html)
    local p = parser.parse(vim.split(util.read(qmd), "\n", { plain = true }))

    eq(#rendered, #p.visible, "slide count")
    for i, s in ipairs(p.visible) do
      if s.kind == "heading" then
        eq(norm(s.title), norm(rendered[i].title), "title of slide " .. (i - 1))
      elseif s.kind == "title" then
        eq("title-slide", rendered[i].id, "slide 0 is the title slide")
      end
    end
  end)
end

-- Opt-in: QUARTO_DECK_EXTRA=/path/a/slides.qmd:/path/b/slides.qmd checks real
-- decks. Each deck's directory is copied to a temp dir first; the original is
-- never rendered or touched.
for _, src in ipairs(vim.split(vim.env.QUARTO_DECK_EXTRA or "", ":", { trimempty = true })) do
  test("parser matches quarto render: " .. src, function()
    local quarto = util.quarto()
    if not quarto then
      skip("quarto not found (set QUARTO_PATH)")
    end
    local dir = util.tmpdir()
    vim.fn.system({ "cp", "-R", vim.fn.fnamemodify(src, ":h") .. "/.", dir })
    local qmd = dir .. "/" .. vim.fn.fnamemodify(src, ":t")
    local rendered = util.html_slides(util.render(quarto, qmd))
    local p = parser.parse(vim.split(util.read(qmd), "\n", { plain = true }))
    eq(#rendered, #p.visible, "slide count")
    for i, s in ipairs(p.visible) do
      if s.kind == "heading" then
        eq(norm(s.title), norm(rendered[i].title), "title of slide " .. (i - 1) .. " (line " .. s.line .. ")")
      end
    end
  end)
end
