APP_NAME := NetWatch
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
EXECUTABLE := $(MACOS_DIR)/$(APP_NAME)
SOURCE := src/NetWatch.mm

CXX := clang++
CXXFLAGS := -std=c++17 -Wall -Wextra -Wpedantic -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework UserNotifications -framework CoreWLAN

.PHONY: all app run clean

all: app

app: $(EXECUTABLE) $(CONTENTS_DIR)/Info.plist
	@mkdir -p "$(RESOURCES_DIR)"
	@chmod -R u+w "$(RESOURCES_DIR)/assets" 2>/dev/null || true
	@cp -R assets "$(RESOURCES_DIR)/"
	@chmod -R u+w "$(RESOURCES_DIR)/assets"
	@printf "APPL????" > "$(CONTENTS_DIR)/PkgInfo"
	@touch "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

$(EXECUTABLE): $(SOURCE)
	@mkdir -p "$(MACOS_DIR)"
	$(CXX) $(CXXFLAGS) "$(SOURCE)" -o "$(EXECUTABLE)" $(FRAMEWORKS)

$(CONTENTS_DIR)/Info.plist: packaging/Info.plist
	@mkdir -p "$(CONTENTS_DIR)"
	@cp packaging/Info.plist "$(CONTENTS_DIR)/Info.plist"

run: app
	open "$(APP_BUNDLE)"

clean:
	rm -rf "$(BUILD_DIR)"
