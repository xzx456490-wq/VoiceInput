.PHONY: build run install clean test

build:
	sh ./scripts/bundle.sh

run: build
	open .build/VoiceInput.app

install: build
	sh ./scripts/install.sh

clean:
	swift package clean
	rm -rf .build/VoiceInput.app

test:
	swift test
