PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
CONFDIR ?= /etc/tmpcleaner
UNITDIR ?= /etc/systemd/system
DESTDIR ?=

install: install-conf
	install -Dm755 tmpcleaner $(DESTDIR)$(BINDIR)/tmpcleaner
	install -Dm644 tmpcleaner.service $(DESTDIR)$(UNITDIR)/tmpcleaner.service
	sed -i 's|^ExecStart=/usr/local/bin/tmpcleaner$$|ExecStart=$(BINDIR)/tmpcleaner|' $(DESTDIR)$(UNITDIR)/tmpcleaner.service
	install -Dm644 tmpcleaner.timer $(DESTDIR)$(UNITDIR)/tmpcleaner.timer
ifeq ($(DESTDIR),)
	systemctl daemon-reload
	systemctl enable --now tmpcleaner.timer
endif

install-conf:
	@c=$(DESTDIR)$(CONFDIR)/tmpcleaner.conf; \
	if [ ! -e $$c ] || cmp -s $$c $$c.default || cmp -s tmpcleaner.conf $$c; then \
		install -Dm644 tmpcleaner.conf $$c && \
		install -Dm644 tmpcleaner.conf $$c.default; \
	else \
		install -Dm644 tmpcleaner.conf $$c.new && \
		install -Dm644 tmpcleaner.conf $$c.default && \
		echo "Notice: $$c has local changes; new defaults installed as $$c.new (please merge)" && \
		{ diff -u $$c $$c.new || true; }; \
	fi

uninstall:
ifeq ($(DESTDIR),)
	-systemctl disable --now tmpcleaner.timer
endif
	rm -f $(DESTDIR)$(UNITDIR)/tmpcleaner.service $(DESTDIR)$(UNITDIR)/tmpcleaner.timer
	rm -rf $(DESTDIR)$(CONFDIR)
	rm -f $(DESTDIR)$(BINDIR)/tmpcleaner
ifeq ($(DESTDIR),)
	systemctl daemon-reload
endif

test:
	sh tests/test.sh

# 73 is systemd-tmpfiles' status when an unprivileged preview cannot open root-only dirs.
preview:
	@TMPCLEANER_CONF=./tmpcleaner.conf sh ./tmpcleaner --dry-run > preview.txt 2>&1; rc=$$?; \
	if [ $$rc -ne 0 ] && [ $$rc -ne 73 ]; then cat preview.txt >&2; exit $$rc; fi; \
	echo "$$(grep -c 'Would remove' preview.txt) entries would be removed; see preview.txt"

# Maintainer helpers for the AUR package: makepkg is only needed here, not by test.
srcinfo:
	makepkg --printsrcinfo > .SRCINFO

check-srcinfo:
	@makepkg --printsrcinfo | diff -u .SRCINFO - || { echo ".SRCINFO is stale; run make srcinfo" >&2; exit 1; }

.PHONY: install install-conf uninstall test preview srcinfo check-srcinfo
