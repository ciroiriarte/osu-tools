PREFIX     ?= /usr/local
MANDIR     ?= $(PREFIX)/share/man
COMPDIR    ?= /etc/bash_completion.d
SCRIPTS    := $(wildcard osu-*.sh)

.PHONY: all lint test install-man uninstall-man install-completions uninstall-completions

all: lint test

# --- Quality Assurance ---

lint:
	@echo "==> Running shellcheck on all scripts..."
	@shellcheck $(SCRIPTS) && echo "    All scripts passed shellcheck"

test:
	@echo "==> Running bats tests..."
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/*.bats; \
	else \
		echo "    bats-core not installed. Install with:"; \
		echo "      - npm install -g bats"; \
		echo "      - or: sudo apt install bats"; \
		echo "      - or: brew install bats-core"; \
		exit 1; \
	fi

check: lint test

install-man:
	install -d $(DESTDIR)$(MANDIR)/man1
	install -m 644 man/man1/*.1 $(DESTDIR)$(MANDIR)/man1/

uninstall-man:
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-import-cloud-images.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-memory-usage-report.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-capacity-report.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-retype-vdisk.1

install-completions:
	install -d $(DESTDIR)$(COMPDIR)
	install -m 644 completions/osu-tools.bash $(DESTDIR)$(COMPDIR)/osu-tools

uninstall-completions:
	rm -f $(DESTDIR)$(COMPDIR)/osu-tools
