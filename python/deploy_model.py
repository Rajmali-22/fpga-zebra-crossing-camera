#!/usr/bin/env python3
"""
Put a different set of BCNN weights on the camera system, keeping every
dependent file consistent:

    python python/deploy_model.py <rom folder> [--stretch-photo] [--keep-band]

  1. copies bcnn_weights.mem, bcnn_thresh.mem, bcnn_config.vh, net.json to mem/
  2. "not sure" band: chosen on the Commons VALIDATION photos (never T1/T2) as
     in the zebra repo's calibrate_demo.py, on auto-contrasted images (what the
     camera path feeds the network); --keep-band keeps mem/demo.json
  3. golden vectors: mem/test_* (self-test) and vectors/t1, vectors/t2
     (hardware-in-the-loop) get this model's answers; with --stretch-photo the
     FPGA auto-contrasts uploaded photos too, and so does the golden model
  4. rtl/top.v: BAND_LO / BAND_HI / STRETCH_PHOTO defaults
Then rebuild (vivado/build.tcl) and re-run sim/check_vision.py.
"""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
import robustness as R  # noqa: E402
from bcnn_model import int_forward, read_mem_files  # noqa: E402
from cam_golden import autocontrast  # noqa: E402


def stretch(X):
    return np.stack([autocontrast(x)[0] for x in X])


def choose_band(m, y, target=0.90):
    """narrowest [lo, hi) whose confident answers are >= target correct (calibrate_demo.py)"""
    best = None
    for width in range(0, 200):
        for lo in range(-width, 1):
            hi = lo + width
            sure = (m < lo) | (m >= hi)
            if sure.sum() and ((m[sure] >= 0) == y[sure]).mean() >= target:
                if best is None or sure.mean() > best[2]:
                    best = (lo, hi, sure.mean())
        if best:
            return best[0], best[1]
    return -100, 100


def main():
    p = argparse.ArgumentParser()
    p.add_argument("rom")
    p.add_argument("--stretch-photo", action="store_true")
    p.add_argument("--keep-band", action="store_true")
    a = p.parse_args()
    src, mem = Path(a.rom), ROOT / "mem"
    for f in ("bcnn_weights.mem", "bcnn_thresh.mem", "bcnn_config.vh", "net.json"):
        shutil.copy(src / f, mem / f)
    folded = read_mem_files(mem)
    thr = int(folded[-1][1][0])
    print(f"deployed {src} (threshold {thr})")

    d = np.load(R.DATA)
    if a.keep_band:
        band = json.loads((mem / "demo.json").read_text())
        lo, hi = band["lo"], band["hi"]
    else:
        cal = (d["split"] == 1) & (d["source"] == "commons_train")
        s, _ = R.int_forward_batch(stretch(d["X80"][cal]), folded)
        lo, hi = choose_band(s - thr, d["y"][cal] == 1)
        (mem / "demo.json").write_text(json.dumps({"lo": int(lo), "hi": int(hi), "target": 0.9,
            "chosen_on": "Commons validation photos, auto-contrasted", "rom": str(src)}) + "\n")
    print(f"'not sure' band: {lo} <= margin < {hi}")

    # golden vectors
    def answers(X):
        Z = stretch(X) if a.stretch_photo else X
        s, t = R.int_forward_batch(Z, folded)
        for i in (0, len(Z) - 1):                       # spot check against the reference model
            assert int_forward(Z[i], folded)[1] == s[i]
        return [(int(v >= t) << 15) | int(v) for v in s]
    for folder, name in ((mem, "self-test"), (ROOT / "vectors" / "t1", "T1"), (ROOT / "vectors" / "t2", "T2")):
        X = np.array([int(v, 16) for v in (folder / "test_images.hex").read_text().split()], np.uint8).reshape(-1, 60, 80)
        y = np.array([int(v) for v in (folder / "test_labels.txt").read_text().split()])
        ans = answers(X)
        (folder / "test_expected.hex").write_text("\n".join(f"{v:04x}" for v in ans) + "\n")
        acc = np.mean([(v >> 15) == t for v, t in zip(ans, y)])
        print(f"  {name:9s} {len(y):4d} vectors, accuracy {acc:.4f}")
    if (src / "test_maps.hex").exists():               # per-layer maps for the BCNN core testbench
        shutil.copy(src / "test_maps.hex", mem / "test_maps.hex")
    elif (mem / "test_maps.hex").exists():
        (mem / "test_maps.hex").unlink()                # they belonged to the previous model

    # rtl/top.v defaults
    top = ROOT / "rtl" / "top.v"
    t = top.read_text(encoding="utf-8")
    t = re.sub(r"parameter signed \[15:0\] BAND_LO = -?16'sd\d+,", f"parameter signed [15:0] BAND_LO = "
               f"{'-' if lo < 0 else ''}16'sd{abs(lo)},", t)
    t = re.sub(r"parameter signed \[15:0\] BAND_HI = -?16'sd\d+,", f"parameter signed [15:0] BAND_HI = "
               f"{'-' if hi < 0 else ''}16'sd{abs(hi)},", t)
    t = re.sub(r"parameter STRETCH_PHOTO = \d", f"parameter STRETCH_PHOTO = {int(a.stretch_photo)}", t)
    top.write_text(t, encoding="utf-8")
    print("rtl/top.v updated; now rebuild: vivado -mode batch -source vivado/build.tcl -tclargs iob 12 bit")


if __name__ == "__main__":
    main()
