.PHONY: build macos-app test

build:
	npm run build

macos-app:
	node tools/build-macos-app.mjs

test:
	npm test
