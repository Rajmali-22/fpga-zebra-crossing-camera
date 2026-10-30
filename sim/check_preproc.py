#!/usr/bin/env python3
"""
Bit-exact check of rtl/vision/cam_preproc.v against python/cam_golden.py.

Two camera frames are made from real photos (plus random noise in the second,
so every one of the 65,536 RGB565 codes the gray path sees is exercised) and
played through the OV7670 model. Every committed 80x60 frame must equal
cam_golden.camera_input() of the frame it came from.

    python sim/check_preproc.py                 # PCLK stopped in blanking (as configured)
    python sim/check_preproc.py --pclk-blank    # PCLK free-running in blanking
    python sim/check_preproc.py --bad-line 100  # every 2nd frame has a short line
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "sim"))
from cam_golden import camera_input, photo_to_frame565, read_bytes_hex, write_frame_hex  # noqa: E402
from xsim import fresh_dir, run_xsim  # noqa: E402

PHOTOS = [ROOT.parent / "zebra-crossing-bcnn-fpga" / "samples" / "crossing_1.jpg",
          ROOT.parent / "zebra-crossing-bcnn-fpga" / "web_test" / "zebra_03.jpg"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--pclk-blank", action="store_true")
    p.add_argument("--bad-line", type=int, default=-1)
    p.add_argument("--frames", type=int, default=3)
    p.add_argument("--run-dir", default=str(ROOT / "sim" / "run" / "preproc"))
    a = p.parse_args()

    run = fresh_dir(a.run_dir)
    rng = np.random.default_rng(1)
    frames = []
    for k, ph in enumerate(PHOTOS):
        f = photo_to_frame565(Image.open(ph))
        if k == 1:      # random pixels in the top half: every 565 code path
            f[:240] = rng.integers(0, 65536, size=(240, 640), dtype=np.uint16)
        frames.append(f)
        write_frame_hex(f, run / f"frame{k}.hex")
    gold = [camera_input(f) for f in frames]

    out = run_xsim("tb_cam_preproc", ["rtl/vision/cam_preproc.v", "sim/ov7670_model.v",
                                      "sim/tb_cam_preproc.v"], run,
                   generics={"FRAMES": a.frames, "NFRAMES": len(frames),
                             "PCLK_IN_BLANK": int(a.pclk_blank), "BAD_LINE": a.bad_line})
    print("\n".join(l for l in out.splitlines() if l.startswith(" ")))

    # Which source frame does commit k belong to? With a bad line every odd
    # frame is rejected, so commits come only from even frames.
    ok = True
    commits = sorted(run.glob("got*.hex"), key=lambda q: int(q.stem[3:]))
    if not commits:
        print("FAIL: no frame committed")
        return 1
    for k, path in enumerate(commits):
        src = (2 * k if a.bad_line >= 0 else k) % len(frames)
        got = read_bytes_hex(path).reshape(60, 80)
        diff = int((got != gold[src]).sum())
        print(f" commit {k}: source frame {src}: {'MATCH' if diff == 0 else f'{diff} pixels differ'}")
        ok &= diff == 0
    expect = (a.frames + 1) // 2 if a.bad_line >= 0 else a.frames
    if len(commits) != expect:
        print(f" expected {expect} commits, got {len(commits)}")
        ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
