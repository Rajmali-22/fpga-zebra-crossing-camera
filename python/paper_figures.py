#!/usr/bin/env python3
"""
Figures for the results paper (docs/paper/fig*.png), sized for one IEEE
column (3.5 in) at 300 dpi with 7-8 pt text.

    python python/paper_figures.py
"""

import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
OUT = ROOT / "docs" / "paper"
OUT.mkdir(parents=True, exist_ok=True)

plt.rcParams.update({"font.family": "serif", "font.serif": ["Times New Roman", "DejaVu Serif"],
                     "font.size": 7.5, "axes.titlesize": 8, "axes.labelsize": 7.5,
                     "xtick.labelsize": 7, "ytick.labelsize": 7, "legend.fontsize": 7,
                     "axes.linewidth": 0.6, "savefig.dpi": 300})
INK, MUTED = "#1f2933", "#6b7280"
NEW, OLD, OUT_C = "#2563eb", "#9ca3af", "#059669"
COL = 3.5


def box(ax, x, y, w, h, title, sub, color):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.01,rounding_size=0.06",
                                fc=color + "26", ec=color, lw=0.9))
    ax.text(x + w / 2, y + h / 2 + (0.07 if sub else 0), title, ha="center", va="center",
            fontsize=7, weight="bold", color=INK)
    if sub:
        ax.text(x + w / 2, y + h / 2 - 0.12, sub, ha="center", va="center", fontsize=5.6, color=MUTED)


def arrow(ax, a, b, color=INK):
    ax.add_patch(FancyArrowPatch(a, b, arrowstyle="-|>", mutation_scale=7, lw=0.8, color=color))


def fig_architecture():
    fig, ax = plt.subplots(figsize=(COL, 2.75))
    ax.set_xlim(0, 3.5)
    ax.set_ylim(0, 2.75)
    ax.axis("off")
    ax.add_patch(FancyBboxPatch((0.62, 0.05), 2.06, 2.62, boxstyle="round,pad=0.01,rounding_size=0.06",
                                fc="none", ec=MUTED, lw=0.6, ls="--"))
    ax.text(0.68, 2.58, "Artix-7 XC7A35T", fontsize=6, color=MUTED)
    box(ax, 0.02, 1.2, 0.52, 0.45, "OV7670", "640x480\n26.7 fps", OLD)
    # proven path
    box(ax, 0.7, 2.05, 0.9, 0.4, "camera_if", "SCCB, pixels", OLD)
    box(ax, 1.7, 2.05, 0.9, 0.4, "SDRAM+VGA", "picture + overlay", OLD)
    # detection path
    box(ax, 0.7, 1.45, 0.9, 0.42, "preprocess", "gray, 8x8 mean", NEW)
    box(ax, 1.7, 1.45, 0.9, 0.42, "auto-contrast", "0.5 % trim, gain<=2.7", NEW)
    box(ax, 1.7, 0.82, 0.9, 0.45, "BCNN", "80x60, 32-64-64-64\n34 ms @ 66.7 MHz", NEW)
    box(ax, 0.7, 0.82, 0.9, 0.45, "decision", "4-frame avg,\nnot-sure band", NEW)
    box(ax, 0.7, 0.18, 0.9, 0.45, "UART link", "5.33 Mbaud", NEW)
    box(ax, 1.7, 0.18, 0.9, 0.45, "outputs", "LCD, LEDs,\nbuzzer, overlay", NEW)
    box(ax, 2.82, 2.05, 0.66, 0.4, "monitor", None, OUT_C)
    box(ax, 2.82, 0.18, 0.66, 0.45, "LCD,\nLEDs", None, OUT_C)
    box(ax, 0.02, 0.18, 0.52, 0.45, "PC", "optional", OUT_C)
    arrow(ax, (0.54, 1.5), (0.7, 2.2), OLD)
    arrow(ax, (0.54, 1.4), (0.7, 1.66), NEW)
    arrow(ax, (1.6, 2.25), (1.7, 2.25), OLD)
    arrow(ax, (1.6, 1.66), (1.7, 1.66), NEW)
    arrow(ax, (2.15, 1.45), (2.15, 1.27), NEW)
    arrow(ax, (1.7, 1.05), (1.6, 1.05), NEW)
    arrow(ax, (1.15, 0.82), (1.15, 0.63), NEW)
    arrow(ax, (1.55, 0.82), (1.75, 0.63), NEW)
    arrow(ax, (2.6, 2.25), (2.82, 2.25), OUT_C)
    arrow(ax, (2.6, 0.4), (2.82, 0.4), OUT_C)
    arrow(ax, (0.7, 0.4), (0.54, 0.4), OUT_C)
    fig.tight_layout(pad=0.1)
    fig.savefig(OUT / "fig1_architecture.png")
    plt.close(fig)


def fig_real_frame():
    from cam_golden import autocontrast, camera_input, expand_565
    raw = ROOT.parent / "soc" / "soc" / "plain" / "capture.raw"
    f = np.frombuffer(raw.read_bytes(), ">u2").reshape(480, 640)
    x = camera_input(f)
    s, lo, hi = autocontrast(x)
    fig, axs = plt.subplots(1, 3, figsize=(COL, 1.15))
    axs[0].imshow(expand_565(f))
    axs[0].set_title("(a) OV7670 frame", fontsize=6.5)
    axs[1].imshow(x, cmap="gray", vmin=0, vmax=255)
    axs[1].set_title(f"(b) 80x60, gray {x.min()}-{x.max()}", fontsize=6.5)
    axs[2].imshow(s, cmap="gray", vmin=0, vmax=255)
    axs[2].set_title("(c) after auto-contrast", fontsize=6.5)
    for a in axs:
        a.axis("off")
    fig.tight_layout(pad=0.15)
    fig.savefig(OUT / "fig2_real_frame.png")
    plt.close(fig)


def fig_robustness():
    d = json.loads((ROOT / "docs" / "model_compare.json").read_text())
    r = d["results"]
    conds = ["clean", "contrast 0.6", "camera-like 0.4", "camera + lamp", "gamma 0.6", "gamma 1.6",
             "blur 0.7 px", "noise 4"]
    labels = ["clean", "contrast\n0.6", "camera-\nlike", "camera\n+ lamp", "gamma\n0.6", "gamma\n1.6",
              "blur", "noise"]
    fig, ax = plt.subplots(figsize=(COL, 1.75))
    w = 0.38
    xs = np.arange(len(conds))
    for i, (key, lab, col) in enumerate((("v3 raw", "without auto-contrast", OLD),
                                         ("v3 stretch", "with auto-contrast (deployed)", NEW))):
        vals = [r[key][c]["mean"] * 100 for c in conds]
        ax.bar(xs + (i - 0.5) * w, vals, w * 0.95, label=lab, color=col)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, fontsize=6)
    ax.set_ylabel("accuracy, mean T1/T2 (%)")
    ax.set_ylim(50, 85)
    ax.grid(axis="y", alpha=0.3, lw=0.5)
    ax.legend(frameon=False, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.17))
    fig.tight_layout(pad=0.2)
    fig.savefig(OUT / "fig3_robustness.png")
    plt.close(fig)


def fig_coverage():
    cov = [30, 40, 50, 60, 80, 100]
    t2 = [97.1, 95.7, 93.1, 88.4, 81.5, 73.0]      # v3, camera path (docs/RESULTS.md)
    t1 = [92.4, 93.8, 91.6, 90.4, 83.5, 77.5]
    fig, ax = plt.subplots(figsize=(COL, 1.6))
    ax.plot(cov, t2, "o-", color=NEW, ms=3, lw=1.1, label="T2 street photos")
    ax.plot(cov, t1, "s-", color=OUT_C, ms=3, lw=1.1, label="T1 dashcam")
    ax.set_xlabel("coverage: share of images answered (%)")
    ax.set_ylabel("correct among answered (%)")
    ax.set_ylim(70, 100)
    ax.grid(alpha=0.3, lw=0.5)
    ax.legend(frameon=False)
    fig.tight_layout(pad=0.2)
    fig.savefig(OUT / "fig4_coverage.png")
    plt.close(fig)


def fig_energy():
    # energy per decision, mJ; see the paper's Table for sources and assumptions
    items = [("This work: FPGA\ncamera system", 0.294 / 27.0 * 1000, NEW),
             ("CDNet, Jetson\nNano (10 W)", 10.0 / 33.1 * 1000, OLD),
             ("Same BCNN,\nlaptop CPU", 45.0 * 8.13, OLD),
             ("ResNet-18,\nlaptop CPU", 45.0 * 42.5, OLD)]
    fig, ax = plt.subplots(figsize=(COL, 1.6))
    ys = np.arange(len(items))[::-1]
    for y, (lab, v, col) in zip(ys, items):
        ax.barh(y, v, color=col, height=0.6)
        ax.text(v * 1.12, y, f"{v:.0f} mJ" if v >= 10 else f"{v:.1f} mJ", va="center", fontsize=6.5)
    ax.set_yticks(ys)
    ax.set_yticklabels([i[0] for i in items], fontsize=6.3)
    ax.set_xscale("log")
    ax.set_xlim(3, 20000)
    ax.set_xlabel("energy per decision (mJ, log scale)")
    ax.grid(axis="x", alpha=0.3, lw=0.5)
    fig.tight_layout(pad=0.2)
    fig.savefig(OUT / "fig5_energy.png")
    plt.close(fig)


def fig_margins():
    # network margin (score - 477) of every held-out image, from the bit-exact answers in vectors/
    pos_c, neg_c = NEW, "#d97706"
    fig, axs = plt.subplots(1, 2, figsize=(COL, 1.75), sharex=True)
    bins = np.arange(-96, 152, 8)
    for ax, (t, name) in zip(axs, (("t1", "T1 dashcam (524)"), ("t2", "T2 street photos (115)"))):
        d = ROOT / "vectors" / t
        e = np.array([int(v, 16) for v in (d / "test_expected.hex").read_text().split()])
        y = np.array([int(v) for v in (d / "test_labels.txt").read_text().split()])
        m = (e & 0x7FFF) - 477
        hp, _ = np.histogram(m[y == 1], bins)
        hn, _ = np.histogram(m[y == 0], bins)
        x = bins[:-1] + 4
        ax.axvspan(-31, 33, color="#e5e7eb", lw=0, zorder=0)
        ax.bar(x, hp, 7, color=pos_c, label="crossing", zorder=2)
        ax.bar(x, -hn, 7, color=neg_c, label="no crossing", zorder=2)
        ax.axhline(0, color=INK, lw=0.5, zorder=3)
        ax.axvline(0, color=INK, lw=0.6, ls="--", zorder=3)
        top = max(hp.max(), hn.max()) * 1.25
        ax.set_ylim(-top, top)
        ax.text(1, top * 0.95, "not sure", ha="center", va="top", fontsize=6, color=MUTED, zorder=4,
                bbox=dict(fc="#e5e7eb", ec="none", pad=0.6))
        ax.set_title(name, fontsize=7)
        ax.set_xlabel("margin = score − 477")
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{abs(v):.0f}"))
        ax.grid(axis="y", alpha=0.3, lw=0.5)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    axs[0].set_ylabel("images")
    axs[1].legend(frameon=False, loc="lower right", fontsize=6, handlelength=1, borderaxespad=0.1)
    fig.tight_layout(pad=0.2, w_pad=0.6)
    fig.savefig(OUT / "fig7_margins.png")
    plt.close(fig)


def fig_monitor():
    im = Image.open(ROOT / "docs" / "vga_state2_src0_camera.png").convert("RGB")
    im.save(OUT / "fig6_monitor.png")


if __name__ == "__main__":
    fig_architecture()
    fig_real_frame()
    fig_robustness()
    fig_coverage()
    fig_energy()
    fig_margins()
    fig_monitor()
    print("written:", sorted(p.name for p in OUT.glob("fig*.png")))
