#!/usr/bin/env bash
# Runs real formatters serially and as parallel batches over the same generated
# files, and checks that both give the same result: identical files after
# fixing, a second pass that changes nothing, and the same files reported in
# check mode, with and without a file that does not parse.

set -o nounset -o errexit -o pipefail

BUILD_WORKSPACE_DIRECTORY=$TEST_TMPDIR source "$TEST_SRCDIR/_main/format/private/format.sh"

function fail {
    echo >&2 "FAIL: $*"
    exit 1
}

# generate <dir> <ext> <ok> <bad> [<malformed>]: 300 files named f0001.<ext> and
# up, split across two directories, one with a space in its name. Every third
# file needs formatting.
function generate {
    local dir="$1" ext="$2" ok="$3" bad="$4" malformed="${5:-}" i sub
    for ((i = 1; i <= 300; i++)); do
        sub="$dir/plain"
        ((i % 2)) || sub="$dir/with space"
        mkdir -p "$sub"
        if ((i % 3 == 0)); then
            printf '%b' "$bad" >"$sub/$(printf 'f%04d' "$i").$ext"
        else
            printf '%b' "$ok" >"$sub/$(printf 'f%04d' "$i").$ext"
        fi
    done
    if [[ -n "$malformed" ]]; then
        printf '%b' "$malformed" >"$dir/plain/f0151.$ext"
    fi
}

# run <dir> <serial|parallel> <lang> <thread variable> <command...>: formats the
# files under dir, from dir, and prints the formatter's output. Fails only when
# the formatter fails and $EXPECT_FAILURE is unset.
function run {
    local dir="$1" how="$2" lang="$3" var="$4" && shift 4
    local files code=0
    files=$(cd "$dir" && find . -type f ! -path './.ruff_cache/*' | sed 's|^\./||' | LC_ALL=C sort)
    if [[ "$how" == parallel ]]; then
        (cd "$dir" && parallel=true cpus=4 thread_env="$var" format-files "$files" "$lang" "$@") 2>&1 || code=$?
    else
        (cd "$dir" && format-files "$files" "$lang" "$@") 2>&1 || code=$?
    fi
    if ((code != 0)) && [[ -z "${EXPECT_FAILURE:-}" ]]; then
        fail "$lang $how run of $* failed with $code"
    fi
    echo "exit=$code"
}

# reported <output> <ext>: the generated files an output names, sorted.
function reported {
    grep -oE "f[0-9]{4}\.$2" <<<"$1" | LC_ALL=C sort -u || true
}

function same_tree {
    diff -r -x .ruff_cache "$1" "$2" >/dev/null
}

# check_formatter <lang> <ext> <thread variable> <binary> <check flags> <fix flags> <ok> <bad> <malformed>
function check_formatter {
    local lang="$1" ext="$2" var="$3" bin="$4" check="$5" fix="$6" ok="$7" bad="$8" malformed="$9"
    local root="$TEST_TMPDIR/$lang" expected out how i
    mkdir -p "$root"
    generate "$root/base" "$ext" "$ok" "$bad"
    expected=$(for ((i = 3; i <= 300; i += 3)); do printf 'f%04d.%s\n' "$i" "$ext"; done)

    # Check mode reports the same files serially and in parallel.
    for how in serial parallel; do
        cp -R "$root/base" "$root/check-$how"
        out=$(EXPECT_FAILURE=1 run "$root/check-$how" $how "$lang" "$var" "$bin" $check)
        [[ "$(reported "$out" "$ext")" == "$expected" ]] || fail "$lang: $how check mode reported $(reported "$out" "$ext" | wc -l) files, expected 100"
        same_tree "$root/base" "$root/check-$how" || fail "$lang: $how check mode changed files"
    done

    # Fix mode gives identical files, and a second pass changes nothing.
    for how in serial parallel; do
        cp -R "$root/base" "$root/fix-$how"
        run "$root/fix-$how" $how "$lang" "$var" "$bin" $fix >/dev/null
    done
    ! same_tree "$root/base" "$root/fix-serial" || fail "$lang: fix mode changed nothing"
    same_tree "$root/fix-serial" "$root/fix-parallel" || fail "$lang: serial and parallel fixes differ: $(diff -r -x .ruff_cache "$root/fix-serial" "$root/fix-parallel" | head -n 20)"
    cp -R "$root/fix-parallel" "$root/second-pass"
    run "$root/second-pass" parallel "$lang" "$var" "$bin" $fix >/dev/null
    same_tree "$root/fix-parallel" "$root/second-pass" || fail "$lang: a second parallel pass changed files"
    out=$(run "$root/second-pass" parallel "$lang" "$var" "$bin" $check)
    [[ -z "$(reported "$out" "$ext")" ]] || fail "$lang: check mode still reports files after fixing"

    # With a file that does not parse, both runs fail, name it, and still report
    # or fix every other file.
    generate "$root/malformed" "$ext" "$ok" "$bad" "$malformed"
    for how in serial parallel; do
        cp -R "$root/malformed" "$root/malformed-check-$how"
        out=$(EXPECT_FAILURE=1 run "$root/malformed-check-$how" $how "$lang" "$var" "$bin" $check)
        grep -q '^exit=0$' <<<"$out" && fail "$lang: $how check mode passed with a malformed file"
        grep -q "f0151\.$ext" <<<"$out" || fail "$lang: $how check mode did not name the malformed file"
        [[ "$(reported "$out" "$ext" | grep -v "f0151\.$ext")" == "$(grep -v "f0151\.$ext" <<<"$expected")" ]] ||
            fail "$lang: $how check mode lost diagnostics next to the malformed file"
        cp -R "$root/malformed" "$root/malformed-fix-$how"
        out=$(EXPECT_FAILURE=1 run "$root/malformed-fix-$how" $how "$lang" "$var" "$bin" $fix)
        grep -q '^exit=0$' <<<"$out" && fail "$lang: $how fix mode passed with a malformed file"
    done
    same_tree "$root/malformed-fix-serial" "$root/malformed-fix-parallel" || fail "$lang: serial and parallel fixes differ next to a malformed file"
    echo "$lang: OK"
}

ruff=$(rlocation "$RUFF")
gofumpt=$(rlocation "$GOFUMPT")
shfmt=$(rlocation "$SHFMT")
buildifier=$(rlocation "$BUILDIFIER")

# Flags match CHECK_FLAGS and FIX_FLAGS in format/private/formatter_binary.bzl.
check_formatter Python py RAYON_NUM_THREADS "$ruff" "format --check --force-exclude --diff" "format --force-exclude" \
    'def f(a, b):\n    return {"a": a, "b": b}\n' 'def f( a,b ):\n  return {"a":a,"b":b}\n' 'def f(:\n'
check_formatter Go go GOMAXPROCS "$gofumpt" "-l" "-w" \
    'package p\n\nfunc F() int {\n\treturn 1\n}\n' 'package p\nfunc F() int {\nreturn 1\n}\n' 'package p\nfunc {\n'
check_formatter Shell sh "" "$shfmt" "--diff --apply-ignore" "-w --apply-ignore" \
    'if true; then\n\techo hi\nfi\n' 'if true; then\necho hi\nfi\n' 'if then fi (\n'
check_formatter Starlark bzl "" "$buildifier" "-mode=check" "-mode=fix" \
    'foo(a = 1, b = 2)\n' 'foo(a=1,b = 2)\n' 'foo(\n'

echo "PASS"
