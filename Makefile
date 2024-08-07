ZIG?=zig
ZIGFLAGS?=

# zig does not automatically clean up the cache, so we should make
# one in the temp dir
ZIG_CACHE=.zig-cache
ZIG_CACHE_TMP=/tmp/zig-cache-zenith

.PHONY: build
build: $(ZIG_CACHE)
	$(ZIG) build $(ZIGFLAGS)

.PHONY: $(ZIG_CACHE)
$(ZIG_CACHE):
	@if [ -L "$(ZIG_CACHE)" ] && [ -d "$(ZIG_CACHE_TMP)" ]; then \
		(du -sb $(ZIG_CACHE_TMP) | awk '{size=$$1; if (size > 1000000000) { exit 1 }}'); \
		if [ $$? -ne 0 ]; then \
			echo "$(ZIG_CACHE) is too big! You should clean it up with make clean-cache"; \
		fi \
	else \
		mkdir -p $(ZIG_CACHE_TMP); \
		[ ! -L "$(ZIG_CACHE)" ] && ln -sf $(ZIG_CACHE_TMP) $(ZIG_CACHE); \
		exit 0; \
	fi

.PHONY: release
release: $(ZIG_CACHE)
	$(ZIG) build -Doptimize=ReleaseSafe $(ZIGFLAGS)

.PHONY: test
test: $(ZIG_CACHE)
	$(ZIG) build test $(ZIGFLAGS)

.PHONY: watch
watch: $(ZIG_CACHE)
	find src -name '*.zig' | entr -cc $(ZIG) build

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
