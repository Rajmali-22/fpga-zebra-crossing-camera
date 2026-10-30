#!/usr/bin/env python3
"""
Render what the VGA monitor and the 16x2 LCD will show, for given results.

    python sim/check_display.py                     # crossing, score 561
    python sim/check_display.py --state 0 --score 416
    python sim/check_display.py --state 1 --score 500 --src 1

Writes docs/vga_<name>.png (one simulated 640x480 frame: test-pattern camera
picture, thumbnail = the network input of a real photo, overlay) and checks
the LCD text against the expected strings.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "sim"))
from cam_golden import camera_input, photo_to_frame565, write_bytes_hex  # noqa: E402
from xsim import fresh_dir, run_xsim  # noqa: E402

LINE1 = {2: "ZEBRA CROSSING! ", 1: "NOT SURE        ", 0: "NO CROSSING     ", 3: "WAITING CAMERA  "}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--state", type=int, default=2)
    p.add_argument("--score", type=int, default=561)
    p.add_argument("--thr", type=int, default=477)
    p.add_argument("--fps", type=int, default=13)
    p.add_argument("--src", type=int, default=0)
    p.add_argument("--photo", default=str(ROOT.parent / "zebra-crossing-bcnn-fpga" / "web_test" / "zebra_03.jpg"))
    p.add_argument("--name", default=None)
    p.add_argument("--camera", action="store_true",
                   help="show --photo as the live camera picture too (instead of a test pattern); "
                        "the thumbnail is then the auto-contrasted network input, as on the board")
    a = p.parse_args()
    margin = a.score - a.thr
    name = a.name or f"state{a.state}_src{a.src}" + ("_camera" if a.camera else "")

    run = fresh_dir(ROOT / "sim" / "run" / f"display_{name}")
    (run / "font8x16.mem").write_bytes((ROOT / "mem" / "font8x16.mem").read_bytes())
    frame = photo_to_frame565(Image.open(a.photo))
    thumb = camera_input(frame)
    if a.camera:
        from cam_golden import autocontrast
        thumb = autocontrast(thumb)[0]
        (run / "cam.hex").write_text("\n".join(f"{v:04x}" for v in frame.reshape(-1)) + "\n")
    write_bytes_hex(np.concatenate([thumb.reshape(-1), np.zeros(8192 - 4800, np.uint8)]), run / "thumb.hex")

    srcs = ["rtl/io/cdc.v", "rtl/io/status_text.v", "rtl/io/lcd_hd44780.v", "rtl/io/vga_overlay.v",
            "rtl/camera/vga_interface.v", "rtl/camera/vga_core.v", "sim/hd44780_model.v", "sim/tb_display.v"]
    out = run_xsim("tb_display", srcs, run, generics={
        "STATE": a.state, "SCORE": a.score, "THR": a.thr, "MARGIN": margin & 0xFFFF,
        "SRC": a.src, "FPS": a.fps, "CAMFILE": int(a.camera)})
    lines = [l for l in out.splitlines() if l.startswith(" ")]
    print("\n".join(lines))

    rgb = np.zeros((480, 640, 3), np.uint8)
    n = 0
    for line in (run / "vga.hex").read_text().splitlines():
        x, y, v = line.split()
        v = int(v, 16)
        rgb[int(y), int(x)] = [((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17]
        n += 1
    print(f" captured {n} of {640 * 480} visible pixels")
    (ROOT / "docs").mkdir(exist_ok=True)
    png = ROOT / "docs" / f"vga_{name}.png"
    Image.fromarray(rgb).save(png)
    print(f" wrote {png}")

    sign = "-" if margin < 0 else "+"
    l1 = LINE1[a.state]
    l2 = (f"PHOTO S{min(a.score, 999):03d} M{sign}{min(abs(margin), 999):03d}" if a.src else
          f"S{min(a.score, 999):03d} M{sign}{min(abs(margin), 999):03d} {min(a.fps, 99):02d}FPS")
    got1 = next(l for l in lines if "LCD line 1" in l).split("|")[1]
    got2 = next(l for l in lines if "LCD line 2" in l).split("|")[1]
    ok = got1 == l1 and got2 == l2
    print(f" LCD expected |{l1}| |{l2}| -> {'MATCH' if ok else 'MISMATCH'}")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
