#!/usr/bin/env python3
"""Generate test fixture files for sleap-io.swift Phase 3 interchange codec tests.

Requirements:
    uv run --with sleap-io --with h5py --with Pillow python3 Tests/Fixtures/generate_phase3_fixtures.py

This generates 8 fixture families in Tests/Fixtures/phase3/:
    1. coco_single_skeleton      — COCO JSON, 1 category, visibility mix
    2. coco_multi_category       — COCO JSON, 2 categories (different skeletons)
    3. coco_predictions          — COCO JSON with annotation scores
    4. csv_multi_instance        — Canonical CSV, multiple instances per frame
    5. csv_predicted_scores      — CSV with prediction columns
    6. labelstudio_keypoints     — Label Studio JSON, percentage coords
    7. yolo_pose_single_class    — YOLO pose directory structure
    8. alphatracker_sample       — AlphaTracker JSON
"""

import json
import os
from pathlib import Path

import numpy as np

try:
    import sleap_io as sio
except ImportError:
    raise ImportError(
        "sleap-io is required: "
        "uv run --with sleap-io --with h5py --with Pillow python3 "
        "Tests/Fixtures/generate_phase3_fixtures.py"
    )

OUTPUT_DIR = Path(__file__).parent / "phase3"

# ---------------------------------------------------------------------------
# Shared skeleton definitions
# ---------------------------------------------------------------------------

# "fly": 3 nodes, 2 edges
FLY_NODE_NAMES = ["head", "thorax", "abdomen"]
FLY_EDGES = [(0, 1), (1, 2)]  # head-thorax, thorax-abdomen

# "mouse": 5 nodes, 4 edges
MOUSE_NODE_NAMES = ["nose", "left_ear", "right_ear", "neck", "tail_base"]
MOUSE_EDGES = [(0, 3), (1, 3), (2, 3), (3, 4)]  # nose-neck, ears-neck, neck-tail


def make_fly_skeleton():
    nodes = [sio.Node(name=n) for n in FLY_NODE_NAMES]
    edges = [sio.Edge(source=nodes[s], destination=nodes[d]) for s, d in FLY_EDGES]
    return sio.Skeleton(name="fly", nodes=nodes, edges=edges)


def make_mouse_skeleton():
    nodes = [sio.Node(name=n) for n in MOUSE_NODE_NAMES]
    edges = [sio.Edge(source=nodes[s], destination=nodes[d]) for s, d in MOUSE_EDGES]
    return sio.Skeleton(name="mouse", nodes=nodes, edges=edges)


# ---------------------------------------------------------------------------
# Memorable coordinate sets (deterministic, easy to verify in Swift tests)
# ---------------------------------------------------------------------------

# fly coords: 3 nodes per instance
FLY_COORDS = [
    # instance 0
    np.array([[100.0, 200.0], [150.0, 250.0], [200.0, 300.0]]),
    # instance 1
    np.array([[110.0, 210.0], [160.0, 260.0], [210.0, 310.0]]),
    # instance 2
    np.array([[120.0, 220.0], [170.0, 270.0], [220.0, 320.0]]),
]

# mouse coords: 5 nodes per instance
MOUSE_COORDS = [
    # instance 0
    np.array([[50.0, 60.0], [40.0, 50.0], [60.0, 50.0], [50.0, 80.0], [50.0, 150.0]]),
    # instance 1
    np.array([[300.0, 100.0], [290.0, 90.0], [310.0, 90.0], [300.0, 120.0], [300.0, 200.0]]),
]

# Image dimensions used across fixtures
IMG_W, IMG_H = 640, 480


def _ptp(arr):
    """Replacement for deprecated np.ptp: max - min along axis."""
    return float(arr.max() - arr.min())


def _bbox(pts):
    """Compute [x_min, y_min, width, height] from (N, 2) points."""
    return [float(pts[:, 0].min()), float(pts[:, 1].min()),
            _ptp(pts[:, 0]), _ptp(pts[:, 1])]


def _area(pts):
    """Compute width * height from (N, 2) points."""
    return _ptp(pts[:, 0]) * _ptp(pts[:, 1])


# ===========================================================================
# 1. coco_single_skeleton
# ===========================================================================

def generate_coco_single_skeleton():
    """COCO JSON with 1 category (fly), 3 images, visibility mix."""
    print("Generating coco_single_skeleton ...")
    outdir = OUTPUT_DIR / "coco_single_skeleton"
    outdir.mkdir(parents=True, exist_ok=True)

    # Build COCO dict manually for full control over visibility values.
    category = {
        "id": 1,
        "name": "fly",
        "supercategory": "insect",
        "keypoints": FLY_NODE_NAMES,
        # COCO skeleton uses 1-based indices
        "skeleton": [[s + 1, d + 1] for s, d in FLY_EDGES],
    }

    images = [
        {"id": 1, "file_name": "img_000.png", "width": IMG_W, "height": IMG_H},
        {"id": 2, "file_name": "img_001.png", "width": IMG_W, "height": IMG_H},
        {"id": 3, "file_name": "img_002.png", "width": IMG_W, "height": IMG_H},
    ]

    annotations = []
    ann_id = 1

    # Image 1: 2 annotations, all visible (v=2)
    for inst_idx in range(2):
        pts = FLY_COORDS[inst_idx]
        kp = []
        for x, y in pts:
            kp.extend([float(x), float(y), 2])  # v=2 visible
        annotations.append({
            "id": ann_id,
            "image_id": 1,
            "category_id": 1,
            "keypoints": kp,
            "num_keypoints": 3,
            "bbox": _bbox(pts),
            "area": _area(pts),
            "iscrowd": 0,
        })
        ann_id += 1

    # Image 2: 1 annotation with mixed visibility
    # node 0: v=0 (not labeled), node 1: v=1 (occluded), node 2: v=2 (visible)
    pts = FLY_COORDS[2]
    kp = [
        0.0, 0.0, 0,                          # v=0: unlabeled
        float(pts[1][0]), float(pts[1][1]), 1, # v=1: occluded
        float(pts[2][0]), float(pts[2][1]), 2, # v=2: visible
    ]
    annotations.append({
        "id": ann_id,
        "image_id": 2,
        "category_id": 1,
        "keypoints": kp,
        "num_keypoints": 2,  # v>0 count
        "bbox": _bbox(pts[1:]),
        "area": _area(pts[1:]),
        "iscrowd": 0,
    })
    ann_id += 1

    # Image 3: 1 annotation, all visible
    pts = FLY_COORDS[0]
    kp = []
    for x, y in pts:
        kp.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id,
        "image_id": 3,
        "category_id": 1,
        "keypoints": kp,
        "num_keypoints": 3,
        "bbox": _bbox(pts),
        "area": _area(pts),
        "iscrowd": 0,
    })

    coco = {
        "images": images,
        "annotations": annotations,
        "categories": [category],
    }

    with open(outdir / "annotations.json", "w") as f:
        json.dump(coco, f, indent=2)

    # Malformed variant: wrong keypoints array length (only 2 values instead of 9)
    bad_coco = {
        "images": [images[0]],
        "annotations": [{
            "id": 1,
            "image_id": 1,
            "category_id": 1,
            "keypoints": [100.0, 200.0],  # should be 3*3=9 values
            "num_keypoints": 1,
            "bbox": [100, 200, 0, 0],
            "area": 0,
            "iscrowd": 0,
        }],
        "categories": [category],
    }
    with open(outdir / "malformed_keypoints.json", "w") as f:
        json.dump(bad_coco, f, indent=2)

    print(f"  -> annotations.json: 3 images, 4 annotations, 1 category")
    print(f"  -> malformed_keypoints.json: wrong keypoints length")


# ===========================================================================
# 2. coco_multi_category
# ===========================================================================

def generate_coco_multi_category():
    """COCO JSON with 2 categories (fly + mouse), mixed annotations."""
    print("Generating coco_multi_category ...")
    outdir = OUTPUT_DIR / "coco_multi_category"
    outdir.mkdir(parents=True, exist_ok=True)

    categories = [
        {
            "id": 1,
            "name": "fly",
            "supercategory": "insect",
            "keypoints": FLY_NODE_NAMES,
            "skeleton": [[s + 1, d + 1] for s, d in FLY_EDGES],
        },
        {
            "id": 2,
            "name": "mouse",
            "supercategory": "rodent",
            "keypoints": MOUSE_NODE_NAMES,
            "skeleton": [[s + 1, d + 1] for s, d in MOUSE_EDGES],
        },
    ]

    images = [
        {"id": 1, "file_name": "mixed_000.png", "width": IMG_W, "height": IMG_H},
        {"id": 2, "file_name": "mixed_001.png", "width": IMG_W, "height": IMG_H},
    ]

    annotations = []
    ann_id = 1

    # Image 1: one fly, one mouse
    fly_pts = FLY_COORDS[0]
    kp_fly = []
    for x, y in fly_pts:
        kp_fly.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id, "image_id": 1, "category_id": 1,
        "keypoints": kp_fly, "num_keypoints": 3,
        "bbox": [100, 200, 100, 100], "area": 10000, "iscrowd": 0,
    })
    ann_id += 1

    mouse_pts = MOUSE_COORDS[0]
    kp_mouse = []
    for x, y in mouse_pts:
        kp_mouse.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id, "image_id": 1, "category_id": 2,
        "keypoints": kp_mouse, "num_keypoints": 5,
        "bbox": [40, 50, 20, 100], "area": 2000, "iscrowd": 0,
    })
    ann_id += 1

    # Image 2: two mice
    for inst_idx in range(2):
        pts = MOUSE_COORDS[inst_idx]
        kp = []
        for x, y in pts:
            kp.extend([float(x), float(y), 2])
        annotations.append({
            "id": ann_id, "image_id": 2, "category_id": 2,
            "keypoints": kp, "num_keypoints": 5,
            "bbox": _bbox(pts),
            "area": _area(pts),
            "iscrowd": 0,
        })
        ann_id += 1

    coco = {
        "images": images,
        "annotations": annotations,
        "categories": categories,
    }
    with open(outdir / "annotations.json", "w") as f:
        json.dump(coco, f, indent=2)

    # Malformed: annotation references nonexistent category_id
    bad_coco = {
        "images": [images[0]],
        "annotations": [{
            "id": 1, "image_id": 1, "category_id": 999,
            "keypoints": [100, 200, 2, 150, 250, 2, 200, 300, 2],
            "num_keypoints": 3,
            "bbox": [100, 200, 100, 100], "area": 10000, "iscrowd": 0,
        }],
        "categories": categories,
    }
    with open(outdir / "missing_category.json", "w") as f:
        json.dump(bad_coco, f, indent=2)

    print(f"  -> annotations.json: 2 images, 4 annotations, 2 categories")
    print(f"  -> missing_category.json: invalid category_id reference")


# ===========================================================================
# 3. coco_predictions
# ===========================================================================

def generate_coco_predictions():
    """COCO JSON with annotations that have score fields (predictions)."""
    print("Generating coco_predictions ...")
    outdir = OUTPUT_DIR / "coco_predictions"
    outdir.mkdir(parents=True, exist_ok=True)

    category = {
        "id": 1,
        "name": "fly",
        "supercategory": "insect",
        "keypoints": FLY_NODE_NAMES,
        "skeleton": [[s + 1, d + 1] for s, d in FLY_EDGES],
    }

    images = [
        {"id": 1, "file_name": "pred_000.png", "width": IMG_W, "height": IMG_H},
        {"id": 2, "file_name": "pred_001.png", "width": IMG_W, "height": IMG_H},
    ]

    annotations = []
    ann_id = 1

    # Image 1: annotation WITH score (predicted)
    pts = FLY_COORDS[0]
    kp = []
    for x, y in pts:
        kp.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id, "image_id": 1, "category_id": 1,
        "keypoints": kp, "num_keypoints": 3,
        "score": 0.95,
        "bbox": [100, 200, 100, 100], "area": 10000, "iscrowd": 0,
    })
    ann_id += 1

    # Image 1: annotation WITHOUT score (user instance)
    pts = FLY_COORDS[1]
    kp = []
    for x, y in pts:
        kp.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id, "image_id": 1, "category_id": 1,
        "keypoints": kp, "num_keypoints": 3,
        # no score field
        "bbox": [110, 210, 100, 100], "area": 10000, "iscrowd": 0,
    })
    ann_id += 1

    # Image 2: annotation WITH score
    pts = FLY_COORDS[2]
    kp = []
    for x, y in pts:
        kp.extend([float(x), float(y), 2])
    annotations.append({
        "id": ann_id, "image_id": 2, "category_id": 1,
        "keypoints": kp, "num_keypoints": 3,
        "score": 0.82,
        "bbox": [120, 220, 100, 100], "area": 10000, "iscrowd": 0,
    })

    coco = {
        "images": images,
        "annotations": annotations,
        "categories": [category],
    }
    with open(outdir / "predictions.json", "w") as f:
        json.dump(coco, f, indent=2)

    print(f"  -> predictions.json: 2 images, 3 annotations (2 with score, 1 without)")


# ===========================================================================
# 4. csv_multi_instance
# ===========================================================================

def generate_csv_multi_instance():
    """Canonical CSV with multiple instances per frame."""
    print("Generating csv_multi_instance ...")
    outdir = OUTPUT_DIR / "csv_multi_instance"
    outdir.mkdir(parents=True, exist_ok=True)

    # Build CSV manually for canonical sleap-io.swift format
    header = "video,frame_idx,skeleton,instance,node,x,y,visible"
    rows = [header]

    video = "video1.mp4"
    skeleton = "fly"

    # Frame 0: 2 instances
    for inst_idx in range(2):
        pts = FLY_COORDS[inst_idx]
        for node_idx, node_name in enumerate(FLY_NODE_NAMES):
            x, y = pts[node_idx]
            rows.append(f"{video},0,{skeleton},{inst_idx},{node_name},{x},{y},true")

    # Frame 5: 1 instance with one invisible node
    pts = FLY_COORDS[2]
    rows.append(f"{video},5,{skeleton},0,head,{pts[0][0]},{pts[0][1]},true")
    rows.append(f"{video},5,{skeleton},0,thorax,{pts[1][0]},{pts[1][1]},false")
    rows.append(f"{video},5,{skeleton},0,abdomen,{pts[2][0]},{pts[2][1]},true")

    # Frame 10: 1 instance, all visible
    pts = FLY_COORDS[0]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x, y = pts[node_idx]
        rows.append(f"{video},10,{skeleton},0,{node_name},{x},{y},true")

    with open(outdir / "multi_instance.csv", "w") as f:
        f.write("\n".join(rows) + "\n")

    # Malformed: missing required 'visible' column
    bad_header = "video,frame_idx,skeleton,instance,node,x,y"
    bad_rows = [bad_header]
    bad_rows.append(f"{video},0,{skeleton},0,head,100.0,200.0")
    with open(outdir / "missing_column.csv", "w") as f:
        f.write("\n".join(bad_rows) + "\n")

    print(f"  -> multi_instance.csv: 1 video, 3 frames, 4 instances total")
    print(f"  -> missing_column.csv: missing 'visible' column")


# ===========================================================================
# 5. csv_predicted_scores
# ===========================================================================

def generate_csv_predicted_scores():
    """CSV with prediction columns: instance_type, scores, tracks."""
    print("Generating csv_predicted_scores ...")
    outdir = OUTPUT_DIR / "csv_predicted_scores"
    outdir.mkdir(parents=True, exist_ok=True)

    header = ("video,frame_idx,skeleton,instance,node,x,y,visible,"
              "complete,instance_type,instance_score,point_score,tracking_score,track")
    rows = [header]

    video = "video1.mp4"
    skeleton = "fly"

    # Frame 0, instance 0: user instance with track
    pts = FLY_COORDS[0]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x, y = pts[node_idx]
        rows.append(
            f"{video},0,{skeleton},0,{node_name},{x},{y},true,true,"
            f"user,,,0.0,track_A"
        )

    # Frame 0, instance 1: predicted instance with scores and track
    pts = FLY_COORDS[1]
    point_scores = [0.99, 0.85, 0.92]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x, y = pts[node_idx]
        ps = point_scores[node_idx]
        rows.append(
            f"{video},0,{skeleton},1,{node_name},{x},{y},true,true,"
            f"predicted,0.95,{ps},0.88,track_B"
        )

    # Frame 5, instance 0: predicted instance, no track
    pts = FLY_COORDS[2]
    point_scores = [0.70, 0.65, 0.80]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x, y = pts[node_idx]
        ps = point_scores[node_idx]
        rows.append(
            f"{video},5,{skeleton},0,{node_name},{x},{y},true,true,"
            f"predicted,0.82,{ps},0.0,"
        )

    # Frame 5, instance 1: user instance, track_A again (shared track)
    pts = FLY_COORDS[0]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x, y = pts[node_idx]
        rows.append(
            f"{video},5,{skeleton},1,{node_name},{x},{y},true,true,"
            f"user,,,0.0,track_A"
        )

    with open(outdir / "predicted_scores.csv", "w") as f:
        f.write("\n".join(rows) + "\n")

    print(f"  -> predicted_scores.csv: 1 video, 2 frames, 4 instances "
          f"(2 user, 2 predicted), 2 tracks")


# ===========================================================================
# 6. labelstudio_keypoints
# ===========================================================================

def generate_labelstudio_keypoints():
    """Label Studio JSON with image tasks, keypoint results, percentage coords."""
    print("Generating labelstudio_keypoints ...")
    outdir = OUTPUT_DIR / "labelstudio_keypoints"
    outdir.mkdir(parents=True, exist_ok=True)

    # Task 1: 2 instances (multi-animal with parentID grouping)
    task1_results = []

    # Instance 0: rectangle label + keypoints + relations
    inst0_id = "inst-0-uuid"
    task1_results.append({
        "original_width": IMG_W,
        "original_height": IMG_H,
        "image_rotation": 0,
        "value": {
            "x": 0, "y": 0,
            "width": IMG_W, "height": IMG_H,
            "rotation": 0,
            "rectanglelabels": ["instance_class"],
        },
        "id": inst0_id,
        "from_name": "individuals",
        "to_name": "image",
        "type": "rectanglelabels",
    })

    pts0 = FLY_COORDS[0]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x_abs, y_abs = pts0[node_idx]
        x_pct = x_abs / IMG_W * 100
        y_pct = y_abs / IMG_H * 100
        kp_id = f"kp-0-{node_idx}-uuid"
        task1_results.append({
            "original_width": IMG_W,
            "original_height": IMG_H,
            "image_rotation": 0,
            "value": {
                "x": x_pct,
                "y": y_pct,
                "keypointlabels": [node_name],
            },
            "from_name": "keypoint-label",
            "to_name": "image",
            "type": "keypointlabels",
            "id": kp_id,
        })
        # Relation linking keypoint to instance
        task1_results.append({
            "from_id": kp_id,
            "to_id": inst0_id,
            "type": "relation",
            "direction": "right",
        })

    # Instance 1: rectangle label + keypoints + relations
    inst1_id = "inst-1-uuid"
    task1_results.append({
        "original_width": IMG_W,
        "original_height": IMG_H,
        "image_rotation": 0,
        "value": {
            "x": 0, "y": 0,
            "width": IMG_W, "height": IMG_H,
            "rotation": 0,
            "rectanglelabels": ["instance_class"],
        },
        "id": inst1_id,
        "from_name": "individuals",
        "to_name": "image",
        "type": "rectanglelabels",
    })

    pts1 = FLY_COORDS[1]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x_abs, y_abs = pts1[node_idx]
        x_pct = x_abs / IMG_W * 100
        y_pct = y_abs / IMG_H * 100
        kp_id = f"kp-1-{node_idx}-uuid"
        task1_results.append({
            "original_width": IMG_W,
            "original_height": IMG_H,
            "image_rotation": 0,
            "value": {
                "x": x_pct,
                "y": y_pct,
                "keypointlabels": [node_name],
            },
            "from_name": "keypoint-label",
            "to_name": "image",
            "type": "keypointlabels",
            "id": kp_id,
        })
        task1_results.append({
            "from_id": kp_id,
            "to_id": inst1_id,
            "type": "relation",
            "direction": "right",
        })

    task1 = {
        "id": 1,
        "data": {"image": "img_000.png"},
        "meta": {
            "video": {
                "filename": "img_000.png",
                "frame_idx": 0,
                "shape": [1, IMG_H, IMG_W, 3],
            }
        },
        "annotations": [{
            "result": task1_results,
            "was_cancelled": False,
            "ground_truth": False,
        }],
    }

    # Task 2: 1 instance (single-animal, no rectangle labels)
    task2_results = []
    pts2 = FLY_COORDS[2]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x_abs, y_abs = pts2[node_idx]
        x_pct = x_abs / IMG_W * 100
        y_pct = y_abs / IMG_H * 100
        task2_results.append({
            "original_width": IMG_W,
            "original_height": IMG_H,
            "image_rotation": 0,
            "value": {
                "x": x_pct,
                "y": y_pct,
                "keypointlabels": [node_name],
            },
            "from_name": "keypoint-label",
            "to_name": "image",
            "type": "keypointlabels",
            "id": f"kp-2-{node_idx}-uuid",
        })

    task2 = {
        "id": 2,
        "data": {"image": "img_001.png"},
        "meta": {
            "video": {
                "filename": "img_001.png",
                "frame_idx": 0,
                "shape": [1, IMG_H, IMG_W, 3],
            }
        },
        "annotations": [{
            "result": task2_results,
            "was_cancelled": False,
            "ground_truth": False,
        }],
    }

    # Task 3: has predictions section (for PredictedInstance import)
    task3_results = []
    pts3 = FLY_COORDS[0]
    for node_idx, node_name in enumerate(FLY_NODE_NAMES):
        x_abs, y_abs = pts3[node_idx]
        x_pct = x_abs / IMG_W * 100
        y_pct = y_abs / IMG_H * 100
        task3_results.append({
            "original_width": IMG_W,
            "original_height": IMG_H,
            "image_rotation": 0,
            "value": {
                "x": x_pct,
                "y": y_pct,
                "keypointlabels": [node_name],
            },
            "from_name": "keypoint-label",
            "to_name": "image",
            "type": "keypointlabels",
            "id": f"kp-pred-{node_idx}-uuid",
        })

    task3 = {
        "id": 3,
        "data": {"image": "img_002.png"},
        "meta": {
            "video": {
                "filename": "img_002.png",
                "frame_idx": 0,
                "shape": [1, IMG_H, IMG_W, 3],
            }
        },
        "annotations": [{
            "result": [],
            "was_cancelled": False,
            "ground_truth": False,
        }],
        "predictions": [{
            "result": task3_results,
            "score": 0.91,
        }],
    }

    tasks = [task1, task2, task3]
    with open(outdir / "keypoints.json", "w") as f:
        json.dump(tasks, f, indent=2)

    # Malformed: missing original_width in keypoint result
    bad_task = {
        "id": 99,
        "data": {"image": "bad.png"},
        "meta": {
            "video": {
                "filename": "bad.png",
                "frame_idx": 0,
                "shape": [1, IMG_H, IMG_W, 3],
            }
        },
        "annotations": [{
            "result": [{
                # Missing original_width and original_height
                "image_rotation": 0,
                "value": {
                    "x": 50.0,
                    "y": 50.0,
                    "keypointlabels": ["head"],
                },
                "from_name": "keypoint-label",
                "to_name": "image",
                "type": "keypointlabels",
                "id": "bad-kp-uuid",
            }],
            "was_cancelled": False,
            "ground_truth": False,
        }],
    }
    with open(outdir / "missing_dimensions.json", "w") as f:
        json.dump([bad_task], f, indent=2)

    print(f"  -> keypoints.json: 3 tasks (2 annotation, 1 prediction), "
          f"4 instances total")
    print(f"  -> missing_dimensions.json: missing original_width/height")


# ===========================================================================
# 7. yolo_pose_single_class
# ===========================================================================

def generate_yolo_pose_single_class():
    """YOLO pose dataset directory structure with single class."""
    print("Generating yolo_pose_single_class ...")
    outdir = OUTPUT_DIR / "yolo_pose_single_class"

    # Clean up old structure if present
    import shutil
    if outdir.exists():
        shutil.rmtree(outdir)

    # Create directory structure
    images_dir = outdir / "images" / "train"
    labels_dir = outdir / "labels" / "train"
    images_dir.mkdir(parents=True, exist_ok=True)
    labels_dir.mkdir(parents=True, exist_ok=True)

    # dataset.yaml
    dataset_yaml = {
        "path": ".",
        "train": "images/train",
        "val": "images/train",  # reuse for simplicity
        "names": {0: "fly"},
        "kpt_shape": [3, 3],  # 3 nodes, 3 values per node (x, y, visibility)
    }
    # Write YAML manually to avoid pyyaml dependency
    yaml_lines = [
        f"path: .",
        f"train: images/train",
        f"val: images/train",
        f"names:",
        f"  0: fly",
        f"kpt_shape: [3, 3]",
    ]
    with open(outdir / "dataset.yaml", "w") as f:
        f.write("\n".join(yaml_lines) + "\n")

    # Create small placeholder images (1x1 PNG) just so files exist
    from PIL import Image
    for i in range(3):
        img = Image.new("RGB", (IMG_W, IMG_H), color=(128, 128, 128))
        img.save(images_dir / f"img_{i:03d}.png")

    # Label files: YOLO format
    # class_id center_x center_y width height kp0_x kp0_y kp0_v kp1_x kp1_y kp1_v ...
    # All coords normalized to [0, 1]

    # img_000: 2 instances
    lines = []
    for inst_idx in range(2):
        pts = FLY_COORDS[inst_idx]
        # Compute bbox from points
        x_min = pts[:, 0].min()
        x_max = pts[:, 0].max()
        y_min = pts[:, 1].min()
        y_max = pts[:, 1].max()
        cx = (x_min + x_max) / 2 / IMG_W
        cy = (y_min + y_max) / 2 / IMG_H
        w = (x_max - x_min) / IMG_W
        h = (y_max - y_min) / IMG_H

        parts = [f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}"]
        for x, y in pts:
            nx = x / IMG_W
            ny = y / IMG_H
            parts.append(f"{nx:.6f} {ny:.6f} 2")
        lines.append(" ".join(parts))
    with open(labels_dir / "img_000.txt", "w") as f:
        f.write("\n".join(lines) + "\n")

    # img_001: 1 instance with mixed visibility
    pts = FLY_COORDS[2]
    x_min = pts[:, 0].min()
    x_max = pts[:, 0].max()
    y_min = pts[:, 1].min()
    y_max = pts[:, 1].max()
    cx = (x_min + x_max) / 2 / IMG_W
    cy = (y_min + y_max) / 2 / IMG_H
    w = (x_max - x_min) / IMG_W
    h = (y_max - y_min) / IMG_H

    # node 0: not visible (v=0), node 1: visible (v=2), node 2: visible (v=2)
    parts = [f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}"]
    parts.append(f"0.000000 0.000000 0")  # not labeled
    parts.append(f"{pts[1][0]/IMG_W:.6f} {pts[1][1]/IMG_H:.6f} 2")
    parts.append(f"{pts[2][0]/IMG_W:.6f} {pts[2][1]/IMG_H:.6f} 2")
    with open(labels_dir / "img_001.txt", "w") as f:
        f.write(" ".join(parts) + "\n")

    # img_002: 1 instance, all visible
    pts = FLY_COORDS[0]
    x_min = pts[:, 0].min()
    x_max = pts[:, 0].max()
    y_min = pts[:, 1].min()
    y_max = pts[:, 1].max()
    cx = (x_min + x_max) / 2 / IMG_W
    cy = (y_min + y_max) / 2 / IMG_H
    w = (x_max - x_min) / IMG_W
    h = (y_max - y_min) / IMG_H
    parts = [f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}"]
    for x, y in pts:
        parts.append(f"{x/IMG_W:.6f} {y/IMG_H:.6f} 2")
    with open(labels_dir / "img_002.txt", "w") as f:
        f.write(" ".join(parts) + "\n")

    # Multi-class variant for rejection testing
    multiclass_dir = OUTPUT_DIR / "yolo_pose_multi_class"
    if multiclass_dir.exists():
        shutil.rmtree(multiclass_dir)
    mc_images = multiclass_dir / "images" / "train"
    mc_labels = multiclass_dir / "labels" / "train"
    mc_images.mkdir(parents=True, exist_ok=True)
    mc_labels.mkdir(parents=True, exist_ok=True)

    yaml_lines = [
        f"path: .",
        f"train: images/train",
        f"val: images/train",
        f"names:",
        f"  0: fly",
        f"  1: mouse",
        f"kpt_shape: [3, 3]",
    ]
    with open(multiclass_dir / "dataset.yaml", "w") as f:
        f.write("\n".join(yaml_lines) + "\n")

    # One image referencing two classes
    img = Image.new("RGB", (IMG_W, IMG_H), color=(128, 128, 128))
    img.save(mc_images / "multi.png")

    lines = [
        "0 0.5 0.5 0.2 0.2 0.15 0.42 2 0.23 0.52 2 0.31 0.63 2",
        "1 0.3 0.3 0.1 0.1 0.08 0.13 2 0.06 0.10 2 0.09 0.10 2",
    ]
    with open(mc_labels / "multi.txt", "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"  -> yolo_pose_single_class/: 3 images, 4 instances, dataset.yaml")
    print(f"  -> yolo_pose_multi_class/: multi-class for rejection testing")


# ===========================================================================
# 8. alphatracker_sample
# ===========================================================================

def generate_alphatracker_sample():
    """AlphaTracker JSON with Face + point annotations, animal IDs for tracks."""
    print("Generating alphatracker_sample ...")
    outdir = OUTPUT_DIR / "alphatracker_sample"
    outdir.mkdir(parents=True, exist_ok=True)

    # AlphaTracker format: array of frame objects, each with:
    #   filename, class: "image", annotations: [Face + point entries]
    frames = []

    # Frame 0: 2 animals, each with 3 keypoints
    frame0_anns = []
    # Animal 0
    pts0 = FLY_COORDS[0]
    frame0_anns.append({
        "class": "Face",
        "height": 50, "width": 50,
        "x": float(pts0[0][0] - 25), "y": float(pts0[0][1] - 25),
    })
    for node_idx in range(3):
        frame0_anns.append({
            "class": "point",
            "x": float(pts0[node_idx][0]),
            "y": float(pts0[node_idx][1]),
        })
    # Animal 1
    pts1 = FLY_COORDS[1]
    frame0_anns.append({
        "class": "Face",
        "height": 50, "width": 50,
        "x": float(pts1[0][0] - 25), "y": float(pts1[0][1] - 25),
    })
    for node_idx in range(3):
        frame0_anns.append({
            "class": "point",
            "x": float(pts1[node_idx][0]),
            "y": float(pts1[node_idx][1]),
        })

    frames.append({
        "filename": "frame_000.png",
        "class": "image",
        "annotations": frame0_anns,
    })

    # Frame 1: 1 animal, 3 keypoints
    frame1_anns = []
    pts2 = FLY_COORDS[2]
    frame1_anns.append({
        "class": "Face",
        "height": 50, "width": 50,
        "x": float(pts2[0][0] - 25), "y": float(pts2[0][1] - 25),
    })
    for node_idx in range(3):
        frame1_anns.append({
            "class": "point",
            "x": float(pts2[node_idx][0]),
            "y": float(pts2[node_idx][1]),
        })

    frames.append({
        "filename": "frame_001.png",
        "class": "image",
        "annotations": frame1_anns,
    })

    # Frame 2: 2 animals, 3 keypoints each (same positions as frame 0)
    frame2_anns = []
    for inst_idx in range(2):
        pts = FLY_COORDS[inst_idx]
        frame2_anns.append({
            "class": "Face",
            "height": 50, "width": 50,
            "x": float(pts[0][0] - 25), "y": float(pts[0][1] - 25),
        })
        for node_idx in range(3):
            frame2_anns.append({
                "class": "point",
                "x": float(pts[node_idx][0]),
                "y": float(pts[node_idx][1]),
            })

    frames.append({
        "filename": "frame_002.png",
        "class": "image",
        "annotations": frame2_anns,
    })

    with open(outdir / "annotations.json", "w") as f:
        json.dump(frames, f, indent=2)

    # Malformed variant: frame with no "annotations" key
    bad_frames = [
        {
            "filename": "bad.png",
            "class": "image",
            # missing "annotations" key entirely
        }
    ]
    with open(outdir / "malformed.json", "w") as f:
        json.dump(bad_frames, f, indent=2)

    # Unsupported variant: completely different schema
    unsupported = {"format": "unknown", "data": [1, 2, 3]}
    with open(outdir / "unsupported_schema.json", "w") as f:
        json.dump(unsupported, f, indent=2)

    print(f"  -> annotations.json: 3 frames, 5 instances (2+1+2), 3 nodes each")
    print(f"  -> malformed.json: missing annotations key")
    print(f"  -> unsupported_schema.json: wrong schema")


# ===========================================================================
# Main
# ===========================================================================

def main():
    """Generate all Phase 3 fixture files."""
    print(f"Output directory: {OUTPUT_DIR}")
    print()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    generate_coco_single_skeleton()
    print()
    generate_coco_multi_category()
    print()
    generate_coco_predictions()
    print()
    generate_csv_multi_instance()
    print()
    generate_csv_predicted_scores()
    print()
    generate_labelstudio_keypoints()
    print()
    generate_yolo_pose_single_class()
    print()
    generate_alphatracker_sample()
    print()

    # Print summary
    print("=" * 60)
    print("All Phase 3 fixtures generated successfully!")
    print("=" * 60)
    print()

    for dirpath, dirnames, filenames in sorted(os.walk(OUTPUT_DIR)):
        level = dirpath.replace(str(OUTPUT_DIR), "").count(os.sep)
        indent = "  " * level
        dirname = os.path.basename(dirpath) or "phase3/"
        print(f"{indent}{dirname}/")
        subindent = "  " * (level + 1)
        for fname in sorted(filenames):
            fpath = Path(dirpath) / fname
            size = fpath.stat().st_size
            if size >= 1024:
                size_str = f"{size / 1024:.1f} KB"
            else:
                size_str = f"{size} B"
            print(f"{subindent}{fname:40s} {size_str:>10s}")


if __name__ == "__main__":
    main()
