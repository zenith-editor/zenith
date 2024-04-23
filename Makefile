ZIG?=zig
#PREFIX?=

.PHONY: build
build:
	$(ZIG) build

.PHONY: build-release
release:
	$(ZIG) build -Doptimize=ReleaseSafe

.PHONY: clean
clean:
	rm -rf zig-out
	rm -rf zig-cache

.PHONY: install
install:
ifeq ($(PREFIX),)
	$(error PREFIX is empty.)
else
	cp ./zig-out/bin/zenith $(PREFIX)
endif
