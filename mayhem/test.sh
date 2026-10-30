#!/usr/bin/env bash
#
# mayhem/test.sh — RUN snow-apps' OWN test suites (pre-built by mayhem/build.sh; nothing is compiled here):
#   * snow_image C++ ctest suite (19 ctest entries over 7 executables; GIF/ICO/XBM codecs on)
#   * snow-image-rs unit/integration tests (core, protocol, codecs crates; libtest, 71 tests)
# Each suite asserts decoded pixels / byte layouts / protocol framing. A test process that is replaced by
# an `exit(0)` no-op prints none of its success markers / libtest result lines, so a missing marker counts
# as a failure rather than a pass.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


WORK="$SRC/build-mayhem"
passed=0 ; failed=0

# ---- snow_image (C++) via ctest ------------------------------------------------------------------
if [ ! -f "$WORK/tests/CTestTestfile.cmake" ]; then
  echo "ERROR: $WORK/tests is missing (mayhem/build.sh builds it)" >&2
  emit_ctrf "snow-apps" 0 1 0 ; exit $?
fi
CTEST_LOG="$(mktemp)"
(cd "$WORK/tests" && ctest -V --timeout 600 -j"$MAYHEM_JOBS") > "$CTEST_LOG" 2>&1
cat "$CTEST_LOG"
ctest_total=$(sed -n 's/^.*tests passed, [0-9]* tests failed out of \([0-9]*\).*$/\1/p' "$CTEST_LOG" | tail -1)
ctest_failed=$(sed -n 's/^.*tests passed, \([0-9]*\) tests failed out of.*$/\1/p' "$CTEST_LOG" | tail -1)
ctest_total=${ctest_total:-0} ; ctest_failed=${ctest_failed:-$ctest_total}
# Known-answer markers the executables print only after every assertion in them ran.
for marker in "snow_image core tests passed" "snow_image raster store tests passed" \
              "snow_image HEIF tests passed" "snow_image JPEG tests passed" \
              "snow_image JPEG XL tests passed" "snow_image PNG tests passed" \
              "Animation decoder tests passed" "raster conversion tests passed"; do
  if ! grep -qF "$marker" "$CTEST_LOG"; then
    echo "MISSING MARKER: $marker" >&2
    failed=$((failed + 1))
  fi
done
if [ "$ctest_total" -lt 19 ]; then
  echo "ERROR: ctest ran $ctest_total tests, expected 19" >&2
  failed=$((failed + 1))
fi
passed=$((passed + ctest_total - ctest_failed))
failed=$((failed + ctest_failed))
rm -f "$CTEST_LOG"

# ---- snow-image-rs (Rust) test executables recorded by build.sh -----------------------------------
if [ ! -s "$WORK/rust-tests.txt" ]; then
  echo "ERROR: $WORK/rust-tests.txt is missing (mayhem/build.sh produces it)" >&2
  failed=$((failed + 1))
else
  rust_seen=0
  while IFS=$'\t' read -r exe crate_dir; do
    [ -n "$exe" ] || continue
    out="$(cd "$crate_dir" && "$exe" 2>&1)"; rc=$?
    echo "$out"
    line="$(printf '%s\n' "$out" | grep -E '^test result: ' | tail -1)"
    if [ -z "$line" ]; then
      echo "NO RESULT LINE from $exe" >&2
      failed=$((failed + 1))
      continue
    fi
    p=$(printf '%s' "$line" | sed -n 's/.* \([0-9]*\) passed;.*/\1/p')
    f=$(printf '%s' "$line" | sed -n 's/.* \([0-9]*\) failed;.*/\1/p')
    passed=$((passed + ${p:-0})) ; failed=$((failed + ${f:-0}))
    [ "$rc" -eq 0 ] || [ "${f:-0}" -gt 0 ] || failed=$((failed + 1))
    rust_seen=$((rust_seen + ${p:-0} + ${f:-0}))
  done < "$WORK/rust-tests.txt"
  if [ "$rust_seen" -lt 71 ]; then
    echo "ERROR: Rust suites ran $rust_seen tests, expected >= 71" >&2
    failed=$((failed + 1))
  fi
fi

emit_ctrf "snow-apps (ctest + libtest)" "$passed" "$failed" 0
