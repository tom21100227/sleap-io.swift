# sleap-io.swift Release Checklist

Date: March 12, 2026

## Purpose

This document defines the release gate for `sleap-io.swift`.

It is written for the first public release after Phases 1 through 4. Phase 5
formats are intentionally out of scope and are not release blockers.

## Release Posture

Unless the API is intentionally frozen and documented as stable, the first
public release should be treated as a `0.x` release rather than a `1.0`.

The release notes must explicitly state:

1. Apple platforms only
2. supported formats
3. unsupported formats
4. known limitations that are accepted at release time
5. whether HDF5-backed I/O is macOS-only or truly deployable on iPadOS

## Hard Gates

These are required before tagging a release.

### 1. Repository State

- [ ] `git status` is clean except for intentionally ignored local assets
- [ ] no local-only stress tests or ad hoc fixture files are part of the release diff
- [ ] the release commit is reproducible from a clean checkout

### 2. Test And Build Health

- [ ] `swift build` succeeds on a clean checkout
- [ ] `swift test` passes on a clean checkout
- [ ] no passing test emits low-level HDF5 diagnostics or similar error spam
- [ ] no test is skipped for a known product bug that is still in scope for the release

### 3. Supported Format Matrix

- [ ] `.slp` lazy read, eager read, and write are green
- [ ] phase 3 codecs are green for their documented supported subsets
- [ ] phase 4 codecs are green for their documented supported subsets
- [ ] CLI `info`, `show`, and `convert` are green
- [ ] unsupported formats fail with deterministic, documented error classes

### 4. Real-World Data Validation

- [ ] at least one large multi-instance predictions `.slp` has been load-tested
- [ ] at least one packaged or embedded-frame `.pkg.slp` has been load-tested
- [ ] at least one single-instance predictions `.slp` has been load-tested
- [ ] at least one CLI conversion has been exercised on real-world data
- [ ] timings and noteworthy memory behavior have been recorded in release notes or an internal log

### 5. Known Correctness Risks

- [ ] no open P1 issues remain
- [ ] no open P2 issues remain that would silently corrupt, merge, or drop pose data
- [ ] packaged or embedded video paths work end to end on supported real-world files
- [ ] public load/save dispatch behaves correctly for all supported formats

### 6. Documentation

- [ ] `README.md` reflects the actual supported format matrix
- [ ] platform support language is precise about current HDF5 deployment status on iPadOS
- [ ] `PHASE3_SPEC.md` and `PHASE4_SPEC.md` match shipped behavior
- [ ] phase 5 formats are documented as not yet implemented
- [ ] CLI usage is documented with at least one concrete example per command
- [ ] release notes include breaking changes and accepted limitations

## Soft Gates

These are not absolute blockers, but should be completed unless there is an
explicit decision to defer them.

### 7. API And Packaging Quality

- [ ] public API examples exist for `Labels.load` and `Labels.save`
- [ ] version number and release tag naming have been chosen in advance
- [ ] `Package.swift` and dependency state are reviewed for accidental debug or local-only artifacts
- [ ] local stress assets remain ignored and do not pollute tracked fixtures

### 8. Performance Confidence

- [ ] lazy `.slp` load is materially faster than eager load on a large file
- [ ] random-access lazy frame reads have been spot-checked on a large file
- [ ] round-trip write time is acceptable on at least one medium and one large file
- [ ] no obvious memory blow-up occurs during eager load of a large predictions file
- [ ] any published Swift-vs-Python performance claim is backed by a fresh run of `Benchmarks/compare_with_python.py`
- [ ] embedded `.pkg.slp` performance claims are based on equivalent-work metrics, not raw `load()` timing alone

## Current Release Delta

This is a snapshot of what should be checked before the next public release.
Update or delete this section once the items below are resolved.

- [ ] eliminate HDF5 diagnostic spam on passing analysis/JABS/DLC paths
- [ ] resolve or explicitly scope out the real-world embedded-video path that currently reports `Unknown backend type: HDF5Video`
- [ ] commit or intentionally discard ad hoc local stress tests before tagging
- [ ] confirm the CLI behaves correctly against at least one real-world dataset, not just synthetic fixtures

## Suggested Go/No-Go Rule

Tag a public release only when:

1. all hard gates are complete
2. all current release-delta items are resolved or explicitly accepted
3. the release notes state exactly what is and is not supported

If those conditions are not met, prefer:

1. an internal build
2. a prerelease tag
3. or no release yet
