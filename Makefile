.DEFAULT_GOAL := build

.PHONY: build
build:
	hugo
	npx rehype-cli public -o
