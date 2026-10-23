#!/usr/bin/env bash
# Tests format.sh's CPU budget and parallel batches with a mock formatter.

set -o nounset -o errexit -o pipefail

FORMAT_SH="$TEST_SRCDIR/_main/format/private/format.sh"
BUILD_WORKSPACE_DIRECTORY=$TEST_TMPDIR source "$FORMAT_SH"

function fail {
    echo >&2 "FAIL: $*"
    exit 1
}

# A mock formatter: one "call" line per process, then each file argument on its
# own line. Exits 1 when given the file named in $MOCK_FAIL_ON. With $MOCK_LOCK,
# records "overlap" in $MOCK_LOCK.overlap when two calls run at once. With
# $MOCK_PIDS, writes its pid there and becomes a long sleep, like a slow
# formatter binary.
cat >mock_formatter.sh <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_PIDS:-}" ]]; then
    echo $$ >"$MOCK_PIDS/$$"
    exec sleep 30
fi
if [[ -n "${MOCK_LOCK:-}" ]]; then
    mkdir "$MOCK_LOCK" 2>/dev/null || echo overlap >>"$MOCK_LOCK.overlap"
    sleep 0.05
fi
echo "call RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-unset} GOMAXPROCS=${GOMAXPROCS:-unset}"
for f in "$@"; do
    echo "$f"
    [[ "$f" != "${MOCK_FAIL_ON:-}" ]] || { echo >&2 "error in $f"; exit 1; }
done
if [[ -n "${MOCK_LOCK:-}" ]]; then
    rmdir "$MOCK_LOCK"
fi
EOF
chmod +x mock_formatter.sh
mock="$PWD/mock_formatter.sh"

# numbered <prefix> <count>: <prefix>0001.txt to <prefix><count>.txt, one per line.
# BusyBox seq has no -f.
function numbered {
    local i
    for ((i = 1; i <= $2; i++)); do
        printf '%s%04d.txt\n' "$1" "$i"
    done
}

files=$(numbered src/file 1000)
small=$(numbered src/file 100)

function calls {
    grep -c '^call' <<<"$1" || true
}

# assert_files <name> <output> <expected files>: the output lists every file once, in order.
function assert_files {
    [[ "$(grep -v '^call' <<<"$2")" == "$3" ]] || fail "$1: output lost, duplicated or reordered files"
}

# assert_serial <name> <output> <thread variables>: one process, with the given thread caps.
function assert_serial {
    [[ "$(calls "$2")" == 1 ]] || fail "$1 should run one process, ran $(calls "$2")"
    grep -q "^call $3" <<<"$2" || fail "$1 should report '$3', got: $(grep '^call' <<<"$2")"
}
none="RAYON_NUM_THREADS=unset GOMAXPROCS=unset"

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
[[ "$(RULES_LINT_FORMAT_CPUS=0 cpus=8 cpu-budget)" == 8 ]] || fail "a zero override should be ignored"

# Parallel batches: every file once, in input order.
out=$(parallel=true cpus=8 format-files "$files" Shell "$mock")
(($(calls "$out") > 1)) || fail "expected several batches with cpus=8, got $(calls "$out")"
assert_files "parallel batches" "$out" "$files"

# The batching threshold is 128 files.
for n in 127 128 129; do
    list=$(numbered src/file "$n")
    out=$(parallel=true cpus=8 format-files "$list" Shell "$mock")
    assert_files "$n files" "$out" "$list"
    if ((n < 128)); then
        [[ "$(calls "$out")" == 1 ]] || fail "$n files should run one process"
    else
        (($(calls "$out") > 1)) || fail "$n files should run as batches"
    fi
done

# Paths with spaces and shell metacharacters reach the formatter unchanged.
odd=$(printf '%s\n' "src/a b.txt" "src/it's.txt" 'src/$HOME*.txt' "src/[x].txt" "src/semi;colon.txt" 'src/back\slash.txt' "src/-dash.txt")
list=$(printf '%s\n%s' "$odd" "$(numbered src/pad 200)")
assert_files "unusual paths in batches" "$(parallel=true cpus=4 format-files "$list" Shell "$mock")" "$list"
assert_files "unusual paths serially" "$(format-files "$list" Shell "$mock")" "$list"

# A batch longer than xargs's command line splits into several calls, in order.
# Each path is 20,000 characters; the files do not need to exist for the mock.
pad=$(printf '%*s' 20000 '' | tr ' ' x)
long=$(for i in $(seq 1 200); do printf "src/%05d%s.txt\n" "$i" "$pad"; done)
out=$(parallel=true cpus=2 format-files "$long" Shell "$mock")
(($(calls "$out") > 4)) || fail "long paths should split batches into more calls than batches, got $(calls "$out")"
assert_files "long paths in batches" "$out" "$long"

# Serial means no two formatter calls at once, even when xargs splits the list.
lock="$TEST_TMPDIR/serial.lock"
out=$(MOCK_LOCK="$lock" format-files "$long" Shell "$mock")
(($(calls "$out") > 1)) || fail "the serial long-path run should take several calls"
[[ ! -e "$lock.overlap" ]] || fail "serial calls overlapped"
assert_files "long paths serially" "$out" "$long"

# Duplicate paths are dropped before batching, so two batches never write one file.
dups=$(for f in $files; do echo "$f"; echo "$f"; done; echo "src/file0001.txt")
out=$(parallel=true cpus=8 format-files "$dups" Shell "$mock")
assert_files "duplicates in batches" "$out" "$files"
# Without a budget the formatter gets the list as before.
[[ "$(grep -vc '^call' <<<"$(format-files "$dups" Shell "$mock")")" == 2001 ]] || fail "the serial path should keep its input"

# Different paths to one file are dropped too: overlapping directory arguments,
# a symlinked directory, .., // and a symlink to a file. The first spelling is
# kept.
mkdir -p alias/src/sub alias/-dir
(cd alias && for f in $(numbered src/f 200) $(numbered -dir/f 2); do : >"$f"; done)
ln -s src alias/link
ln -s f0001.txt alias/src/symlink.txt
ln -s ../f0002.txt alias/src/sub/up.txt
first=$(numbered src/f 200 && numbered -dir/f 2)
aliases=$(
    echo "$first"
    numbered ./src/f 200
    numbered link/f 200
    numbered src/sub/../f 200
    numbered src//f 200
    numbered ./-dir/f 2
    echo src/symlink.txt
    echo src/sub/up.txt
    echo "$TEST_TMPDIR/alias/src/f0003.txt"
)
out=$(cd alias && parallel=true cpus=2 format-files "$aliases" Shell "$mock")
assert_files "aliased paths in batches" "$out" "$first"
# The same through find, given overlapping directories.
for f in $(numbered alias/src/f 200); do mv "$f" "${f%.txt}.py"; done
out=$(cd alias && disable_git_attribute_checks=true && found=$(ls-files Python src ./src link/) &&
    parallel=true cpus=2 format-files "$found" Python "$mock")
(($(calls "$out") > 1)) || fail "overlapping directory arguments should still run as batches"
[[ "$(grep -v '^call' <<<"$out" | sed 's|.*/||' | LC_ALL=C sort)" == "$(numbered f 200 | sed 's|\.txt$|.py|')" ]] ||
    fail "overlapping directory arguments should format each file once, got $(grep -vc '^call' <<<"$out") paths"

# Threaded formatters: 4 batches at a time, each capped to a share of the budget.
grep -q 'RAYON_NUM_THREADS=2 ' <<<"$(parallel=true thread_env=RAYON_NUM_THREADS cpus=8 format-files "$files" Python "$mock")" || fail "Python should get RAYON_NUM_THREADS=2"
grep -q 'GOMAXPROCS=4$' <<<"$(parallel=true thread_env=GOMAXPROCS cpus=16 format-files "$files" Go "$mock")" || fail "Go should get GOMAXPROCS=4"

# Without a budget, the default, nothing changes: one process, no thread caps.
assert_serial "the default" "$(parallel=true thread_env=RAYON_NUM_THREADS format-files "$files" Python "$mock")" "$none"
assert_serial "cpus=none" "$(parallel=true thread_env=GOMAXPROCS cpus=none format-files "$files" Go "$mock")" "$none"

# With a budget, serial runs still cap threads to it.
assert_serial "cpus=1" "$(parallel=true thread_env=RAYON_NUM_THREADS cpus=1 format-files "$files" Python "$mock")" "RAYON_NUM_THREADS=1 GOMAXPROCS=unset"
assert_serial "a small Python set" "$(parallel=true thread_env=RAYON_NUM_THREADS cpus=8 format-files "$small" Python "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"
assert_serial "a small Go set" "$(parallel=true thread_env=GOMAXPROCS cpus=2 format-files "src/one.go" Go "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=2"
assert_serial "a formatter not marked parallel" "$(thread_env=RAYON_NUM_THREADS cpus=8 format-files "$files" Python "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"
assert_serial "parallel=false" "$(parallel=false cpus=8 format-files "$files" Shell "$mock")" "$none"

# The thread variable comes from thread_env, not the language.
assert_serial "Python without thread_env" "$(cpus=8 format-files "$small" Python "$mock")" "$none"
assert_serial "an invalid thread_env" "$(thread_env='A-B' cpus=8 format-files "$small" Python "$mock")" "$none"
assert_serial "a custom thread_env" "$(thread_env=RAYON_NUM_THREADS cpus=8 format-files "$small" Shell "$mock")" "RAYON_NUM_THREADS=8 GOMAXPROCS=unset"

# A thread variable the caller set is kept, serial or parallel.
assert_serial "a caller's GOMAXPROCS" "$(GOMAXPROCS=3 thread_env=GOMAXPROCS cpus=8 format-files "src/one.go" Go "$mock")" "RAYON_NUM_THREADS=unset GOMAXPROCS=3"
out=$(RAYON_NUM_THREADS=7 parallel=true thread_env=RAYON_NUM_THREADS cpus=8 format-files "$files" Python "$mock")
(($(calls "$out") > 1)) || fail "a caller's RAYON_NUM_THREADS should not stop parallel batches"
! grep '^call' <<<"$out" | grep -qv "^call RAYON_NUM_THREADS=7 " || fail "every batch should keep the caller's RAYON_NUM_THREADS=7"

# format_test sets cpus=serial, which RULES_LINT_FORMAT_CPUS cannot change.
assert_serial "format_test with the override" \
    "$(RULES_LINT_FORMAT_CPUS=8 parallel=true thread_env=RAYON_NUM_THREADS cpus=serial format-files "$files" Python "$mock")" "$none"
# For format_multirun the override wins over the attribute, and opts in without it.
(($(calls "$(RULES_LINT_FORMAT_CPUS=8 parallel=true cpus=1 format-files "$files" Shell "$mock")") > 1)) || fail "RULES_LINT_FORMAT_CPUS=8 should override cpus=1"
(($(calls "$(RULES_LINT_FORMAT_CPUS=8 parallel=true cpus=none format-files "$files" Shell "$mock")") > 1)) || fail "RULES_LINT_FORMAT_CPUS=8 should opt in with cpus=none"

# A failing batch fails the run, and the other batches' output is still printed.
code=0
out=$(MOCK_FAIL_ON=src/file0500.txt parallel=true cpus=8 format-files "$files" Shell "$mock" 2>err.txt) || code=$?
((code != 0)) || fail "a failing batch should fail format-files"
grep -q 'error in src/file0500.txt' err.txt || fail "the failing batch's stderr should be printed"
grep -q '^src/file1000.txt$' <<<"$out" || fail "batches after the failure should still be printed"

# An interrupt stops every formatter and removes the batch files, then the
# signal ends the script. Job control keeps SIGINT from being ignored in the
# background shell.
for signal in TERM INT; do
    pids="$TEST_TMPDIR/pids.$signal"
    tmp="$TEST_TMPDIR/tmp.$signal"
    mkdir -p "$pids" "$tmp"
    set -m
    TMPDIR="$tmp" MOCK_PIDS="$pids" BUILD_WORKSPACE_DIRECTORY="$TEST_TMPDIR" parallel=true cpus=4 \
        bash -c 'source "$1"; format-files "$2" Shell "$3"' _ "$FORMAT_SH" "$files" "$mock" >/dev/null 2>"$TEST_TMPDIR/child.$signal.err" &
    shell=$!
    set +m
    for _ in $(seq 1 100); do
        (($(ls "$pids" | wc -l) >= 4)) && break
        sleep 0.1
    done
    (($(ls "$pids" | wc -l) >= 4)) || fail "$signal: the formatters did not start"
    start=$SECONDS
    kill -"$signal" "$shell"
    code=0
    wait "$shell" || code=$?
    # The mock formatters sleep 30s, so finishing them would take longer.
    ((SECONDS - start < 10)) || fail "$signal: the script took $((SECONDS - start))s to stop"
    ((code > 128)) || fail "$signal: the script should end by the signal, exited $code: $(cat "$TEST_TMPDIR/child.$signal.err")"
    for pid in $(cat "$pids"/*); do
        ! kill -0 "$pid" 2>/dev/null || fail "$signal: formatter $pid is still running"
    done
    [[ -z "$(ls -A "$tmp")" ]] || fail "$signal: batch files were left in TMPDIR: $(ls -A "$tmp")"
done

echo "PASS"
