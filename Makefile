ZIG?=zig

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