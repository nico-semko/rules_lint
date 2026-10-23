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

# cpu-budget: the run-time override wins over the attribute, and auto is at most 16.
[[ "$(RULES_LINT_FORMAT_CPUS=3 cpus=8 cpu-budget)" == 3 ]] || fail "override should win"
[[ "$(cpus=8 cpu-budget)" == 8 ]] || fail "attribute should apply"
[[ "$(RULES_LINT_FORMAT_CPUS=8 cpus=serial cpu-budget)" == 1 ]] || fail "cpus=serial should ignore the override"
auto=$(cpus=auto cpu-budget)
((auto >= 1 && auto <= 16)) || fail "auto budget out of range: $auto"
[[ "$(RULES_LINT_FORMAT_CPUS=junk cpus=auto cpu-budget)" == "$auto" ]] || fail "invalid override should fall back to auto"

# Parallel batches: every file once, in input order, with no "call" line inside a batch's file list.
out=$(cpus=8 format-files "$files" Shell "$mock")
calls=$(grep -c '^call' <<<"$out")
((calls > 1)) || fail "expected several batches with cpus=8, got $calls"
[[ "$(grep -v '^call' <<<"$out")" == "$files" ]] || fail "parallel output lost, duplicated or reordered files"

# Threaded formatters: 4 batches at a time, each capped to a share of the budget.
grep -q 'RAYON_NUM_THREADS=2 ' <<<"$(cpus=8 format-files "$files" Python "$mock")" || fail "Python should get RAYON_NUM_THREADS=2"
grep -q 'GOMAXPROCS=4$' <<<"$(cpus=16 format-files "$files" Go "$mock")" || fail "Go should get GOMAXPROCS=4"

# Serial cases run one process. Go and Python formatters still get their threads
# capped to the budget.
function assert_serial {
    local name="$1" out="$2" threads="$3"
    [[ "$(grep -c '^call' <<<"$out")" == 1 ]] || fail "$name should run one process"
    grep -q "^call $threads" <<<"$out" || fail "$name should report '$threads', got: $(grep '^call' <<<"$out")"
}
assert_serial "cpus=1" "$(cpus=1 format-files "$files" Python "$mock")" "RAYON_NUM_THREADS=1 GOMAXPROCS=unset"
assert_serial "a small Python set" "$(cpus=8 format-files "$small" Python "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"
assert_serial "a small Go set" "$(cpus=2 format-files "src/one.go" Go "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=2"
assert_serial "a JVM formatter" "$(cpus=8 format-files "$files" Java "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=unset"
assert_serial "a small set of another language" "$(cpus=8 format-files "$small" Shell "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=unset"

# format_test sets cpus=serial, which RULES_LINT_FORMAT_CPUS cannot change.
assert_serial "format_test with the override" \
    "$(RULES_LINT_FORMAT_CPUS=8 cpus=serial format-files "$files" Python "$mock")" "RAYON_NUM_THREADS=1 GOMAXPROCS=unset"
# For format_multirun the override still wins over the attribute.
calls=$(RULES_LINT_FORMAT_CPUS=8 cpus=1 format-files "$files" Shell "$mock" | grep -c '^call')
((calls > 1)) || fail "RULES_LINT_FORMAT_CPUS=8 should override cpus=1, got $calls process(es)"

# A failing batch fails the run, and the other batches' output is still printed.
code=0
out=$(MOCK_FAIL_ON=src/file0500.txt cpus=8 format-files "$files" Shell "$mock" 2>err.txt) || code=$?
((code != 0)) || fail "a failing batch should fail format-files"
grep -q 'error in src/file0500.txt' err.txt || fail "the failing batch's stderr should be printed"
grep -q '^src/file1000.txt$' <<<"$out" || fail "batches after the failure should still be printed"

echo "PASS"
