.PHONY: build macos-app test

build:
	npm run build

macos-app:
	npm run build:macos-app

test:
	npm test
