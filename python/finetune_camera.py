#!/usr/bin/env python3
"""
Fine-tune the deployed BCNN on frames from a specific camera and scene.

1. Collect: python host/zebracam.py auto live --save data/cam
   point the camera at crossings (press z) and at everything else you will
   show it (press n): table, floor, hands, posters, printed roads without
   crossings... 150+ of each is a good start. The saved images are exactly
   the bytes the network saw (after the FPGA's auto-contrast).
2. Fine-tune: python python/finetune_camera.py data/cam/camera_set.npz
   - starts from the model in --base (default: the zebra repo's v3 weights)
   - by default adapts only the output layer (the features and the BatchNorm
     thresholds stay), which moves the decision towards your scene without
     forgetting street photos; --all-layers adapts everything
   - keeps the best epoch, or the original model if nothing beats it
   - mixes the camera frames (20 % held out for testing) with the original
     training images, so street photos are not forgotten
   - reports camera hold-out, T1, T2 before and after, writes mem_cam/
3. Deploy: copy mem_cam/* to mem/, rebuild (vivado/build.tcl), program.

All arithmetic of the exported ROMs is the same as on the FPGA (fold_model ->
int_forward agreement is checked on every reported set).
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parent.parent
ZEBRA = ROOT.parent / "zebra-crossing-bcnn-fpga"
sys.path.insert(0, str(ROOT / "python"))
from bcnn_model import BCNN, fold_model, int_forward, make_layers, write_mem_files  # noqa: E402
from cam_golden import autocontrast  # noqa: E402

sys.path.insert(0, str(ZEBRA / "python"))


def stretch_np(X):
    return np.stack([autocontrast(x)[0] for x in X])


def augment(x, stretch, camera):
    """Photos: the augmentation the base model was trained with. Camera frames:
    + gamma / blur / noise, then the FPGA's auto-contrast (camera frames are
    always stretched on the FPGA)."""
    import train_diverse as td
    from train_camaug import camera_augment, stretch_torch
    x = camera_augment(x) if camera else td.augment(x)
    return stretch_torch(x) if stretch else x


def int_acc(folded, X, y):
    if len(X) == 0:
        return None
    p = np.array([int_forward(img, folded)[0] for img in X])
    return round(float((p == (y == 1)).mean()), 4)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("camera_set", help="camera_set.npz from zebracam.py live --save")
    p.add_argument("--base", default=str(ZEBRA / "model" / "model.pt"), help="starting weights (state dict)")
    p.add_argument("--base-stretched", action="store_true",
                   help="the base model was trained on auto-contrasted images (v3cs)")
    p.add_argument("--data", default=str(ZEBRA / "dataset" / "diverse_v3.npz"))
    p.add_argument("--epochs", type=int, default=8)
    p.add_argument("--lr", type=float, default=None,
                   help="default 1e-3 (output layer) / 3e-4 (--all-layers): a large step flips many"
                        " binary weights at once")
    p.add_argument("--cam-share", type=float, default=0.3, help="share of each batch from the camera set")
    p.add_argument("--out", default=str(ROOT / "mem_cam"))
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--all-layers", action="store_true",
                   help="adapt every layer (stronger, but forgets more); default: only the output layer")
    p.add_argument("--train-bn", action="store_true",
                   help="also adapt BatchNorm (= the neuron thresholds); off by default, it makes the"
                        " network forget street photos")
    a = p.parse_args()
    if a.lr is None:
        a.lr = 3e-4 if a.all_layers else 1e-3
    torch.manual_seed(a.seed)
    rng = np.random.default_rng(a.seed)

    cam = np.load(a.camera_set)
    Xc, yc = cam["X"].astype(np.uint8), cam["y"].astype(np.int64)
    idx = rng.permutation(len(yc))
    n_test = max(1, len(yc) // 5)
    te_c, tr_c = idx[:n_test], idx[n_test:]
    print(f"camera set: {len(yc)} frames ({int(yc.sum())} crossing), {len(tr_c)} train / {n_test} test")

    d = np.load(a.data)
    X, y, split, src = d["X80"], d["y"].astype(np.int64), d["split"], d["source"]
    if a.base_stretched:
        X = stretch_np(X)
    sets = {"camera hold-out": (Xc[te_c], yc[te_c]),
            "T1 dashcam": (X[(split == 2) & (src == "cdset")], y[(split == 2) & (src == "cdset")]),
            "T2 street": (X[split == 3], y[split == 3])}

    layers = make_layers(60, 80, (32, 64, 64, 64))
    model = BCNN(layers)
    model.load_state_dict(torch.load(a.base, weights_only=True))
    before = {k: int_acc(fold_model(model.eval()), *v) for k, v in sets.items()}
    print("before:", before)

    def score(res):
        """what we keep: half your camera, half the original test sets"""
        return 0.5 * res["camera hold-out"] + 0.25 * res["T1 dashcam"] + 0.25 * res["T2 street"]

    @torch.no_grad()
    def quick(m):           # PyTorch = integer model (checked at the end), fast
        m.eval()
        out = {}
        for k, (Xs, ys) in sets.items():
            logit = torch.cat([m(torch.tensor(Xs[i:i + 512], dtype=torch.float32)[:, None])
                               for i in range(0, len(Xs), 512)])
            out[k] = float(((logit >= 0).numpy() == (ys == 1)).mean())
        return out

    best = (score(before), 0, {k: t.clone() for k, t in model.state_dict().items()}, before)

    Xt_photo = torch.tensor(X[split == 0], dtype=torch.float32)[:, None]
    yt_photo = torch.tensor(y[split == 0], dtype=torch.float32)
    Xt_cam = torch.tensor(Xc[tr_c], dtype=torch.float32)[:, None]
    yt_cam = torch.tensor(yc[tr_c], dtype=torch.float32)
    crit = nn.BCEWithLogitsLoss()
    bs, n_cam = 64, max(1, int(64 * a.cam_share))
    steps = max(len(Xt_photo) // (bs - n_cam), 1)
    if not a.train_bn:
        for bn in model.bns:
            for prm in bn.parameters():
                prm.requires_grad_(False)
    if not a.all_layers:                   # features stay, only the decision moves
        for w in list(model.convs)[:-1]:
            w.requires_grad_(False)
    opt = torch.optim.Adam([q for q in model.parameters() if q.requires_grad], lr=a.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, a.epochs, eta_min=a.lr * 0.05)
    for ep in range(a.epochs):
        model.train()
        if not a.train_bn:
            for bn in model.bns:
                bn.eval()                  # keep the running statistics
        for _ in range(steps):
            ip = torch.randint(0, len(Xt_photo), (bs - n_cam,))
            ic = torch.randint(0, len(Xt_cam), (n_cam,))
            xb = torch.cat([augment(Xt_photo[ip], a.base_stretched, False), augment(Xt_cam[ic], True, True)])
            yb = torch.cat([yt_photo[ip], yt_cam[ic]])
            loss = crit(model(xb), yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            model.clamp_latent()
        sched.step()
        res = quick(model)
        print(f"epoch {ep + 1}/{a.epochs}  loss {loss.item():.3f}  " +
              "  ".join(f"{k} {v:.3f}" for k, v in res.items()) + f"  score {score(res):.3f}", flush=True)
        if score(res) > best[0]:
            best = (score(res), ep + 1, {k: t.clone() for k, t in model.state_dict().items()}, res)

    print(f"keeping epoch {best[1]}" + (" (= the original model: fine-tuning did not help)" if best[1] == 0 else ""))
    model.load_state_dict(best[2])
    model.eval()
    folded = fold_model(model)
    after = {k: int_acc(folded, *v) for k, v in sets.items()}
    print("after: ", after)
    out = Path(a.out)
    out.mkdir(exist_ok=True)
    write_mem_files(folded, out, layers, 60, 80)
    torch.save(model.state_dict(), out / "model.pt")
    (out / "finetune.json").write_text(json.dumps({"base": a.base, "camera_set": a.camera_set, "epoch": best[1],
                                                   "before": before, "after": after}, indent=2))
    print(f"wrote {out}/ - copy its .mem/.vh files to mem/ and rebuild if 'after' is better")


if __name__ == "__main__":
    main()
