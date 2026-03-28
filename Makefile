PREFIX     ?= /usr/local
MANDIR     ?= $(PREFIX)/share/man
COMPDIR    ?= /etc/bash_completion.d

.PHONY: install-man uninstall-man install-completions uninstall-completions

install-man:
	install -d $(DESTDIR)$(MANDIR)/man1
	install -m 644 man/man1/*.1 $(DESTDIR)$(MANDIR)/man1/

uninstall-man:
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-import-cloud-images.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-memory-usage-report.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-resource-efficiency-report.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-retype-vdisk.1

install-completions:
	install -d $(DESTDIR)$(COMPDIR)
	install -m 644 completions/osu-tools.bash $(DESTDIR)$(COMPDIR)/osu-tools

uninstall-completions:
	rm -f $(DESTDIR)$(COMPDIR)/osu-tools
