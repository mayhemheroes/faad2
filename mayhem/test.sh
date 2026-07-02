#!/usr/bin/env bash
# faad2/mayhem/test.sh — RUN faad2's golden decode oracle (built by mayhem/build.sh with NORMAL
# flags) → CTRF. PATCH-grade oracle: it never compiles, and it asserts decoder BEHAVIOR, not just
# exit status.
#
# faad2 upstream ships no runnable unit-test suite (the repo has only the CLI frontend + bazel fuzz
# targets — no `make check` / ctest with assertions). So mayhem/build.sh builds a small golden
# program (mayhem/golden_decode.c) that decodes a known real ADTS AAC frame (mayhem/golden.aac,
# 44100 Hz mono, AAC-LC) through the public libfaad API and ASSERTS the decoder reports the exact
# header-derived sample rate (44100) and channel count (2, faad's deterministic SBR-upsampled mono),
# NeAACDecInit returns no error, and the first NeAACDecDecode reports frameinfo.error == 0.
#
# Those values are read out of the AAC bitstream by the decoder, so a no-op / exit(0) "patch" that
# stops actually decoding — or a regression that mis-parses the ADTS header / breaks the decode
# path — makes an asserted value wrong and golden_decode exits non-zero. "Ran without crashing" does
# NOT pass this oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

GOLDEN_BIN=/mayhem/golden_decode
GOLDEN_AAC="$SRC/mayhem/golden.aac"

[ -x "$GOLDEN_BIN" ]  || { echo "missing $GOLDEN_BIN — build.sh did not build the golden test" >&2; emit_ctrf "faad2-golden" 0 1; exit 2; }
[ -f "$GOLDEN_AAC" ]  || { echo "missing $GOLDEN_AAC — golden frame absent" >&2; emit_ctrf "faad2-golden" 0 1; exit 2; }

echo "test.sh: running faad2 golden decode oracle on $GOLDEN_AAC" >&2
# Capture both stdout and exit code; parse the output for expected behavioral markers.
# A no-op / exit(0) "patch" produces NO output, so the grep checks below fail it even if
# exit code is 0 — the oracle asserts BEHAVIOR (decoded values), not just exit status.
GOLDEN_OUT="$("$GOLDEN_BIN" "$GOLDEN_AAC" 2>&1)" || golden_rc=$?
golden_rc="${golden_rc:-0}"
printf '%s\n' "$GOLDEN_OUT" >&2

FAIL=0

# Require the specific "PASS" marker that golden_decode prints only on full success.
if ! printf '%s\n' "$GOLDEN_OUT" | grep -qF "PASS: golden decode matched expected header values"; then
  echo "test.sh: FAIL — expected PASS marker not found in output (got: $(printf '%s\n' "$GOLDEN_OUT" | head -3))" >&2
  FAIL=1
fi

# Require decoded samplerate=44100 in the output — written by NeAACDecDecode report.
if ! printf '%s\n' "$GOLDEN_OUT" | grep -qE "samplerate=44100"; then
  echo "test.sh: FAIL — expected samplerate=44100 not found in output" >&2
  FAIL=1
fi

# Require non-zero exit code to map as failure.
if [ "$golden_rc" -ne 0 ]; then
  echo "test.sh: FAIL — golden_decode exited $golden_rc" >&2
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test.sh: golden decode PASSED" >&2
  emit_ctrf "faad2-golden" 1 0
else
  echo "test.sh: golden decode FAILED" >&2
  emit_ctrf "faad2-golden" 0 1
  exit 1
fi
