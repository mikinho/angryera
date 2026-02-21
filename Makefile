.PHONY: docs docs-clean lint lint-syntax lint-style lint-luacheck lint-luacheck-strict check

LDOC ?= ldoc
LDOC_CONFIG ?= .ldoc
DOCS_DIR ?= docs/ldoc
LUA ?= luac
LUACHECK ?= luacheck
LUACHECK_FLAGS ?= --codes --ranges --ignore 111 --ignore 112 --ignore 113 --ignore 212 --ignore 631
LUA_FILES := $(shell rg --files -g '*.lua' 2>/dev/null || find . -maxdepth 1 -type f -name '*.lua' -print | sed 's|^\./||')

docs:
	$(LDOC) -c $(LDOC_CONFIG) .

docs-clean:
	rm -rf $(DOCS_DIR) doc

lint: lint-syntax lint-style lint-luacheck

lint-syntax:
	@command -v $(LUA) >/dev/null 2>&1 || { echo "Error: $(LUA) not found."; exit 1; }
	@$(LUA) -p $(LUA_FILES)
	@echo "Syntax check passed."

lint-style:
	@if awk '/[ \t]+$$/{print FILENAME ":" FNR ":" $$0; found=1} END{exit found?0:1}' $(LUA_FILES); then \
		echo "Error: trailing whitespace found."; \
		exit 1; \
	fi
	@if awk '/\r$$/{print FILENAME ":" FNR ":" $$0; found=1} END{exit found?0:1}' $(LUA_FILES); then \
		echo "Error: CRLF line endings found."; \
		exit 1; \
	fi
	@echo "Style check passed."

lint-luacheck:
	@if command -v $(LUACHECK) >/dev/null 2>&1; then \
		$(LUACHECK) $(LUACHECK_FLAGS) -- $(LUA_FILES) || \
		echo "luacheck reported warnings (advisory in make lint)."; \
	else \
		echo "luacheck not installed; skipping luacheck (optional)."; \
	fi

lint-luacheck-strict:
	@command -v $(LUACHECK) >/dev/null 2>&1 || { echo "Error: $(LUACHECK) not found."; exit 1; }
	@$(LUACHECK) $(LUACHECK_FLAGS) -- $(LUA_FILES)

check: lint docs
