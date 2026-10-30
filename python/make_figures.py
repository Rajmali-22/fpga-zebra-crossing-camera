#!/usr/bin/env python3
"""
Figures for the report / presentation (docs/fig_*.png):

  fig_architecture.png   block diagram of the FPGA design
  fig_real_frame.png     a real OV7670 frame from the board -> 80x60 -> auto-contrast
  fig_robustness.png     v3 accuracy under camera effects, with / without auto-contrast
                         (needs docs/model_compare.json from python/compare_models.py)
"""

import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
DOCS = ROOT / "docs"

INK, MUTED, NEW, OLD, OUT = "#1f2933", "#6b7280", "#2563eb", "#9ca3af", "#059669"


def box(ax, x, y, w, h, text, color, sub=None):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
                                fc=color + "22", ec=color, lw=1.6))
    ax.text(x + w / 2, y + h / 2 + (0.12 if sub else 0), text, ha="center", va="center",
            fontsize=10.5, color=INK, weight="bold")
    if sub:
        ax.text(x + w / 2, y + h / 2 - 0.2, sub, ha="center", va="center", fontsize=8, color=MUTED)


def arrow(ax, a, b, color=INK, rad=0.0):
    ax.add_patch(FancyArrowPatch(a, b, arrowstyle="-|>", mutation_scale=12, lw=1.3, color=color,
                                 connectionstyle=f"arc3,rad={rad}"))


def architecture():
    fig, ax = plt.subplots(figsize=(13, 6.2))
    ax.set_xlim(0, 13)
    ax.set_ylim(0, 6.2)
    ax.axis("off")
    ax.add_patch(FancyBboxPatch((1.55, 0.25), 9.25, 5.7, boxstyle="round,pad=0.02,rounding_size=0.15",
                                fc="none", ec=MUTED, lw=1, ls="--"))
    ax.text(1.75, 5.72, "Artix-7 XC7A35T  (one MMCM: 133.33 / 50 / 25 / 21.33 MHz)", fontsize=9, color=MUTED)

    box(ax, 0.1, 2.6, 1.25, 1.0, "OV7670", OLD, "640x480 RGB565\n26.7 fps")
    # proven path
    box(ax, 1.9, 4.5, 2.1, 0.9, "camera_interface", OLD, "SCCB setup, pixels")
    box(ax, 4.4, 4.5, 1.6, 0.9, "SDRAM", OLD, "frame store")
    box(ax, 6.4, 4.5, 2.0, 0.9, "VGA output", OLD, "live picture")
    box(ax, 6.4, 3.35, 2.0, 0.8, "photo capture", OLD, "'c' -> 640x480")
    # new path
    box(ax, 1.9, 2.0, 2.1, 1.0, "cam_preproc", NEW, "gray, 8x8 mean -> 80x60")
    box(ax, 4.4, 2.0, 1.6, 1.0, "frame buffer", NEW, "2 camera banks + photo")
    box(ax, 6.4, 2.0, 2.0, 1.0, "auto-contrast", NEW, "histogram, 0.5 % trim")
    box(ax, 8.75, 2.0, 1.85, 1.0, "v3 BCNN", NEW, "80x60 -> 32-64-64-64\n45 ms @ 50 MHz")
    box(ax, 8.75, 0.55, 1.85, 1.0, "decision", NEW, "4-frame average\nnot-sure band")
    box(ax, 6.4, 0.55, 2.0, 1.0, "UART link", NEW, "5.33 Mbaud\nsnapshot / photo / status")
    box(ax, 8.75, 4.5, 1.85, 0.9, "overlay", NEW, "result + network view")
    # outputs
    box(ax, 11.1, 4.5, 1.8, 0.9, "VGA monitor", OUT)
    box(ax, 11.1, 3.3, 1.8, 0.8, "LCD 16x2", OUT)
    box(ax, 11.1, 2.15, 1.8, 0.8, "LEDs + buzzer", OUT, "LED0 = crossing")
    box(ax, 11.1, 0.6, 1.8, 0.9, "PC (optional)", OUT, "zebracam.py")

    arrow(ax, (1.35, 3.3), (1.9, 4.9), OLD)
    arrow(ax, (1.35, 2.9), (1.9, 2.5), NEW)
    arrow(ax, (4.0, 4.95), (4.4, 4.95), OLD)
    arrow(ax, (6.0, 4.95), (6.4, 4.95), OLD)
    arrow(ax, (6.0, 4.6), (6.4, 3.75), OLD)
    arrow(ax, (4.0, 2.5), (4.4, 2.5), NEW)
    arrow(ax, (6.0, 2.5), (6.4, 2.5), NEW)
    arrow(ax, (8.4, 2.5), (8.75, 2.5), NEW)
    arrow(ax, (9.67, 2.0), (9.67, 1.55), NEW)
    arrow(ax, (8.4, 4.95), (8.75, 4.95), OLD)
    arrow(ax, (10.6, 4.95), (11.1, 4.95), OUT)
    arrow(ax, (10.6, 1.15), (11.1, 3.6), OUT)
    arrow(ax, (10.6, 1.0), (11.1, 2.45), OUT)
    arrow(ax, (10.6, 1.35), (10.45, 4.5), NEW, rad=0.35)
    arrow(ax, (8.75, 1.05), (8.4, 1.05), NEW)
    arrow(ax, (7.4, 0.55), (11.1, 0.85), OUT, rad=0.25)
    arrow(ax, (6.4, 1.3), (5.2, 2.0), NEW)
    ax.text(0.1, 0.05, "grey = hardware-proven camera design (kept)     blue = new detection path     "
                       "green = outputs", fontsize=8.5, color=MUTED)
    fig.tight_layout()
    fig.savefig(DOCS / "fig_architecture.png", dpi=160)
    plt.close(fig)


def real_frame():
    from cam_golden import autocontrast, camera_input, expand_565
    raw = ROOT.parent / "soc" / "soc" / "plain" / "capture.raw"
    if not raw.exists():
        return
    f = np.frombuffer(raw.read_bytes(), ">u2").reshape(480, 640)
    x = camera_input(f)
    s, lo, hi = autocontrast(x)
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.4))
    axs[0].imshow(expand_565(f))
    axs[0].set_title("OV7670 frame from the board (640x480)", fontsize=10)
    axs[1].imshow(x, cmap="gray", vmin=0, vmax=255)
    axs[1].set_title(f"80x60 network input, gray {x.min()}..{x.max()}", fontsize=10)
    axs[2].imshow(s, cmap="gray", vmin=0, vmax=255)
    axs[2].set_title(f"after auto-contrast (levels {lo}..{hi})", fontsize=10)
    for a in axs:
        a.axis("off")
    fig.tight_layout()
    fig.savefig(DOCS / "fig_real_frame.png", dpi=150)
    plt.close(fig)


def robustness():
    p = DOCS / "model_compare.json"
    if not p.exists():
        return
    d = json.loads(p.read_text())
    conds = d["conditions"]
    fig, ax = plt.subplots(figsize=(11, 4))
    series = [("v3, raw", "v3 raw", OLD), ("v3 + auto-contrast", "v3 stretch", NEW)]
    for extra in d.get("deployed_label", []):
        series.append((extra, extra, OUT))
    w = 0.8 / len(series)
    for i, (label, key, col) in enumerate(series):
        if key not in d["results"]:
            continue
        vals = [d["results"][key][c]["mean"] * 100 for c in conds]
        ax.bar(np.arange(len(conds)) + (i - (len(series) - 1) / 2) * w, vals, w * 0.92, label=label, color=col)
    ax.set_xticks(range(len(conds)))
    ax.set_xticklabels(conds, fontsize=9, rotation=20, ha="right")
    ax.set_ylabel("accuracy, mean of T1 + T2 (%)")
    ax.set_ylim(40, 90)
    ax.grid(axis="y", alpha=0.3)
    ax.legend(frameon=False, fontsize=9)
    ax.set_title("Accuracy under camera effects (bit-exact integer model of the FPGA)", fontsize=11)
    fig.tight_layout()
    fig.savefig(DOCS / "fig_robustness.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    architecture()
    real_frame()
    robustness()
    print("figures written to docs/")
