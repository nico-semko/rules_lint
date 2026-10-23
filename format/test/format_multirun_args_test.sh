#!/usr/bin/env bash

set -o nounset -o errexit -o pipefail

# What format_multirun arguments set in the generated commands. Its positional
# arguments are name, jobs, print_command, disable_git_attribute_checks; cpus
# comes after them, so it does not shift them.
dir="$TEST_SRCDIR/_main/format/test"

function fail {
    echo >&2 "FAIL: $*"
    exit 1
}

grep -q '"print_command": *true' "$dir/format_positional_3.json" || fail "the third positional argument should set print_command"
grep -q "export disable_git_attribute_checks='false'" "$dir/format_positional_3_Python_with_ruff.bash" || fail "three positional arguments should keep git attribute checks"
grep -q '"print_command": *false' "$dir/format_positional_4.json" || fail "print_command should be False"
grep -q "export disable_git_attribute_checks='true'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "the fourth positional argument should disable git attribute checks"
grep -q "export cpus='none'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "cpus should default to none"

grep -q "export cpus='auto'" "$dir/format_cpus_auto_Python_with_ruff.bash" || fail "cpus = \"auto\" should reach the formatter"

# The thread variable comes from THREAD_ENV, and {language}_thread_env replaces it.
grep -q "export thread_env='RAYON_NUM_THREADS'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "ruff should get RAYON_NUM_THREADS"
grep -q "export thread_env=''" "$dir/format_cpus_auto_Python_with_ruff.bash" || fail "python_thread_env = None should clear it"
grep -q "export thread_env='MY_THREADS'" "$dir/format_cpus_auto_Go_with_gofmt.bash" || fail "go_thread_env should replace GOMAXPROCS"

# Only built-in formatters in PARALLEL_SAFE_LABELS batch by default, through the
# multitool label or the //format alias. Any other label for the language, here
# a mock, may be a different tool and stays serial unless {language}_parallel
# allows it.
grep -q "export parallel='true'" "$dir/format_builtin_Python_with_ruff.bash" || fail "//format:ruff should batch"
grep -q "export parallel='true'" "$dir/format_builtin_Go_with_gofmt.bash" || fail "@multitool//tools/gofumpt should batch"
grep -q "export parallel='false'" "$dir/format_builtin_Shell_with_shfmt.bash" || fail "shell_parallel = False should turn batches off"
grep -q "export parallel='false'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "a custom Python formatter should not batch by default"
grep -q "export parallel='true'" "$dir/format_cpus_auto_Go_with_gofmt.bash" || fail "go_parallel = True should allow batches for a custom formatter"
grep -q "export parallel='false'" "$dir/format_with_custom_args_Java_with_java-format.bash" || fail "java-format should not batch"

echo "PASS"
