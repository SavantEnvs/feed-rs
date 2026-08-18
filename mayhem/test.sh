#!/usr/bin/env bash
#
# feed-rs/mayhem/test.sh — RUN feed-rs's own upstream test suite and a known-answer probe, and
# emit a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `cargo test -p feed-rs --all-features` — feed-rs's own real assertion suite: 76 src unit
#     tests across the parser modules (Atom/RSS 0.x/1.0/2.0/JSON Feed, sanitization, util/xml
#     helpers) that parse committed fixture/ documents and assert the exact resulting Feed model
#     field-by-field, plus tests/id_generator.rs and tests/sanitize.rs (feature `sanitize`,
#     enabled by --all-features). These assert concrete values, so a no-op / neutered binary
#     cannot pass them outright — BUT docs/netnew-worker-prompt.md §4 explicitly forbids "cargo
#     test alone" as the oracle: its `--test` harness binaries are not a reliable sabotage target.
#     So this suite is leg 1, not the whole oracle.
#
#  2) The KAT probe /mayhem/kat (the load-bearing leg). It is a plain `[[bin]]` (NORMAL flags, no
#     sanitizer) that the verify-repo sabotage check CAN reach via LD_PRELOAD (Rust binaries are
#     dynamically linked by default — build.sh asserts this). It parses three FIXED feeds already
#     shipped by upstream under feed-rs/fixture/ (Atom, RSS 1.0, JSON Feed) through the real public
#     feed_rs::parser::parse entry point and prints EXACT values (title, entry count, a
#     published/updated timestamp, an entry link) per feed; a neutered binary prints nothing and
#     every assertion below fails.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own cargo test suite (already compiled by build.sh) ────────────────────
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 2
fi

echo "=== running: cargo +stable test -p feed-rs --all-features ==="
# +stable: matches the toolchain build.sh precompiled with (see mayhem/Dockerfile comment on
# keeping the functional oracle off the pinned fuzzing nightly) — must match or this re-triggers
# a full (failing, in an air-gapped re-run) rebuild under the default nightly toolchain.
OUT="$SRC/mayhem-build-test.log"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
cargo +stable test -p feed-rs --all-features --no-fail-fast 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}

# libtest prints one line per test binary:
#   test result: ok. 76 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries (lib + tests/id_generator.rs + tests/sanitize.rs).
while read -r p f s; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
done < <(grep -oE '[0-9]+ passed; [0-9]+ failed; [0-9]+ ignored' "$OUT" \
          | sed -E 's/([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored/\1 \2 \3/')

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test-result summary parsed — the suite did not run (cargo exit $rc)" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 1
fi
# A non-zero cargo exit with zero counted failures means a build/harness error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ─────────────────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -f ... ]` guard here
# is how a probe silently stops running and the oracle quietly degrades to the
# cargo-test-only (potentially reward-hackable) case.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
# Expected values — computed from the real (host) build during integration against upstream's own
# fixtures (feed-rs/fixture/atom/atom_spec_1.xml, feed-rs/fixture/rss1/rss_1.0_spec_1.xml,
# feed-rs/fixture/jsonfeed/jsonfeed_spec_1.json — each format's own spec worked example):
kat_expect "Atom feed title (atom_spec_1.xml)"        'KAT_ATOM_TITLE=Example Feed'
kat_expect "Atom entry count (atom_spec_1.xml)"       'KAT_ATOM_ENTRY_COUNT=1'
kat_expect "Atom entry updated timestamp (atom_spec_1.xml)" 'KAT_ATOM_ENTRY_UPDATED=2003-12-13T18:30:02+00:00'
kat_expect "Atom entry link (atom_spec_1.xml)"        'KAT_ATOM_ENTRY_LINK=http://example.org/2003/12/13/atom03'
kat_expect "RSS 1.0 feed title (rss_1.0_spec_1.xml)"  'KAT_RSS1_TITLE=XML.com'
kat_expect "RSS 1.0 entry count (rss_1.0_spec_1.xml)" 'KAT_RSS1_ENTRY_COUNT=2'
kat_expect "RSS 1.0 entry link (rss_1.0_spec_1.xml)"  'KAT_RSS1_ENTRY_LINK=http://xml.com/pub/2000/08/09/xslt/xslt.html'
kat_expect "JSON Feed title (jsonfeed_spec_1.json)"   'KAT_JSONFEED_TITLE=JSON Feed'
kat_expect "JSON Feed entry count (jsonfeed_spec_1.json)" 'KAT_JSONFEED_ENTRY_COUNT=1'
kat_expect "JSON Feed entry published timestamp (jsonfeed_spec_1.json)" 'KAT_JSONFEED_ENTRY_PUBLISHED=2017-05-17T15:02:12+00:00'
kat_expect "JSON Feed entry link (jsonfeed_spec_1.json)" 'KAT_JSONFEED_ENTRY_LINK=https://jsonfeed.org/2017/05/17/announcing_json_feed'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
