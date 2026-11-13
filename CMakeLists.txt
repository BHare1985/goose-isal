# isal: the package's native part.
#
# Goose configures this project, links the `igzip_goose` static library, and
# takes the rest of the link line from it. ISA-L is not installed on the
# machine: it is the pinned submodule in vendor/isa-l, built here as a static
# library with its own CMake options turned down to "just the code".
#
# nasm assembles ISA-L's x86-64 kernels and is a build requirement. ISA-L
# carries portable C fallbacks (igzip_base_aliases.c), so a machine without
# nasm can be made to build at the cost of most of the speed this package
# exists for; the configure step failing loudly is the honest default.
cmake_minimum_required(VERSION 3.20)
project(igzip_goose LANGUAGES C)

# ISA-L's own settings. CACHE ... FORCE so a caller cannot flip them by
# accident: a shared ISA-L would have to be installed, and its tests, perf
# tools and CLI are dead weight in a binding.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ISAL_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ISAL_BUILD_PERF_TESTS OFF CACHE BOOL "" FORCE)
set(ISAL_BUILD_FUZZ_TESTS OFF CACHE BOOL "" FORCE)
set(ISAL_BUILD_ISAL_SHIM OFF CACHE BOOL "" FORCE)

# ISA-L assembles its x86-64 kernels with nasm. Its own CMakeLists calls
# enable_language(ASM_NASM), which fails with a paragraph about compiler
# variables; check first and say what is actually missing.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    find_program(NASM_EXECUTABLE nasm)
    if(NOT NASM_EXECUTABLE)
        message(FATAL_ERROR
            "goose-igzip needs nasm to assemble ISA-L's x86-64 kernels.\n"
            "Install it (apt install nasm, dnf install nasm, brew install nasm) "
            "or put it on PATH, then build again.")
    endif()
endif()

add_subdirectory(vendor/isa-l EXCLUDE_FROM_ALL)

add_library(igzip_goose STATIC src/igzip_shim.c)
target_include_directories(igzip_goose PRIVATE vendor/isa-l/include)
target_link_libraries(igzip_goose PRIVATE isal)
set_target_properties(igzip_goose PROPERTIES POSITION_INDEPENDENT_CODE ON)
