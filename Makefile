LABEL      := io.github.swipekey
APP        := $(HOME)/Applications/Swipekey.app
APP_BIN    := $(APP)/Contents/MacOS/swipekey
# Command-line shortcut to the app's executable (for --debug, --print-default-config).
BIN        := $(HOME)/.local/bin/swipekey
PLIST      := $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG     := $(HOME)/.config/swipekey/config.json
LOG        := $(HOME)/Library/Logs/swipekey.log
DOMAIN     := gui/$(shell id -u)

.PHONY: build test app install uninstall restart logs permissions

build:
	swift build -c release

test:
	swift test

## Wraps the binary in an .app bundle: macOS tracks Accessibility permission far more
## reliably for a bundle with an identifier than for a bare executable.
app: build
	rm -rf $(APP)
	install -d $(APP)/Contents/MacOS
	install -m 644 support/Info.plist $(APP)/Contents/Info.plist
	install -m 755 .build/release/swipekey $(APP_BIN)
	codesign --force --sign - --identifier $(LABEL) $(APP)

## Installs Swipekey.app, a default config and a LaunchAgent that starts it at login.
install: app
	install -d $(dir $(BIN)) $(dir $(PLIST)) $(dir $(CONFIG))
	ln -sf $(APP_BIN) $(BIN)
	@test -f $(CONFIG) || $(APP_BIN) --print-default-config > $(CONFIG)
	sed -e 's|@BIN@|$(APP_BIN)|g' -e 's|@LABEL@|$(LABEL)|g' -e 's|@LOG@|$(LOG)|g' \
		support/launchagent.plist > $(PLIST)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@# bootout is asynchronous: wait until the old agent is gone before loading the new one.
	@while launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1; do sleep 0.2; done
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "Installed. Allow Swipekey in Accessibility (make permissions), then run: make restart"

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -rf $(PLIST) $(BIN) $(APP)
	@echo "Removed. Your config is kept at $(CONFIG)."

## Reload after editing the config or granting permissions.
restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

logs:
	tail -f $(LOG)

## Opens the Accessibility settings and reveals Swipekey.app to drag into the list.
permissions:
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
	open -R $(APP)
