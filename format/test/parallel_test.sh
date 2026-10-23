#!/usr/bin/env bash

set -o nounset -o errexit -o pipefail

BUILD_WORKSPACE_DIRECTORY=$TEST_TMPDIR source "$TEST_SRCDIR/_main/format/private/format.sh"

function fail {
    echo >&2 "FAIL: $*"
    exit 1
}

# A mock formatter: one "call" line per process, then each file argument on its
# own line. Exits 1 when given the file named in $MOCK_FAIL_ON.
cat >mock_formatter.sh <<'EOF'
#!/usr/bin/env bash
echo "call RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-unset} GOMAXPROCS=${GOMAXPROCS:-unset}"
for f in "$@"; do
    echo "$f"
    [[ "$f" != "${MOCK_FAIL_ON:-}" ]] || { echo >&2 "error in $f"; exit 1; }
done
EOF
chmod +x mock_formatter.sh
mock="$PWD/mock_formatter.sh"

files=$(seq -f "src/file%04g.txt" 1 1000)
small=$(seq -f "src/file%04g.txt" 1 100)

# cpu-budget: 0 means no budget. The run-time override wins over the attribute,
# auto is at most 16, and format_test's cpus=serial ignores the override.
[[ "$(cpus=none cpu-budget)" == 0 ]] || fail "cpus=none should have no budget"
[[ "$(cpu-budget)" == 0 ]] || fail "unset cpus should have no budget"
[[ "$(cpus=8 cpu-budget)" == 8 ]] || fail "attribute should apply"
[[ "$(RULES_LINT_FORMAT_CPUS=3 cpus=8 cpu-budget)" == 3 ]] || fail "override should win"
[[ "$(RULES_LINT_FORMAT_CPUS=3 cpus=none cpu-budget)" == 3 ]] || fail "override should opt in without the attribute"
[[ "$(RULES_LINT_FORMAT_CPUS=8 cpus=serial cpu-budget)" == 0 ]] || fail "cpus=serial should ignore the override"
auto=$(cpus=auto cpu-budget)
((auto >= 1 && auto <= 16)) || fail "auto budget out of range: $auto"
[[ "$(RULES_LINT_FORMAT_CPUS=auto cpus=none cpu-budget)" == "$auto" ]] || fail "override should accept auto"
[[ "$(RULES_LINT_FORMAT_CPUS=junk cpus=8 cpu-budget)" == 8 ]] || fail "an invalid override should be ignored"

# Parallel batches: every file once, in input order, with no "call" line inside a batch's file list.
out=$(cpus=8 format-files "$files" Shell "$mock")
calls=$(grep -c '^call' <<<"$out")
((calls > 1)) || fail "expected several batches with cpus=8, got $calls"
[[ "$(grep -v '^call' <<<"$out")" == "$files" ]] || fail "parallel output lost, duplicated or reordered files"

# Threaded formatters: 4 batches at a time, each capped to a share of the budget.
grep -q 'RAYON_NUM_THREADS=2 ' <<<"$(thread_env=RAYON_NUM_THREADS cpus=8 format-files "$files" Python "$mock")" || fail "Python should get RAYON_NUM_THREADS=2"
grep -q 'GOMAXPROCS=4$' <<<"$(thread_env=GOMAXPROCS cpus=16 format-files "$files" Go "$mock")" || fail "Go should get GOMAXPROCS=4"

# Serial cases run one process.
function assert_serial {
    local name="$1" out="$2" threads="$3"
    [[ "$(grep -c '^call' <<<"$out")" == 1 ]] || fail "$name should run one process"
    grep -q "^call $threads" <<<"$out" || fail "$name should report '$threads', got: $(grep '^call' <<<"$out")"
}
none="RAYON_NUM_THREADS=unset GOMAXPROCS=unset"

# Without a budget, the default, nothing changes: one process, no thread caps.
assert_serial "the default" "$(thread_env=RAYON_NUM_THREADS format-files "$files" Python "$mock")" "$none"
assert_serial "cpus=none" "$(thread_env=GOMAXPROCS cpus=none format-files "$files" Go "$mock")" "$none"

# With a budget, serial runs still cap Go and Python threads to it.
assert_serial "cpus=1" "$(thread_env=RAYON_NUM_THREADS cpus=1 format-files "$files" Python "$mock")" "RAYON_NUM_THREADS=1 GOMAXPROCS=unset"
assert_serial "a small Python set" "$(thread_env=RAYON_NUM_THREADS cpus=8 format-files "$small" Python "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"
assert_serial "a small Go set" "$(thread_env=GOMAXPROCS cpus=2 format-files "src/one.go" Go "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=2"
assert_serial "a JVM formatter" "$(cpus=8 format-files "$files" Java "$mock")" "$none"
assert_serial "a small set of another language" "$(cpus=8 format-files "$small" Shell "$mock")" "$none"

# The thread variable comes from thread_env, not the language: a Python
# formatter without one gets no cap.
assert_serial "Python without thread_env" "$(cpus=8 format-files "$small" Python "$mock")" "$none"
assert_serial "an invalid thread_env" "$(thread_env='A-B' cpus=8 format-files "$small" Python "$mock")" "$none"
assert_serial "a custom thread_env" "$(thread_env=RAYON_NUM_THREADS cpus=8 format-files "$small" Shell "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"

# A thread variable the caller set is kept, serial or parallel.
assert_serial "a caller's GOMAXPROCS" "$(GOMAXPROCS=3 thread_env=GOMAXPROCS cpus=8 format-files "src/one.go" Go "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=3"
out=$(RAYON_NUM_THREADS=7 thread_env=RAYON_NUM_THREADS cpus=8 format-files "$files" Python "$mock")
(($(grep -c '^call' <<<"$out") > 1)) || fail "a caller's RAYON_NUM_THREADS should not stop parallel batches"
! grep '^call' <<<"$out" | grep -qv "^call RAYON_NUM_THREADS=7 " || fail "every batch should keep the caller's RAYON_NUM_THREADS=7"

# format_test sets cpus=serial, which RULES_LINT_FORMAT_CPUS cannot change.
assert_serial "format_test with the override" \
    "$(RULES_LINT_FORMAT_CPUS=8 thread_env=RAYON_NUM_THREADS cpus=serial format-files "$files" Python "$mock")" "$none"
# For format_multirun the override wins over the attribute, and opts in without it.
calls=$(RULES_LINT_FORMAT_CPUS=8 cpus=1 format-files "$files" Shell "$mock" | grep -c '^call')
((calls > 1)) || fail "RULES_LINT_FORMAT_CPUS=8 should override cpus=1, got $calls process(es)"
calls=$(RULES_LINT_FORMAT_CPUS=8 cpus=none format-files "$files" Shell "$mock" | grep -c '^call')
((calls > 1)) || fail "RULES_LINT_FORMAT_CPUS=8 should opt in with cpus=none, got $calls process(es)"

# A failing batch fails the run, and the other batches' output is still printed.
code=0
out=$(MOCK_FAIL_ON=src/file0500.txt cpus=8 format-files "$files" Shell "$mock" 2>err.txt) || code=$?
((code != 0)) || fail "a failing batch should fail format-files"
grep -q 'error in src/file0500.txt' err.txt || fail "the failing batch's stderr should be printed"
grep -q '^src/file1000.txt$' <<<"$out" || fail "batches after the failure should still be printed"

echo "PASS"
