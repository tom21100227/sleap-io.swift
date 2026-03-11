#!/usr/bin/env python3
"""Generate test fixture .slp files for sleap-io.swift Phase 1 tests.

Requirements:
    uv run --with sleap-io --with h5py python3 generate_fixtures.py

This generates the following fixture files in the current directory:
    1. sparse_v1_5.slp          — Multiple videos, sparse frames, user instances only
    2. dense_predictions_v1_5.slp — One video, many frames, user + predicted instances, tracks
    3. packaged_frames_v1_5.pkg.slp — Embedded image frames, sparse frame numbers
    4. legacy_v1_0.slp          — Pre-1.1 format (coordinate adjustment case)
    5. legacy_v1_1.slp          — Pre-1.2 format (no tracking_score field)
    6. legacy_v1_3.slp          — Pre-1.4 format (no channel_order attribute)
    7. multiview_v1_5.slp       — Sessions / cameras / frame groups
    8. roi_mask_v1_5.slp        — ROIs and segmentation masks
"""

import json
import os
import struct
from pathlib import Path

import h5py
import numpy as np

try:
    import sleap_io as sio
except ImportError:
    raise ImportError("sleap-io is required: uv run --with sleap-io")


OUTPUT_DIR = Path(__file__).parent
rng = np.random.default_rng(42)


def make_skeleton(name="Drosophila", num_nodes=5):
    """Create a simple skeleton for testing."""
    node_names = [f"node_{i}" for i in range(num_nodes)]
    nodes = [sio.Node(name=n) for n in node_names]
    edges = [sio.Edge(source=nodes[i], destination=nodes[i + 1]) for i in range(len(nodes) - 1)]
    symmetries = []
    if num_nodes >= 4:
        symmetries = [sio.Symmetry(nodes=[nodes[1], nodes[3]])]
    return sio.Skeleton(name=name, nodes=nodes, edges=edges, symmetries=symmetries)


def make_points(num_nodes):
    """Create random points as a numpy (N, 2) array."""
    return rng.uniform(50, 500, size=(num_nodes, 2)).astype(np.float64)


def make_instance(skeleton, track=None):
    """Create a user instance with random visible points."""
    pts = make_points(len(skeleton.nodes))
    return sio.Instance(points=pts, skeleton=skeleton, track=track)


def make_predicted_instance(skeleton, track=None, score=0.9):
    """Create a predicted instance with random points and scores."""
    pts = make_points(len(skeleton.nodes))
    return sio.PredictedInstance(
        points=pts,
        skeleton=skeleton,
        track=track,
        score=score,
    )


def generate_sparse_v1_5():
    """1. Multiple videos, sparse labeled frames, user instances only."""
    print("Generating sparse_v1_5.slp ...")
    skeleton = make_skeleton()

    video1 = sio.Video(filename="video1.mp4")
    video2 = sio.Video(filename="video2.mp4")

    frames = []
    # Video 1: frames at indices 0, 5, 10, 20
    for idx in [0, 5, 10, 20]:
        instances = [make_instance(skeleton) for _ in range(2)]
        frames.append(sio.LabeledFrame(video=video1, frame_idx=idx, instances=instances))

    # Video 2: frames at indices 3, 7, 15
    for idx in [3, 7, 15]:
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video2, frame_idx=idx, instances=instances))

    suggestions = [
        sio.SuggestionFrame(video=video1, frame_idx=2),
        sio.SuggestionFrame(video=video2, frame_idx=8),
    ]

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video1, video2],
        skeletons=[skeleton],
        suggestions=suggestions,
    )
    sio.save_file(labels, str(OUTPUT_DIR / "sparse_v1_5.slp"))
    print(f"  -> {len(frames)} frames, {len(labels.videos)} videos")


def generate_dense_predictions_v1_5():
    """2. One video, many frames, user + predicted instances, tracks."""
    print("Generating dense_predictions_v1_5.slp ...")
    skeleton = make_skeleton()
    video = sio.Video(filename="dense_video.mp4")

    tracks = [sio.Track(name=f"track_{i}") for i in range(3)]

    frames = []
    for idx in range(50):
        instances = []
        # User instances
        for t in range(2):
            inst = make_instance(skeleton, track=tracks[t])
            instances.append(inst)

        # Predicted instances
        for t in range(3):
            pred = make_predicted_instance(skeleton, track=tracks[t])
            instances.append(pred)

        # Create from_predicted links: first user instance derived from first prediction
        if len(instances) >= 3:
            instances[0].from_predicted = instances[2]

        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
        tracks=tracks,
    )
    sio.save_file(labels, str(OUTPUT_DIR / "dense_predictions_v1_5.slp"))
    print(f"  -> {len(frames)} frames, {sum(len(f.instances) for f in frames)} instances")


def generate_packaged_frames_v1_5():
    """3. Embedded JPEG frames, sparse frame numbers.

    Since we can't embed from a non-existent video via sleap-io, we create
    a normal SLP then manually inject embedded video frames as HDF5 datasets.
    """
    print("Generating packaged_frames_v1_5.pkg.slp ...")
    skeleton = make_skeleton()
    video = sio.Video(filename="embedded.mp4")

    frame_indices = [0, 3, 7, 12, 20]
    frames = []
    for idx in frame_indices:
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
    )

    output_path = str(OUTPUT_DIR / "packaged_frames_v1_5.pkg.slp")
    sio.save_file(labels, output_path)

    # Manually inject embedded video frames into the HDF5 file
    import io
    from PIL import Image

    with h5py.File(output_path, "r+") as f:
        # Create video0 group with embedded PNG frames
        if "video0" in f:
            del f["video0"]
        grp = f.create_group("video0")

        # Generate small random PNG images and encode them
        height, width = 64, 64
        encoded_frames = []
        for _ in frame_indices:
            img_array = rng.integers(0, 255, size=(height, width, 3), dtype=np.uint8)
            img = Image.fromarray(img_array)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            encoded_frames.append(np.frombuffer(buf.getvalue(), dtype=np.int8))

        # Write as variable-length int8 dataset
        vlen_dt = h5py.vlen_dtype(np.dtype("int8"))
        ds = grp.create_dataset("video", (len(encoded_frames),), dtype=vlen_dt)
        for i, frame_data in enumerate(encoded_frames):
            ds[i] = frame_data

        ds.attrs["format"] = "png"
        ds.attrs["channel_order"] = "RGB"
        ds.attrs["frames"] = len(encoded_frames)
        ds.attrs["height"] = height
        ds.attrs["width"] = width
        ds.attrs["channels"] = 3
        ds.attrs["fps"] = 30.0

        # Frame numbers mapping
        grp.create_dataset("frame_numbers", data=np.array(frame_indices, dtype=np.uint64))

        # Source video metadata
        src_grp = grp.create_group("source_video")
        src_grp.attrs["json"] = json.dumps({
            "backend": {"filename": "embedded.mp4", "type": "media"},
        })

        # Update videos_json to point to embedded video
        if "videos_json" in f:
            vj = f["videos_json"]
            vid_json = json.loads(vj[0])
            vid_json["backend"]["filename"] = "."
            vid_json["backend"]["type"] = "hdf5"
            new_json = json.dumps(vid_json)
            del f["videos_json"]
            dt = h5py.string_dtype()
            f.create_dataset("videos_json", data=[new_json], dtype=dt)

    print(f"  -> {len(frames)} frames with embedded PNG images")


def _patch_format_id(filepath, format_id):
    """Patch the format_id attribute in an existing .slp file."""
    with h5py.File(filepath, "r+") as f:
        if "metadata" in f:
            if "format_id" in f["metadata"].attrs:
                f["metadata"].attrs["format_id"] = format_id


def generate_legacy_v1_0():
    """4. Pre-1.1 format — coordinate adjustment case (points.xy -= 0.5)."""
    print("Generating legacy_v1_0.slp ...")
    skeleton = make_skeleton(num_nodes=3)
    video = sio.Video(filename="legacy_v1_0_video.mp4")

    frames = []
    for idx in [0, 5]:
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
    )

    output_path = str(OUTPUT_DIR / "legacy_v1_0.slp")
    sio.save_file(labels, output_path)

    # Patch format_id to 1.0
    _patch_format_id(output_path, 1.0)
    print("  -> Patched format_id to 1.0")


def generate_legacy_v1_1():
    """5. Pre-1.2 format — missing tracking_score field."""
    print("Generating legacy_v1_1.slp ...")
    skeleton = make_skeleton(num_nodes=3)
    video = sio.Video(filename="legacy_v1_1_video.mp4")

    frames = []
    for idx in [0, 3, 8]:
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
    )

    output_path = str(OUTPUT_DIR / "legacy_v1_1.slp")
    sio.save_file(labels, output_path)

    # Patch format_id to 1.1
    _patch_format_id(output_path, 1.1)

    # Remove tracking_score field from /instances compound dataset
    with h5py.File(output_path, "r+") as f:
        if "instances" in f:
            instances = f["instances"]
            data = instances[()]
            if "tracking_score" in data.dtype.names:
                new_dtype = np.dtype(
                    [(n, data.dtype[n]) for n in data.dtype.names if n != "tracking_score"]
                )
                new_data = np.empty(len(data), dtype=new_dtype)
                for name in new_dtype.names:
                    new_data[name] = data[name]
                del f["instances"]
                f.create_dataset("instances", data=new_data)

    print("  -> Patched format_id to 1.1, removed tracking_score")


def generate_legacy_v1_3():
    """6. Pre-1.4 format — no channel_order on embedded video."""
    print("Generating legacy_v1_3.slp ...")
    skeleton = make_skeleton(num_nodes=3)
    video = sio.Video(filename="legacy_v1_3_video.mp4")

    frames = []
    for idx in [0, 2]:
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
    )

    output_path = str(OUTPUT_DIR / "legacy_v1_3.slp")
    sio.save_file(labels, output_path)

    # Patch format_id to 1.3
    _patch_format_id(output_path, 1.3)
    print("  -> Patched format_id to 1.3")


def generate_multiview_v1_5():
    """7. Sessions / cameras / frame groups."""
    print("Generating multiview_v1_5.slp ...")
    skeleton = make_skeleton(num_nodes=4)

    video1 = sio.Video(filename="cam0.mp4")
    video2 = sio.Video(filename="cam1.mp4")

    frames = []
    for idx in range(5):
        inst1 = [make_instance(skeleton)]
        inst2 = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video1, frame_idx=idx, instances=inst1))
        frames.append(sio.LabeledFrame(video=video2, frame_idx=idx, instances=inst2))

    # Create recording session with cameras
    cam0 = sio.Camera(name="camera_0")
    cam1 = sio.Camera(name="camera_1")

    session = sio.RecordingSession(
        camera_group=sio.CameraGroup(cameras=[cam0, cam1]),
        video_by_camera={cam0: video1, cam1: video2},
    )

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video1, video2],
        skeletons=[skeleton],
        sessions=[session],
    )

    output_path = str(OUTPUT_DIR / "multiview_v1_5.slp")
    sio.save_file(labels, output_path)
    print(f"  -> {len(frames)} frames, 2 cameras, 1 session")


def generate_roi_mask_v1_5():
    """8. ROIs and segmentation masks."""
    print("Generating roi_mask_v1_5.slp ...")
    skeleton = make_skeleton(num_nodes=3)
    video = sio.Video(filename="roi_video.mp4")

    frames = []
    for idx in range(5):
        instances = [make_instance(skeleton)]
        frames.append(sio.LabeledFrame(video=video, frame_idx=idx, instances=instances))

    labels = sio.Labels(
        labeled_frames=frames,
        videos=[video],
        skeletons=[skeleton],
    )

    output_path = str(OUTPUT_DIR / "roi_mask_v1_5.slp")
    sio.save_file(labels, output_path)

    # Manually add ROI and mask datasets to the HDF5 file
    with h5py.File(output_path, "r+") as f:
        # Patch format_id to 1.5
        if "metadata" in f:
            f["metadata"].attrs["format_id"] = 1.5

        # Add ROI dataset matching the SLP 1.5 spec
        roi_dtype = np.dtype([
            ("annotation_type", np.uint8),
            ("video", np.int32),
            ("frame_idx", np.int64),
            ("track", np.int32),
            ("score", np.float32),
            ("wkb_start", np.uint64),
            ("wkb_end", np.uint64),
        ])
        roi_data = np.array(
            [
                (0, 0, 0, -1, 0.95, 0, 4),   # bounding_box
                (1, 0, 1, -1, 0.80, 4, 10),   # polygon
            ],
            dtype=roi_dtype,
        )
        if "rois" not in f:
            ds = f.create_dataset("rois", data=roi_data)
            ds.attrs["categories"] = json.dumps(["object"])
            ds.attrs["names"] = json.dumps(["roi_0", "roi_1"])
            ds.attrs["sources"] = json.dumps(["manual", "manual"])

        # WKB data for ROIs (simplified placeholder bytes)
        wkb_data = np.array([0, 0, 0, 100, 100, 200, 200, 50, 60, 70], dtype=np.uint8)
        if "roi_wkb" not in f:
            f.create_dataset("roi_wkb", data=wkb_data)

        # Add mask dataset matching the SLP 1.5 spec
        mask_dtype = np.dtype([
            ("height", np.uint32),
            ("width", np.uint32),
            ("annotation_type", np.uint8),
            ("video", np.int32),
            ("frame_idx", np.int64),
            ("track", np.int32),
            ("score", np.float32),
            ("rle_start", np.uint64),
            ("rle_end", np.uint64),
        ])
        mask_data = np.array(
            [(64, 64, 5, 0, 0, -1, 0.90, 0, 8)],
            dtype=mask_dtype,
        )
        if "masks" not in f:
            ds = f.create_dataset("masks", data=mask_data)
            ds.attrs["categories"] = json.dumps(["foreground"])
            ds.attrs["names"] = json.dumps(["mask_0"])
            ds.attrs["sources"] = json.dumps(["model"])

        # RLE data for mask
        rle_data = np.array([100, 50, 200, 50, 100, 50, 200, 50], dtype=np.uint8)
        if "mask_rle" not in f:
            f.create_dataset("mask_rle", data=rle_data)

    print("  -> Added ROI and mask datasets")


def main():
    """Generate all fixture files."""
    print(f"Output directory: {OUTPUT_DIR}")
    print()

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    generate_sparse_v1_5()
    generate_dense_predictions_v1_5()
    generate_packaged_frames_v1_5()
    generate_legacy_v1_0()
    generate_legacy_v1_1()
    generate_legacy_v1_3()
    generate_multiview_v1_5()
    generate_roi_mask_v1_5()

    print()
    print("All fixtures generated successfully!")
    print()
    print("Generated files:")
    for p in sorted(OUTPUT_DIR.glob("*.slp")):
        size_kb = p.stat().st_size / 1024
        print(f"  {p.name:40s} {size_kb:8.1f} KB")


if __name__ == "__main__":
    main()
