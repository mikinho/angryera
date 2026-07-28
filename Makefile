.PHONY: docs docs-clean lint lint-syntax lint-style lint-stylua lint-stylua-strict lint-luacheck lint-luacheck-strict test test-bounded-deflate test-bounded-deflate-runtimes test-json-regression test-order-regression test-smart-markers test-chat-output test-tag-page-context test-model-updates test-init-lifecycle test-identity-meta test-entity-identity test-pin-migration test-received-cleanup test-priority-assignments test-assigned-roles test-layout test-layout-grid test-layout-modal test-raid-layout test-raid-assignments test-page-menu test-category-menu test-tree-pins test-active-page-network test-permissions test-import-ownership test-import-export-options test-protocol test-protocol-runtime test-sync-schema test-sync-active-page test-sync-page-runtime test-sync-revisions test-sync-scopes test-sync-snapshot test-sync-apply test-sync-runtime test-variable-inheritance test-variable-meta test-display-inheritance test-category-serialization test-model-hierarchy-safety test-note-api test-public-api test-display-note-api test-display-autohide test-display-fallback test-legacy-id-migration test-template-load test-auto-markers test-auto-advance check check-strict

LDOC ?= ldoc
LDOC_CONFIG ?= .ldoc
LDOC_LUA_INIT ?= $(abspath tools/ldoc_lua55_compat.lua)
DOCS_DIR ?= docs/ldoc
LUA ?= luac
LUACHECK ?= luacheck
LUACHECK_CONFIG ?= .luacheckrc
STYLUA ?= stylua
STYLUA_CONFIG ?= .stylua.toml
LUA_RUN ?= lua
LUAJIT_RUN ?= luajit
LUA_FILES := $(shell rg --files -g '*.lua' 2>/dev/null || find . -maxdepth 1 -type f -name '*.lua' -print | sed 's|^\./||')

docs:
	LUA_INIT="@$(LDOC_LUA_INIT)" LUA_INIT_5_5="@$(LDOC_LUA_INIT)" $(LDOC) -c $(LDOC_CONFIG) .

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

test: test-bounded-deflate test-json-regression test-order-regression test-smart-markers test-chat-output test-tag-page-context test-model-updates test-init-lifecycle test-identity-meta test-entity-identity test-pin-migration test-received-cleanup test-priority-assignments test-assigned-roles test-layout test-layout-grid test-layout-modal test-raid-layout test-raid-assignments test-page-menu test-category-menu test-tree-pins test-active-page-network test-permissions test-import-ownership test-import-export-options test-protocol test-protocol-runtime test-sync-schema test-sync-active-page test-sync-page-runtime test-sync-revisions test-sync-scopes test-sync-snapshot test-sync-apply test-sync-runtime test-variable-inheritance test-variable-meta test-display-inheritance test-category-serialization test-model-hierarchy-safety test-note-api test-public-api test-display-note-api test-display-autohide test-display-fallback test-legacy-id-migration test-template-load test-auto-markers test-auto-advance

test-bounded-deflate:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/bounded_deflate.lua

test-bounded-deflate-runtimes: test-bounded-deflate
	@command -v $(LUAJIT_RUN) >/dev/null 2>&1 || { echo "Error: $(LUAJIT_RUN) not found."; exit 1; }
	@$(LUAJIT_RUN) tests/bounded_deflate.lua

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

test-tag-page-context:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/tag_page_context.lua

test-model-updates:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/model_updates.lua

test-init-lifecycle:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/init_lifecycle.lua

test-identity-meta:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/identity_meta.lua

test-entity-identity:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/entity_identity.lua

test-pin-migration:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/pin_migration.lua

test-received-cleanup:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/received_cleanup.lua

test-priority-assignments:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/priority_assignments.lua

test-assigned-roles:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/assigned_roles.lua

test-layout:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/layout.lua

test-layout-grid:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/layout_grid.lua

test-layout-modal:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/layout_modal.lua

test-raid-layout:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/raid_layout.lua

test-raid-assignments:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/raid_assignments.lua

test-page-menu:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/page_menu.lua

test-category-menu:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/category_menu.lua

test-tree-pins:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/tree_pins.lua

test-active-page-network:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/active_page_network.lua

test-permissions:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/permissions.lua

test-import-ownership:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/import_ownership.lua

test-import-export-options:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/import_export_options.lua

test-protocol:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/protocol.lua

test-protocol-runtime:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/protocol_runtime.lua

test-sync-schema:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_schema.lua

test-sync-active-page:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_active_page.lua

test-sync-page-runtime:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_page_runtime.lua

test-sync-revisions:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_revisions.lua

test-sync-scopes:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_scopes.lua

test-sync-snapshot:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_snapshot.lua

test-sync-apply:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_apply.lua

test-sync-runtime:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/sync_runtime.lua

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

test-variable-meta:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/variable_meta.lua

test-note-api:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/note_api.lua

test-public-api:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/public_api.lua

test-display-note-api:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/display_note_api.lua

test-display-autohide:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/display_autohide.lua

test-display-fallback:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/display_fallback.lua

test-legacy-id-migration:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/legacy_id_migration.lua

test-template-load:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/template_load.lua

test-auto-markers:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/auto_markers.lua

test-auto-advance:
	@command -v $(LUA_RUN) >/dev/null 2>&1 || { echo "Error: $(LUA_RUN) not found."; exit 1; }
	@$(LUA_RUN) tests/auto_advance.lua

check: lint test docs

check-strict: lint-syntax lint-style lint-stylua-strict lint-luacheck-strict test docs
