#!/usr/bin/env bash

set -o nounset -o errexit -o pipefail

# format_multirun's positional arguments are name, jobs, print_command,
# disable_git_attribute_checks. cpus comes after them, so it does not shift them.
dir="$TEST_SRCDIR/_main/format/test"

function fail {
    echo >&2 "FAIL: $*"
    exit 1
}

grep -q '"print_command": *true' "$dir/format_positional_3.json" || fail "the third positional argument should set print_command"
grep -q "export disable_git_attribute_checks='false'" "$dir/format_positional_3_Python_with_ruff.bash" || fail "three positional arguments should keep git attribute checks"
grep -q '"print_command": *false' "$dir/format_positional_4.json" || fail "print_command should be False"
grep -q "export disable_git_attribute_checks='true'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "the fourth positional argument should disable git attribute checks"
grep -q "export cpus='auto'" "$dir/format_positional_4_Python_with_ruff.bash" || fail "cpus should default to auto"

echo "PASS"
