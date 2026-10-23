load("@aspect_rules_lint//format:defs.bzl", "format_multirun")

package(default_visibility = ["//:__subpackages__"])

format_multirun(
    name = "format",
    c = "@llvm_toolchain_llvm//:bin/clang-format",
    # clang-format writes only the files it is given, so it may run as parallel
    # batches when a CPU budget is set.
    c_parallel = True,
    cc = "@llvm_toolchain_llvm//:bin/clang-format",
    cc_parallel = True,
    cuda = "@llvm_toolchain_llvm//:bin/clang-format",
    cuda_parallel = True,
    visibility = ["//:__subpackages__"],
)
