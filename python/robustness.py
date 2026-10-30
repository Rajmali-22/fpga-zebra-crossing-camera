#!/usr/bin/env python3
"""
How much does the deployed v3 model care about what an OV7670 does to an
image? Every test image (T1 dashcam, T2 street photos, in-domain test) is
altered at the 80x60 level the way a cheap camera alters the picture -
gamma, contrast, exposure, focus blur, sensor noise - and accuracy is
re-measured with the bit-exact integer model of the FPGA.

    python python/robustness.py [--mem mem] [--data <diverse_v3.npz>]

Writes docs/robustness.json and prints a table.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
from bcnn_model import load_net, read_mem_files  # noqa: E402

DATA = ROOT.parent / "zebra-crossing-bcnn-fpga" / "dataset" / "diverse_v3.npz"


def int_forward_batch(X, folded):
    """Integer golden model of bcnn_core on a batch (N,60,80) uint8 -> scores.
    Same arithmetic as bcnn_model.int_forward, vectorised with torch (exact
    integer values in float64)."""
    x = torch.tensor(X, dtype=torch.float64)[:, None] - 128
    w, thr = folded[0]
    acc = F.conv2d(x, torch.tensor(w, dtype=torch.float64), padding=1)
    a = F.max_pool2d((acc >= torch.tensor(thr, dtype=torch.float64)[None, :, None, None]).double(), 2)
    for w, thr in folded[1:-1]:
        n_in = w.shape[1] * 9
        s = F.conv2d(F.pad(a * 2 - 1, (1, 1, 1, 1), value=-1.0), torch.tensor(w, dtype=torch.float64))
        p = (s + n_in) / 2
        a = F.max_pool2d((p >= torch.tensor(thr, dtype=torch.float64)[None, :, None, None]).double(), 2)
    w, thr = folded[-1]
    n_in = w.shape[1] * w.shape[2] * w.shape[3]
    s = F.conv2d(a * 2 - 1, torch.tensor(w, dtype=torch.float64))
    score = ((s[:, 0, 0, 0] + n_in) / 2).round().long().numpy()
    return score, int(thr[0])


def blur(X, sigma):
    k = np.exp(-0.5 * (np.arange(-3, 4) / sigma) ** 2)
    k /= k.sum()
    t = torch.tensor(X, dtype=torch.float32)[:, None]
    kt = torch.tensor(k, dtype=torch.float32)
    t = F.conv2d(F.pad(t, (3, 3, 0, 0), mode="replicate"), kt.view(1, 1, 1, 7))
    t = F.conv2d(F.pad(t, (0, 0, 3, 3), mode="replicate"), kt.view(1, 1, 7, 1))
    return np.clip(np.round(t[:, 0].numpy()), 0, 255).astype(np.uint8)


TRANSFORMS = {
    "clean":          lambda X, r: X,
    "gamma 0.6":      lambda X, r: (255 * (X / 255.0) ** 0.6).round().astype(np.uint8),
    "gamma 1.6":      lambda X, r: (255 * (X / 255.0) ** 1.6).round().astype(np.uint8),
    "contrast 0.6":   lambda X, r: np.clip((X - X.mean((1, 2), keepdims=True)) * 0.6 + X.mean((1, 2), keepdims=True), 0, 255).round().astype(np.uint8),
    "brighter +40":   lambda X, r: np.clip(X.astype(int) + 40, 0, 255).astype(np.uint8),
    "darker -40":     lambda X, r: np.clip(X.astype(int) - 40, 0, 255).astype(np.uint8),
    "blur 0.7 px":    lambda X, r: blur(X, 0.7),
    "blur 1.2 px":    lambda X, r: blur(X, 1.2),
    "noise 4":        lambda X, r: np.clip(X + r.normal(0, 4, X.shape), 0, 255).round().astype(np.uint8),
    "mirror":         lambda X, r: X[:, :, ::-1].copy(),
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mem", default=str(ROOT / "mem"))
    p.add_argument("--data", default=str(DATA))
    p.add_argument("--out", default=str(ROOT / "docs" / "robustness.json"))
    a = p.parse_args()

    folded = read_mem_files(Path(a.mem))
    d = np.load(a.data)
    X, y, split, src = d["X80"], d["y"].astype(int), d["split"], d["source"]
    sets = {"T1 dashcam": (split == 2) & (src == "cdset"),
            "T2 street": split == 3,
            "test, all sources": split == 2}
    rng = np.random.default_rng(0)
    res = {}
    print(f"{'transform':16s}" + "".join(f"{k:>20s}" for k in sets))
    for name, fn in TRANSFORMS.items():
        row = {}
        for sname, m in sets.items():
            Xt = fn(X[m], rng)
            score, thr = int_forward_batch(Xt, folded)
            acc = float(((score >= thr).astype(int) == y[m]).mean())
            row[sname] = round(acc, 4)
        res[name] = row
        print(f"{name:16s}" + "".join(f"{row[k]*100:19.1f}%" for k in sets))
    Path(a.out).write_text(json.dumps({"mem": a.mem, "n": {k: int(v.sum()) for k, v in sets.items()},
                                       "accuracy": res}, indent=2))
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
