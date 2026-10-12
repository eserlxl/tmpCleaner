UNITDIR = /etc/systemd/system
CONFDIR = /etc/tmpcleaner

install: install-conf
	install -Dm755 tmpcleaner /usr/local/bin/tmpcleaner
	install -Dm644 tmpcleaner.service $(UNITDIR)/tmpcleaner.service
	install -Dm644 tmpcleaner.timer $(UNITDIR)/tmpcleaner.timer
	systemctl daemon-reload
	systemctl enable --now tmpcleaner.timer

install-conf:
	@if [ ! -e $(CONFDIR)/tmpcleaner.conf ]; then \
		install -Dm644 tmpcleaner.conf $(CONFDIR)/tmpcleaner.conf; \
	elif ! cmp -s tmpcleaner.conf $(CONFDIR)/tmpcleaner.conf; then \
		install -Dm644 tmpcleaner.conf $(CONFDIR)/tmpcleaner.conf.new && \
		echo "Notice: $(CONFDIR)/tmpcleaner.conf differs from shipped default; new defaults installed as $(CONFDIR)/tmpcleaner.conf.new (please merge)"; \
	fi

uninstall:
	-systemctl disable --now tmpcleaner.timer
	rm -f $(UNITDIR)/tmpcleaner.service $(UNITDIR)/tmpcleaner.timer
	rm -rf $(CONFDIR)
	rm -f /usr/local/bin/tmpcleaner
	systemctl daemon-reload

test:
	sh tests/test.sh

preview:
	TMPCLEANER_CONF=./tmpcleaner.conf sh ./tmpcleaner --dry-run > preview.txt 2>&1 || true
	@echo "$$(grep -c 'Would remove' preview.txt) entries would be removed; see preview.txt"

.PHONY: install install-conf uninstall test preview
