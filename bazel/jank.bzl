load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

"""Bazel rules for building jank (Clojure dialect) projects.

Usage:
    load("//bazel:jank.bzl", "jank_library", "jank_binary")

    jank_library(
        name = "core",
        module = "clojure.core",
        srcs = ["src/jank/clojure/core.jank"],
    )

    jank_binary(
        name = "hello",
        main = "example/hello.jank",
        srcs = ["hello.jank"],
        deps = [":core"],
    )
"""

JankInfo = provider(
    doc = "Provider for jank compilation artifacts.",
    fields = {
        "object_file": "The compiled .o file for this module.",
        "module": "The module name (e.g. 'clojure.core').",
        "transitive_objects": "Depset of all transitive .o files.",
        "transitive_sources": "Depset of all transitive .jank sources.",
    },
)

def _collect_src_dirs(files):
    """Extract unique module root directories from source file paths.

    For files under a src/jank/ tree, the root is that directory.
    Otherwise, the root is derived by stripping the .jank filename
    segments that correspond to the module namespace from the path.
    For example, example/aot/core.jank → example/ (the dir above aot/).
    """
    dirs = {}
    for f in files:
        path = f.path
        idx = path.find("/src/jank/")
        if idx >= 0:
            dirs[path[:idx] + "/src/jank"] = True
        else:
            # Strip the deepest directory that matches a module path
            # component.  E.g. for example/aot/core.jank the dirname
            # is example/aot; we walk up to find a directory that, when
            # used as module root, makes the file reachable.
            d = f.dirname
            # Keep stripping path segments until we reach a plausible
            # module root (at most 5 levels to avoid infinite loop).
            for _ in range(5):
                dirs[d] = True
                parent = d.rsplit("/", 1)[0] if "/" in d else ""
                if parent == d or not parent:
                    break
                d = parent
    return dirs.keys()

_JANK_ACTION_ENV = {
    "HOME": "/tmp/jank-cache",
    "TMPDIR": "/tmp",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
}

def _jank_library_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.module.replace(".", "/") + ".o")

    trans_srcs = depset(
        ctx.files.srcs,
        transitive = [dep[JankInfo].transitive_sources for dep in ctx.attr.deps],
    )
    trans_objs = depset(
        transitive = [dep[JankInfo].transitive_objects for dep in ctx.attr.deps],
    )

    module_path = ":".join(_collect_src_dirs(trans_srcs.to_list()))

    ctx.actions.run(
        outputs = [out],
        inputs = depset(
            transitive = [trans_srcs, trans_objs, ctx.attr._resource_dir.files, ctx.attr._pch.files],
        ),
        executable = ctx.executable._compiler,
        arguments = [
            "-O" + str(ctx.attr.optimization),
            "compile-module",
            "--module-path", module_path,
            # jank writes to {output-dir}/{module/path}.o. Strip the
            # module-relative part from the declared output to get the dir.
            "--output-dir", out.path[:-(len(ctx.attr.module.replace(".", "/")) + 3)],
            "-o", out.path,
            ctx.attr.module,
        ],
        tools = [ctx.attr._compiler[DefaultInfo].files_to_run],
        mnemonic = "JankCompile",
        progress_message = "Compiling jank module %s" % ctx.attr.module,
        execution_requirements = {"no-sandbox": "1"},
        env = _JANK_ACTION_ENV,
    )

    return [
        DefaultInfo(files = depset([out])),
        JankInfo(
            object_file = out,
            module = ctx.attr.module,
            transitive_objects = depset([out], transitive = [trans_objs]),
            transitive_sources = trans_srcs,
        ),
    ]

jank_library = rule(
    implementation = _jank_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".jank"]),
        "module": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [JankInfo]),
        "optimization": attr.int(default = 3),
        "_compiler": attr.label(
            default = "//compiler+runtime:jank",
            executable = True,
            cfg = "target",
        ),
        "_resource_dir": attr.label(default = "//compiler+runtime:jank_resource"),
        "_pch": attr.label(default = "//compiler+runtime:incremental_pch"),
    },
)

def _jank_binary_impl(ctx):
    launcher = ctx.actions.declare_file(ctx.attr.name)

    trans_srcs = depset(
        ctx.files.srcs,
        transitive = [dep[JankInfo].transitive_sources for dep in ctx.attr.deps if JankInfo in dep],
    )

    src_dirs = _collect_src_dirs(trans_srcs.to_list())
    compiler = ctx.executable._compiler

    # Resolve runfiles-relative paths for core libs and PCH.
    core_o_path = ctx.files._core_libs[0].short_path if ctx.files._core_libs else ""
    pch_path = ctx.files._pch[0].short_path if ctx.files._pch else ""

    # --module-path entries (runfiles-relative).
    module_path_parts = []
    for d in src_dirs:
        module_path_parts.append("\"$RUNFILES/_main/{}\"".format(d))
    module_path_expr = ":".join(module_path_parts) if module_path_parts else ""

    # Collect -I include directories from cc_deps.
    # We derive the include path from the actual header file locations in
    # runfiles rather than CcInfo paths (which may reference virtual
    # include trees that are not present in runfiles).
    include_dirs = {}
    cc_header_files = []
    for dep in ctx.attr.cc_deps:
        if CcInfo in dep:
            cc_header_files.append(dep[CcInfo].compilation_context.headers)
            for hdr in dep[CcInfo].compilation_context.headers.to_list():
                include_dirs[hdr.dirname] = True

    include_flags = []
    for d in include_dirs.keys():
        include_flags.append("-I \"$RUNFILES/_main/{}\"".format(d))
    include_flags_str = " ".join(include_flags)

    # Resolve the main source file.
    main_file = None
    for f in ctx.files.srcs:
        if f.short_path == ctx.attr.main or f.path.endswith(ctx.attr.main):
            main_file = f
            break
    if not main_file and ctx.files.srcs:
        main_file = ctx.files.srcs[0]
    main_path = main_file.short_path if main_file else ctx.attr.main

    script = """\
#!/bin/bash
set -euo pipefail

# Resolve runfiles directory.
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
  RUNFILES="${{RUNFILES_DIR}}"
elif [[ -d "${{BASH_SOURCE[0]}}.runfiles" ]]; then
  RUNFILES="${{BASH_SOURCE[0]}}.runfiles"
else
  echo "error: cannot find runfiles directory" >&2
  exit 1
fi

# Symlink pre-compiled core-libs next to the jank binary so the module
# loader finds .o files and skips slow JIT compilation of clojure.core.
resolve() {{ python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }}
JANK_BIN="${{RUNFILES}}/_main/{compiler}"
JANK_DIR="$(dirname "$(resolve "$JANK_BIN")")"
if [[ -f "${{RUNFILES}}/_main/{core_o}" ]]; then
  mkdir -p "$JANK_DIR/core-libs/clojure"
  ln -sf "$(resolve "${{RUNFILES}}/_main/{core_o}")" "$JANK_DIR/core-libs/clojure/core.o"
fi
# Symlink the Bazel-built PCH next to the binary so jank finds it.
PCH_SRC="$(resolve "${{RUNFILES}}/_main/{pch}" 2>/dev/null || true)"
if [[ -n "$PCH_SRC" && "$PCH_SRC" != "$JANK_DIR/incremental.pch" ]]; then
  ln -sf "$PCH_SRC" "$JANK_DIR/incremental.pch"
fi

exec "$JANK_BIN" \\
  --module-path {module_path} \\
  {include_flags} \\
  run "${{RUNFILES}}/_main/{main}" "$@"
""".format(
        compiler = compiler.short_path,
        module_path = module_path_expr,
        include_flags = include_flags_str,
        main = main_path,
        core_o = core_o_path,
        pch = pch_path,
    )

    ctx.actions.write(
        output = launcher,
        content = script,
        is_executable = True,
    )

    runfiles_transitive = [
        trans_srcs,
        ctx.attr._resource_dir.files,
        ctx.attr._core_libs.files,
        ctx.attr._pch.files,
        ctx.attr._compiler[DefaultInfo].default_runfiles.files,
    ] + cc_header_files

    runfiles = ctx.runfiles(
        files = ctx.files.srcs + [compiler],
        transitive_files = depset(transitive = runfiles_transitive),
    )

    return [DefaultInfo(
        files = depset([launcher]),
        executable = launcher,
        runfiles = runfiles,
    )]

jank_binary = rule(
    implementation = _jank_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".jank"]),
        "main": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [JankInfo]),
        "cc_deps": attr.label_list(providers = [CcInfo]),
        "_compiler": attr.label(
            default = "//compiler+runtime:jank",
            executable = True,
            cfg = "target",
        ),
        "_resource_dir": attr.label(default = "//compiler+runtime:jank_resource"),
        "_core_libs": attr.label(default = "//compiler+runtime:clojure_core"),
        "_pch": attr.label(default = "//compiler+runtime:incremental_pch"),
    },
    executable = True,
)

# ---------------------------------------------------------------------------
# jank_aot_binary — produces a standalone native executable via AOT.
# ---------------------------------------------------------------------------

def _jank_aot_binary_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name)

    trans_srcs = depset(
        ctx.files.srcs,
        transitive = [dep[JankInfo].transitive_sources for dep in ctx.attr.deps if JankInfo in dep],
    )

    src_dirs = _collect_src_dirs(trans_srcs.to_list())
    module_path = ":".join(src_dirs)

    # The AOT compiler needs the resource dir with static libs.
    # We stage the jank binary alongside jank_aot_resource as "jank_resource".
    compiler = ctx.executable._compiler
    aot_res_files = ctx.attr._aot_resource_dir.files

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(
            transitive = [trans_srcs, aot_res_files, ctx.attr._compiler[DefaultInfo].files],
        ),
        tools = [ctx.attr._compiler[DefaultInfo].files_to_run],
        command = """\
set -euo pipefail
STAGE="/tmp/jank-aot-stage"
mkdir -p "$STAGE"
REAL_JANK="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "{compiler}")"
REAL_AOT="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "{aot_resource}")"
cp -f "$REAL_JANK" "$STAGE/jank" 2>/dev/null || true
chmod +x "$STAGE/jank"
ln -sfn "$REAL_AOT" "$STAGE/jank_resource"
"$STAGE/jank" compile --module-path {module_path} -o {output} {main}
""".format(
            compiler = compiler.path,
            aot_resource = ctx.files._aot_resource_dir[0].path,
            module_path = module_path,
            output = out.path,
            main = ctx.attr.main,
        ),
        mnemonic = "JankAOT",
        progress_message = "AOT compiling jank binary %s" % ctx.attr.name,
        execution_requirements = {"no-sandbox": "1"},
        env = _JANK_ACTION_ENV,
    )

    return [DefaultInfo(
        files = depset([out]),
        executable = out,
    )]

jank_aot_binary = rule(
    implementation = _jank_aot_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".jank"]),
        "main": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [JankInfo]),
        "_compiler": attr.label(
            default = "//compiler+runtime:jank",
            executable = True,
            cfg = "target",
        ),
        "_aot_resource_dir": attr.label(default = "//compiler+runtime:jank_aot_resource"),
    },
    executable = True,
)
