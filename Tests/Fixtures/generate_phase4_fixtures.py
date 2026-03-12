#!/usr/bin/env python3
"""Generate test fixture HDF5 files for sleap-io.swift Phase 4 codec tests.

Requirements:
    uv run --with h5py --with numpy --with pandas --with tables \
        python3 Tests/Fixtures/generate_phase4_fixtures.py

This generates fixture families in Tests/Fixtures/phase4/:
    1. analysis_h5/   — Analysis HDF5 format (SLEAP analysis exports)
    2. jabs_h5/       — JABS format (Jackson Labs pose estimation)
    3. dlc_h5/        — DeepLabCut HDF5 format (pandas HDFStore)
    4. cli_smoke/     — Small fixture for CLI integration testing
"""

import json
import os
import shutil
from pathlib import Path

import h5py
import numpy as np

OUTPUT_DIR = Path(__file__).parent / "phase4"

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

ANALYSIS_NODE_NAMES = ["head", "thorax", "tail"]
ANALYSIS_TRACK_NAMES = ["animal_0", "animal_1"]
ANALYSIS_EDGE_INDS = [[0, 1], [1, 2]]
ANALYSIS_EDGE_NAMES = ["head,thorax", "thorax,tail"]

JABS_NODE_NAMES = ["nose", "left_ear", "right_ear", "tail_base"]

DLC_BODYPARTS = ["head", "body", "tail"]
DLC_SCORER = "DLC_resnet50"


def _analysis_coords_track0():
    """Deterministic coords for analysis track 0: (T=3, K=3, 2)."""
    # Frame 0: [[100,200],[150,250],[200,300]]
    # Frame 1: +10 per frame
    # Frame 2: +20 per frame
    base = np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]])
    return np.stack([base + 10.0 * t for t in range(3)])  # (3, 3, 2)


def _analysis_coords_track1():
    """Deterministic coords for analysis track 1: (T=3, K=3, 2)."""
    base = np.array([[300.0, 400.0], [350.0, 450.0], [400.0, 500.0]])
    return np.stack([base + 10.0 * t for t in range(3)])  # (3, 3, 2)


def _write_expected(path, data):
    """Write a JSON sidecar with expected summary stats."""
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


# ===========================================================================
# 1. Analysis HDF5
# ===========================================================================

def generate_analysis_minimal():
    """analysis_minimal.h5 — 3 frames, 2 tracks, 3 nodes, edges, no scores."""
    print("  Generating analysis_minimal.h5 ...")
    outdir = OUTPUT_DIR / "analysis_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "analysis_minimal.h5"

    T, N, K = 3, 2, 3
    coords_t0 = _analysis_coords_track0()  # (3, 3, 2)
    coords_t1 = _analysis_coords_track1()  # (3, 3, 2)

    # locations: (T, N, K, 2)
    locations = np.zeros((T, N, K, 2), dtype=np.float64)
    locations[:, 0, :, :] = coords_t0
    locations[:, 1, :, :] = coords_t1

    # track_occupancy: (T, N) — all present
    track_occupancy = np.ones((T, N), dtype=bool)

    with h5py.File(path, "w") as f:
        f.attrs["video_path"] = "test_video.mp4"

        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("track_names", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        f.create_dataset("track_occupancy", data=track_occupancy)
        f.create_dataset("locations", data=locations)
        f.create_dataset("edge_names", data=ANALYSIS_EDGE_NAMES, dtype=dt)
        f.create_dataset("edge_inds", data=np.array(ANALYSIS_EDGE_INDS, dtype=np.int64))

    _write_expected(outdir / "analysis_minimal_expected.json", {
        "frame_count": T,
        "track_count": N,
        "node_count": K,
        "track_names": ANALYSIS_TRACK_NAMES,
        "node_names": ANALYSIS_NODE_NAMES,
        "edge_names": ANALYSIS_EDGE_NAMES,
        "edge_inds": ANALYSIS_EDGE_INDS,
        "video_path": "test_video.mp4",
        "has_scores": False,
        "all_tracks_present": True,
        "locations_frame0_track0": coords_t0[0].tolist(),
        "locations_frame0_track1": coords_t1[0].tolist(),
        "locations_frame2_track0": coords_t0[2].tolist(),
        "locations_frame2_track1": coords_t1[2].tolist(),
    })


def generate_analysis_scores():
    """analysis_scores.h5 — 3 frames, 2 tracks, 3 nodes, all score datasets."""
    print("  Generating analysis_scores.h5 ...")
    outdir = OUTPUT_DIR / "analysis_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "analysis_scores.h5"

    T, N, K = 3, 2, 3
    coords_t0 = _analysis_coords_track0()
    coords_t1 = _analysis_coords_track1()

    locations = np.zeros((T, N, K, 2), dtype=np.float64)
    locations[:, 0, :, :] = coords_t0
    locations[:, 1, :, :] = coords_t1

    track_occupancy = np.ones((T, N), dtype=bool)

    # Scores
    point_scores = np.full((T, N, K), 0.9, dtype=np.float64)
    instance_scores = np.zeros((T, N), dtype=np.float64)
    instance_scores[:, 0] = 0.85
    instance_scores[:, 1] = 0.75
    tracking_scores = np.zeros((T, N), dtype=np.float64)
    tracking_scores[:, 0] = 0.95
    tracking_scores[:, 1] = 0.80

    with h5py.File(path, "w") as f:
        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("track_names", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        f.create_dataset("track_occupancy", data=track_occupancy)
        f.create_dataset("locations", data=locations)
        f.create_dataset("point_scores", data=point_scores)
        f.create_dataset("instance_scores", data=instance_scores)
        f.create_dataset("tracking_scores", data=tracking_scores)

    _write_expected(outdir / "analysis_scores_expected.json", {
        "frame_count": T,
        "track_count": N,
        "node_count": K,
        "track_names": ANALYSIS_TRACK_NAMES,
        "node_names": ANALYSIS_NODE_NAMES,
        "has_scores": True,
        "point_scores_value": 0.9,
        "instance_scores_track0": 0.85,
        "instance_scores_track1": 0.75,
        "tracking_scores_track0": 0.95,
        "tracking_scores_track1": 0.80,
    })


def generate_analysis_missing_tracks():
    """analysis_missing_tracks.h5 — 5 frames, 2 tracks, track 1 intermittent."""
    print("  Generating analysis_missing_tracks.h5 ...")
    outdir = OUTPUT_DIR / "analysis_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "analysis_missing_tracks.h5"

    T, N, K = 5, 2, 3

    # Track 0: always present, increasing coords
    base_t0 = np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]])
    # Track 1: present at frames 0, 2, 4 only
    base_t1 = np.array([[300.0, 400.0], [350.0, 450.0], [400.0, 500.0]])

    locations = np.full((T, N, K, 2), np.nan, dtype=np.float64)
    track_occupancy = np.zeros((T, N), dtype=bool)

    for t in range(T):
        # Track 0 always present
        locations[t, 0, :, :] = base_t0 + 10.0 * t
        track_occupancy[t, 0] = True

        # Track 1 present only at even frames
        if t % 2 == 0:
            locations[t, 1, :, :] = base_t1 + 10.0 * t
            track_occupancy[t, 1] = True
        # else: remains NaN and False

    with h5py.File(path, "w") as f:
        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("track_names", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        f.create_dataset("track_occupancy", data=track_occupancy)
        f.create_dataset("locations", data=locations)

    _write_expected(outdir / "analysis_missing_tracks_expected.json", {
        "frame_count": T,
        "track_count": N,
        "node_count": K,
        "track_names": ANALYSIS_TRACK_NAMES,
        "node_names": ANALYSIS_NODE_NAMES,
        "has_scores": False,
        "track1_present_frames": [0, 2, 4],
        "track1_absent_frames": [1, 3],
        "occupancy_frame1": [True, False],
        "occupancy_frame2": [True, True],
        "locations_frame1_track1_is_nan": True,
    })


def generate_analysis_no_edges():
    """analysis_no_edges.h5 — 3 frames, 1 track, 3 nodes, no edge datasets."""
    print("  Generating analysis_no_edges.h5 ...")
    outdir = OUTPUT_DIR / "analysis_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "analysis_no_edges.h5"

    T, N, K = 3, 1, 3
    base = np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]])
    locations = np.zeros((T, N, K, 2), dtype=np.float64)
    for t in range(T):
        locations[t, 0, :, :] = base + 10.0 * t

    track_occupancy = np.ones((T, N), dtype=bool)

    with h5py.File(path, "w") as f:
        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=["animal_0"], dtype=dt)
        f.create_dataset("track_names", data=["animal_0"], dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        f.create_dataset("track_occupancy", data=track_occupancy)
        f.create_dataset("locations", data=locations)
        # Deliberately no edge_names or edge_inds

    _write_expected(outdir / "analysis_no_edges_expected.json", {
        "frame_count": T,
        "track_count": N,
        "node_count": K,
        "track_names": ["animal_0"],
        "node_names": ANALYSIS_NODE_NAMES,
        "has_edges": False,
        "has_scores": False,
    })


def generate_analysis_malformed():
    """analysis_malformed.h5 — locations has wrong shape (3D instead of 4D)."""
    print("  Generating analysis_malformed.h5 ...")
    outdir = OUTPUT_DIR / "analysis_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "analysis_malformed.h5"

    with h5py.File(path, "w") as f:
        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        # Wrong shape: 3D (T, K, 2) instead of 4D (T, N, K, 2)
        bad_locations = np.zeros((3, 3, 2), dtype=np.float64)
        f.create_dataset("locations", data=bad_locations)

    _write_expected(outdir / "analysis_malformed_expected.json", {
        "error": "locations_wrong_shape",
        "locations_ndim": 3,
        "expected_ndim": 4,
    })


def generate_all_analysis():
    """Generate all analysis HDF5 fixtures."""
    print("Generating analysis_h5/ fixtures ...")
    generate_analysis_minimal()
    generate_analysis_scores()
    generate_analysis_missing_tracks()
    generate_analysis_no_edges()
    generate_analysis_malformed()


# ===========================================================================
# 2. JABS H5
# ===========================================================================

def _jabs_base_coords():
    """Base coords for JABS: 4 nodes (nose, left_ear, right_ear, tail_base)."""
    return np.array([
        [100.0, 200.0],
        [120.0, 180.0],
        [80.0, 180.0],
        [100.0, 350.0],
    ], dtype=np.float32)


def generate_jabs_single_animal():
    """jabs_single_animal.h5 — 5 frames, 1 animal, 4 nodes."""
    print("  Generating jabs_single_animal.h5 ...")
    outdir = OUTPUT_DIR / "jabs_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "jabs_single_animal.h5"

    T, N, K = 5, 1, 4
    base = _jabs_base_coords()

    points = np.zeros((T, N, K, 2), dtype=np.float32)
    confidence = np.full((T, N, K), 0.9, dtype=np.float32)

    for t in range(T):
        points[t, 0, :, :] = base + 5.0 * t

    with h5py.File(path, "w") as f:
        f.attrs["num_frames"] = T
        dt = h5py.string_dtype()
        f.attrs.create("node_names", data=JABS_NODE_NAMES, dtype=dt)

        grp = f.create_group("poseest")
        grp.create_dataset("points", data=points)
        grp.create_dataset("confidence", data=confidence)
        grp.create_dataset("instance_count", data=np.ones(T, dtype=np.int32))

    _write_expected(outdir / "jabs_single_animal_expected.json", {
        "frame_count": T,
        "animal_count": N,
        "node_count": K,
        "node_names": JABS_NODE_NAMES,
        "has_node_names": True,
        "confidence_value": 0.9,
        "points_frame0": (base + 0.0).tolist(),
        "points_frame4": (base + 20.0).tolist(),
    })


def generate_jabs_multi_animal():
    """jabs_multi_animal.h5 — 5 frames, 3 animals, 4 nodes, intermittent presence."""
    print("  Generating jabs_multi_animal.h5 ...")
    outdir = OUTPUT_DIR / "jabs_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "jabs_multi_animal.h5"

    T, N, K = 5, 3, 4
    base = _jabs_base_coords()

    points = np.full((T, N, K, 2), np.nan, dtype=np.float32)
    confidence = np.full((T, N, K), 0.0, dtype=np.float32)
    instance_count = np.zeros(T, dtype=np.int32)

    for t in range(T):
        # Animal 0: always present
        points[t, 0, :, :] = base + 5.0 * t
        confidence[t, 0, :] = 0.85

        # Animal 1: present frames 0-3
        if t <= 3:
            points[t, 1, :, :] = base + 5.0 * t + 200.0
            confidence[t, 1, :] = 0.85

        # Animal 2: present frames 0, 2, 4
        if t % 2 == 0:
            points[t, 2, :, :] = base + 5.0 * t + 400.0
            confidence[t, 2, :] = 0.85

        # Count valid animals this frame
        count = 1  # animal 0 always
        if t <= 3:
            count += 1
        if t % 2 == 0:
            count += 1
        instance_count[t] = count

    with h5py.File(path, "w") as f:
        f.attrs["num_frames"] = T
        f.attrs["num_animals"] = N
        dt = h5py.string_dtype()
        f.attrs.create("node_names", data=JABS_NODE_NAMES, dtype=dt)

        grp = f.create_group("poseest")
        grp.create_dataset("points", data=points)
        grp.create_dataset("confidence", data=confidence)
        grp.create_dataset("instance_count", data=instance_count)

    _write_expected(outdir / "jabs_multi_animal_expected.json", {
        "frame_count": T,
        "animal_count": N,
        "node_count": K,
        "node_names": JABS_NODE_NAMES,
        "has_node_names": True,
        "confidence_value": 0.85,
        "animal0_present_frames": [0, 1, 2, 3, 4],
        "animal1_present_frames": [0, 1, 2, 3],
        "animal1_absent_frames": [4],
        "animal2_present_frames": [0, 2, 4],
        "animal2_absent_frames": [1, 3],
        "instance_counts": instance_count.tolist(),
    })


def generate_jabs_no_node_names():
    """jabs_no_node_names.h5 — 3 frames, 1 animal, 3 nodes, no node_names attr."""
    print("  Generating jabs_no_node_names.h5 ...")
    outdir = OUTPUT_DIR / "jabs_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "jabs_no_node_names.h5"

    T, N, K = 3, 1, 3
    base = np.array([[50.0, 60.0], [70.0, 80.0], [90.0, 100.0]], dtype=np.float32)

    points = np.zeros((T, N, K, 2), dtype=np.float32)
    confidence = np.full((T, N, K), 0.9, dtype=np.float32)

    for t in range(T):
        points[t, 0, :, :] = base + 5.0 * t

    with h5py.File(path, "w") as f:
        f.attrs["num_frames"] = T
        # Deliberately no node_names attribute

        grp = f.create_group("poseest")
        grp.create_dataset("points", data=points)
        grp.create_dataset("confidence", data=confidence)

    _write_expected(outdir / "jabs_no_node_names_expected.json", {
        "frame_count": T,
        "animal_count": N,
        "node_count": K,
        "has_node_names": False,
    })


def generate_jabs_malformed():
    """jabs_malformed.h5 — poseest/points is 2D instead of 4D."""
    print("  Generating jabs_malformed.h5 ...")
    outdir = OUTPUT_DIR / "jabs_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "jabs_malformed.h5"

    with h5py.File(path, "w") as f:
        f.attrs["num_frames"] = 3
        grp = f.create_group("poseest")
        # Wrong shape: 2D (T, 2) instead of 4D (T, N, K, 2)
        bad_points = np.zeros((3, 2), dtype=np.float32)
        grp.create_dataset("points", data=bad_points)

    _write_expected(outdir / "jabs_malformed_expected.json", {
        "error": "points_wrong_shape",
        "points_ndim": 2,
        "expected_ndim": 4,
    })


def generate_all_jabs():
    """Generate all JABS HDF5 fixtures."""
    print("Generating jabs_h5/ fixtures ...")
    generate_jabs_single_animal()
    generate_jabs_multi_animal()
    generate_jabs_no_node_names()
    generate_jabs_malformed()


# ===========================================================================
# 3. DeepLabCut H5
# ===========================================================================

def _try_pandas_dlc(outdir):
    """Try to generate DLC fixtures using pandas HDFStore (the canonical format).

    Returns True if successful, False if pandas/tables not available.
    """
    try:
        import pandas as pd
        # tables is needed for pd.HDFStore
        import tables  # noqa: F401
    except ImportError:
        return False

    # --- Single animal ---
    print("  Generating dlc_single_animal.h5 (pandas) ...")
    path = outdir / "dlc_single_animal.h5"

    T, K = 5, 3
    base_coords = np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]])

    # Build MultiIndex columns: (scorer, bodypart, coords)
    cols = pd.MultiIndex.from_tuples(
        [(DLC_SCORER, bp, c) for bp in DLC_BODYPARTS for c in ["x", "y", "likelihood"]],
        names=["scorer", "bodyparts", "coords"],
    )

    data = np.zeros((T, K * 3), dtype=np.float64)
    for t in range(T):
        for k in range(K):
            coords = base_coords[k] + 5.0 * t
            data[t, k * 3] = coords[0]      # x
            data[t, k * 3 + 1] = coords[1]  # y
            data[t, k * 3 + 2] = 0.95       # likelihood

    df = pd.DataFrame(data, columns=cols, index=range(T))
    df.to_hdf(str(path), key="df_with_missing", mode="w")

    _write_expected(outdir / "dlc_single_animal_expected.json", {
        "frame_count": T,
        "individual_count": 1,
        "bodypart_count": K,
        "bodyparts": DLC_BODYPARTS,
        "scorer": DLC_SCORER,
        "has_individuals": False,
        "likelihood_value": 0.95,
        "coords_frame0": base_coords.tolist(),
        "coords_frame4": (base_coords + 20.0).tolist(),
    })

    # --- Multi animal ---
    print("  Generating dlc_multi_animal.h5 (pandas) ...")
    path = outdir / "dlc_multi_animal.h5"

    individuals = ["mouse1", "mouse2"]
    N = len(individuals)

    cols = pd.MultiIndex.from_tuples(
        [
            (DLC_SCORER, ind, bp, c)
            for ind in individuals
            for bp in DLC_BODYPARTS
            for c in ["x", "y", "likelihood"]
        ],
        names=["scorer", "individuals", "bodyparts", "coords"],
    )

    data = np.zeros((T, N * K * 3), dtype=np.float64)
    for t in range(T):
        for n_idx, ind in enumerate(individuals):
            offset = n_idx * K * 3
            for k in range(K):
                coords = base_coords[k] + 5.0 * t + 200.0 * n_idx
                col_base = offset + k * 3

                # mouse2 absent at frames 3, 4
                if n_idx == 1 and t >= 3:
                    data[t, col_base] = np.nan
                    data[t, col_base + 1] = np.nan
                    data[t, col_base + 2] = np.nan
                else:
                    data[t, col_base] = coords[0]
                    data[t, col_base + 1] = coords[1]
                    data[t, col_base + 2] = 0.95

    df = pd.DataFrame(data, columns=cols, index=range(T))
    df.to_hdf(str(path), key="df_with_missing", mode="w")

    _write_expected(outdir / "dlc_multi_animal_expected.json", {
        "frame_count": T,
        "individual_count": N,
        "bodypart_count": K,
        "bodyparts": DLC_BODYPARTS,
        "individuals": individuals,
        "scorer": DLC_SCORER,
        "has_individuals": True,
        "likelihood_value": 0.95,
        "mouse2_absent_frames": [3, 4],
        "mouse2_present_frames": [0, 1, 2],
    })

    return True


def _h5py_only_dlc(outdir):
    """Fallback: generate DLC fixtures using h5py only (simplified fixed format).

    Creates the 'fixed' format variant that stores a simple 2D array
    with column metadata as attributes on the group.
    """
    T, K = 5, 3
    base_coords = np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]])

    # --- Single animal ---
    print("  Generating dlc_single_animal.h5 (h5py-only fallback) ...")
    path = outdir / "dlc_single_animal.h5"

    data = np.zeros((T, K * 3), dtype=np.float64)
    for t in range(T):
        for k in range(K):
            coords = base_coords[k] + 5.0 * t
            data[t, k * 3] = coords[0]
            data[t, k * 3 + 1] = coords[1]
            data[t, k * 3 + 2] = 0.95

    with h5py.File(path, "w") as f:
        grp = f.create_group("df_with_missing")
        # Store as fixed-format: block0_values + metadata
        grp.create_dataset("block0_values", data=data)
        grp.create_dataset("axis0", data=np.arange(T, dtype=np.int64))

        # Column labels as structured metadata
        dt = h5py.string_dtype()
        col_labels = [
            f"{DLC_SCORER}/{bp}/{c}"
            for bp in DLC_BODYPARTS
            for c in ["x", "y", "likelihood"]
        ]
        grp.create_dataset("block0_items", data=col_labels, dtype=dt)
        grp.attrs["scorer"] = DLC_SCORER
        grp.attrs.create("bodyparts", data=DLC_BODYPARTS, dtype=dt)
        grp.attrs["format"] = "fixed_h5py"

    _write_expected(outdir / "dlc_single_animal_expected.json", {
        "frame_count": T,
        "individual_count": 1,
        "bodypart_count": K,
        "bodyparts": DLC_BODYPARTS,
        "scorer": DLC_SCORER,
        "has_individuals": False,
        "likelihood_value": 0.95,
        "coords_frame0": base_coords.tolist(),
        "coords_frame4": (base_coords + 20.0).tolist(),
        "format_note": "h5py-only fallback, not canonical pandas HDFStore",
    })

    # --- Multi animal ---
    print("  Generating dlc_multi_animal.h5 (h5py-only fallback) ...")
    path = outdir / "dlc_multi_animal.h5"

    individuals = ["mouse1", "mouse2"]
    N = len(individuals)

    data = np.zeros((T, N * K * 3), dtype=np.float64)
    for t in range(T):
        for n_idx in range(N):
            offset = n_idx * K * 3
            for k in range(K):
                coords = base_coords[k] + 5.0 * t + 200.0 * n_idx
                col_base = offset + k * 3
                if n_idx == 1 and t >= 3:
                    data[t, col_base] = np.nan
                    data[t, col_base + 1] = np.nan
                    data[t, col_base + 2] = np.nan
                else:
                    data[t, col_base] = coords[0]
                    data[t, col_base + 1] = coords[1]
                    data[t, col_base + 2] = 0.95

    with h5py.File(path, "w") as f:
        grp = f.create_group("df_with_missing")
        grp.create_dataset("block0_values", data=data)
        grp.create_dataset("axis0", data=np.arange(T, dtype=np.int64))

        dt = h5py.string_dtype()
        col_labels = [
            f"{DLC_SCORER}/{ind}/{bp}/{c}"
            for ind in individuals
            for bp in DLC_BODYPARTS
            for c in ["x", "y", "likelihood"]
        ]
        grp.create_dataset("block0_items", data=col_labels, dtype=dt)
        grp.attrs["scorer"] = DLC_SCORER
        grp.attrs.create("bodyparts", data=DLC_BODYPARTS, dtype=dt)
        grp.attrs.create("individuals", data=individuals, dtype=dt)
        grp.attrs["format"] = "fixed_h5py"

    _write_expected(outdir / "dlc_multi_animal_expected.json", {
        "frame_count": T,
        "individual_count": N,
        "bodypart_count": K,
        "bodyparts": DLC_BODYPARTS,
        "individuals": individuals,
        "scorer": DLC_SCORER,
        "has_individuals": True,
        "likelihood_value": 0.95,
        "mouse2_absent_frames": [3, 4],
        "mouse2_present_frames": [0, 1, 2],
        "format_note": "h5py-only fallback, not canonical pandas HDFStore",
    })


def generate_dlc_unsupported():
    """dlc_unsupported.h5 — has df_with_missing but wrong internal structure."""
    print("  Generating dlc_unsupported.h5 ...")
    outdir = OUTPUT_DIR / "dlc_h5"
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "dlc_unsupported.h5"

    with h5py.File(path, "w") as f:
        grp = f.create_group("df_with_missing")
        # Just a scalar dataset, no block0_values or table — totally wrong
        grp.create_dataset("garbage", data=42)

    _write_expected(outdir / "dlc_unsupported_expected.json", {
        "error": "unsupported_format",
    })


def generate_all_dlc():
    """Generate all DLC HDF5 fixtures."""
    print("Generating dlc_h5/ fixtures ...")
    outdir = OUTPUT_DIR / "dlc_h5"
    outdir.mkdir(parents=True, exist_ok=True)

    used_pandas = _try_pandas_dlc(outdir)
    if not used_pandas:
        print("  (pandas/tables not available, using h5py-only fallback)")
        _h5py_only_dlc(outdir)

    generate_dlc_unsupported()


# ===========================================================================
# 4. CLI Smoke
# ===========================================================================

def generate_cli_smoke():
    """Small analysis H5 for CLI integration testing — same as analysis_minimal."""
    print("Generating cli_smoke/ fixtures ...")
    outdir = OUTPUT_DIR / "cli_smoke"
    outdir.mkdir(parents=True, exist_ok=True)

    # Create a small analysis file inline (don't depend on analysis fixtures existing)
    path = outdir / "cli_test.h5"

    T, N, K = 3, 2, 3
    coords_t0 = _analysis_coords_track0()
    coords_t1 = _analysis_coords_track1()

    locations = np.zeros((T, N, K, 2), dtype=np.float64)
    locations[:, 0, :, :] = coords_t0
    locations[:, 1, :, :] = coords_t1

    track_occupancy = np.ones((T, N), dtype=bool)

    with h5py.File(path, "w") as f:
        f.attrs["video_path"] = "test_video.mp4"
        f.attrs["labels_path"] = "test_labels.slp"

        dt = h5py.string_dtype()
        f.create_dataset("tracks", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("track_names", data=ANALYSIS_TRACK_NAMES, dtype=dt)
        f.create_dataset("node_names", data=ANALYSIS_NODE_NAMES, dtype=dt)
        f.create_dataset("track_occupancy", data=track_occupancy)
        f.create_dataset("locations", data=locations)
        f.create_dataset("edge_names", data=ANALYSIS_EDGE_NAMES, dtype=dt)
        f.create_dataset("edge_inds", data=np.array(ANALYSIS_EDGE_INDS, dtype=np.int64))

        # Also add scores for CLI summary testing
        f.create_dataset("point_scores", data=np.full((T, N, K), 0.9, dtype=np.float64))
        f.create_dataset("instance_scores", data=np.full((T, N), 0.85, dtype=np.float64))

    _write_expected(outdir / "cli_test_expected.json", {
        "frame_count": T,
        "track_count": N,
        "node_count": K,
        "track_names": ANALYSIS_TRACK_NAMES,
        "node_names": ANALYSIS_NODE_NAMES,
        "video_path": "test_video.mp4",
        "labels_path": "test_labels.slp",
    })


# ===========================================================================
# Main
# ===========================================================================

def main():
    """Generate all Phase 4 fixture files."""
    print(f"Output directory: {OUTPUT_DIR}")
    print()

    # Clean and recreate
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    generate_all_analysis()
    print()
    generate_all_jabs()
    print()
    generate_all_dlc()
    print()
    generate_cli_smoke()
    print()

    # Print summary
    print("=" * 60)
    print("All Phase 4 fixtures generated successfully!")
    print("=" * 60)
    print()

    for dirpath, dirnames, filenames in sorted(os.walk(OUTPUT_DIR)):
        level = dirpath.replace(str(OUTPUT_DIR), "").count(os.sep)
        indent = "  " * level
        dirname = os.path.basename(dirpath) or "phase4/"
        print(f"{indent}{dirname}/")
        subindent = "  " * (level + 1)
        for fname in sorted(filenames):
            fpath = Path(dirpath) / fname
            size = fpath.stat().st_size
            if size >= 1024:
                size_str = f"{size / 1024:.1f} KB"
            else:
                size_str = f"{size} B"
            print(f"{subindent}{fname:45s} {size_str:>10s}")


if __name__ == "__main__":
    main()
