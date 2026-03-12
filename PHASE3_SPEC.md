# sleap-io.swift Phase 3 Interchange Spec

Date: March 11, 2026

## Purpose

This document defines the behavioral spec for Phase 3 interchange codecs.

Phase 3 is more ambiguous than Phase 1 or Phase 2 because interchange formats
are often lossy and do not map 1:1 to the SLEAP object graph. This spec exists
to make those losses explicit before implementation.

The Python `sleap-io` codecs are the normative reference when this document is
silent. When this document intentionally narrows or changes the supported
subset, this document wins.

## Phase 3 Scope

Phase 3 covers:

1. COCO keypoints JSON
2. Canonical flat CSV
3. Label Studio keypoints JSON
4. Ultralytics YOLO pose datasets
5. AlphaTracker JSON (read-only)

Phase 3 does not require:

1. Lazy interchange loads
2. Full metadata preservation across lossy formats
3. Video timeline exports for Label Studio
4. Multi-class YOLO pose export in the first pass
5. Exact round-trip preservation for fields that the target format cannot represent

## Guiding Principles

### P01: Explicit loss over implicit magic

If a target format cannot represent a SLEAP concept, the codec must do one of:

1. Drop it explicitly and document the loss
2. Use a documented codec-specific extension field
3. Throw if dropping it would make reconstruction ambiguous

Silent heuristic behavior is not acceptable.

### P02: Eager interchange imports

Interchange formats must load eagerly.

Given a non-SLP import
When it is loaded
Then the returned `Labels` is fully materialized and `isLazy == false`

### P03: Deterministic ordering

Writers must emit stable ordering.

Unless a format requires otherwise, exported order is:

1. videos in `labels.videos` order
2. frames by `frameIndex`
3. instances in frame order
4. nodes in skeleton node order

Readers must preserve logical ordering where the source format defines one.

### P04: Identity reconstruction

On import:

1. repeated references to the same logical video resolve to one `Video`
2. repeated references to the same logical skeleton resolve to one `Skeleton`
3. repeated references to the same track key resolve to one `Track`

Interchange formats are not required to preserve the full original identity
graph after export/import, but repeated references within one imported document
must be shared consistently.

### P05: Path handling

Relative paths are resolved relative to the input file or dataset root.

Writers emit path strings deterministically:

1. image and video filenames are written exactly from `Video.filename` unless
   the codec spec below says otherwise
2. no writer is required to rewrite or copy media files in the first pass

### P06: Error behavior

The following behavior is mandatory across codecs:

1. nonexistent input path throws `SleapIOError.fileNotFound`
2. unsupported extension, directory layout, or schema variant throws `SleapIOError.unsupportedFormat`
3. malformed JSON, malformed CSV, missing required columns, or inconsistent row/object structure throws `SleapIOError.corruptData`
4. missing required skeleton mapping or impossible skeleton reconstruction throws `SleapIOError.invalidSkeleton`

### P07: Still-image imports

Many interchange formats are image-based rather than video-based.

Given an image-based format
When it is imported
Then each image becomes a one-frame source with:

1. `Video.filename` set to the resolved image path or source string
2. `frameIndex == 0`
3. backend behavior implementation-defined for phase 3

Phase 3 only requires data interchange for still-image sources. It does not
require every imported still-image `Video` to be immediately renderable via the
phase 2 video APIs.

## Shared Losses

Unless explicitly stated otherwise for a codec, the following SLEAP data is not
preserved through interchange export:

1. `SuggestionFrame`
2. `RecordingSession`
3. `ROI`
4. `SegmentationMask`
5. `from_predicted`
6. `Symmetry`
7. video backend metadata

Tracks are codec-specific and are addressed in each format section below.

## Fixture Policy

Phase 3 tests should use Python-generated fixtures whenever possible.

Required fixture families:

1. `coco_single_skeleton`
2. `coco_multi_category`
3. `coco_predictions`
4. `csv_multi_instance`
5. `csv_predicted_scores`
6. `labelstudio_keypoints`
7. `yolo_pose_single_class`
8. `alphatracker_sample`

Each fixture family should have:

1. at least one source file written by Python `sleap-io`
2. a compact expected summary checked by Swift tests
3. at least one malformed or unsupported variant for error testing

## COCO JSON

### Scope

Phase 3 supports COCO keypoints JSON with top-level:

1. `images`
2. `annotations`
3. `categories`

Optional top-level keys like `info` and `licenses` may be ignored on read and
omitted on write.

### C01: Category to skeleton mapping

Given a COCO category with:

1. `id`
2. `name`
3. `keypoints`

When it is imported
Then it becomes one `Skeleton` with:

1. `Skeleton.name == category.name`
2. node order matching `category.keypoints` order
3. edges created from `category.skeleton` if present
4. no edges if `category.skeleton` is absent

`category.skeleton` uses COCO's 1-based node indices.

### C02: Image to frame mapping

Given a COCO image object
When it is imported
Then it becomes a one-frame source:

1. one `Video` per image
2. one `LabeledFrame` for that video
3. `frameIndex == 0`

`Video.filename` is the resolved `file_name`.

If `width` and `height` are present, they populate `video.frameSize`.

### C03: Annotation to instance mapping

Given a COCO annotation with valid `image_id`, `category_id`, and `keypoints`
When it is imported
Then it becomes one pose instance in the frame for `image_id`.

If the annotation has numeric `score`, it imports as `PredictedInstance`.
Otherwise it imports as `Instance`.

`bbox`, `area`, `iscrowd`, and `segmentation` are not authoritative for pose
construction in phase 3.

### C04: Keypoint visibility mapping

COCO visibility values map as follows:

1. `v == 0`
   - point coordinates import as `NaN`
   - `visible == false`
   - `complete == false`
2. `v == 1`
   - coordinates import as provided
   - `visible == false`
   - `complete == true`
3. `v >= 2`
   - coordinates import as provided
   - `visible == true`
   - `complete == true`

If the keypoints array length is not exactly `3 * nodeCount`, import throws
`SleapIOError.corruptData`.

### C05: COCO export behavior

Given a `Labels` object
When it is exported to COCO
Then:

1. `categories` are written in `labels.skeletons` order
2. category IDs are stable and 1-based
3. one `images` entry is written per labeled frame
4. one `annotations` entry is written per instance
5. `keypoints` are emitted in skeleton node order
6. `num_keypoints` counts keypoints with `v > 0`
7. `bbox` is computed from finite point coordinates
8. `area == bbox.width * bbox.height`
9. `score` is written for `PredictedInstance`

Visibility export rules:

1. finite coordinates and `visible == true` -> `v = 2`
2. finite coordinates and `visible == false` -> `v = 1`
3. non-finite coordinates -> `v = 0` and coordinates are emitted as `0, 0`

### C06: COCO width and height requirements

COCO export requires deterministic image dimensions.

Given a frame being exported to COCO
When width and height are unavailable from `video.frameSize`
Then the writer may:

1. open the source frame and use its dimensions

If dimensions still cannot be determined, export throws `SleapIOError.videoError`.

### C07: COCO losses

Standard COCO export drops:

1. track identity
2. `trackingScore`
3. per-point prediction scores
4. `from_predicted`
5. sessions, suggestions, ROIs, masks

COCO import ignores non-standard track-like fields in the first pass.

## Canonical CSV

### Scope

The Phase 3 CSV format is a canonical long-table format defined by this
library. It is not just "any CSV containing x and y columns."

This spec intentionally extends the rough implementation-plan sketch so that
reconstruction is unambiguous.

### CSV schema

Required columns:

1. `video`
2. `frame_idx`
3. `skeleton`
4. `instance`
5. `node`
6. `x`
7. `y`
8. `visible`

Optional columns:

1. `complete`
2. `track`
3. `instance_type`
4. `instance_score`
5. `point_score`
6. `tracking_score`

Unknown columns are ignored on read.

### V01: CSV grouping semantics

Rows are grouped into one instance by the tuple:

1. `video`
2. `frame_idx`
3. `skeleton`
4. `instance`

Without `instance`, reconstruction of multiple trackless instances would be
ambiguous, so the column is mandatory.

### V02: CSV skeleton reconstruction

CSV does not represent skeleton edges or symmetries.

On import:

1. one `Skeleton` is created per distinct `skeleton` value
2. node order is the first-seen order of `node` values for that skeleton
3. imported skeletons are edgeless

On export:

1. rows are emitted in the original skeleton node order
2. edge and symmetry information is lost

### V03: CSV missing-node behavior

Given a frame/instance group where not every node has a row
When it is imported
Then missing nodes are materialized as:

1. `x == NaN`
2. `y == NaN`
3. `visible == false`
4. `complete == false`

Writers must emit one row for every node in the instance skeleton so that
Swift-written CSV is fully reconstructable.

### V04: CSV predicted-instance behavior

If any row in an instance group indicates prediction semantics via:

1. `instance_type == predicted`
2. `instance_score` present
3. `point_score` present

Then that group imports as `PredictedInstance`.

Otherwise it imports as `Instance`.

`point_score` maps to per-point score.
`instance_score` maps to `PredictedInstance.score`.
`tracking_score` maps to `Instance.trackingScore`.

### V05: CSV track behavior

Tracks are keyed by the `track` string.

Given multiple rows with the same `track` string
When imported
Then they share one `Track` object.

CSV does not preserve distinct `Track` identities that happen to share the same
name. Export is lossy in that case.

### V06: CSV export behavior

Given a `Labels` object exported to CSV
Then the writer emits:

1. one row per node per instance
2. header row always present
3. `instance` zero-based within each `(video, frame_idx)` group
4. `instance_type` as `user` or `predicted`
5. `track` as the track name, or empty if absent

Numeric formatting must round-trip within normal `Float` precision.

### V07: CSV losses

CSV export drops:

1. skeleton edges
2. skeleton symmetries
3. suggestions, sessions, ROIs, masks
4. `from_predicted`
5. duplicate same-name track identities

## Label Studio JSON

### Scope

Phase 3 supports image-based Label Studio keypoint tasks only.

It does not support:

1. Label Studio video timeline projects
2. free-form schema inference
3. automatic topology inference from Label Studio labels

### LJS01: Explicit skeleton mapping requirement

Label Studio does not define enough information to reconstruct SLEAP skeleton
order and topology on its own.

Therefore:

1. import requires an explicit codec-side mapping from Label Studio keypoint labels to `Node`s
2. export requires either one target skeleton or an explicit skeleton mapping config

If the mapping is missing or inconsistent, the codec throws `SleapIOError.invalidSkeleton`.

### LJS02: Task to frame mapping

Given an image task with `data.image`
When imported
Then it becomes:

1. one `Video`
2. one `LabeledFrame`
3. `frameIndex == 0`

The image path resolves relative to the Label Studio JSON file unless an
explicit media root override is supplied.

### LJS03: Result grouping

Keypoint results are grouped into one instance by:

1. `parentID` when present
2. otherwise the result's own `id`

This grouping rule must be deterministic.

### LJS04: Coordinate mapping

Label Studio keypoint coordinates are percentage-based.

On import:

1. percentages are converted back to absolute image coordinates using `original_width` and `original_height`
2. missing original dimensions are an error

On export:

1. absolute coordinates are converted to percentages
2. export requires known image width and height

### LJS05: User vs predicted behavior

When importing:

1. `annotations` import as `Instance`
2. `predictions` import as `PredictedInstance`

When exporting:

1. user instances are written under `annotations`
2. predicted instances may be written under `predictions`

Label Studio does not preserve per-point prediction scores in the first pass.

### LJS06: Label Studio losses

Label Studio export drops:

1. tracks
2. `trackingScore`
3. `from_predicted`
4. sessions, suggestions, ROIs, masks
5. full skeleton topology unless encoded out-of-band in codec config

## Ultralytics YOLO Pose

### Scope

Phase 3 supports Ultralytics pose datasets with:

1. dataset root directory
2. `dataset.yaml`
3. image files
4. pose label `.txt` files

The first pass supports single-class pose datasets only.

### Y01: Explicit node-order requirement

YOLO pose labels contain keypoint coordinates by index, not by name.

Therefore read support requires one of:

1. explicit node names and order from codec config
2. an already-specified target skeleton

If node order cannot be determined, import throws `SleapIOError.invalidSkeleton`.

### Y02: Single-class first pass

Given a YOLO pose dataset with multiple semantic classes or multiple unrelated
skeletons
When phase 3 first-pass import or export is attempted
Then the codec throws `SleapIOError.unsupportedFormat`.

### Y03: Image to frame mapping

Each image file becomes:

1. one `Video`
2. one `LabeledFrame`
3. `frameIndex == 0`

Image paths are resolved relative to the dataset root.

### Y04: Coordinate mapping

YOLO pose coordinates are normalized.

On import:

1. normalized coordinates convert to absolute pixel coordinates using image width and height
2. label files without accessible image size are invalid

On export:

1. absolute coordinates normalize by image width and height
2. export requires known image dimensions

### Y05: Visibility mapping

Phase 3 supports:

1. `kpt_shape: [N, 3]`
2. `kpt_shape: [N, 2]`

For `[N, 3]`:

1. visibility value `<= 0` imports as not labeled
2. visibility value `> 0` imports as labeled and visible
3. occlusion distinctions beyond that are lost

For `[N, 2]`:

1. listed coordinates import as visible points

### Y06: YOLO losses

YOLO pose export drops:

1. tracks
2. instance scores
3. point scores
4. `from_predicted`
5. sessions, suggestions, ROIs, masks

## AlphaTracker JSON

### Scope

AlphaTracker support is read-only in phase 3.

Write attempts must throw `SleapIOError.unsupportedFormat`.

### A01: Supported subset

The first implementation targets the AlphaTracker JSON variant already supported
by Python `sleap-io`.

The Python-generated fixture is the contract for supported structure.

If the input schema variant differs materially from the fixture-supported
variant, import throws `SleapIOError.unsupportedFormat`.

### A02: Track behavior

If AlphaTracker provides stable identity keys or animal IDs
Then they import as shared `Track` objects.

If no track-like identity exists
Then instances import without tracks.

### A03: Skeleton behavior

AlphaTracker may not provide explicit node names or topology.

Therefore:

1. codec config may provide node names and order
2. if not provided, node names default to `node_0`, `node_1`, ...
3. imported skeletons are edgeless unless topology is provided externally

### A04: Predicted behavior

If AlphaTracker provides instance confidence
Then instances may import as `PredictedInstance`.

Otherwise they import as `Instance`.

## Suggested Test Suite Layout

1. `COCOCodecTests`
   - category/skeleton mapping
   - visibility mapping
   - image/frame mapping
   - predicted-score import
   - export bbox and keypoint layout
   - malformed arrays and missing category/image references

2. `CSVCodecTests`
   - required-column validation
   - multi-instance reconstruction
   - missing-node fill behavior
   - predicted instance reconstruction
   - track sharing by string key
   - export row ordering

3. `LabelStudioCodecTests`
   - explicit skeleton mapping requirement
   - task/result grouping
   - annotation vs prediction import
   - coordinate scaling
   - unsupported video-project rejection

4. `YOLOCodecTests`
   - single-class dataset import
   - normalized coordinate scaling
   - visibility handling
   - explicit node-order requirement
   - multi-class rejection

5. `AlphaTrackerCodecTests`
   - supported fixture import
   - track mapping
   - write rejection

6. `InterchangeRoundTripTests`
   - Swift write -> Swift read for the supported subset of each writable format
   - fixture import summaries against expected counts and topology

## Definition Of Done

Phase 3 is complete when:

1. each codec obeys the format-specific behavior in this document
2. each writable codec has round-trip tests for its supported subset
3. Python-generated fixtures are covered for the supported subsets
4. lossy behaviors are tested explicitly rather than treated as accidental
5. unsupported variants fail deterministically with the documented error class

## Resolved Ambiguities

This document intentionally resolves the following open questions before coding:

1. CSV requires `instance` and `skeleton` columns; the earlier rough sketch was not sufficient
2. CSV is allowed to lose skeleton topology
3. Label Studio import/export requires explicit skeleton mapping config
4. YOLO pose import/export requires explicit node-order config and is single-class in the first pass
5. COCO standard mode drops tracks rather than inventing private extension fields in the first pass
