#pragma once

// This header is force-included by the Bazel build to provide compile-time
// configuration that CMake normally passes via -D flags.  Values here are
// placeholders; override them (or regenerate this file) for deployment.

#define JANK_VERSION "jank-0.1-alpha"
#define JANK_CLANG_PREFIX ""
// JANK_CLANG_PATH is left empty so find_clang() falls through to
// checking {resource_dir}/bin/clang++ where the hermetic clang lives.
#define JANK_CLANG_PATH ""
#define JANK_CLANG_MAJOR_VERSION "22"
#define JANK_CLANG_RESOURCE_DIR ""
// Relative to the binary's directory (bazel-bin/).  The jank_resource_dir
// rule assembles the tree at this path.
#define JANK_RESOURCE_DIR "jank_resource"
// These flags must match the defines used during AOT compilation so the
// JIT-compiled code is ABI-compatible with the linked runtime.
#define JANK_JIT_FLAGS "-std=gnu++20 -femulated-tls -DGC_THREADS -DIMMER_HAS_LIBGC=1 -DIMMER_TAGGED_NODE=0 -DHAVE_CXX14=1 -DCPPINTEROP_USE_REPL -DFOLLY_HAVE_JEMALLOC=0 -DFOLLY_HAVE_TCMALLOC=0 -DFOLLY_ASSUME_NO_JEMALLOC=1 -DFOLLY_ASSUME_NO_TCMALLOC=1"
#define JANK_AOT_FLAGS ""
