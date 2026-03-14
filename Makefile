.PHONY: install uninstall test

PREFIX ?= /usr/local

install:
	@echo "Installing mcp-reconnect to $(PREFIX)/bin..."
	@install -d $(PREFIX)/bin
	@install -m 755 bin/mcp-reconnect $(PREFIX)/bin/mcp-reconnect
	@echo "Done. Run 'mcp-reconnect --help' to verify."

uninstall:
	@echo "Removing mcp-reconnect from $(PREFIX)/bin..."
	@rm -f $(PREFIX)/bin/mcp-reconnect
	@echo "Done."

test:
	@echo "Running dry-run test..."
	@bash bin/mcp-reconnect --dry-run
	@echo "Syntax check..."
	@bash -n bin/mcp-reconnect
	@echo "All checks passed."
