UNITDIR = /etc/systemd/system
CONFDIR = /etc/tmpcleaner

install: install-conf
	install -Dm755 tmpcleaner /usr/local/bin/tmpcleaner
	install -Dm644 tmpcleaner.service $(UNITDIR)/tmpcleaner.service
	install -Dm644 tmpcleaner.timer $(UNITDIR)/tmpcleaner.timer
	systemctl daemon-reload
	systemctl enable --now tmpcleaner.timer

install-conf:
	@c=$(CONFDIR)/tmpcleaner.conf; \
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
	-systemctl disable --now tmpcleaner.timer
	rm -f $(UNITDIR)/tmpcleaner.service $(UNITDIR)/tmpcleaner.timer
	rm -rf $(CONFDIR)
	rm -f /usr/local/bin/tmpcleaner
	systemctl daemon-reload

test:
	sh tests/test.sh

# 73 is systemd-tmpfiles' status when an unprivileged preview cannot open root-only dirs.
preview:
	@TMPCLEANER_CONF=./tmpcleaner.conf sh ./tmpcleaner --dry-run > preview.txt 2>&1; rc=$$?; \
	if [ $$rc -ne 0 ] && [ $$rc -ne 73 ]; then cat preview.txt >&2; exit $$rc; fi; \
	echo "$$(grep -c 'Would remove' preview.txt) entries would be removed; see preview.txt"

.PHONY: install install-conf uninstall test preview
