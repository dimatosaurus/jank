"""Rule to assemble the jank resource directory tree.

The jank compiler expects a resource directory containing:
  - src/jank/**/*.jank    (core library sources)
  - include/              (jank + third-party C++ headers for JIT)
  - bin/clang++           (Clang binary for JIT/AOT)
  - lib/clang/<ver>/      (Clang builtin headers)
"""

def _jank_resource_dir_impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.name)
    outpath = out.path

    # Derive the package prefix to strip from source file paths.
    # e.g. "compiler+runtime/" when BUILD is in that directory.
    pkg = ctx.label.package
    pkg_prefix = (pkg + "/") if pkg else ""

    commands = ["set -e"]

    # --- .jank source files → src/jank/... ---
    for f in ctx.files.jank_sources:
        rel = f.path
        if rel.startswith(pkg_prefix):
            rel = rel[len(pkg_prefix):]
        commands.append("mkdir -p '{}/{}'".format(outpath, rel.rsplit("/", 1)[0]))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/{}'".format(f.path, outpath, rel))

    # --- jank headers → include/... (strip include/cpp/ prefix) ---
    for f in ctx.files.jank_headers:
        rel = f.path
        if rel.startswith(pkg_prefix):
            rel = rel[len(pkg_prefix):]
        if rel.startswith("include/cpp/"):
            rel = "include/" + rel[len("include/cpp/"):]
        commands.append("mkdir -p '{}/{}'".format(outpath, rel.rsplit("/", 1)[0]))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/{}'".format(f.path, outpath, rel))

    # --- third-party headers ---
    for i, target in enumerate(ctx.attr.third_party_headers):
        strip = ctx.attr.third_party_header_strips[i] if i < len(ctx.attr.third_party_header_strips) else ""
        prefix = ctx.attr.third_party_header_prefixes[i] if i < len(ctx.attr.third_party_header_prefixes) else "include"
        for f in target.files.to_list():
            # Use short_path which strips the external repo prefix,
            # giving paths relative to the repo root (e.g. "include/gc.h").
            rel = f.short_path
            # For external repos, short_path starts with "../<repo>/"
            if rel.startswith("../"):
                rel = "/".join(rel.split("/")[2:])
            if strip and rel.startswith(strip):
                rel = rel[len(strip):]
            if rel.startswith("/"):
                rel = rel[1:]
            dst = prefix + "/" + rel if prefix else rel
            commands.append("mkdir -p '{}/{}'".format(outpath, dst.rsplit("/", 1)[0]))
            commands.append("ln -sf \"${{PWD}}/{}\" '{}/{}'".format(f.path, outpath, dst))

    # --- clang++ binary → bin/clang++ ---
    if ctx.files.clang_binary:
        clang = ctx.files.clang_binary[0]
        commands.append("mkdir -p '{}/bin'".format(outpath))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/bin/clang++'".format(clang.path, outpath))

    # --- libc++ headers → include/c++/v1/ ---
    # The JIT on macOS uses -nostdinc++ -I {clang_dir}/../include/c++/v1
    # which resolves to {resource_dir}/include/c++/v1/
    # We symlink the entire directory from the sysroot.
    if ctx.files.sysroot:
        sysroot = ctx.files.sysroot[0]
        commands.append("mkdir -p '{}/include/c++'".format(outpath))
        commands.append("ln -sf \"${{PWD}}/{}/usr/include/c++/v1\" '{}/include/c++/v1'".format(
            sysroot.path, outpath,
        ))

    # --- clang resource dir → lib/clang/<ver>/ ---
    for f in ctx.files.clang_resource_dir:
        path = f.path
        idx = path.find("lib/clang/")
        if idx >= 0:
            rel = path[idx:]
            commands.append("mkdir -p '{}/{}'".format(outpath, rel.rsplit("/", 1)[0]))
            commands.append("ln -sf \"${{PWD}}/{}\" '{}/{}'".format(path, outpath, rel))

    # --- pre-compiled core modules → core-libs/ ---
    # The module loader checks {process_dir}/core-libs/ for .o files
    # and prefers them over JIT-compiling from .jank source.
    for f in ctx.files.core_libs:
        # f.path is like "clojure/core.o" — place at core-libs/clojure/core.o
        commands.append("mkdir -p '{}/core-libs/{}'".format(outpath, f.path.rsplit("/", 1)[0]))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/core-libs/{}'".format(
            f.path, outpath, f.path,
        ))

    # --- static libraries → lib/ ---
    # The AOT linker uses -L{resource_dir}/lib and links against these.
    for f in ctx.files.static_libs:
        commands.append("mkdir -p '{}/lib'".format(outpath))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/lib/{}'".format(
            f.path, outpath, f.basename,
        ))

    # --- .clang-format ---
    if ctx.files.clang_format:
        commands.append("mkdir -p '{}/share'".format(outpath))
        commands.append("ln -sf \"${{PWD}}/{}\" '{}/share/.clang-format'".format(
            ctx.files.clang_format[0].path,
            outpath,
        ))

    all_inputs = (
        ctx.files.jank_sources +
        ctx.files.jank_headers +
        ctx.files.clang_binary +
        ctx.files.sysroot +
        ctx.files.clang_resource_dir +
        ctx.files.core_libs +
        ctx.files.static_libs +
        ctx.files.clang_format
    )
    for target in ctx.attr.third_party_headers:
        all_inputs = all_inputs + target.files.to_list()

    ctx.actions.run_shell(
        outputs = [out],
        inputs = all_inputs,
        command = "\n".join(commands),
        mnemonic = "JankResourceDir",
        progress_message = "Assembling jank resource directory",
    )

    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

jank_resource_dir = rule(
    implementation = _jank_resource_dir_impl,
    attrs = {
        "jank_sources": attr.label_list(allow_files = [".jank"]),
        "jank_headers": attr.label_list(allow_files = True),
        "third_party_headers": attr.label_list(allow_files = True),
        "third_party_header_strips": attr.string_list(),
        "third_party_header_prefixes": attr.string_list(),
        "clang_binary": attr.label_list(allow_files = True),
        "sysroot": attr.label_list(allow_files = True),
        "clang_resource_dir": attr.label_list(allow_files = True),
        "core_libs": attr.label_list(allow_files = [".o"]),
        "static_libs": attr.label_list(allow_files = [".a"]),
        "clang_format": attr.label_list(allow_files = True),
    },
)
