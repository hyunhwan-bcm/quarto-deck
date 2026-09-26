# quarto-deck demo. Run through demo/record.sh (it sets up the isolated
# herdr, the deck copy and deck/.demo-init.lua); don't run `vhs demo/demo.tape` directly.

Output "demo/quarto-deck-demo.gif"
Output "demo/quarto-deck-demo.mp4"

Require herdr
Require nvim
Require carbonyl

Set Shell "zsh"
Set FontSize 15
Set Width 1600
Set Height 900
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

Hide
Type "cd $QD_ROOT/deck && clear && herdr --session qdemo"
Enter
Wait+Screen@20s /➜ +deck/
Sleep 500ms
Type "nvim -u .demo-init.lua demo.qmd"
Enter
Wait+Screen@20s /theme: moon/
Show

# A .qmd deck in nvim, inside herdr.
Sleep 1.5s

# Start: quarto renders, and a page pane opens on the slide under the cursor.
Type ":QuartoDeck start"
Sleep 700ms
Enter
Wait+Screen@90s /127\.0\.0\.1/
Sleep 4s

# nvim -> browser: move the cursor, and the slide follows.
Type "/## The fix"
Sleep 400ms
Enter
Sleep 2.5s
Type "/# How"
Sleep 400ms
Enter
Sleep 2.5s
Type "/## Inside"
Sleep 400ms
Enter
Sleep 2.5s

# browser -> nvim: focus the page pane (ctrl+b l) and page back with arrows.
Ctrl+B
Type "l"
Sleep 1.2s
Left
Sleep 2s
Left
Sleep 2s
Left
Sleep 2s
Ctrl+B
Type "h"
Sleep 1s

# Edit + :w -> quarto re-renders, and the page reloads on the same slide.
Type "/Nothing to click"
Sleep 400ms
Enter
Sleep 2s
Type "o- Just keep typing"
Sleep 500ms
Escape
Sleep 400ms
Type ":w"
Sleep 400ms
Enter
Wait+Screen@90s /(?s)Just keep typing.*Just keep typing/
Sleep 4s

Hide
Type ":qa!"
Enter
Sleep 1s
