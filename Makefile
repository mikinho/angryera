.PHONY: docs docs-clean

LDOC ?= ldoc
LDOC_CONFIG ?= .ldoc
DOCS_DIR ?= docs/ldoc

docs:
	$(LDOC) -c $(LDOC_CONFIG) .

docs-clean:
	rm -rf $(DOCS_DIR) doc
