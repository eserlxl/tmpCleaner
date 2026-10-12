UNITDIR = /etc/systemd/system

install:
	install -Dm755 tmpcleaner /usr/local/bin/tmpcleaner
	install -Dm644 tmpcleaner.conf /etc/tmpcleaner/tmpcleaner.conf
	install -Dm644 tmpcleaner.service $(UNITDIR)/tmpcleaner.service
	install -Dm644 tmpcleaner.timer $(UNITDIR)/tmpcleaner.timer
	systemctl daemon-reload
	systemctl enable --now tmpcleaner.timer

uninstall:
	-systemctl disable --now tmpcleaner.timer
	rm -f $(UNITDIR)/tmpcleaner.service $(UNITDIR)/tmpcleaner.timer
	rm -rf /etc/tmpcleaner
	rm -f /usr/local/bin/tmpcleaner
	systemctl daemon-reload

test:
	sh tests/test.sh

.PHONY: install uninstall test
