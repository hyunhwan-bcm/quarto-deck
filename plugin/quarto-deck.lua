if vim.g.loaded_quarto_deck then
  return
end
vim.g.loaded_quarto_deck = true

vim.api.nvim_create_user_command("QuartoDeck", function(o)
  local deck = require("quarto-deck")
  local sub = o.fargs[1] or "start"
  local fn = deck.commands[sub]
  if not fn then
    return vim.notify("quarto-deck: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
  fn()
end, {
  nargs = "?",
  desc = "Sync a Quarto revealjs deck with the browser",
  complete = function(lead)
    return vim.tbl_filter(function(c)
      return c:find(lead, 1, true) == 1
    end, vim.tbl_keys(require("quarto-deck").commands))
  end,
})
