#!/usr/bin/env python3
"""
v3c: the v3 recipe (zebra-crossing-bcnn-fpga, branch diverse-data,
python/train_diverse.py) plus augmentation for what an OV7670 does to a
picture, measured by python/robustness.py to hurt v3:

    gamma 0.6..1.6 (p 0.5), focus blur sigma 0.3..1.0 px at 80x60 (p 0.4),
    sensor noise sigma 0..4 (p 0.5)

Everything else - data, splits, balance, online distillation from the
ResNet-18 teacher, 60 epochs, seed, best-validation checkpoint - is the v3
command line, so the two models differ only by this augmentation. The
training code is imported unchanged; only its augment() is wrapped.

    python python/train_camaug.py [--name CAMv3c_s42] [--seed 42] [--epochs 60]

Results: <zebra repo>/outputs/experiments/<name>/ and ROMs in <zebra repo>/mem_<name>/
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

ROOT_OV = Path(__file__).resolve().parent.parent
ZEBRA = ROOT_OV.parent / "zebra-crossing-bcnn-fpga"
sys.path.insert(0, str(ZEBRA / "python"))
import train_diverse as td  # noqa: E402

_base_augment = td.augment


def camera_augment(x):
    """v3 augmentation, then camera effects; stays in integer pixels 0..255."""
    x = _base_augment(x)
    b = x.shape[0]
    # gamma, per image
    g = torch.exp(torch.empty(b, 1, 1, 1).uniform_(np.log(0.6), np.log(1.6)))
    use = (torch.rand(b, 1, 1, 1) < 0.5).float()
    x = use * (255.0 * (x / 255.0).clamp(0, 1) ** g) + (1 - use) * x
    # focus blur, one sigma per batch
    if np.random.rand() < 0.4:
        s = np.random.uniform(0.3, 1.0)
        k = torch.exp(-0.5 * (torch.arange(-3, 4, dtype=torch.float32) / s) ** 2)
        k = k / k.sum()
        x = F.conv2d(F.pad(x, (3, 3, 0, 0), mode="replicate"), k.view(1, 1, 1, 7))
        x = F.conv2d(F.pad(x, (0, 0, 3, 3), mode="replicate"), k.view(1, 1, 7, 1))
    # sensor noise, per image
    sig = torch.empty(b, 1, 1, 1).uniform_(0, 4) * (torch.rand(b, 1, 1, 1) < 0.5).float()
    x = x + torch.randn_like(x) * sig
    return torch.clamp(torch.round(x), 0, 255)


STRETCH_K, STRETCH_MIN = 24, 96          # = rtl/vision/bcnn_engine.v, cam_golden.autocontrast


def stretch_torch(x):
    """cam_golden.autocontrast on a batch (B,1,H,W) of integer-valued floats,
    exactly: lo / hi = (K+1)-th smallest / largest pixel, integer scale."""
    b = x.shape[0]
    flat = x.reshape(b, -1)
    n = flat.shape[1]
    lo = flat.kthvalue(STRETCH_K + 1, dim=1).values.view(b, 1, 1, 1)
    hi = flat.kthvalue(n - STRETCH_K, dim=1).values.view(b, 1, 1, 1)
    scale = torch.floor(65280.0 / (hi - lo).clamp(min=STRETCH_MIN))
    return torch.clamp(torch.floor((x - lo).clamp(min=0) * scale / 256.0), 0, 255)


def stretched_dataset(src, dst):
    """Copy of the dataset with every 80x60 image auto-contrasted (what the
    network then sees for validation / T1 / T2, as on the FPGA)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from cam_golden import autocontrast
    d = np.load(src)
    out = {k: d[k] for k in d.files}
    out["X80"] = np.stack([autocontrast(img, STRETCH_K, STRETCH_MIN)[0] for img in d["X80"]])
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(dst, **out)
    return dst


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="CAMv3c_s42")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--stretch", action="store_true",
                   help="v3cs: train and evaluate on auto-contrasted images (the FPGA camera path)")
    a = p.parse_args()
    data = ZEBRA / "dataset" / "diverse_v3.npz"
    if a.stretch:
        data = ROOT_OV / "dataset" / "diverse_v3_stretched.npz"
        if not data.exists():
            stretched_dataset(ZEBRA / "dataset" / "diverse_v3.npz", data)
        td.augment = lambda x: stretch_torch(camera_augment(x))
    else:
        td.augment = camera_augment
    sys.argv = ["train_diverse.py", "--name", a.name, "--data", str(data),
                "--res", "80", "--channels", "32,64,64,64", "--balance", "sqrt",
                "--teacher", str(ZEBRA / "outputs" / "experiments" / "R18_ceiling"),
                "--kd", "0.5", "--kd-temp", "2", "--kd-online",
                "--epochs", str(a.epochs), "--seed", str(a.seed), "--export"]
    td.main()


if __name__ == "__main__":
    main()
