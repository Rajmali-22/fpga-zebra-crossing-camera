#!/usr/bin/env python3
"""
Feed the bytes the RTL actually sent in the end-to-end simulation
(sim/run/vision/rx.hex, from sim/check_vision.py) to host/zebracam.py's
protocol code, in the same command order as the testbench, so the PC tool and
the FPGA are known to agree byte for byte before any hardware exists.
"""

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "host"))
import zebracam  # noqa: E402


class Replay:
    def __init__(self, data):
        self.d, self.i, self.sent = bytes(data), 0, []

    def write(self, b):
        self.sent.append(bytes(b)[:1])

    def read(self, n, timeout=2.0):
        out = self.d[self.i:self.i + n]
        self.i += len(out)
        return out

    def drain(self):
        pass


def main():
    rx = [int(v, 16) for v in (ROOT / "sim" / "run" / "vision" / "rx.hex").read_text().split()]
    photo = np.array([int(v, 16) for v in (ROOT / "mem" / "test_images.hex").read_text().split()[:4800]], np.uint8)
    cam = zebracam.ZebraCam.__new__(zebracam.ZebraCam)
    cam.t = Replay(rx)
    ok = True

    def check(c, msg):
        nonlocal ok
        print(("  ok   " if c else "  FAIL ") + msg)
        ok &= bool(c)

    v = cam.version()
    check(v == "ZEBRACAM 1.1 I", f"version {v!r}")
    info, img = cam.snapshot()
    check(img.shape == (60, 80) and info["thr"] == 477 and info["state"] in (0, 1, 2) and info["stretched"],
          f"snapshot {info}")
    st = cam.status()
    check(st["tag"] == "ZC11" and st["line_len"] == 640 and st["lines"] == 480 and st["hi"] >= st["lo"],
          f"status frames {st['frames']}, auto-contrast {st['lo']}..{st['hi']}")
    cam.pause(True)
    det, score = cam.classify(photo)
    check((det, score) == (1, 503), f"photo result det {det} score {score}")
    info2, img2 = cam.snapshot()
    check(np.array_equal(img2, photo.reshape(60, 80)) and info2["photo"] and info2["paused"], "snapshot of the photo")
    cam.pause(False)
    check(cam.t.i == len(rx), "all bytes consumed")
    check([s for s in cam.t.sent] == [b"v", b"g", b"s", b"p", b"\xa5", b"g", b"r"], "command order")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
