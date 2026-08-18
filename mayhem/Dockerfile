# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for feed-rs (a feed parser handling Atom, RSS 2.0, RSS 1.0, RSS 0.x and
# JSON Feed; Rust / cargo-fuzz). Builds ON TOP of the org base image, adding a pinned Rust nightly
# + cargo-fuzz under /opt/toolchains/rust (SPEC §6.2 item 8), plus a DWARF3 "anchor" object used to
# satisfy the DWARF<4 gate against the ASan runtime's DWARF5 archive (SPEC §6.2 item 10 — see
# mayhem/build.sh for why).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t feed-rs-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# Nightly is required for -Zsanitizer=address (the OSS-Fuzz Rust ASan path).
ARG RUST_CHANNEL=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.13.2

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 # A SECOND, stable toolchain for the oracle path (mayhem/kat + `cargo test`). Keeps the
 # functional oracle build off the pinned fuzzing nightly, so an unrelated nightly-only
 # dev-dependency quirk (a known trap across this cohort — see docs/netnew-worker-prompt.md §6)
 # can never break the oracle. The fuzz target still builds/links on nightly (required for
 # -Zsanitizer=address).
 && rustup toolchain install stable --profile minimal --no-self-update \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
 # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# ── DWARF<4 anchor (SPEC §6.2 item 10) ─────────────────────────────────────────
# cargo-fuzz's ASan build links a precompiled `librustc-nightly_rt.asan.a` runtime archive built
# with DWARF5, via --whole-archive, and it lands FIRST in the final binary's .debug_info — so
# plain rustc debuginfo flags (which only affect rustc's OWN codegen units) can't fix the
# first-CU check verify-repo runs (measured empirically: -Zdwarf-version=3 alone still leaves
# DWARF5 at the first CU). Fix: force a tiny hand-built DWARF3 compile-unit to be the FIRST object
# the linker sees, via a `-Clinker` wrapper that always PREPENDS it (order matters: the anchor
# must come before "$@" or its CU doesn't land at .debug_info offset 0). This is cosmetic for
# symbolication of the REST of the binary (still DWARF4/5) but satisfies the mechanical gate,
# which only reads the first CU.
RUN install -d /opt/mayhem-dwarf3-anchor \
 && printf 'int __mayhem_dwarf3_anchor;\n' > /opt/mayhem-dwarf3-anchor/anchor.c \
 && clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c -o /opt/mayhem-dwarf3-anchor/anchor.o \
 && printf '#!/bin/sh\nexec clang /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
        > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh \
 && chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh \
 && chmod -R a+rX /opt/mayhem-dwarf3-anchor

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target plus the
# mayhem/kat KAT probe.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time IF present (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
