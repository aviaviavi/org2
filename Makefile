.PHONY: build macos-app macos-app-restart test

build:
	npm run build

macos-app:
	npm run build:macos-app

macos-app-restart:
	npm run build:macos-app:restart

test:
	npm test
