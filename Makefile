# goose-igzip: Goose bindings for Intel ISA-L's igzip.
#
# ISA-L is not installed system-wide: it is the pinned submodule in
# vendor/isa-l, built by CMakeLists.txt. Building needs git (for the submodule),
# cmake, nasm (ISA-L's x86-64 kernels) and a C compiler.
#
# The Goose compiler comes from $GOOSE when set, otherwise from PATH, otherwise
# from the first unpacked release under ~/.goose/toolchain.
SHELL := /bin/bash

ifeq ($(origin GOOSE),undefined)
GOOSE := $(shell command -v goose 2>/dev/null)
ifeq ($(GOOSE),)
GOOSE := $(firstword $(wildcard $(HOME)/.goose/toolchain/goose-*/goose))
endif
endif

# nasm, from PATH or a private unpack.
ifeq ($(shell command -v nasm 2>/dev/null),)
ifneq ($(wildcard $(HOME)/local/nasm/usr/bin/nasm),)
export PATH := $(HOME)/local/nasm/usr/bin:$(PATH)
endif
endif

ENTRY    := igzip.goose
EXAMPLES := $(sort $(wildcard examples/*.goose))
# Threading cannot run under the JIT, so it is built and run separately. The
# large-input test is native too: it feeds a Writer past 4 GiB, and is kept out
# of the JIT loop to keep `make test` quick.
JIT_TESTS   := $(filter-out test/threads.goose test/large_stream.goose,$(sort $(wildcard test/*.goose)))
THREAD_TEST := test/threads.goose
LARGE_TEST  := test/large_stream.goose

.PHONY: all check test test-threads test-large examples bench stress fmt fmt-check verify tools submodule clean

all: check

submodule:
	@test -f vendor/isa-l/include/igzip_lib.h || \
		git submodule update --init --depth 1 vendor/isa-l

tools: submodule
	@echo "goose: $(if $(GOOSE),$(GOOSE),NOT FOUND - set GOOSE=/path/to/goose)"
	@$(if $(GOOSE),$(GOOSE) version,true)
	@echo "isa-l: $$(git -C vendor/isa-l describe --tags --always 2>/dev/null || echo MISSING)"
	@echo "nasm:  $(shell command -v nasm 2>/dev/null || echo 'MISSING - needed to assemble ISA-L')"
	@echo "cmake: $(shell command -v cmake 2>/dev/null || echo MISSING)"

check:
	@$(GOOSE) check $(ENTRY)

# Each JIT test is a root file that asserts and writes artifacts; the Python
# step then inflates every stream it produced.
test: submodule
	@mkdir -p build/tmp
	@for f in $(JIT_TESTS); do echo "== $$f"; $(GOOSE) run --debug "$$f" || exit 1; done
	@python3 scripts/check_gzip.py

# Workers need a native build: the JIT cannot place thread-local storage.
test-threads: submodule
	@mkdir -p build
	@echo "== $(THREAD_TEST)"
	@$(GOOSE) build $(THREAD_TEST) -o build/threads_test
	@./build/threads_test

# Past MAX_INPUT and past the 32-bit gzip ISIZE wrap, without holding the
# uncompressed stream.
test-large: submodule
	@mkdir -p build
	@echo "== $(LARGE_TEST)"
	@$(GOOSE) build $(LARGE_TEST) -o build/large_stream
	@./build/large_stream

examples: check
	@for f in $(EXAMPLES); do echo "== $$f"; $(GOOSE) check "$$f" || exit 1; done

# The output bound must hold as an *exact* buffer size, or igzip writes past the
# end of the destination. Anything that changes the bound, the shim's buffers,
# or the ISA-L version should be followed by this.
stress:
	@mkdir -p build
	@lib=$$(find $(HOME)/.goose/build/pkg -path '*/cmake/pkg/vendor/isa-l/libisal.a' 2>/dev/null | head -1); \
	if [ -z "$$lib" ]; then echo "build the package first: make test"; exit 1; fi; \
	gcc -g -O1 -fsanitize=address -Ivendor/isa-l/include \
		-o build/bound_stress scripts/bound_stress.c "$$lib" && ./build/bound_stress

# Throughput needs a native build; `goose run` timings mean nothing.
bench: check
	@mkdir -p build
	@$(GOOSE) build examples/bench.goose -o build/bench
	@./build/bench

verify: check test test-threads test-large examples
	@echo "verify: ok"

fmt:
	@$(GOOSE) format $(ENTRY) test examples

fmt-check:
	@$(GOOSE) format --check $(ENTRY) test examples

clean:
	@rm -rf build
