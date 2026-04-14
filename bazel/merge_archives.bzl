load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

"""Rule to merge multiple static archives (and loose .o files) into one."""

def _merge_archives_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.output_name)

    # Collect all .a files from deps that provide CcInfo.
    inputs = []
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
                for lib in linker_input.libraries:
                    if lib.pic_static_library:
                        inputs.append(lib.pic_static_library)
                    elif lib.static_library:
                        inputs.append(lib.static_library)

    # Also include loose .o / .a files from extra_objects.
    inputs.extend(ctx.files.extra_objects)

    # Deduplicate by path.
    seen = {}
    unique = []
    for a in inputs:
        if a.path not in seen:
            seen[a.path] = True
            unique.append(a)

    ar = ctx.executable._ar

    ctx.actions.run_shell(
        outputs = [out],
        inputs = unique + [ar],
        command = "{ar} qcLS {out} {inputs}".format(
            ar = ar.path,
            out = out.path,
            inputs = " ".join([a.path for a in unique]),
        ),
        mnemonic = "MergeArchives",
        progress_message = "Merging archives into %s" % ctx.attr.output_name,
    )

    return [DefaultInfo(files = depset([out]))]

merge_archives = rule(
    implementation = _merge_archives_impl,
    attrs = {
        "deps": attr.label_list(providers = [CcInfo]),
        "extra_objects": attr.label_list(allow_files = [".o", ".a"]),
        "output_name": attr.string(mandatory = True),
        "_ar": attr.label(
            default = "@@llvm++http_archive+llvm-toolchain-minimal-22.1.0-darwin-arm64//:llvm-ar",
            executable = True,
            cfg = "exec",
        ),
    },
)
