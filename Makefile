NVIM ?= nvim
RUN   = $(NVIM) --headless --clean -l tests/run.lua

UNIT = parser server sync herdr
E2E  = quarto_parity e2e_browser

.PHONY: test unit e2e herdr herdr-tb strict

# Everything. Tests needing quarto/Chrome/herdr SKIP (loudly) when missing.
test:
	@fail=0; for s in $(UNIT) $(E2E); do $(RUN) tests/spec/$${s}_spec.lua || fail=1; done; \
	bash tests/herdr_live.sh || fail=1; exit $$fail

# No external tools needed.
unit:
	@fail=0; for s in $(UNIT); do $(RUN) tests/spec/$${s}_spec.lua || fail=1; done; exit $$fail

# Real quarto + headless Chrome. Set QUARTO_PATH / CHROME_PATH if not on PATH.
e2e:
	@fail=0; for s in $(E2E); do $(RUN) tests/spec/$${s}_spec.lua || fail=1; done; exit $$fail

# herdr plugin + layout against a private, headless herdr server.
herdr:
	@bash tests/herdr_live.sh

# Same, with a real terminal-browser in the page pane.
herdr-tb:
	@QD_TERMINAL_BROWSER=1 bash tests/herdr_live.sh

# unit + e2e with skips counted as failures (CI has no herdr).
strict:
	@fail=0; for s in $(UNIT) $(E2E); do STRICT=1 $(RUN) tests/spec/$${s}_spec.lua || fail=1; done; exit $$fail
