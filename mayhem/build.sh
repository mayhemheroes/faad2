#!/usr/bin/env bash
# faad2/mayhem/build.sh — build the two faad2 AAC-decoder libFuzzer harnesses (fuzz_decode,
# fuzz_config) plus their standalone (non-fuzzer) reproducers, AND a small golden decode test
# binary for mayhem/test.sh.
#
# faad2 is the freeware AAC audio decoder library (libfaad). The OSS-Fuzz integration builds via
# bazel (`bazel_build_fuzz_tests`), which compiles the `faad` cc_library from libfaad/**/*.c and
# links each fuzz/*.c harness against it. We do the same compile DIRECTLY with $CC (no bazel): the
# library translation units are compiled WITH $SANITIZER_FLAGS so the FUZZED decoder code is
# instrumented, then each harness is linked twice (libFuzzer engine + standalone driver).
#
# Harnesses (copied from fuzz/ into mayhem/ and committed):
#   fuzz_decode.c — drives the full decode path. Reads a WRAPPED byte stream (NOT a bare .aac):
#       [len1:u16-le][len2:u16-le][flags:u8][NeAACDecConfiguration struct] then len1/len2/len3 AAC
#       payload chunks fed to NeAACDecInit/Init2 + NeAACDecDecode/Decode2. len1 is the
#       init buffer (ADTS/ADIF/raw AAC), len2/len3 are decoded frames.
#   fuzz_config.c — [errcode:u8] then a raw mp4 AudioSpecificConfig fed to
#       NeAACDecAudioSpecificConfig (plus the version/capability/error-message getters).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the base ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# faad2 PACKAGE_VERSION (used by the version getter the config harness reads); read from the repo's
# properties.json so it tracks upstream.
PKG_VERSION="$(sed -n 's/.*"PACKAGE_VERSION"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p' properties.json)"
[ -n "$PKG_VERSION" ] || PKG_VERSION="0.0.0"

# The defines the bazel FAAD_DEFINES list uses for a normal (non-embedded) build. APPLY_DRC pulls in
# the dynamic-range-control path; the HAVE_* mirror what autotools/cmake would detect on Linux.
FAAD_DEFINES=(
  -DAPPLY_DRC
  -DHAVE_INTTYPES_H=1 -DHAVE_MEMCPY=1 -DHAVE_STRING_H=1 -DHAVE_STRINGS_H=1
  -DHAVE_SYS_STAT_H=1 -DHAVE_SYS_TYPES_H=1
  -DPACKAGE_VERSION="\"$PKG_VERSION\""
)

# libfaad sources #include their own headers (libfaad/) and neaacdec.h (include/); the harnesses
# #include neaacdec.h. -Ilibfaad first so the lib's internal headers resolve.
INC=(-Ilibfaad -Iinclude)

# ── 1) Compile the faad decoder library (instrumented with $SANITIZER_FLAGS) ─────────────────────
# bazel's faad cc_library = glob libfaad/**/*.c. Compile each to an object with the sanitizer flags
# so the FUZZED decoder code is instrumented, then archive into libfaad_fuzz.a.
echo "build.sh: compiling libfaad ($(ls libfaad/*.c | wc -l) sources) with sanitizers"
OBJDIR="$(mktemp -d)"
# shellcheck disable=SC2086
for src in libfaad/*.c; do
  obj="$OBJDIR/$(basename "${src%.c}").o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 "${FAAD_DEFINES[@]}" "${INC[@]}" -c "$src" -o "$obj"
done
ar rcs "$OBJDIR/libfaad_fuzz.a" "$OBJDIR"/*.o
FAAD_LIB="$OBJDIR/libfaad_fuzz.a"

# Standalone (non-fuzzer) run-once driver, compiled as a C object (C harnesses).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJDIR/standalone_main.o"

# ── 2) Build each harness: libFuzzer target + standalone reproducer ──────────────────────────────
# fuzz_decode is the bazel default fuzz_decode target (no DRM, no FIXED_POINT). fuzz_config matches
# the bazel fuzz_config target. -lm: faad's math (filterbank/sbr) pulls libm.
build_harness() {
  local name="$1" src="$2"
  # libFuzzer target -> /mayhem/<name>
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${FAAD_DEFINES[@]}" "${INC[@]}" \
      "$src" "$FAAD_LIB" $LIB_FUZZING_ENGINE -lm -o "/mayhem/$name"
  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${FAAD_DEFINES[@]}" "${INC[@]}" \
      "$src" "$FAAD_LIB" "$OBJDIR/standalone_main.o" -lm -o "/mayhem/$name-standalone"
  echo "build.sh: built /mayhem/$name (+ -standalone)"
}

build_harness fuzz_decode "$SRC/mayhem/fuzz_decode.c"
build_harness fuzz_config "$SRC/mayhem/fuzz_config.c"

# ── 3) Golden decode test binary (NORMAL flags — no sanitizers) for mayhem/test.sh ───────────────
# An honest PATCH oracle: a tiny program that decodes a known ADTS AAC frame
# (mayhem/golden.aac) and asserts the decoder reports the expected sample-rate / channel count and a
# clean (error==0) decode. Built here with the project's normal flags (sanitizer-free) so test.sh
# only RUNS it. See mayhem/golden_decode.c.
echo "build.sh: building golden decode test (normal flags)"
# shellcheck disable=SC2086
clang -O2 "${FAAD_DEFINES[@]}" "${INC[@]}" \
    libfaad/*.c "$SRC/mayhem/golden_decode.c" -lm \
    -o /mayhem/golden_decode
echo "build.sh: built /mayhem/golden_decode"

rm -rf "$OBJDIR"
ls -l /mayhem/fuzz_decode /mayhem/fuzz_config /mayhem/golden_decode
