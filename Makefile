# Conver — Unified Build File for macOS, Linux, and Windows

.PHONY: help setup mac linux windows run-mac run-desktop clean

help:
	@echo "Conver Open-Source Build Targets:"
	@echo "  make mac          - Build native macOS app & DMG (ConverMac/dist/Conver.dmg)"
	@echo "  make linux        - Build Linux AppImage & .deb (conver/dist/)"
	@echo "  make windows      - Build Windows .exe installer & portable (conver/dist/)"
	@echo "  make run-mac      - Build and launch native macOS app"
	@echo "  make run-desktop  - Launch cross-platform Electron app (Linux / Windows / macOS)"
	@echo "  make clean        - Clean build artifacts"

setup:
	cd conver && npm install

mac:
	cd ConverMac && chmod +x package.sh && ./package.sh

run-mac: mac
	open ConverMac/dist/Conver.app

linux: setup
	cd conver && npm run dist:linux

windows: setup
	cd conver && npm run dist:win

run-desktop: setup
	cd conver && npm start

clean:
	rm -rf ConverMac/.build ConverMac/dist conver/dist
