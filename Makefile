PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
CONFDIR ?= /etc/tmpcleaner
UNITDIR ?= /etc/systemd/system
DESTDIR ?=
ENABLE_TIMER ?= 1
ifneq ($(ENABLE_TIMER),0)
ifneq ($(ENABLE_TIMER),1)
$(error ENABLE_TIMER must be 0 or 1)
endif
endif
KEEP_CONFIG ?= 0
ifneq ($(KEEP_CONFIG),0)
ifneq ($(KEEP_CONFIG),1)
$(error KEEP_CONFIG must be 0 or 1)
endif
endif
define newline


endef
shell_quote = $(if $(findstring $(newline),$(1)),$(error source-install paths cannot contain newlines),'$(subst ','"'"',$(1))')

install: install-conf
	@unit=$$(TMPCLEANER_EXEC=$(call shell_quote,$(BINDIR)/tmpcleaner) LC_ALL=C awk '\
		BEGIN { \
			path = ENVIRON["TMPCLEANER_EXEC"]; \
			if (substr(path, 1, 1) != "/" || path ~ /[[:cntrl:]\\\042\047]/) { \
				print "make install: BINDIR must be absolute and contain no quotes, backslashes or control bytes" > "/dev/stderr"; exit 1 \
			} \
		} \
		/^ExecStart=\/usr\/local\/bin\/tmpcleaner$$/ { \
			encoded = path; gsub(/%/, "%%", encoded); \
			$$0 = "ExecStart=\"" encoded "\""; found = 1 \
		} \
		{ print } END { if (!found) exit 1 }' tmpcleaner.service && printf x) && \
		install -Dm755 -- tmpcleaner $(call shell_quote,$(DESTDIR)$(BINDIR)/tmpcleaner) && \
		printf '%s' "$${unit%x}" | install -Dm644 -- /dev/stdin $(call shell_quote,$(DESTDIR)$(UNITDIR)/tmpcleaner.service)
	install -Dm644 -- tmpcleaner.timer $(call shell_quote,$(DESTDIR)$(UNITDIR)/tmpcleaner.timer)
ifeq ($(DESTDIR),)
	systemctl daemon-reload
ifeq ($(ENABLE_TIMER),1)
	systemctl enable --now tmpcleaner.timer
endif
endif

install-conf:
	@c=$(call shell_quote,$(DESTDIR)$(CONFDIR)/tmpcleaner.conf); \
	if [ ! -e "$$c" ] || cmp -s "$$c" "$$c.default" || cmp -s tmpcleaner.conf "$$c"; then \
		install -Dm644 tmpcleaner.conf "$$c" && \
		install -Dm644 tmpcleaner.conf "$$c.default"; \
	else \
		install -Dm644 tmpcleaner.conf "$$c.new" && \
		install -Dm644 tmpcleaner.conf "$$c.default" && \
		echo "Notice: $$c has local changes; new defaults installed as $$c.new (please merge)" && \
		{ diff -u "$$c" "$$c.new" || true; }; \
	fi

uninstall:
ifeq ($(DESTDIR),)
	-systemctl disable --now tmpcleaner.timer
endif
	rm -f -- $(call shell_quote,$(DESTDIR)$(UNITDIR)/tmpcleaner.service) $(call shell_quote,$(DESTDIR)$(UNITDIR)/tmpcleaner.timer)
ifeq ($(KEEP_CONFIG),0)
	rm -rf -- $(call shell_quote,$(DESTDIR)$(CONFDIR))
endif
	rm -f -- $(call shell_quote,$(DESTDIR)$(BINDIR)/tmpcleaner)
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
	@tmp=$$(mktemp ./.SRCINFO.XXXXXX) || exit $$?; \
	trap 'status=$$?; rm -f -- "$$tmp"; exit "$$status"' EXIT; \
	makepkg --printsrcinfo > "$$tmp" || exit $$?; \
	if [ -e .SRCINFO ]; then chmod --reference=.SRCINFO "$$tmp"; else chmod 644 "$$tmp"; fi && \
		mv -f -- "$$tmp" .SRCINFO

check-srcinfo:
	@tmp=$$(mktemp ./.SRCINFO.XXXXXX) || exit $$?; \
	trap 'status=$$?; rm -f -- "$$tmp"; exit "$$status"' EXIT; \
	makepkg --printsrcinfo > "$$tmp" || exit $$?; \
	diff -u .SRCINFO "$$tmp" || { echo ".SRCINFO is stale; run make srcinfo" >&2; exit 1; }

# Warning level and above; notes and style hints stay advisory.
lint:
	shellcheck -s sh -S warning tmpcleaner tests/test.sh

.PHONY: install install-conf uninstall test preview srcinfo check-srcinfo lint
