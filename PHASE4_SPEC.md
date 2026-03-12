# sleap-io.swift Phase 4 Advanced I/O Spec

Date: March 12, 2026

## Purpose

This document defines the behavioral spec for Phase 4 advanced I/O.

Phase 4 is different from Phase 3 in two ways:

1. several target formats are HDF5-based and therefore extension-based format
   inference is no longer sufficient
2. the CLI becomes a public entry point and must be treated as a stable product
   surface rather than a thin debugging tool

The Python `sleap-io` codecs remain the normative reference when this document
is silent. When this document intentionally narrows the supported subset or
resolves an ambiguity, this document wins.

## Phase 4 Scope

Phase 4 covers:

1. SLEAP analysis HDF5 read/write
2. JABS H5 read/write
3. DeepLabCut H5 read-only import
4. a first-party CLI built with `swift-argument-parser`

Phase 4 does not require:

1. NWB or LEAP support
2. DeepLabCut CSV import in the first pass
3. lazy loading for non-SLP HDF5 formats
4. rendered image/video export from the CLI
5. full metadata preservation when the target format cannot represent it

## Guiding Principles

### P401: HDF5 imports are eager

All Phase 4 advanced HDF5 formats load eagerly.

Given a Phase 4 non-SLP HDF5 file
When it is imported
Then the returned `Labels` is fully materialized and `isLazy == false`

Phase 4 does not introduce a second lazy-loading stack beyond `.slp`.

### P402: `.h5` load uses schema sniffing

The `.h5` and `.hdf5` extensions are not enough to identify the target format.

Given a `.h5` or `.hdf5` input
When `Labels.load` is called without an explicit `format`
Then the library must inspect the HDF5 schema and dispatch to exactly one of:

1. analysis HDF5
2. JABS
3. DeepLabCut H5

If the schema matches none of them, import throws `SleapIOError.unsupportedFormat`.

If the schema is malformed within one recognized family, import throws
`SleapIOError.corruptData`.

### P403: `.h5` save requires explicit format

Because multiple writable formats share the same extension, save inference for
generic HDF5 outputs must not guess.

Given an output URL ending in `.h5` or `.hdf5`
When `Labels.save` is called without an explicit `format`
Then save throws `SleapIOError.unsupportedFormat` with guidance to pass a
specific HDF5 output format

This resolves the ambiguity between analysis HDF5 and JABS export.

### P404: One logic path for library and CLI

The CLI must call library entry points and codec APIs directly.

Phase 4 must not introduce a second parser/serializer implementation inside the
CLI target.

If a format-specific behavior needs to exist for the CLI, it must either:

1. be expressible through the public library surface, or
2. be a thin CLI option layer that passes config into an existing codec

### P405: Explicit topology config beats heuristics

When a format does not fully encode skeleton topology, node naming, or track
semantics, the codec must use explicit config or documented defaults.

Silent node-order guesses are not acceptable.

### P406: Deterministic CLI output and exit behavior

The CLI must produce deterministic text or JSON output and stable exit codes.

Human-readable output may evolve slightly over time, but:

1. `--json` output is a machine contract
2. exit code `0` means success
3. non-zero exit codes mean failure and map to documented categories below

## Shared Advanced HDF5 Rules

### P407: Identity reconstruction

On import:

1. repeated references to the same logical skeleton resolve to one `Skeleton`
2. repeated references to the same logical track key resolve to one `Track`
3. repeated references to the same logical video resolve to one `Video`

Phase 4 formats are not required to reproduce the full original identity graph
after round-trip unless the target format can represent it.

### P408: Missing pose semantics

Across analysis HDF5, JABS, and DLC:

1. non-finite or absent coordinates import as missing points with `NaN`
2. missing animals/tracks at a frame produce no instance for that slot
3. fixed-shape storage formats must not manufacture visible points from empty
   slots

### P409: Shared losses

Unless a format section below says otherwise, the following data is not
preserved through Phase 4 exports:

1. `SuggestionFrame`
2. `RecordingSession`
3. `ROI`
4. `SegmentationMask`
5. `from_predicted`
6. `Symmetry`
7. video backend state

## Public API Consequences

Phase 4 extends the format-routing surface beyond Phase 3.

The public `FileFormat` set for advanced I/O should include:

1. `.analysisHDF5`
2. `.jabs`
3. `.deepLabCut`

`Labels.load` should support:

1. `.analysisHDF5`
2. `.jabs`
3. `.deepLabCut`

`Labels.save` should support:

1. `.analysisHDF5`
2. `.jabs`

`Labels.save` with `.deepLabCut` must throw `SleapIOError.unsupportedFormat`
because DLC is read-only in Phase 4.

## Analysis HDF5

### Scope

Phase 4 supports the canonical SLEAP analysis HDF5 subset written by Python
`sleap-io`.

This is the analysis-only pose format used for tracked pose outputs detached
from full `.slp` document structure.

### A01: One file maps to one logical video stream

Given an analysis HDF5 file
When it is imported
Then it produces one logical `Video` and a sequence of frames ordered by frame
index

If the file stores a source video path string, that value becomes
`Video.filename`.

If no source video path is available, `Video.filename` may fall back to the
input file path.

### A02: Node and track metadata reconstruct shared identity

Given canonical node and track metadata in the analysis HDF5 file
When it is imported
Then:

1. one shared `Skeleton` is created from the node order
2. track names or IDs create shared `Track` objects
3. all instances in the file reference that shared skeleton and the appropriate
   shared track

### A03: Frame occupancy controls instance materialization

Analysis files often store track-major fixed-shape arrays rather than sparse
instance lists.

Given a track slot at frame `t`
When occupancy metadata or all-coordinate missingness indicates that the animal
is absent
Then no `Instance` is emitted for that track at frame `t`

Given a track slot with valid coordinates
Then one instance is emitted for that frame/track pair.

### A04: Score datasets map to predicted data

When the analysis file provides:

1. per-point scores
2. per-instance scores
3. tracking scores

Then they map to:

1. `PredictedPointsArray.scores`
2. `PredictedInstance.score`
3. `PredictedInstance.trackingScore`

If any of those score families are absent, the import still succeeds and the
missing score fields are left unset or defaulted according to the model type.

### A05: Edge metadata is preserved when present

If the analysis HDF5 file stores skeleton edge metadata, import reconstructs
those edges on the shared skeleton.

If edge metadata is absent, the imported skeleton is edgeless.

### A06: Analysis export is single-skeleton

Phase 4 analysis HDF5 export supports one logical skeleton per output file.

Given a `Labels` object with instances from more than one skeleton
When it is exported to analysis HDF5
Then export throws `SleapIOError.unsupportedFormat`

This avoids inventing an unsupported multi-skeleton packing rule.

### A07: Analysis export preserves tracks and scores when available

Given a supported single-skeleton `Labels`
When it is exported to analysis HDF5
Then:

1. frame order is preserved by `frameIndex`
2. tracks are written deterministically
3. per-point, instance, and tracking scores are written when present
4. missing track/frame slots are represented as absent occupancy rather than
   fake zero coordinates

### A08: Analysis round-trip is subset-preserving

Analysis HDF5 round-trip must preserve:

1. frame count
2. node order
3. track identities by name or stable ID
4. finite coordinates
5. score arrays when present

The round-trip is allowed to lose:

1. suggestion frames
2. sessions
3. ROIs and masks
4. non-analysis `.slp` metadata

## JABS H5

### Scope

Phase 4 supports the JABS H5 subset covered by Python `sleap-io` and the Phase
4 fixture contract.

JABS support is read/write, but the first pass is intentionally narrow:

1. one skeleton per file
2. one logical video stream per file
3. explicit node naming configuration when the file does not encode it

### J01: JABS import may require explicit node names

If the JABS file does not encode node names directly
Then import requires `JABSCodec.Config` with explicit `nodeNames`

If node names cannot be inferred and no config is provided, import throws
`SleapIOError.invalidSkeleton`.

### J02: Animal identity maps to tracks

Given JABS data with stable animal identity slots
When it is imported
Then those identities become shared `Track` objects

Instances in the same identity slot across frames share the same `Track`.

### J03: One frame slot produces at most one instance per identity

Given one identity slot at one frame
When valid coordinates are present
Then import emits one instance for that identity/frame pair

When the identity is absent or fully missing at that frame
Then import emits no instance for that slot.

### J04: JABS export is single-skeleton and deterministic

Given a `Labels` object
When it is exported to JABS
Then:

1. exactly one skeleton is allowed
2. frame order is deterministic
3. track or identity ordering is deterministic
4. missing identity/frame combinations are written as empty slots, not fake
   visible points

Mixed-skeleton export throws `SleapIOError.unsupportedFormat`.

### J05: JABS preserves identity but may lose topology

JABS round-trip must preserve:

1. frame count
2. track identity assignment
3. finite coordinates
4. node order

JABS is allowed to lose:

1. skeleton edges and symmetries if the file family does not encode them
2. `from_predicted`
3. non-pose document metadata

## DeepLabCut H5

### Scope

Phase 4 supports DeepLabCut H5 import only.

The supported subset is the pandas/HDF export family handled by Python
`sleap-io` and covered by the Phase 4 fixtures.

DeepLabCut write support is explicitly out of scope.

### D01: DLC import reconstructs node order from bodyparts

Given a supported DLC H5 file
When it is imported
Then bodypart order becomes skeleton node order

Because DLC does not encode graph topology, imported skeletons are edgeless.

### D02: Single-animal and multi-animal imports are both supported

Given a DLC H5 file without an individual dimension
When it is imported
Then each frame produces at most one untracked instance

Given a DLC H5 file with an individual dimension
Then each individual becomes a shared `Track` and may produce one instance per
frame.

### D03: Likelihood maps to score and visibility

If the DLC file provides per-point likelihood/confidence values
Then import maps them to per-point scores.

Visibility and completeness are derived deterministically:

1. non-finite coordinates produce missing points
2. finite coordinates produce complete points
3. likelihood does not by itself drop finite coordinates

### D04: Unsupported column layouts fail explicitly

If the DLC H5 schema is outside the supported pandas/HDF subset
Then import throws `SleapIOError.unsupportedFormat`

If the schema is recognized but internally inconsistent
Then import throws `SleapIOError.corruptData`.

## CLI

### Scope

Phase 4 introduces a first-party executable target, `sleapio`.

The CLI is intended for inspection and conversion, not training, rendering, or
annotation workflows.

Phase 4 requires these commands:

1. `info`
2. `show`
3. `convert`

### C01: `info` prints dataset-level summary

`sleapio info INPUT`

This command prints a compact dataset summary.

The human-readable default output includes at least:

1. inferred or explicit format
2. frame count
3. video count
4. skeleton count
5. track count
6. instance and predicted-instance counts

`sleapio info INPUT --json`

This emits a stable JSON object with those same top-level summary fields.

### C02: `show` prints frame-level detail

`sleapio show INPUT`

This prints a detailed view of frames and instances without rendering images.

Required options:

1. `--frame N`
2. `--limit N`
3. `--json`

The default `show` behavior prints a small bounded sample rather than the
entire dataset.

### C03: `convert` performs format translation

`sleapio convert INPUT OUTPUT`

Required behavior:

1. input format may be inferred or passed explicitly with `--input-format`
2. output format may be inferred when unambiguous
3. output format must be passed explicitly when the output extension is
   ambiguous, especially `.h5`
4. existing files are not overwritten unless `--force` is passed

### C04: CLI exposes format-specific config only where required

The CLI must support passing codec config for formats that require it.

Required Phase 4 options:

1. `--labelstudio-mapping PATH`
2. `--yolo-node-order PATH`
3. `--alphatracker-node-names PATH`
4. `--jabs-node-names PATH`

Those paths point to small file-based config payloads.

The CLI is not required to invent new inline mini-languages for these options
in the first pass.

### C05: Exit codes

Phase 4 uses these exit categories:

1. `0` success
2. `2` argument or config error
3. `1` runtime I/O or data error

Argument parsing failures, missing required config files, and mutually
incompatible flags exit with `2`.

Format/data failures exit with `1`.

## Fixture Policy

Phase 4 tests should use Python-generated fixtures whenever possible.

Required fixture families:

1. `analysis_h5_minimal`
2. `analysis_h5_scores`
3. `analysis_h5_missing_tracks`
4. `jabs_single_animal`
5. `jabs_multi_animal`
6. `jabs_requires_config`
7. `dlc_h5_single_animal`
8. `dlc_h5_multi_animal`
9. `dlc_h5_unsupported_variant`
10. `cli_smoke`

Each fixture family should include:

1. at least one canonical Python-generated source artifact
2. a compact expected summary for Swift tests
3. at least one malformed or unsupported variant where applicable

## Test Suite Layout

Phase 4 should add:

1. `AnalysisHDF5CodecTests`
   - schema recognition
   - sparse occupancy handling
   - score import/export
   - single-skeleton export rejection for mixed-skeleton documents

2. `JABSCodecTests`
   - single-animal import/export
   - multi-animal identity mapping
   - explicit node-name config requirement

3. `DLCCodecTests`
   - single-animal import
   - multi-animal import
   - likelihood mapping
   - unsupported schema rejection

4. `LabelsIOAdvancedFormatTests`
   - `.h5` schema sniffing
   - explicit output-format requirement for ambiguous HDF5 saves

5. `CLITests`
   - `info` human-readable output
   - `info --json`
   - `show --frame`
   - `convert` success path
   - `convert` ambiguous `.h5` output rejection
   - config-required format rejection without sidecar config

## Definition Of Done

Phase 4 is complete when:

1. analysis HDF5 read/write obeys the supported subset above
2. JABS read/write obeys the supported subset above
3. DeepLabCut H5 import obeys the supported subset above
4. `.h5` input sniffing is deterministic and tested
5. `.h5` output ambiguity is rejected unless the format is explicit
6. the CLI commands behave according to this document and are tested
7. unsupported variants fail with the documented error category

## Resolved Ambiguities

This document intentionally resolves the following open questions before
implementation:

1. advanced `.h5` inputs are schema-sniffed rather than extension-routed
2. advanced `.h5` outputs require explicit format selection when ambiguous
3. Phase 4 HDF5 imports are eager; there is no second lazy loader
4. JABS is config-driven for node names when the file does not encode them
5. DLC H5 is import-only in the first pass
6. the CLI is an inspection/conversion surface, not a rendering tool
