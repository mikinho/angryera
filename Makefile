.PHONY: docs docs-clean lint lint-syntax lint-style lint-stylua lint-stylua-strict lint-luacheck lint-luacheck-strict test test-json-regression test-order-regression test-smart-markers test-chat-output test-model-updates test-identity-meta test-entity-identity test-network-identity test-permissions test-import-ownership test-protocol test-protocol-runtime test-sync-schema test-variable-inheritance test-display-inheritance test-category-serialization test-model-hierarchy-safety check check-strict

LDOC ?= ldoc
LDOC_CONFIG ?= .ldoc
DOCS_DIR ?= docs/ldoc
LUA ?= luac
LUACHECK ?= luacheck
LUACHECK_CONFIG ?= .luacheckrc
STYLUA ?= stylua
STYLUA_CONFIG ?= .stylua.toml
LUA_RUN ?= lua
LUA_FILES := $(shell rg --files -g '*.lua' 2>/dev/null || find . -maxdepth 1 -type f -name '*.lua' -print | sed 's|^\./||')

docs:
	$(LDOC) -c $(LDOC_CONFIG) .

docs-clean:
	rm -rf $(DOCS_DIR) doc

lint: lint-syntax lint-style lint-stylua lint-luacheck

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

lint-stylua:
	@if command -v $(STYLUA) >/dev/null 2>&1; then \
		$(STYLUA) --config-path $(STYLUA_CONFIG) --check $(LUA_FILES) || \
		echo "stylua reported formatting differences (advisory in make lint)."; \
	else \
		echo "stylua not installed; skipping stylua check (optional)."; \
	fi

lint-stylua-strict:
	@command -v $(STYLUA) >/dev/null 2>&1 || { echo "Error: $(STYLUA) not found."; exit 1; }
	@$(STYLUA) --config-path $(STYLUA_CONFIG) --check $(LUA_FILES)

lint-luacheck:
	@if command -v $(LUACHECK) >/dev/null 2>&1; then \
		$(LUACHECK) --config $(LUACHECK_CONFIG) -- $(LUA_FILES) || \
		echo "luacheck reported warnings (advisory in make lint)."; \
	else \
		echo "luacheck not installed; skipping luacheck (optional)."; \
	fi

lint-luacheck-strict:
	@command -v $(LUACHECK) >/dev/null 2>&1 || { echo "Error: $(LUACHECK) not found."; exit 1; }
	@$(LUACHECK) --config $(LUACHECK_CONFIG) -- $(LUA_FILES)

test: test-json-regression test-order-regression test-smart-markers test-chat-output test-model-updates test-identity-meta test-entity-identity test-network-identity test-permissions test-import-ownership test-protocol test-protocol-runtime test-sync-schema test-variable-inheritance test-display-inheritance test-category-serialization test-model-hierarchy-safety

test-json-regression:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/json_regression.lua

test-order-regression:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/order_regression.lua

test-smart-markers:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/smart_markers.lua

test-chat-output:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/chat_output.lua

test-model-updates:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/model_updates.lua

test-identity-meta:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/identity_meta.lua

test-entity-identity:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/entity_identity.lua

test-network-identity:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/network_identity.lua

test-permissions:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/permissions.lua

test-import-ownership:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/import_ownership.lua

test-protocol:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/protocol.lua

test-protocol-runtime:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/protocol_runtime.lua

test-sync-schema:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_schema.lua

test-variable-inheritance:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/variable_inheritance.lua

test-display-inheritance:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/display_inheritance.lua

test-category-serialization:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/category_serialization.lua

test-model-hierarchy-safety:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/model_hierarchy_safety.lua

check: lint test docs

check-strict: lint-syntax lint-style lint-stylua-strict lint-luacheck-strict test docs
