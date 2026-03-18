# sleap-io.swift `v0.3.0` Release Plan

Date: March 17, 2026

## Purpose

This document is the release handoff for `sleap-io.swift` `v0.3.0`.

Its job is to close the last two downstream blockers called out by
`sleap.swift`:

1. a real iPad `.slp` deployment story for downstream apps
2. a persisted relocated-video-path API that cleanly separates temporary and
   permanent relocation

This file is the implementation source of truth for `v0.3.0`.
Use it instead of the app-side coordination brief when making code and doc
changes in this repository.

## Locked Decisions

- `v0.3.0` treats HDF5-backed `.slp` support on iPad as an official release
  target through the existing vendored `CHDF5.xcframework` path.
- If real downstream iPad validation fails, the release slips. The posture is
  not downgraded to "experimental" for this tag.
- `v0.3.0` does not introduce a new portable file format, an "Export for iPad"
  workaround, or a pure-Swift HDF5 path.
- The public relocation contract is a first-class `Video` API, not an
  undocumented `backendMetadata` convention.
- The original imported path is preserved for provenance.

## Public API

`Video` is extended to support a persisted relocation model with explicit
semantics:

- `originalFilename: String`
  The original imported or decoded source path.
- `persistedFilename: String?`
  An optional persisted override path that should be written back on save.
- `filename: String`
  The effective active path used by open/export/save behavior. It resolves to
  `persistedFilename ?? originalFilename`.

This means:

- existing read-only call sites can continue using `video.filename`
- callers that need provenance can read `video.originalFilename`
- permanent relocation sets `video.persistedFilename`
- temporary relocation never mutates the persisted API surface

## Relocation Semantics

Two behaviors must be supported and documented:

1. Temporary relocation
   - session-only
   - implemented via opener/runtime state
   - must not change serialized file contents

2. Permanent relocation
   - set `video.persistedFilename`
   - preserve `video.originalFilename`
   - save/reopen must continue using the relocated path without prompting again

The design goal is explicitness:

- temporary relocation = runtime-only behavior
- permanent relocation = model mutation plus serialization

## Serialization Rules

### SLP

- Serialize `backend.filename = video.filename`
- When `persistedFilename` is set and differs from `originalFilename`, also
  serialize `backend.original_filename = originalFilename`
- Legacy SLP files that only contain `backend.filename` decode as:
  - `originalFilename = backend.filename`
  - `persistedFilename = nil`
- Relocated SLP files that contain both decode as:
  - `originalFilename = backend.original_filename`
  - `persistedFilename = backend.filename`

### Non-SLP codecs and read-only surfaces

- Anything that exports or reports the active video path should use
  `video.filename`
- Nothing should silently use stale original-path semantics unless a caller
  explicitly opts into `originalFilename`

### Path preservation

- Persist the raw selected path string
- Do not rewrite user-entered paths into a normalized serialized form
- Only normalize paths for internal comparisons such as same-file detection and
  atomic replace logic

## Implementation Workstreams

### 1. Model and API

Update:

- `Sources/SleapIO/Model/Video.swift`
- `Sources/SleapIO/Codecs/DictionaryCodec.swift`
- `API_DESIGN.md`

Required outcome:

- `Video` exposes the `originalFilename` / `persistedFilename` contract
- `filename` is the effective path
- dictionary-style round trips preserve provenance and persisted overrides

### 2. Runtime path resolution

Update:

- `Sources/SleapVideo/VideoExtensions.swift`

Required outcome:

- `open()` resolves through `persistedFilename ?? originalFilename`
- session-only relocation through `backendOpener` continues to work
- code paths that only need the active path remain simple

### 3. SLP read/write

Update:

- `Sources/SleapHDF5/SLP/SLPVideoTable.swift`
- `Sources/SleapHDF5/SLP/SLPWriter.swift`

Required outcome:

- SLP read/write preserves original path provenance when present
- legacy files remain backward-compatible
- save/reopen correctly preserves permanent relocation

### 4. Tests

Update tests for:

- legacy SLP decode
- no-relocation control case
- permanent relocation round-trip
- temporary relocation non-persistence
- effective-path runtime behavior
- dictionary/interchange provenance preservation

### 5. Downstream iPad validation

Use `sleap.swift` as the real release gate:

- link release-candidate `sleap-io.swift` bits into a downstream iPad target or
  host app
- open a real external-video `.slp`
- render at least one frame
- edit one label
- save
- reopen
- verify the edit persisted

Also validate relocation end to end:

- choose `Use Temporarily`
- verify save/reopen still prompts for relocation
- choose `Update In File`
- save/reopen
- verify no second relocation prompt appears

### 6. Docs and release posture

Update:

- `README.md`
- `IMPLEMENTATION_PLAN.md`
- `RELEASE_CHECKLIST.md`
- `HDF5_IPADOS_STRATEGY.md`

Required outcome:

- root docs point to this file as the release-specific plan
- no root doc still presents `v0.3.0` as macOS-only for `.slp`
- root docs no longer present persisted relocation as an open design question

## Acceptance Criteria

`v0.3.0` is ready only when all of the following are true:

1. `Video` has the documented persisted-relocation API.
2. Permanent relocation survives save/reopen.
3. Temporary relocation does not modify serialized contents.
4. Legacy `.slp` files load without migration requirements.
5. A real downstream iPad app target links the release-candidate package and
   passes open/edit/save/reopen validation on a real `.slp`.
6. Docs describe iPad support and relocation behavior consistently.

## Out Of Scope

The following are intentionally not part of `v0.3.0`:

- a brand-new portable non-HDF5 file format
- a Mac-side "Export for iPad" workaround flow
- a pure-Swift HDF5 reader
- any broad embedded-video save redesign beyond what is required to keep this
  release focused on the two blockers above
