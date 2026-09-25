#!/usr/bin/env bash
#
# mayhem/build.sh — build feed-rs's ADDITIVE cargo-fuzz target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus this repo's KAT probe used by
# mayhem/test.sh.
#
# Target produced (one Mayhemfile):
#   /mayhem/parse — feed_rs::parser::parse(&[u8]) — the single public entry point that sniffs
#                   the input (XML vs JSON) and dispatches to Atom / RSS 0.9x / RSS 1.0 / RSS 2.0
#                   / JSON Feed parsing. Preserved from the legacy mayhemheroes integration
#                   (same target name "parse", same harness body).
#   /mayhem/kat   — dynamically-linked known-answer probe used by mayhem/test.sh.
#
# feed-rs's own upstream root Cargo.toml IS a workspace (members = ["feed-rs", "tools"]), so
# mayhem/fuzz/ (this build's fuzz crate — feed-rs ships no fuzz/ of its own) and mayhem/kat/ each
# carry their OWN empty [workspace] table to stay decoupled from it and fully additive under
# mayhem/ (docs/netnew-worker-prompt.md §6). Neither the fuzz harness nor the KAT probe does any
# filesystem/network I/O of its own: the harness takes bytes straight from the fuzzer, and the KAT
# probe's fixtures are pulled in at COMPILE time via include_str!.
#
# NOTE (Rust): rustc ignores $SANITIZER_FLAGS (those are clang/C++ flags meant for C/C++
# harnesses, baked into the base image ENV) — this cargo-fuzz build's ASan comes from
# -Zsanitizer=address in RUSTFLAGS below, not from $SANITIZER_FLAGS.
#
# DWARF gate (SPEC §6.2 item 10): cargo-fuzz's ASan build links a precompiled
# `librustc-nightly_rt.asan.a` runtime (DWARF5) via --whole-archive, which lands FIRST in the
# binary's .debug_info — so plain rustc debuginfo flags alone can't fix the FIRST-CU check
# verify-repo runs (they only affect rustc's own codegen units, not the precompiled runtime
# archive; -Zdwarf-version=3 alone measured DWARF5 on the first CU in this repo). $RUST_DEBUG_FLAGS
# below therefore includes -Clinker=<dwarf3-anchor wrapper> (built in mayhem/Dockerfile), which
# prepends a hand-built DWARF3 compile-unit ahead of everything else so it is the first CU the
# linker emits. This is a first-CU-only, cosmetic fix — the rest of the binary (asan runtime +
# most rustc-emitted CUs) stays DWARF4/5; fuzzing and crash-finding are unaffected, only
# debug-info triage of the bulk of the binary.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under
#     $CARGO_HOME=/opt/toolchains/rust/cargo (pinned by the Dockerfile ENV).
#   - The committed Cargo.lock files (mayhem/fuzz/Cargo.lock, mayhem/kat/Cargo.lock) pin exact
#     versions, so the offline re-run resolves the SAME versions from that cache with no new
#     network I/O. The rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run, so this script
#     does NOT hard-code --offline (that would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "${SRC:-/mayhem}"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_TARGETS=(parse)

# DWARF<4 anchor (see header) + OSS-Fuzz Rust libFuzzer+ASan flags. --cfg fuzzing matches
# libfuzzer-sys; force-frame-pointers aids ASan backtraces. Scoped to the fuzz-build invocations
# only (the test suite + KAT probe below build with NORMAL, non-instrumented flags — SPEC §6.3:
# the oracle build is a functional oracle, not a triage artifact).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
FUZZ_RUSTFLAGS="--cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS, DWARF3 anchor) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # mayhem/fuzz/ is its OWN cargo workspace (empty [workspace] in mayhem/fuzz/Cargo.toml — the
  # upstream root Cargo.toml IS a workspace, but mayhem/fuzz/ is not a member of it), so cargo-fuzz
  # writes into ITS OWN target dir ($FUZZ_DIR/target/...), not the repo-root target/.
  bin="${SRC:-/mayhem}/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# The XML/feed-tag dictionary referenced by mayhem/Mayhemfile_parse — copy it into /mayhem (flat,
# alongside the built binary) so the referenced path actually exists; a referenced-but-absent dict
# makes libFuzzer exit 1 at 0 edges (docs/netnew-worker-prompt.md §5).
cp "${SRC:-/mayhem}/mayhem/parse-buggy-mhh-run-6/parse.dict" /mayhem/parse.dict
echo "copied /mayhem/parse.dict"

# ── the project's own test suite (NORMAL flags — a clean, non-sanitized build; ──────────────
#    mayhem/test.sh only RUNS it). feed-rs ships 76 src unit tests (parser modules for Atom/RSS
#    0.x/1.0/2.0/JSON Feed, sanitization, util/xml helpers) plus tests/id_generator.rs and
#    tests/sanitize.rs (feature `sanitize`), all asserting exact parsed/derived values. Scoped to
#    -p feed-rs (not --workspace): the sibling `tools` crate is a CLI dev utility (depends on
#    reqwest) that ships no tests and would otherwise pull in network-facing TLS deps for no
#    benefit to the oracle.
echo "=== precompiling: cargo +stable test -p feed-rs --all-features --no-run (project's NORMAL flags) ==="
# +stable: builds off the pinned nightly deliberately (a second, stable toolchain keeps an
# unrelated nightly-only dev-dependency quirk from ever breaking the functional oracle — see
# mayhem/Dockerfile) so an unrelated nightly-only dev-dependency quirk can never break the oracle.
cargo +stable test -p feed-rs --all-features --no-run 2>&1 | tail -20

# ── the KAT probe used by mayhem/test.sh (NORMAL flags — a functional oracle, not a ─────────
#    triage artifact; see mayhem/kat/Cargo.toml + src/main.rs for why this is a SEPARATE binary
#    rather than relying on `cargo test` alone). mayhem/kat is its OWN cargo workspace (empty
#    [workspace] in its Cargo.toml) so building it never touches the upstream root Cargo.toml.
echo "=== building /mayhem/kat (KAT probe) ==="
( cd mayhem/kat && cargo +stable build --release )
cp mayhem/kat/target/release/kat /mayhem/kat

# Rust binaries are dynamically linked against glibc by DEFAULT on this target — unlike Go, which
# statically links everything — but assert it explicitly so a toolchain/target change can't
# silently turn the probe static and defeat the verify-repo sabotage check (LD_PRELOAD can only
# neuter a dynamically linked exe).
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

echo "build.sh complete:"
ls -la /mayhem/parse /mayhem/parse.dict /mayhem/kat
