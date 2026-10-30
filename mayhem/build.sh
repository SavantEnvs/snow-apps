#!/usr/bin/env bash
#
# mayhem/build.sh — build every fuzz harness (sanitized + DWARF 3) and the project's own test suites.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; re-runnable and air-gapped
# on re-run (the cargo registry lives in /opt/toolchains/rust/cargo, populated by the first build).
#
# Targets:
#   snow_image_decode_fuzzer      C++ libFuzzer harness over snow_image::Service::decode (upstream's own
#                                 snow_image/fuzz/decode_fuzzer.cpp; codecs: BMP/PNM/ICO/XBM/XPM/GIF)
#   snow_image_rs_{inspect,decode,animation,ipc}   upstream's cargo-fuzz crate snow-image-rs/fuzz
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
# rustc rejects `-C llvm-args=-gdwarf-3`; its own knob is -C dwarf-version.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C dwarf-version=3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem
WORK="$SRC/build-mayhem"          # matched by the upstream .gitignore (**/build-*/)
mkdir -p "$WORK"

# Codecs that build from apt/in-tree sources. PNG (needs zlib-ng compat), JPEG (needs libjpeg-turbo >= 3.1),
# SVG/HEIF/JXL/EXR/WebP (vcpkg-only dependencies) are not available offline on Debian, so they stay off.
CODECS=(-DSNOW_IMAGE_CODEC_GIF=ON -DSNOW_IMAGE_CODEC_ICON=ON -DSNOW_IMAGE_CODEC_XBITMAP=ON)
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE= -DSNOW_IMAGE_STRICT_COMPILE=OFF -DSNOW_IMAGE_BUILD_SHARED=OFF
        -DSNOW_IMAGE_ENABLE_INSTALL=OFF -DSNOW_IMAGE_BUILD_FUZZERS=OFF "${CODECS[@]}")

# ---- 1) snow_image (C++), sanitized, for the libFuzzer harness -----------------------------------
cmake -S snow_image -B "$WORK/fuzz" "${COMMON[@]}" -DSNOW_IMAGE_BUILD_TESTS=OFF \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O2" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O2"
cmake --build "$WORK/fuzz" -j"$MAYHEM_JOBS"

# ---- 2) harness: fuzzer + standalone reproducer, LSan off ---------------------------------------
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$WORK/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$WORK/standalone_main.o"
HARNESS=(-std=c++20 -O2 -Isnow_image/include snow_image/fuzz/decode_fuzzer.cpp
         "$WORK/fuzz/libsnow_image_static.a" "$WORK/lsan_off.o" -lgif)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${HARNESS[@]}" -o "$OUT/snow_image_decode_fuzzer"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$WORK/standalone_main.o" "${HARNESS[@]}" \
  -o "$OUT/snow_image_decode_fuzzer-standalone"

# ---- 3) snow-image-rs cargo-fuzz targets (ASan via RUSTFLAGS) -------------------------------------
# RUSTFLAGS in the environment replaces build.rustflags from the repo's .cargo/config.toml (-Dwarnings);
# CARGO_TARGET_DIR replaces its target-dir = "build/cargo".
FUZZ_DIR=snow-image-rs/fuzz
TRIPLE=x86_64-unknown-linux-gnu
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
export CARGO_TARGET_DIR="$WORK/cargo-fuzz"
RUSTFLAGS="--cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -C link-arg=$WORK/lsan_off.o" \
  bash -c '
    set -euo pipefail
    for t in inspect decode animation ipc; do
      echo "--- building fuzz target: $t ---"
      cargo fuzz build --fuzz-dir '"$FUZZ_DIR"' -O --debug-assertions "$t"
      bin="$CARGO_TARGET_DIR/'"$TRIPLE"'/release/$t"
      [ -x "$bin" ] || { echo "ERROR: missing fuzz binary $bin" >&2; exit 1; }
      cp "$bin" "'"$OUT"'/snow_image_rs_$t"
    done'

# ---- 4) test suites, NORMAL flags (independent of the sanitized builds above) -------------------
# C++: snow_image's own CTest executables.
cmake -S snow_image -B "$WORK/tests" "${COMMON[@]}" -DCMAKE_BUILD_TYPE=Release -DSNOW_IMAGE_BUILD_TESTS=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$WORK/tests" -j"$MAYHEM_JOBS"

# Rust: unit + integration tests of the pure-Rust crates (the native-backends feature is Windows/macOS only).
# Record each test executable with its crate dir so test.sh runs them without invoking cargo.
export CARGO_TARGET_DIR="$WORK/cargo-test"
RUSTFLAGS="--cap-lints warn" cargo test --manifest-path snow-image-rs/Cargo.toml \
  -p snow-image-core -p snow-image-protocol -p snow-image-codecs --no-run --message-format=json \
  | python3 -c '
import json, os, sys
rows = []
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("executable") and m.get("profile", {}).get("test"):
        rows.append(m["executable"] + "\t" + os.path.dirname(m["manifest_path"]))
rows.sort()
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
print("rust test executables:", len(rows))
' "$WORK/rust-tests.txt"
[ -s "$WORK/rust-tests.txt" ]

echo "build.sh complete"
