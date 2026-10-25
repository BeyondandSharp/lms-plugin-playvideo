# PlayVideo - Lyrion Music Server plugin
#
#   ./build.sh      one-click release build (recommended)
#   make            show this help
#   make test       run the Perl unit tests (prove -l t)
#   make lint       static UI checks and, when LMS_HOME is set, perl -c
#   make docker-test  run the LMS 9.0.0/9.1.1 Docker harness
#   make dist       create dist/PlayVideo/ + archives (uses build.sh)
#   make install    install into $(PLUGINS_DIR)/PlayVideo
#   make clean      remove build/, dist/ and temporary files
#
# VERSION is the single source of truth for the plugin version; install.xml
# is rendered from install.xml.in by build.sh, never edited by hand.

VERSION  ?= $(shell cat VERSION 2>/dev/null | head -n 1)
LMS_HOME ?=
DIST     := dist/PlayVideo
PROVE    ?= prove
TESTS    ?= t
LINT_MAIN := build/lint/LintMain.pm

.PHONY: all help test lint docker-test dist install clean verify-dist

all: help

help:
	@echo "PlayVideo $(VERSION)"
	@echo
	@sed -n '2,11p' Makefile | sed 's/^# \{0,1\}//'
	@echo
	@echo "Examples:"
	@echo "  make test"
	@echo "  LMS_HOME=/lms make lint"
	@echo "  make dist"
	@echo "  make install PLUGINS_DIR=/var/lib/squeezeboxserver/Plugins"

# Run the unit tests.  Backend tests may skip or shorten themselves when no
# Lyrion Music Server installation is available.
test:
	$(PROVE) -l $(TESTS)

# Tiny compile-time stub for the main:: constants defined by slimserver.pl
# and scanner.pl.  It is used by "make lint" so perl -c can compile the plugin
# modules against an LMS tree without executing the server.
$(LINT_MAIN):
	@mkdir -p build/lint
	@printf '%s\n' \
		'package main;' \
		'use strict;' \
		'use constant SCANNER => 0;' \
		'use constant RESIZER => 0;' \
		'use constant ISWINDOWS => ($$^O =~ /^m?s?win/i) ? 1 : 0;' \
		'use constant ISMAC => ($$^O =~ /darwin/i) ? 1 : 0;' \
		'use constant TRANSCODING => 1;' \
		'use constant PERFMON => 0;' \
		'use constant DEBUGLOG => 0;' \
		'use constant INFOLOG => 0;' \
		'use constant STATISTICS => 0;' \
		'use constant SB1SLIMP3SYNC => 1;' \
		'use constant WEBUI => 1;' \
		'use constant NOMYSB => 1;' \
		'use constant LOCALFILE => 0;' \
		'use constant NOBROWSECACHE => 0;' \
		'use constant SLIM_SERVICE => 0;' \
		'use constant NOUPNP => 0;' \
		'use constant ISACTIVEPERL => 0;' \
		'1;' > $@

# Static checks always run.  When LMS_HOME points at a Lyrion Music Server
# checkout or installation, every module is also checked with perl -c.
lint: $(LINT_MAIN)
	@if [ -n "$(LMS_HOME)" ] && [ -d "$(LMS_HOME)" ]; then \
		set -e; \
		found=0; \
		for file in $$(find lib -name '*.pm' | sort); do \
			found=1; \
			echo "syntax check $$file"; \
			perl -Ilib -Ibuild/lint -I"$(LMS_HOME)" -I"$(LMS_HOME)/lib" -I"$(LMS_HOME)/CPAN" -MLintMain -c "$$file" >/dev/null; \
		done; \
		if [ "$$found" -eq 0 ]; then echo "No modules found" >&2; exit 1; fi; \
	else \
		echo "LMS_HOME not set - skipping the LMS core syntax checks"; \
	fi
	$(PROVE) -l t/70-ui.t

# The Docker harness is owned by script/docker-test.sh.  It boots the LMS
# images, installs the plugin and exercises scanning/playback.
docker-test:
	@if [ -x script/docker-test.sh ]; then \
		./script/docker-test.sh $(DOCKER_TEST_ARGS); \
	else \
		echo "script/docker-test.sh is missing or not executable" >&2; \
		exit 1; \
	fi

# Build a self-contained plugin folder and archives.  All version handling
# and manifest rendering is done by build.sh from the single VERSION file.
dist:
	./build.sh

verify-dist:
	@test -f "$(DIST)/install.xml" || (echo "missing $(DIST)/install.xml; run make dist" >&2; exit 1)
	@test -d "$(DIST)/lib/Plugins/PlayVideo" || (echo "missing lib/Plugins/PlayVideo in $(DIST)" >&2; exit 1)
	@test -f "$(DIST)/HTML/EN/plugins/PlayVideo/settings.html" || (echo "missing settings.html in $(DIST)" >&2; exit 1)
	@grep -qF "<version>$$(tr -d '[:space:]' < VERSION)</version>" "$(DIST)/install.xml" || (echo "dist/install.xml version mismatch" >&2; exit 1)
	@echo "$(DIST) looks complete."

# Install into an existing LMS Plugins directory.  The target directory must
# be named PlayVideo exactly.
install: dist
	@if [ -z "$(PLUGINS_DIR)" ]; then \
		echo "Usage: make install PLUGINS_DIR=/path/to/lms/Plugins" >&2; \
		exit 1; \
	fi
	mkdir -p "$(PLUGINS_DIR)/PlayVideo"
	cp -Rp "$(DIST)/." "$(PLUGINS_DIR)/PlayVideo/"
	@echo "Installed PlayVideo $(VERSION) to $(PLUGINS_DIR)/PlayVideo"

clean:
	rm -rf build dist
	rm -f *.bak *.log
