BINDIR ?= $(if $(XDG_BIN_HOME),$(XDG_BIN_HOME),$(HOME)/.local/bin)
SWIFT_FLAGS ?=
ACCOUNT := $(shell id -un)
EXECUTABLE := $(CURDIR)/.build/release/awaken

.PHONY: build test install uninstall install-sudoers uninstall-sudoers

build:
	swift build $(SWIFT_FLAGS) -c release --product awaken

test:
	swift test $(SWIFT_FLAGS)

install: build
	install -d "$(BINDIR)"
	install -m 755 "$(EXECUTABLE)" "$(BINDIR)/awaken"

uninstall:
	rm -f "$(BINDIR)/awaken"

install-sudoers: build
	sudo -- "$(EXECUTABLE)" --install-sudoers "$(ACCOUNT)"

uninstall-sudoers: build
	sudo -- "$(EXECUTABLE)" --uninstall-sudoers "$(ACCOUNT)"
