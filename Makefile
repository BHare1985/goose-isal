# goose-igzip: Goose bindings for Intel ISA-L's igzip.
#
# ISA-L is not installed system-wide: it is the pinned submodule in
# vendor/isa-l, built by CMakeLists.txt. Building needs git (for the submodule),
# cmake, nasm (ISA-L's x86-64 kernels) and a C compiler.
#
# The Goose compiler comes from $GOOSE when set, otherwise from PATH, otherwise
# from the first unpacked release under $GOOSE_HOME/toolchain.
SHELL := /bin/bash

# Where the Goose toolchain and its package build tree live. `goose toolchain`
# reports it; setting GOOSE_HOME moves both.
GOOSE_HOME ?= $(HOME)/.goose

ifeq ($(origin GOOSE),undefined)
GOOSE := $(shell command -v goose 2>/dev/null)
ifeq ($(GOOSE),)
GOOSE := $(firstword $(wildcard $(GOOSE_HOME)/toolchain/goose-*/goose))
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

.PHONY: all check test crosscheck test-threads test-large examples bench stress fmt fmt-check verify tools submodule clean

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

# Each JIT test is a root file that asserts, and that now decodes what it wrote
# with the package's own reader. No Python, no network: a compressor and a
# decompressor wired to each other is the point of 0.3.0.
test: submodule
	@mkdir -p build/tmp
	@for f in $(JIT_TESTS); do echo "== $$f"; $(GOOSE) run --debug "$$f" || exit 1; done

# The independent decoder. A compressor and a decompressor that agree can agree
# on a broken stream, so CPython's zlib still inflates every artifact the tests
# wrote -- it is the only decoder here that is not ours. Optional: `make verify`
# runs it when python3 is installed, and `make test` never needs it.
crosscheck:
	@command -v python3 >/dev/null 2>&1 || { echo "crosscheck: python3 not found, skipped"; exit 0; }
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

# Two harnesses, both under AddressSanitizer with exactly sized buffers:
#
#   bound_stress  the output bound holds as an *exact* buffer size, or igzip
#                 writes past the end of the destination
#   read_stress   nothing is written past the destination or read past the
#                 input, at chunk sizes from 1 byte up, across every truncation
#                 offset, mutations, and the dictionary paths
#
# Anything that changes the bound, the shim's buffers, the reader's draining, or
# the ISA-L version should be followed by this.
stress:
	@mkdir -p build
	@lib=$$(find $(GOOSE_HOME)/build/pkg -path '*/cmake/pkg/vendor/isa-l/libisal.a' 2>/dev/null | head -1); \
	if [ -z "$$lib" ]; then echo "build the package first: make test"; exit 1; fi; \
	for src in bound_stress read_stress; do \
		echo "== scripts/$$src.c"; \
		gcc -g -O1 -fsanitize=address -Ivendor/isa-l/include \
			-o build/$$src scripts/$$src.c "$$lib" && ./build/$$src || exit 1; \
	done

# Throughput needs a native build; `goose run` timings mean nothing.
bench: check
	@mkdir -p build
	@$(GOOSE) build examples/bench.goose -o build/bench
	@./build/bench

verify: check test crosscheck test-threads test-large examples
	@echo "verify: ok"

fmt:
	@$(GOOSE) format $(ENTRY) test examples

fmt-check:
	@$(GOOSE) format --check $(ENTRY) test examples

clean:
	@rm -rf build
