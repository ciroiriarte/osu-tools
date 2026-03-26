PREFIX  ?= /usr/local
MANDIR  ?= $(PREFIX)/share/man

.PHONY: install-man uninstall-man

install-man:
	install -d $(DESTDIR)$(MANDIR)/man1
	install -m 644 man/man1/*.1 $(DESTDIR)$(MANDIR)/man1/

uninstall-man:
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-import-cloud-images.1
	rm -f $(DESTDIR)$(MANDIR)/man1/osu-memory-usage-report.1
