ZIG?=zig
ZIGFLAGS?=

# zig does not automatically clean up the cache, so we should make
# one in the temp dir
ZIG_CACHE=zig-cache
ZIG_CACHE_TMP=/tmp/zig-cache-zenith

.PHONY: build
build: $(ZIG_CACHE)
	$(ZIG) build $(ZIGFLAGS)

.PHONY: $(ZIG_CACHE)
$(ZIG_CACHE):
	@if [ -d "$(ZIG_CACHE)" ]; then \
		(du -sb $(ZIG_CACHE_TMP) | awk '{size=$$1; if (size > 1000000000) { exit 1 }}'); \
		if [ $$? -ne 0 ]; then \
			echo "$(ZIG_CACHE) is too big! You should delete it"; \
		fi \
	else \
		mkdir -p $(ZIG_CACHE_TMP); \
		ln -s $(ZIG_CACHE_TMP) $(ZIG_CACHE); \
	fi

.PHONY: release
release: $(ZIG_CACHE)
	$(ZIG) build -Doptimize=ReleaseSafe

.PHONY: test
test: $(ZIG_CACHE)
	$(ZIG) build test

.PHONY: clean
clean:
	rm -rf zig-out
	rm -rf $(ZIG_CACHE_TMP)
	rm -rf zig-cache

.PHONY: clean-cache
clean-cache:
	rm -rf $(ZIG_CACHE_TMP)
	rm -rf zig-cache

.PHONY: install
install:
ifeq ($(PREFIX),)
	$(error PREFIX is empty.)
else
	cp ./zig-out/bin/zenith $(PREFIX)
endif
