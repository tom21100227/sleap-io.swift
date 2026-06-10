export const meta = {
  name: 'sleap-io-parity-gap-analysis',
  description: 'Compare Python sleap-io + sleap-io.js against the Swift port; emit a structured gap inventory',
  whenToUse: 'Feature-parity audit of sleap-io.swift vs upstream Python and JS',
  phases: [
    { title: 'Analyze' },
    { title: 'Completeness' },
  ],
}

const PY = '/Users/chan/PersonalProjects/sleap-io/sleap_io'
const JS = '/Users/chan/PersonalProjects/sleap-io.js/src'
const SW = '/Users/chan/PersonalProjects/sleap-io.swift/Sources'

const GAP_SCHEMA = {
  type: 'object',
  required: ['module', 'summary', 'gaps'],
  properties: {
    module: { type: 'string' },
    summary: { type: 'string', description: '3-5 sentence overview of parity status for this module group' },
    gaps: {
      type: 'array',
      description: 'One entry per concrete feature/class/method/format. Focus on where Swift is missing or partial vs Python OR JS.',
      items: {
        type: 'object',
        required: ['feature', 'pythonHas', 'jsHas', 'swiftStatus', 'guiRelevance', 'backendRelevance', 'complexity', 'description'],
        properties: {
          feature: { type: 'string', description: 'Specific class/method/format/symbol name as it appears upstream' },
          pythonHas: { type: 'boolean' },
          jsHas: { type: 'boolean' },
          swiftStatus: { type: 'string', enum: ['full', 'partial', 'none'] },
          swiftLocation: { type: 'string', description: 'Existing Swift symbol/file if any, or proposed location' },
          description: { type: 'string', description: 'What it does, concretely, naming real symbols' },
          guiRelevance: { type: 'string', enum: ['high', 'medium', 'low'], description: 'Need for a SwiftUI annotation GUI replacing sleap-label' },
          backendRelevance: { type: 'string', enum: ['high', 'medium', 'low'], description: 'Need as a Swift training/inference backend (sleap.swift)' },
          complexity: { type: 'string', enum: ['S', 'M', 'L', 'XL'] },
          notes: { type: 'string' },
        },
      },
    },
  },
}

function buildPrompt(d) {
  return `You are auditing FEATURE PARITY across three implementations of the sleap-io pose-data library:
- Python reference (canonical): files under ${PY}
- JavaScript port: files under ${JS}
- Our Swift port (the target being audited): files under ${SW}

FOCUS AREA: ${d.focus}

Read these files (small-to-medium; read them fully):
- Python: ${d.py.length ? d.py.join(', ') : '(none)'}
- JavaScript: ${d.js.length ? d.js.join(', ') : '(none)'}
- Swift (our port): ${d.sw.length ? d.sw.join(', ') : '(none — likely entirely missing)'}

TASK: For every meaningful feature, public class, method, property, format, or behavior present in the Python or JS implementation, determine whether our Swift port has it: "full" (behavioral parity), "partial" (exists but incomplete/divergent), or "none" (absent). Produce a gap list. Concentrate on partial/none gaps; include "full" items only when notable for confidence.

For each gap judge:
- guiRelevance: how much a native SwiftUI annotation/labeling GUI (a replacement for the Python "sleap-label" app: loading projects, editing instances/points, managing tracks/skeletons, navigating frames, video playback, rendering overlays, suggestions, undo/redo, merge) needs it. The PROJECT NORTH STAR is unblocking this GUI, so weight this carefully and concretely.
- backendRelevance: how much a Swift training/inference backend (sleap.swift: tensor export, numpy-equivalent arrays, batching, analysis export) needs it.
- complexity: S (<0.5 day), M (~1-2 days), L (~3-5 days), XL (>1 week) to implement in Swift with TDD.

Rules: Name REAL symbols (e.g. Labels.numpy(), Instance.update_skeleton(), matching.MatchedFrame). Do NOT invent upstream features. Note Apple-platform considerations (e.g. NWB/LEAP/h5py-only paths) in notes. If a Python-only feature is explicitly out of scope for an Apple-native port, still list it but mark relevance low and say why in notes.

Return the structured object. Be specific and exhaustive within your focus area.`
}

const DIMENSIONS = [
  {
    key: 'model-labels',
    focus: 'The Labels container API surface — the single most GUI-critical type. Enumerate every public method/property/operation: append, extend, find, __getitem__ overloads, numpy/export, merge, split, append_video/remove_video, replace_videos/replace_filenames, rename/remove/reorder skeletons, tracks management, instances iteration, save/load dispatch, sessions, provenance, suggestions accessors, clean/trim, make_training_splits, etc. Plus the LabelsSet container.',
    py: [`${PY}/model/labels.py`, `${PY}/model/labels_set.py`],
    js: [`${JS}/model/labels.ts`, `${JS}/model/labels-set.ts`, `${JS}/model/lazy.ts`],
    sw: [`${SW}/SleapIO/Model/Labels.swift`, `${SW}/SleapHDF5/SLP/LazyFrameList.swift`, `${SW}/SleapHDF5/SLP/LazyDataStore.swift`],
  },
  {
    key: 'model-instance-frame',
    focus: 'Instance / PredictedInstance / LabeledFrame model + Point/PointsArray + bbox, centroid, identity types. Methods like Instance.numpy(), update_skeleton, from_numpy, replace_skeleton, bounding box/centroid computation, n_visible, scores, track assignment, frame-level ops (merge, remove_empty_instances, numpy), 3D instances.',
    py: [`${PY}/model/instance.py`, `${PY}/model/labeled_frame.py`, `${PY}/model/bbox.py`, `${PY}/model/centroid.py`, `${PY}/model/identity.py`],
    js: [`${JS}/model/instance.ts`, `${JS}/model/labeled-frame.ts`, `${JS}/model/bbox.ts`, `${JS}/model/centroid.ts`, `${JS}/model/identity.ts`, `${JS}/model/instance3d.ts`],
    sw: [`${SW}/SleapIO/Model/Instance.swift`, `${SW}/SleapIO/Model/PredictedInstance.swift`, `${SW}/SleapIO/Model/LabeledFrame.swift`, `${SW}/SleapIO/Model/Point.swift`, `${SW}/SleapIO/Model/PointsArray.swift`],
  },
  {
    key: 'model-skeleton-video',
    focus: 'Skeleton / Node / Edge / Symmetry model + skeleton JSON codec + Video model. Skeleton ops: add/remove/rename node, add_edge, add_symmetry, required_nodes, flip indices, get_flipped_node_inds, index_pairs. Video: backend metadata, shape/grayscale/channels, exists, open/close, filename resolution, embedded vs file, replace_filename.',
    py: [`${PY}/model/skeleton.py`, `${PY}/model/video.py`, `${PY}/io/skeleton.py`],
    js: [`${JS}/model/skeleton.ts`, `${JS}/model/video.ts`, `${JS}/codecs/skeleton-json.ts`, `${JS}/codecs/skeleton-yaml.ts`],
    sw: [`${SW}/SleapIO/Model/Skeleton.swift`, `${SW}/SleapIO/Model/Node.swift`, `${SW}/SleapIO/Model/Edge.swift`, `${SW}/SleapIO/Model/Symmetry.swift`, `${SW}/SleapIO/Model/Video.swift`, `${SW}/SleapHDF5/SLP/SkeletonCodec.swift`],
  },
  {
    key: 'model-roi-mask-matching',
    focus: 'ROI, segmentation mask, label_image, suggestions, and ESPECIALLY matching/merge algorithms. matching.py defines instance/frame matching, MatchedFrame, conflict resolution used by Labels.merge — critical for GUI merge/import. Suggestions generation. Mask encode/decode (RLE/WKB).',
    py: [`${PY}/model/roi.py`, `${PY}/model/mask.py`, `${PY}/model/label_image.py`, `${PY}/model/matching.py`, `${PY}/model/suggestions.py`],
    js: [`${JS}/model/roi.ts`, `${JS}/model/mask.ts`, `${JS}/model/label-image.ts`, `${JS}/model/matching.ts`, `${JS}/model/suggestions.ts`],
    sw: [`${SW}/SleapIO/Model/ROI.swift`, `${SW}/SleapIO/Model/SegmentationMask.swift`, `${SW}/SleapIO/Model/SuggestionFrame.swift`],
  },
  {
    key: 'slp-io',
    focus: 'SLP HDF5 read/write completeness incl. lazy/streaming, embedded video, version handling (1.0-1.5), provenance, sessions/cameras, ROIs/masks datasets, write round-trip fidelity, append/in-place edits.',
    py: [`${PY}/io/slp.py`, `${PY}/io/slp_lazy.py`, `${PY}/io/utils.py`],
    js: [`${JS}/codecs/slp/read.ts`, `${JS}/codecs/slp/write.ts`, `${JS}/codecs/slp/read-streaming.ts`, `${JS}/codecs/slp/parsers.ts`, `${JS}/codecs/slp/h5.ts`],
    sw: [`${SW}/SleapHDF5/SLP/SLPReader.swift`, `${SW}/SleapHDF5/SLP/SLPWriter.swift`, `${SW}/SleapHDF5/SLP/SLPMetadata.swift`, `${SW}/SleapHDF5/SLP/SLPVideoTable.swift`, `${SW}/SleapHDF5/SLP/EmbeddedVideo.swift`, `${SW}/SleapHDF5/SLP/LabelsIO.swift`],
  },
  {
    key: 'formats-coco-csv-ls-at',
    focus: 'COCO, CSV, Label Studio, AlphaTracker import/export parity and round-trip fidelity. Check read AND write directions, options, edge cases vs Python.',
    py: [`${PY}/io/coco.py`, `${PY}/io/csv.py`, `${PY}/io/labelstudio.py`, `${PY}/io/alphatracker.py`],
    js: [],
    sw: [`${SW}/SleapIO/Codecs/COCOCodec.swift`, `${SW}/SleapIO/Codecs/CSVCodec.swift`, `${SW}/SleapIO/Codecs/LabelStudioCodec.swift`, `${SW}/SleapIO/Codecs/AlphaTrackerCodec.swift`],
  },
  {
    key: 'formats-dlc-jabs-yolo-analysis',
    focus: 'DLC, JABS, Ultralytics/YOLO, Analysis-HDF5 import/export parity. Check both directions and option coverage vs Python and JS.',
    py: [`${PY}/io/dlc.py`, `${PY}/io/jabs.py`, `${PY}/io/ultralytics.py`, `${PY}/io/analysis_h5.py`],
    js: [`${JS}/io/jabs.ts`, `${JS}/io/ultralytics.ts`, `${JS}/io/analysis-h5.ts`],
    sw: [`${SW}/SleapHDF5/DLCCodec.swift`, `${SW}/SleapHDF5/JABSCodec.swift`, `${SW}/SleapIO/Codecs/YOLOCodec.swift`, `${SW}/SleapHDF5/AnalysisHDF5Codec.swift`],
  },
  {
    key: 'formats-missing',
    focus: 'Formats present upstream but likely ABSENT in Swift: GeoJSON, TrackMate, SEQ image series, TIFF, NWB (annotations+predictions), LEAP .mat. For each, assess relevance to an Apple-native GUI/backend and whether a Swift ecosystem exists. NWB/LEAP are flagged out-of-scope in CLAUDE.md — confirm and note why.',
    py: [`${PY}/io/geojson.py`, `${PY}/io/trackmate.py`, `${PY}/io/seq.py`, `${PY}/io/tiff.py`, `${PY}/io/nwb.py`, `${PY}/io/nwb_annotations.py`, `${PY}/io/nwb_predictions.py`, `${PY}/io/leap.py`],
    js: [`${JS}/io/geojson.ts`, `${JS}/io/trackmate.ts`],
    sw: [],
  },
  {
    key: 'codecs-dict-numpy-tensor',
    focus: 'Dictionary codec (identity-preserving serialization), numpy/tensor array export (the (n_frames, n_tracks, n_nodes, 2/3) arrays used for training/analysis), dataframe export, skeleton YAML, training-config parsing. Compare DictionaryCodec + TensorCodec coverage.',
    py: [`${PY}/codecs/dictionary.py`, `${PY}/codecs/numpy.py`, `${PY}/codecs/dataframe.py`],
    js: [`${JS}/codecs/dictionary.ts`, `${JS}/codecs/numpy.ts`, `${JS}/codecs/training-config.ts`],
    sw: [`${SW}/SleapIO/Codecs/DictionaryCodec.swift`, `${SW}/SleapIO/Codecs/TensorCodec.swift`, `${SW}/SleapIO/Codecs/CodecHelpers.swift`],
  },
  {
    key: 'rendering',
    focus: 'Rendering pipeline for GUI overlays: drawing nodes, edges, instances, labels/text, track colors, color maps, masks, trails, bounding boxes, overlays, callbacks, frame compositing, video export. Compare PoseRenderer + Colors + RenderOptions against the much richer Python/JS rendering modules.',
    py: [`${PY}/rendering/core.py`, `${PY}/rendering/colors.py`, `${PY}/rendering/overlays.py`, `${PY}/rendering/shapes.py`, `${PY}/rendering/callbacks.py`],
    js: [`${JS}/rendering/render.ts`, `${JS}/rendering/overlays.ts`, `${JS}/rendering/shapes.ts`, `${JS}/rendering/trails.ts`, `${JS}/rendering/colors.ts`, `${JS}/rendering/context.ts`, `${JS}/rendering/types.ts`],
    sw: [`${SW}/SleapRendering/PoseRenderer.swift`, `${SW}/SleapRendering/Colors.swift`, `${SW}/SleapRendering/RenderOptions.swift`],
  },
  {
    key: 'transform',
    focus: 'Geometric transforms: affine, scale, rotate, translate, crop, flip, applied to points/instances/frames/videos. Compare the Transforms module against Python/JS transform packages.',
    py: [`${PY}/transform/core.py`, `${PY}/transform/frame.py`, `${PY}/transform/points.py`, `${PY}/transform/video.py`],
    js: [`${JS}/transform/frame.ts`, `${JS}/transform/points.ts`, `${JS}/transform/index.ts`],
    sw: [`${SW}/SleapIO/Transforms/AffineTransform.swift`, `${SW}/SleapIO/Transforms/InstanceTransforms.swift`, `${SW}/SleapIO/Transforms/PointsArrayTransforms.swift`],
  },
  {
    key: 'video-backends',
    focus: 'Video read/write backends: media (mp4/mov), HDF5 embedded, image sequence, SEQ, TIFF, streaming, cropping, frame caching, grayscale, channel order, seeking, frame extraction. Compare SleapVideo (AVFoundation/HDF5/ImageSequence/FrameCache) vs the rich JS video backends and Python video_reading/writing.',
    py: [`${PY}/io/video_reading.py`, `${PY}/io/video_writing.py`, `${PY}/io/seq.py`, `${PY}/io/tiff.py`],
    js: [`${JS}/video/backend.ts`, `${JS}/video/factory.ts`, `${JS}/video/media-video.ts`, `${JS}/video/hdf5-video.ts`, `${JS}/video/streaming-hdf5-video.ts`, `${JS}/video/crop-backend.ts`, `${JS}/video/embedded-frame.ts`, `${JS}/video/seq-video.ts`],
    sw: [`${SW}/SleapVideo/VideoBackend.swift`, `${SW}/SleapVideo/AVFoundationBackend.swift`, `${SW}/SleapVideo/HDF5VideoBackend.swift`, `${SW}/SleapVideo/ImageSequenceBackend.swift`, `${SW}/SleapVideo/FrameCache.swift`, `${SW}/SleapVideo/VideoExtensions.swift`],
  },
  {
    key: 'cli-dispatch',
    focus: 'High-level load/save dispatch with format auto-detection (io/main.py: load_file/save_file, load_slp/load_video etc.) and CLI commands (convert, info, etc.). Compare against SleapioCLI + LabelsIO load/save entry points. List every format the dispatcher auto-detects.',
    py: [`${PY}/io/main.py`, `${PY}/io/cli.py`],
    js: [`${JS}/io/main.ts`],
    sw: [`${SW}/SleapCLI/SleapioCLI.swift`, `${SW}/SleapHDF5/SLP/LabelsIO.swift`],
  },
]

phase('Analyze')
log(`Auditing ${DIMENSIONS.length} module groups across Python, JS, and Swift...`)

const results = await parallel(
  DIMENSIONS.map((d) => () =>
    agent(buildPrompt(d), { label: `gap:${d.key}`, phase: 'Analyze', schema: GAP_SCHEMA })
  )
)

const findings = results.filter(Boolean)
const allGaps = findings.flatMap((f) => (f.gaps || []).map((g) => ({ ...g, module: f.module })))
log(`Collected ${allGaps.length} gap items across ${findings.length} modules.`)

// Completeness critic — what did the sweep miss?
phase('Completeness')
const moduleSummaries = findings.map((f) => `### ${f.module}\n${f.summary}\nGaps flagged: ${(f.gaps || []).map((g) => g.feature).join('; ')}`).join('\n\n')
const critic = await agent(
  `You are a completeness critic for a feature-parity audit of sleap-io.swift vs Python sleap-io and sleap-io.js.

Here is what the audit covered, by module:

${moduleSummaries}

The full upstream Python tree is under ${PY} and JS under ${JS}. The Swift port is under ${SW}.

Identify what the audit likely MISSED: whole upstream modules/files not covered, cross-cutting features (e.g. __init__.py public API exports, async I/O, error types, provenance/metadata, version migration, units/coordinate conventions, thread-safety, streaming), or Swift-specific concerns for a SwiftUI macOS/iPadOS GUI and a training backend. List concrete additional gap candidates with the same fields. Read upstream files as needed to verify. Prioritize anything HIGH for the GUI north star.`,
  { label: 'completeness-critic', phase: 'Completeness', schema: GAP_SCHEMA }
)

if (critic && critic.gaps) {
  for (const g of critic.gaps) allGaps.push({ ...g, module: critic.module || 'completeness' })
  log(`Critic added ${critic.gaps.length} candidate gaps.`)
}

return {
  moduleSummaries: findings.map((f) => ({ module: f.module, summary: f.summary, gapCount: (f.gaps || []).length })),
  gaps: allGaps,
  criticModule: critic ? { module: critic.module, summary: critic.summary } : null,
}
