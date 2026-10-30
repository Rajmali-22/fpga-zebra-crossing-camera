#!/usr/bin/env python3
"""
End-to-end check of the detection path (rtl/vision/*) with sim/tb_vision.v.

Camera frames come from two real photos; the uploaded photo is golden test
vector 0 of the v3 model (mem/test_images.hex). Checks:
  * 'v' version string
  * 'g' snapshot: pixels == cam_golden.camera_input(source frame),
    score == bcnn_model.int_forward(pixels), threshold, margin, state
  * 's' status: frame counters, 640-pixel lines, 480 lines, no rejected frames
  * 'p' / 'r' acknowledgements
  * photo upload: reply == golden expected result of test vector 0
  * 'g' after the upload shows that photo, source flag and pause flag set
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "sim"))
from bcnn_model import int_forward, load_net, read_mem_files  # noqa: E402
from cam_golden import autocontrast, camera_input, photo_to_frame565, write_bytes_hex, write_frame_hex  # noqa: E402
from xsim import fresh_dir, run_xsim  # noqa: E402

PHOTO = ROOT.parent / "zebra-crossing-bcnn-fpga" / "web_test" / "zebra_03.jpg"
REAL = ROOT.parent / "soc" / "soc" / "plain" / "capture.raw"     # a real OV7670 frame from this board
RTL = ["rtl/io/cdc.v", "rtl/io/bram.v", "rtl/bcnn/bcnn_core.v", "rtl/vision/cam_preproc.v",
       "rtl/vision/bcnn_engine.v", "rtl/vision/uart_link.v", "rtl/vision/vision.v",
       "rtl/camera/uart_rx.v", "rtl/camera/uart_tx.v", "sim/ov7670_model.v", "sim/tb_vision.v"]


def s16(hi, lo):
    v = (hi << 8) | lo
    return v - 65536 if v >= 32768 else v


class Reader:
    def __init__(self, data):
        self.d, self.i = data, 0

    def take(self, n, what):
        if self.i + n > len(self.d):
            raise SystemExit(f"FAIL: ran out of bytes reading {what} ({len(self.d) - self.i} left, need {n})")
        out = self.d[self.i:self.i + n]
        self.i += n
        return out


def parse_snapshot(r, what):
    h = r.take(8, what + " header")
    assert list(h) == [0xA5, 0x5A, 0x0F, 0xF1, 0, 80, 0, 60], f"{what}: bad header {h.hex()}"
    info = r.take(16, what + " info")
    pix = np.frombuffer(bytes(r.take(4800, what + " pixels")), np.uint8).reshape(60, 80)
    t = r.take(2, what + " trailer")
    assert list(t) == [0x5A, 0xA5], f"{what}: bad trailer {t.hex()}"
    return dict(state=info[0], src=info[1] & 1, paused=(info[1] >> 1) & 1,
                score=(info[2] << 8) | info[3], thr=s16(info[4], info[5]),
                margin=s16(info[6], info[7]), avg=s16(info[8], info[9]),
                frame=(info[10] << 8) | info[11], infer=(info[12] << 8) | info[13],
                fps=info[14], stretched=info[15] & 1), pix


def band(v, lo, hi):
    return 2 if v >= hi else (0 if v < lo else 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--run-dir", default=str(ROOT / "sim" / "run" / "vision"))
    p.add_argument("--infer-wait", type=int, default=2)
    p.add_argument("--raw", action="store_true", help="auto-contrast switch off")
    p.add_argument("--core-mhz", type=float, default=50.0, help="BCNN clock in the testbench")
    a = p.parse_args()

    mem = ROOT / "mem"
    run = fresh_dir(a.run_dir)
    for f in mem.iterdir():
        (run / f.name).write_bytes(f.read_bytes())
    folded = read_mem_files(mem)
    demo = json.loads((mem / "demo.json").read_text())

    frames = [photo_to_frame565(Image.open(PHOTO))]
    if REAL.exists():
        frames.append(np.frombuffer(REAL.read_bytes(), ">u2").reshape(480, 640).astype(np.uint16))
    else:
        frames.append(photo_to_frame565(Image.open(PHOTO.with_name("none_03.jpg"))))
    for k, f in enumerate(frames):
        write_frame_hex(f, run / f"frame{k}.hex")
    cam = [camera_input(f) if a.raw else autocontrast(camera_input(f))[0] for f in frames]
    lohi = [(0, 255) if a.raw else autocontrast(camera_input(f))[1:] for f in frames]
    vec_imgs = np.array([int(v, 16) for v in (mem / "test_images.hex").read_text().split()], np.uint8)
    photo = vec_imgs[:4800].reshape(60, 80)
    write_bytes_hex(photo, run / "photo.hex")
    exp0 = int((mem / "test_expected.hex").read_text().split()[0], 16)

    out = run_xsim("tb_vision", RTL, run, generics={"INFER_WAIT": a.infer_wait, "SW_RAW": int(a.raw),
                             "CORE_HALF": round(500.0 / a.core_mhz, 4), "CORE_HZ": int(a.core_mhz * 1e6)},
                   include=[run])
    lines = [l for l in out.splitlines() if l.startswith(" ")]
    print("\n".join(lines))
    errors = [l for l in lines if "ERROR" in l]

    rx = [int(v, 16) for v in (run / "rx.hex").read_text().split()]
    r = Reader(rx)
    ok = not errors
    def check(cond, msg):
        nonlocal ok
        print(("  ok   " if cond else "  FAIL ") + msg)
        ok &= bool(cond)

    ver = bytes(r.take(15, "version")).decode(errors="replace")
    check(ver == "ZEBRACAM 1.1 I\n", f"version string {ver!r}")

    info, pix = parse_snapshot(r, "snapshot 1")
    src = (info["frame"] - 1) % len(frames)
    gold_det, gold_score, _ = int_forward(cam[src], folded)
    what = "camera_input" if a.raw else "autocontrast(camera_input)"
    check(np.array_equal(pix, cam[src]), f"snapshot pixels == {what}(frame {info['frame']} -> source {src})")
    check(info["stretched"] == (0 if a.raw else 1), f"auto-contrast flag {info['stretched']}")
    check(info["score"] == gold_score, f"score {info['score']} == golden {gold_score}")
    check(info["thr"] == int(folded[-1][1][0]), f"threshold {info['thr']}")
    check(info["margin"] == gold_score - info["thr"], f"margin {info['margin']}")
    check(info["state"] == band(info["avg"], demo["lo"], demo["hi"]),
          f"state {info['state']} matches averaged margin {info['avg']} and band {demo['lo']}..{demo['hi']}")
    check(info["src"] == 0 and info["paused"] == 0, "source camera, not paused")

    st = r.take(42, "status")
    check(list(st[:4]) == [0xA5, 0x5A, 0x0F, 0xF2] and list(st[-2:]) == [0x5A, 0xA5], "status framing")
    sb = st[4:40]
    committed, rejected = (sb[16] << 8) | sb[17], (sb[18] << 8) | sb[19]
    line_len, nlines = (sb[20] << 8) | sb[21], (sb[22] << 8) | sb[23]
    check(committed >= 2 and rejected == 0, f"frames committed {committed}, rejected {rejected}")
    check(line_len == 640 and nlines == 480, f"line length {line_len}, lines {nlines}")
    check(bytes(sb[32:36]) == b"ZC11" and sb[26] == 6, f"status tag {bytes(sb[32:36])}, camera LEDs {sb[26]}")
    st_src = (((sb[10] << 8) | sb[11]) - 1) % len(frames)
    check((sb[28], sb[29]) == tuple(lohi[st_src]), f"auto-contrast lo/hi {sb[28]}/{sb[29]} == golden {lohi[st_src]}")

    check(r.take(1, "pause ack") == [ord("P")], "pause acknowledged")
    rep = r.take(4, "upload reply")
    exp_det, exp_score = exp0 >> 15, exp0 & 0x7FFF
    check(rep == [0x5A, exp_det, exp_score >> 8, exp_score & 0xFF],
          f"upload reply {bytes(rep).hex()} == golden 5a {exp_det:02x} {exp_score:04x}")

    info2, pix2 = parse_snapshot(r, "snapshot 2")
    check(np.array_equal(pix2, photo), "snapshot after upload shows the uploaded photo")
    check(info2["src"] == 1 and info2["paused"] == 1 and info2["stretched"] == 0,
          "source photo, paused, photo used as it is (no auto-contrast)")
    check(info2["score"] == exp_score, f"snapshot score {info2['score']} == upload score")

    check(r.take(1, "resume ack") == [ord("R")], "resume acknowledged")
    check(r.i == len(rx), f"no stray bytes ({len(rx) - r.i} extra)")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
