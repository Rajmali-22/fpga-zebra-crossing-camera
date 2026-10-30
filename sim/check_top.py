#!/usr/bin/env python3
"""
Whole-design simulation (rtl/top.v with the Xilinx MMCM / ODDR models): the
camera model on the camera pins, a serial PC on the UART pins, no SDRAM.

Checks: MMCM locks, XCLK = 21.33 MHz, version over the real UART pins, the
snapshot equals autocontrast(camera_input(frame)) and its score the golden
model, status, photo upload = golden, LED 0/1/2 follow the decision.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "sim"))
from bcnn_model import int_forward, read_mem_files  # noqa: E402
from cam_golden import autocontrast, camera_input, photo_to_frame565, write_bytes_hex, write_frame_hex  # noqa: E402
from check_vision import Reader, parse_snapshot  # noqa: E402
from xsim import fresh_dir, run_xsim  # noqa: E402

RTL = sorted(str(p.relative_to(ROOT)) for d in ("rtl", "rtl/io", "rtl/vision", "rtl/bcnn", "rtl/camera")
             for p in (ROOT / d).glob("*.v"))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-sim", action="store_true", help="re-check the last run (sim/run/top) without simulating")
    a = ap.parse_args()
    run = ROOT / "sim" / "run" / "top"
    if not a.no_sim:
        run = fresh_dir(run)
    mem = ROOT / "mem"
    for f in mem.iterdir():
        (run / f.name).write_bytes(f.read_bytes())
    folded = read_mem_files(mem)
    frames = [photo_to_frame565(Image.open(ROOT.parent / "zebra-crossing-bcnn-fpga" / "web_test" / n))
              for n in ("zebra_03.jpg", "none_03.jpg")]
    for k, f in enumerate(frames):
        write_frame_hex(f, run / f"frame{k}.hex")
    net = [autocontrast(camera_input(f))[0] for f in frames]
    photo = np.array([int(v, 16) for v in (mem / "test_images.hex").read_text().split()[:4800]], np.uint8)
    write_bytes_hex(photo, run / "photo.hex")
    exp0 = int((mem / "test_expected.hex").read_text().split()[0], 16)

    if a.no_sim:
        out = (run / "xsim.log").read_text(errors="replace")
    else:
        out = run_xsim("tb_top", RTL + ["sim/ov7670_model.v", "sim/tb_top.v"], run, include=[run], glbl=True)
    lines = [l for l in out.splitlines() if l.startswith(" ")]
    print("\n".join(lines))
    ok = not any("ERROR" in l for l in lines)

    def check(c, msg):
        nonlocal ok
        print(("  ok   " if c else "  FAIL ") + msg)
        ok &= bool(c)

    xl = next((l for l in lines if "XCLK" in l), "")
    check(xl and abs(float(xl.split()[1]) - 21.333) < 0.01, f"camera XCLK: {xl.strip()}")
    r = Reader([int(v, 16) for v in (run / "rx.hex").read_text().split()])
    check(bytes(r.take(15, "version")) == b"ZEBRACAM 1.1 I\n", "version over the UART pins")
    info, pix = parse_snapshot(r, "snapshot")
    # which camera frame was it? (the model starts before reset ends, so the
    # first frame may be dropped: identify it by content, not by number)
    src = next((i for i in range(2) if np.array_equal(pix, net[i])), -1)
    _, gs, _ = int_forward(net[max(src, 0)], folded)
    check(src >= 0, f"snapshot = autocontrast(camera_input(camera frame {info['frame']} = photo {src}))")
    check(info["score"] == gs, f"score {info['score']} == golden {gs}")
    st = r.take(42, "status")
    check(st[:4] == [0xA5, 0x5A, 0x0F, 0xF2] and bytes(st[36:40]) == b"ZC11", "status packet")
    rep = r.take(4, "photo reply")
    check(rep == [0x5A, exp0 >> 15, (exp0 & 0x7FFF) >> 8, exp0 & 0xFF], f"photo reply {bytes(rep).hex()}")
    check(r.take(1, "resume") == [ord("R")], "resume ack")
    # LED rule: exactly one of led0..2 lit, matching the state
    for l in lines:
        if "result" in l and "LEDs" in l:
            state = int(l.split("state")[1].split()[0])
            leds = l.split("LEDs")[1].strip().replace("_", "")
            low = leds[-3:][::-1]                    # led0, led1, led2
            want = {2: "100", 1: "010", 0: "001"}.get(state, "000")
            check(low == want, f"LEDs for state {state}: led0..2 = {low}")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
