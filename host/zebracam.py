#!/usr/bin/env python3
"""
zebracam.py - PC side of the zebra-crossing camera (FPGA design in this repo).

    python host/zebracam.py auto selftest           # find the board, check every subsystem
    python host/zebracam.py COM5 info               # version + camera / BCNN status
    python host/zebracam.py COM5 live               # live window: what the network sees + answer
    python host/zebracam.py COM5 live --save data   # ... and z / n keys store labelled frames
    python host/zebracam.py COM5 photo a.jpg b.jpg  # classify photos on the FPGA (+ golden check)
    python host/zebracam.py COM5 hil vectors/       # golden test vectors through the real FPGA
    python host/zebracam.py COM5 snapshot out.png   # what the network sees right now
    python host/zebracam.py COM5 capture out.png    # full 640x480 photo (frame_capture, 'c')
    python host/zebracam.py COM5 pause | resume     # stop / restart camera inference

Use "fake" instead of a COM port for a software model of the FPGA (golden
models, photos in web_test/ as the "camera"), to try everything without a board.

Link: 5,333,333 baud 8-N-1 (133.33 MHz / 25 on the FPGA, 12 MHz / 2.25 on the
board's FT2232H). Protocol: rtl/vision/uart_link.v.
"""

import argparse
import json
import struct
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
from bcnn_model import int_forward, preprocess_image, read_mem_files  # noqa: E402
from cam_golden import autocontrast  # noqa: E402

BAUD = 5_333_333
W, H, NPIX = 80, 60, 4800
STATES = {0: "NO CROSSING", 1: "NOT SURE", 2: "ZEBRA CROSSING", 3: "WAITING FOR CAMERA"}
DEMO = json.loads((ROOT / "mem" / "demo.json").read_text())


class LinkError(RuntimeError):
    pass


def s16(v):
    return v - 65536 if v >= 32768 else v


def verdict(margin):
    return "CROSSING" if margin >= DEMO["hi"] else ("NO CROSSING" if margin < DEMO["lo"] else "NOT SURE")


#------------------------------------------------------------------------------
# Transport
#------------------------------------------------------------------------------

class Serial:
    def __init__(self, port, baud=BAUD):
        import serial
        try:
            self.s = serial.Serial(port, baud, timeout=1.0, write_timeout=5.0)
        except serial.SerialException as e:
            raise SystemExit(f"cannot open {port}: {e}\n"
                             f"(close other programs using it; if {baud} baud is refused, the "
                             f"USB-UART chip is not an FT2232H - see README, 'Baud rate')")
        time.sleep(0.05)
        self.s.reset_input_buffer()

    def write(self, b):
        self.s.write(bytes(b))
        self.s.flush()

    def read(self, n, timeout=2.0):
        out = bytearray()
        end = time.time() + timeout
        while len(out) < n and time.time() < end:
            out += self.s.read(n - len(out))
        return bytes(out)

    def drain(self):
        time.sleep(0.05)
        self.s.reset_input_buffer()


class FakeFPGA:
    """Software stand-in: same bytes as the RTL, answers from the golden models."""

    def __init__(self):
        from cam_golden import camera_input, photo_to_frame565
        self.folded = read_mem_files(ROOT / "mem")
        self.thr = int(self.folded[-1][1][0])
        photos = sorted((ROOT / "demo_photos").glob("*.jpg"))
        self.cam = [autocontrast(camera_input(photo_to_frame565(Image.open(p))))[0] for p in photos] or \
                   [np.full((H, W), 128, np.uint8)]
        self.k, self.out, self.paused, self.infer, self.hist = 0, bytearray(), False, 0, []
        self.t0 = time.time()              # frames 'arrive' at 26.7 per second
        self.last = (self.cam[0], 0, 0, 0)        # image, src, score, frame

    def _result(self, img):
        _, score, _ = int_forward(img, self.folded)
        self.infer += 1
        return int(score)

    def write(self, b):
        b = bytes(b)
        if b[:1] == b"\xA5" and len(b) == 1 + NPIX:
            img = np.frombuffer(b[1:], np.uint8).reshape(H, W)
            score = self._result(img)
            self.last = (img, 1, score, self.last[3])
            self.out += bytes([0x5A, int(score >= self.thr), score >> 8, score & 255])
            return
        c = b[:1]
        if c == b"v":
            self.out += b"ZEBRACAM 1.1 F\n"
        elif c in (b"p", b"r"):
            self.paused = c == b"p"
            self.out += b"P" if self.paused else b"R"
        elif c in (b"g", b"s"):
            if not self.paused:
                img = self.cam[self.k % len(self.cam)]
                self.k += 1
                score = self._result(img)
                self.hist = (self.hist + [score - self.thr])[-4:]
                self.last = (img, 0, score, self.k)
            img, src, score, frame = self.last
            margin = score - self.thr
            avg = margin if src else int(np.floor(np.mean(self.hist))) if self.hist else margin
            v = avg
            state = 2 if v >= DEMO["hi"] else (0 if v < DEMO["lo"] else 1)
            info = struct.pack(">BBHhhhHHBB", state, src | (self.paused << 1), score, self.thr,
                               margin, avg, frame, self.infer, 13, 0 if src else 1)
            if c == b"g":
                self.out += bytes([0xA5, 0x5A, 0x0F, 0xF1, 0, W, 0, H]) + info + img.tobytes() + b"\x5A\xA5"
            else:
                st = info + struct.pack(">HHHHHBBBBBB", int((time.time() - self.t0) * 26.7) & 0xFFFF,
                                      0, 640, 480, 0, 6, 0, 0, 255, 0, 0) + b"ZC11"
                self.out += bytes([0xA5, 0x5A, 0x0F, 0xF2]) + st + b"\x5A\xA5"
        elif c == b"c":
            from cam_golden import photo_to_frame565
            f = photo_to_frame565(Image.fromarray(np.repeat(self.last[0], 8, 0).repeat(8, 1)).convert("RGB"))
            self.out += bytes([0xA5, 0x5A, 0x0F, 0xF0, 2, 128, 1, 224, 2, 1]) + f.astype(">u2").tobytes() + b"\x5A\xA5"

    def read(self, n, timeout=2.0):
        out, self.out = bytes(self.out[:n]), self.out[n:]
        return out

    def drain(self):
        self.out = bytearray()


#------------------------------------------------------------------------------
# Protocol
#------------------------------------------------------------------------------

def find_port():
    """The board's FT2232H shows up as two COM ports (JTAG and UART); ask every
    port for the version string and keep the one that answers."""
    import serial
    import serial.tools.list_ports as lp
    ports = sorted(lp.comports(), key=lambda p: (p.vid != 0x0403, p.device))   # FTDI first
    tried = []
    for p in ports:
        tried.append(f"{p.device} ({p.description})")
        try:
            s = serial.Serial(p.device, BAUD, timeout=0.3, write_timeout=0.5)
        except Exception:
            continue
        try:
            time.sleep(0.05)
            s.reset_input_buffer()
            s.write(b"v")
            if s.read(15).startswith(b"ZEBRACAM"):
                s.close()
                return p.device
        except Exception:
            pass
        s.close()
    raise SystemExit("no zebra-crossing FPGA answered on any COM port.\n  ports: "
                     + ("; ".join(tried) or "none") +
                     "\n  -> board powered, programmed (DONE LED on), USB cable in, switch M6 UP?")


class ZebraCam:
    def __init__(self, port):
        if port.lower() == "auto":
            port = find_port()
            print(f"(FPGA found on {port})")
        self.port = port
        self.t = FakeFPGA() if port.lower() == "fake" else Serial(port)

    def _expect(self, n, what, timeout=2.0):
        b = self.t.read(n, timeout)
        if len(b) != n:
            raise LinkError(f"{what}: got {len(b)} of {n} bytes "
                            f"(board programmed? right COM port? uart pins swapped?)")
        return b

    def version(self):
        self.t.drain()
        self.t.write(b"v")
        return self._expect(15, "version").decode(errors="replace").strip()

    @staticmethod
    def _info(b):
        state, flags, score, thr, margin, avg, frame, infer, fps, f2 = struct.unpack(">BBHhhhHHBB", b)
        return dict(state=state, photo=bool(flags & 1), paused=bool(flags & 2), score=score, thr=thr,
                    margin=margin, avg=avg, frame=frame, infer=infer, fps=fps, stretched=bool(f2 & 1))

    def snapshot(self):
        self.t.write(b"g")
        h = self._expect(4, "snapshot header", 1.0)
        if h == bytes([0xA5, 0x5A, 0x0F, 0xEE]):
            self._expect(2, "error trailer")
            raise LinkError("FPGA: BCNN engine did not answer within 250 ms")
        if h != bytes([0xA5, 0x5A, 0x0F, 0xF1]):
            raise LinkError(f"snapshot: bad header {h.hex()}")
        size = self._expect(4, "snapshot size")
        info = self._info(self._expect(16, "snapshot info"))
        img = np.frombuffer(self._expect(NPIX, "snapshot pixels"), np.uint8).reshape(H, W)
        if self._expect(2, "snapshot trailer") != b"\x5A\xA5":
            raise LinkError("snapshot: bad trailer")
        assert size == bytes([0, W, 0, H])
        return info, img

    def status(self):
        self.t.write(b"s")
        h = self._expect(4, "status header", 1.0)
        if h != bytes([0xA5, 0x5A, 0x0F, 0xF2]):
            raise LinkError(f"status: bad header {h.hex()}")
        b = self._expect(36, "status")
        self._expect(2, "status trailer")
        st = self._info(b[:16])
        (st["frames"], st["rejected"], st["line_len"], st["lines"],
         st["skipped"], st["cam_led"], st["flags"], st["lo"], st["hi"]) = struct.unpack(">HHHHHBBBB", b[16:30])
        st["tag"] = b[32:36].decode(errors="replace")
        st["stretch_photo"] = bool(st["flags"] & 4)
        return st

    def classify(self, img):
        img = np.asarray(img, np.uint8).reshape(-1)
        assert img.size == NPIX
        self.t.write(b"\xA5" + img.tobytes())
        r = self._expect(4, "photo result", 3.0)
        if r[0] != 0x5A:
            raise LinkError(f"photo result: bad header {r.hex()}")
        if r[1:] == b"\xFF\xFF\xFF":
            raise LinkError("FPGA: no result within 500 ms")
        return r[1], (r[2] << 8) | r[3]

    def pause(self, on=True):
        self.t.write(b"p" if on else b"r")
        r = self._expect(1, "pause ack")
        if r != (b"P" if on else b"R"):
            raise LinkError(f"pause: got {r!r}")

    def capture(self):
        self.t.write(b"c")
        hdr = self._expect(10, "capture header", 3.0)
        if hdr[:4] != bytes([0xA5, 0x5A, 0x0F, 0xF0]):
            raise LinkError(f"capture: bad header {hdr.hex()}")
        w, h = (hdr[4] << 8) | hdr[5], (hdr[6] << 8) | hdr[7]
        raw = self._expect(w * h * 2, "capture pixels", 10.0)
        self._expect(2, "capture trailer")
        px = np.frombuffer(raw, ">u2").reshape(h, w)
        from cam_golden import expand_565
        return expand_565(px)


#------------------------------------------------------------------------------
# Commands
#------------------------------------------------------------------------------

def cmd_info(cam, a):
    print("version :", cam.version())
    st = cam.status()
    print(f"camera  : {st['frames']} frames committed, {st['rejected']} rejected, "
          f"last line {st['line_len']} px, last frame {st['lines']} lines, "
          f"camera_interface LEDs {st['cam_led']:04b} (0110 = configured)")
    print(f"BCNN    : {st['infer']} inferences, {st['fps']} per second, {st['skipped']} frames skipped; "
          f"auto-contrast {'on, levels ' + str(st['lo']) + '..' + str(st['hi']) if st['stretched'] else 'off'}; "
          f"build: {'PROVEN' if st['flags'] & 1 else 'IOB'} SDRAM, core {'66.7' if st['flags'] & 2 else '50'} MHz")
    print(f"answer  : {STATES[st['state']]}  score {st['score']}  threshold {st['thr']}  "
          f"margin {st['margin']:+d}  averaged {st['avg']:+d}"
          f"{'  (photo from PC)' if st['photo'] else ''}{'  (paused)' if st['paused'] else ''}")
    ok = st["line_len"] == 640 and st["lines"] == 480 and st["frames"] > 0
    print("camera check:", "OK" if ok else "NOT OK - see README, 'Bring-up'")


def cmd_selftest(cam, a):
    """Everything a working system must show, each with the fix if it does not."""
    results = []

    def report(name, ok, detail, fix=""):
        results.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:28s} {detail}")
        if not ok and fix:
            print(f"         -> {fix}")

    print("zebra-crossing camera self-test")
    try:
        v = cam.version()
    except LinkError as e:
        report("UART link", False, str(e), "check the COM port; the board must run top.bit")
        return 1
    report("UART link", v.startswith("ZEBRACAM"), v)

    st1 = cam.status()
    time.sleep(1.2)
    st2 = cam.status()
    fps_cam = (st2["frames"] - st1["frames"]) / 1.2
    report("camera configured (SCCB)", st2["cam_led"] in (0b0110, 0b1001),
           f"camera_interface LEDs {st2['cam_led']:04b}" +
           (" (1001 = after a brightness/contrast change, or a camera FIFO overflow)" if st2["cam_led"] == 0b1001 else ""),
           "OV7670 not answering on SCCB: check the camera seating / 3.3 V / SDA M16-SCL N16 wiring, press reset")
    report("camera frames arriving", fps_cam > 5, f"{fps_cam:.1f} frames/s committed "
           f"({st2['rejected'] - st1['rejected']} rejected)",
           "no VSYNC/HREF/PCLK: check the camera header; XCLK is pin R16")
    report("frame geometry 640 x 480", st2["line_len"] >= 640 and st2["lines"] >= 480,
           f"last line {st2['line_len']} px, last frame {st2['lines']} lines",
           "camera window registers differ (HSTART/VSTART); see README 'Bring-up'")
    report("BCNN running on camera", st2["infer"] > st1["infer"] or st2["paused"],
           f"{st2['fps']} inferences/s, {st2['skipped']} frames skipped",
           "clk_core not running? check LED 7 (heartbeat)")
    report("auto-contrast", st2["stretched"] or not st2["frames"],
           f"levels {st2['lo']}..{st2['hi']}" if st2["stretched"] else "off (switch sw[8] up?)")

    # golden vectors through the real hardware
    d = ROOT / "mem"
    imgs = np.array([int(x, 16) for x in (d / "test_images.hex").read_text().split()], np.uint8).reshape(-1, NPIX)
    exp = [int(x, 16) for x in (d / "test_expected.hex").read_text().split()]
    n = min(len(imgs), a.n)
    cam.pause(True)
    try:
        match = sum(cam.classify(imgs[i]) == (exp[i] >> 15, exp[i] & 0x7FFF) for i in range(n))
    finally:
        cam.pause(False)
    report("BCNN = golden model", match == n, f"{match}/{n} test images bit-exact",
           "ROM contents differ from mem/: rebuild with vivado/build.tcl from this repo")

    info, img = cam.snapshot()
    Image.fromarray(img).resize((W * 6, H * 6), Image.NEAREST).save("selftest_snapshot.png")
    report("snapshot", True, f"{STATES[info['state']]}, score {info['score']}, margin {info['margin']:+d} "
           f"-> selftest_snapshot.png")
    ok = all(results)
    print("ALL PASS - the system is working" if ok else "SOME CHECKS FAILED - see the hints above")
    return 0 if ok else 1


def cmd_snapshot(cam, a):
    info, img = cam.snapshot()
    Image.fromarray(img).resize((W * 6, H * 6), Image.NEAREST).save(a.out)
    print(f"{STATES[info['state']]}: score {info['score']} (thr {info['thr']}, margin {info['margin']:+d}, "
          f"avg {info['avg']:+d}), frame {info['frame']} -> {a.out}")


def cmd_capture(cam, a):
    rgb = cam.capture()
    Image.fromarray(rgb).save(a.out)
    print(f"{rgb.shape[1]}x{rgb.shape[0]} photo -> {a.out}")


def cmd_photo(cam, a):
    folded = read_mem_files(ROOT / "mem")
    thr = int(folded[-1][1][0])
    match = 0
    stretch = cam.status()["stretch_photo"]
    import glob
    files = [g for f in a.files for g in (sorted(glob.glob(f)) or [f])]   # cmd.exe does not expand *
    cam.pause(True)
    try:
        for f in files:
            px = preprocess_image(Image.open(f), 8)
            det, score = cam.classify(px)
            gd, gs, _ = int_forward(autocontrast(px)[0] if stretch else px, folded)
            same = (det == int(gd)) and score == gs
            match += same
            print(f"{Path(f).name:36s} score {score:4d}  margin {score - thr:+4d}  "
                  f"{verdict(score - thr):12s} golden {'MATCH' if same else f'MISMATCH ({gs})'}")
    finally:
        if not a.keep_paused:
            cam.pause(False)
    print(f"FPGA = golden model on {match}/{len(files)} photos")


def cmd_hil(cam, a):
    d = Path(a.vectors)
    imgs = np.array([int(v, 16) for v in (d / "test_images.hex").read_text().split()], np.uint8).reshape(-1, NPIX)
    exp = [int(v, 16) for v in (d / "test_expected.hex").read_text().split()]
    labels = [int(v) for v in (d / "test_labels.txt").read_text().split()]
    n = min(a.n or len(imgs), len(imgs))
    cam.pause(True)
    t0, match, correct, bad = time.time(), 0, 0, []
    try:
        for i in range(n):
            det, score = cam.classify(imgs[i])
            e_det, e_score = exp[i] >> 15, exp[i] & 0x7FFF
            ok = det == e_det and score == e_score
            match += ok
            correct += det == labels[i]
            if not ok:
                bad.append(i)
            if (i + 1) % 50 == 0 or i == n - 1:
                print(f"  {i + 1}/{n}: {match} match golden, accuracy {correct / (i + 1):.3f}", flush=True)
    finally:
        cam.pause(False)
    dt = time.time() - t0
    print(f"FPGA hardware = golden model on {match}/{n} images; accuracy vs labels {correct / n:.4f}; "
          f"{dt / n * 1000:.1f} ms per image (UART + inference)")
    if bad:
        print("mismatching vectors:", bad[:20])
    return 0 if match == n else 1


def cmd_pause(cam, a):
    cam.pause(a.cmd == "pause")
    print("camera inference", "paused" if a.cmd == "pause" else "running")


def cmd_live(cam, a):
    import cv2
    save = Path(a.save) if a.save else None
    data = {"X": [], "y": []}
    if save:
        save.mkdir(parents=True, exist_ok=True)
        npz = save / "camera_set.npz"
        if npz.exists():
            old = np.load(npz)
            data = {"X": list(old["X"]), "y": list(old["y"])}
        print(f"saving labelled frames to {npz} ({len(data['y'])} already there)")
    hist = []
    colours = {0: (0, 0, 255), 1: (0, 255, 255), 2: (0, 255, 0), 3: (160, 160, 160)}
    paused = False
    print("keys: z = crossing, n = no crossing (with --save), p = pause/resume, q = quit")
    while True:
        try:
            info, img = cam.snapshot()
        except LinkError as e:
            print("link:", e)
            time.sleep(0.5)
            continue
        hist = (hist + [info["margin"]])[-120:]
        big = cv2.resize(img, (W * 6, H * 6), interpolation=cv2.INTER_NEAREST)
        canvas = np.zeros((H * 6 + 160, W * 6 + 20, 3), np.uint8)
        canvas[10:10 + H * 6, 10:10 + W * 6] = big[..., None]
        col = colours[info["state"]]
        cv2.rectangle(canvas, (5, 5), (W * 6 + 14, H * 6 + 14), col, 3)
        cv2.putText(canvas, STATES[info["state"]], (12, H * 6 + 48), cv2.FONT_HERSHEY_SIMPLEX, 1.0, col, 2)
        cv2.putText(canvas, f"score {info['score']}  thr {info['thr']}  margin {info['margin']:+d}  "
                            f"avg {info['avg']:+d}  {info['fps']} fps{'  auto-contrast' if info['stretched'] else ''}",
                    (12, H * 6 + 78), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        y0, y1 = H * 6 + 150, H * 6 + 95
        for lvl, c in ((DEMO["hi"], (0, 255, 0)), (0, (255, 255, 255)), (DEMO["lo"], (0, 0, 255))):
            yy = int(np.interp(lvl, [-150, 150], [y0, y1]))
            cv2.line(canvas, (10, yy), (W * 6 + 10, yy), c, 1)
        for i in range(1, len(hist)):
            p0 = (10 + (i - 1) * 4, int(np.interp(hist[i - 1], [-150, 150], [y0, y1])))
            p1 = (10 + i * 4, int(np.interp(hist[i], [-150, 150], [y0, y1])))
            cv2.line(canvas, p0, p1, (255, 200, 0), 2)
        if save:
            cv2.putText(canvas, f"saved {len(data['y'])} ({sum(data['y'])} crossing)",
                        (W * 6 - 170, H * 6 + 48), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 200, 200), 1)
        cv2.imshow("zebra-crossing FPGA - what the network sees", canvas)
        k = cv2.waitKey(1) & 0xFF
        if k == ord("q"):
            break
        if k == ord("p"):
            paused = not paused
            cam.pause(paused)
        if save and k in (ord("z"), ord("n")):
            data["X"].append(img.copy())
            data["y"].append(1 if k == ord("z") else 0)
            Image.fromarray(img).save(save / f"{len(data['y']):05d}_{'z' if k == ord('z') else 'n'}.png")
            np.savez_compressed(save / "camera_set.npz", X=np.array(data["X"]), y=np.array(data["y"], np.uint8))
    cv2.destroyAllWindows()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("port", help="COM port (e.g. COM5), 'auto' to find the board, or 'fake' for the software model")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    s = sub.add_parser("selftest"); s.add_argument("--n", type=int, default=20)
    s = sub.add_parser("snapshot"); s.add_argument("out", nargs="?", default="snapshot.png")
    s = sub.add_parser("capture"); s.add_argument("out", nargs="?", default="capture.png")
    s = sub.add_parser("photo"); s.add_argument("files", nargs="+"); s.add_argument("--keep-paused", action="store_true")
    s = sub.add_parser("hil"); s.add_argument("vectors"); s.add_argument("--n", type=int)
    s = sub.add_parser("live"); s.add_argument("--save")
    sub.add_parser("pause"); sub.add_parser("resume")
    a = p.parse_args()
    cam = ZebraCam(a.port)
    fn = {"info": cmd_info, "selftest": cmd_selftest, "snapshot": cmd_snapshot, "capture": cmd_capture, "photo": cmd_photo,
          "hil": cmd_hil, "live": cmd_live, "pause": cmd_pause, "resume": cmd_pause}[a.cmd]
    try:
        return fn(cam, a) or 0
    except LinkError as e:
        print("ERROR:", e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
