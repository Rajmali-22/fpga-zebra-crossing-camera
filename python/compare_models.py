#!/usr/bin/env python3
"""
Which weights should the camera system use? Every candidate is scored with
the bit-exact integer model of the FPGA on T1 (524 dashcam frames) and T2
(115 street photos), clean and under what a cheap camera does to a picture,
with and without the FPGA's auto-contrast (cam_golden.autocontrast).

    python python/compare_models.py
Writes docs/model_compare.json and prints a table.
"""

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
ZEBRA = ROOT.parent / "zebra-crossing-bcnn-fpga"
sys.path.insert(0, str(ROOT / "python"))
import robustness as R  # noqa: E402
from bcnn_model import int_forward, read_mem_files  # noqa: E402
from cam_golden import autocontrast, camera_input  # noqa: E402

CANDIDATES = [  # label, ROM folder, auto-contrast in front of the network
    ("v3 raw", ROOT / "mem", False),
    ("v3 stretch", ROOT / "mem", True),
    ("v3c raw", ZEBRA / "mem_CAMv3c_s42", False),
    ("v3c stretch", ZEBRA / "mem_CAMv3c_s42", True),
    ("v3cs stretch", ZEBRA / "mem_CAMv3cs_s42", True),
]


def camera_like(X, c=0.4):
    return np.clip((X.astype(float) - X.mean((1, 2), keepdims=True)) * c + 115, 0, 255).round().astype(np.uint8)


def lamp(X):
    Z = camera_like(X).copy()
    Z[:, 5:8, 70:73] = 255
    Z[:, 50:53, 5:8] = 0
    return Z


CONDITIONS = {
    "clean": lambda X, r: X,
    "contrast 0.6": lambda X, r: camera_like(X, 0.6),
    "camera-like 0.4": lambda X, r: camera_like(X, 0.4),
    "camera + lamp": lambda X, r: lamp(X),
    "gamma 0.6": R.TRANSFORMS["gamma 0.6"],
    "gamma 1.6": R.TRANSFORMS["gamma 1.6"],
    "brighter +40": R.TRANSFORMS["brighter +40"],
    "darker -40": R.TRANSFORMS["darker -40"],
    "blur 0.7 px": R.TRANSFORMS["blur 0.7 px"],
    "noise 4": R.TRANSFORMS["noise 4"],
}
CAMERA_CONDS = ["contrast 0.6", "camera-like 0.4", "camera + lamp", "gamma 0.6", "gamma 1.6",
                "brighter +40", "darker -40", "blur 0.7 px", "noise 4"]


def stretch(X):
    return np.stack([autocontrast(x)[0] for x in X])


def main():
    d = np.load(R.DATA)
    X, y, split, src = d["X80"], d["y"].astype(int), d["split"], d["source"]
    sets = {"T1": (split == 2) & (src == "cdset"), "T2": split == 3}
    raw = ROOT.parent / "soc" / "soc" / "plain" / "capture.raw"
    real = camera_input(np.frombuffer(raw.read_bytes(), ">u2").reshape(480, 640)) if raw.exists() else None

    results = {}
    for label, mem, st in CANDIDATES:
        if not (mem / "bcnn_weights.mem").exists():
            print(f"skip {label}: {mem} missing")
            continue
        folded = read_mem_files(mem)
        row = {}
        for cname, fn in CONDITIONS.items():
            rng = np.random.default_rng(0)
            accs = {}
            for sname, m in sets.items():
                Z = fn(X[m], rng)
                if st:
                    Z = stretch(Z)
                s, thr = R.int_forward_batch(Z, folded)
                accs[sname] = float(((s >= thr).astype(int) == y[m]).mean())
            accs["mean"] = (accs["T1"] + accs["T2"]) / 2
            row[cname] = accs
        row["camera average"] = float(np.mean([row[c]["mean"] for c in CAMERA_CONDS]))
        if real is not None:
            img = autocontrast(real)[0] if st else real
            _, sc, _ = int_forward(img, folded)
            row["ceiling margin"] = int(sc - int(folded[-1][1][0]))
        results[label] = row
        print(f"{label:14s} clean T1 {row['clean']['T1']*100:5.1f} T2 {row['clean']['T2']*100:5.1f}  "
              f"camera-like {row['camera-like 0.4']['mean']*100:5.1f}  lamp {row['camera + lamp']['mean']*100:5.1f}  "
              f"camera avg {row['camera average']*100:5.1f}  ceiling {row.get('ceiling margin')}", flush=True)
    out = {"conditions": list(CONDITIONS), "camera_conditions": CAMERA_CONDS, "results": results,
           "n": {k: int(v.sum()) for k, v in sets.items()}}
    (ROOT / "docs" / "model_compare.json").write_text(json.dumps(out, indent=2))
    print("wrote docs/model_compare.json")


if __name__ == "__main__":
    main()
