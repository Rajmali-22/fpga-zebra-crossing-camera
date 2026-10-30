#!/usr/bin/env python3
"""
capture_host.py -- pull a photo off the Artix-7 / OV7670 design over UART.

  pip install pyserial

  python capture_host.py COM5                    # 640x480 -> capture.png, ~1 s
  python capture_host.py COM5 --half             # 320x240, ~4x faster
  python capture_host.py COM5 --wait             # wait for the board's M14 button
  python capture_host.py COM5 -b 2666667 -o me.png   # slower fallback
  python capture_host.py /dev/ttyUSB0            # Linux / macOS

Default baud is 5333333 and MUST match BAUD_RATE on top_module.

Protocol (matches frame_capture.v):
  PC -> FPGA : one command byte, 'c' = full res, 'd' = half res
  FPGA -> PC : A5 5A 0F F0  W_hi W_lo  H_hi H_lo  bpp  fmt      (10 byte header)
               W*H pixels, 2 bytes each, RGB565 HIGH byte first, raster order
               5A A5                                            (2 byte trailer)

Only pyserial is required -- the PNG writer below is self-contained.
"""

import argparse
import struct
import sys
import time
import zlib

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing.  Install it with:  pip install pyserial")

MAGIC = b"\xA5\x5A\x0F\xF0"
TRAILER = b"\x5A\xA5"
HEADER_LEN = 10


# ----------------------------------------------------------------------------
# tiny dependency-free PNG writer
# ----------------------------------------------------------------------------
def write_png(path, width, height, rgb):
    """rgb must be width*height*3 bytes of 8-bit RGB."""
    rows = bytearray()
    stride = width * 3
    for y in range(height):
        rows.append(0)                                  # filter type 0 (None)
        rows += rgb[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# ----------------------------------------------------------------------------
# RGB565 -> RGB888 (bit replication so that 0x1F -> 0xFF, not 0xF8)
# ----------------------------------------------------------------------------
_EXPAND5 = bytes((v << 3) | (v >> 2) for v in range(32))   # 5 bit -> 8 bit
_EXPAND6 = bytes((v << 2) | (v >> 4) for v in range(64))   # 6 bit -> 8 bit


def rgb565_to_rgb888(payload, byteswap=False):
    out = bytearray(len(payload) // 2 * 3)
    o = 0
    for i in range(0, len(payload) - 1, 2):
        if byteswap:
            px = payload[i] | (payload[i + 1] << 8)
        else:
            px = (payload[i] << 8) | payload[i + 1]
        out[o] = _EXPAND5[(px >> 11) & 0x1F]   # R
        out[o + 1] = _EXPAND6[(px >> 5) & 0x3F]  # G
        out[o + 2] = _EXPAND5[px & 0x1F]         # B
        o += 3
    return bytes(out)


# ----------------------------------------------------------------------------
def read_exact(ser, n, what, progress=False):
    """Block until n bytes arrive; bail out if the link goes quiet."""
    buf = bytearray()
    last_progress = 0.0
    t0 = time.time()
    while len(buf) < n:
        chunk = ser.read(min(4096, n - len(buf)))
        if not chunk:
            raise IOError(
                f"timed out after {len(buf)}/{n} bytes of {what} "
                f"-- check the baud rate and that uart_txd is on the right pin"
            )
        buf += chunk
        now = time.time()
        if progress and now - last_progress > 0.25:
            last_progress = now
            pct = 100.0 * len(buf) / n
            rate = len(buf) / max(now - t0, 1e-6)
            eta = (n - len(buf)) / max(rate, 1e-6)
            sys.stdout.write(f"\r  {pct:5.1f}%  {len(buf)}/{n} B  "
                             f"{rate/1024:.1f} kB/s  eta {eta:4.1f}s")
            sys.stdout.flush()
    if progress:
        sys.stdout.write("\r" + " " * 70 + "\r")
        sys.stdout.flush()
    return bytes(buf)


def sync_to_magic(ser, deadline):
    """Slide a 4-byte window along the stream until the header magic shows up."""
    window = bytearray()
    while time.time() < deadline:
        b = ser.read(1)
        if not b:
            continue
        window += b
        if len(window) > 4:
            del window[0]
        if bytes(window) == MAGIC:
            return
    raise IOError("no header magic from the FPGA -- is it programmed, and are "
                  "the baud rate / uart_rxd pin correct?")


def main():
    ap = argparse.ArgumentParser(description="Capture a frame from the FPGA over UART.")
    ap.add_argument("port", help="serial port, e.g. COM5 or /dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=5333333,
                    help="must match BAUD_RATE in top_module.v (default 5333333)")
    ap.add_argument("-o", "--out", default="capture.png", help="output PNG (default capture.png)")
    ap.add_argument("--half", action="store_true", help="ask for 320x240 instead of 640x480")
    ap.add_argument("--raw", metavar="FILE", help="also dump the raw RGB565 payload here")
    ap.add_argument("--byteswap", action="store_true",
                    help="swap the two bytes of every pixel (try this if colours look wrong)")
    ap.add_argument("--wait", action="store_true",
                    help="send no command, just wait for a frame -- use this when you "
                         "trigger the capture with the board's centre push-button")
    args = ap.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=2)
    except (serial.SerialException, ValueError) as exc:
        sys.exit(
            f"could not open {args.port} at {args.baud} baud: {exc}\n"
            f"High rates are limited by the USB-UART bridge, not by the FPGA:\n"
            f"  FT232H / FT2232H : 12 MHz base -> only 12M, 6M, 4M, 3M, 2.4M ...\n"
            f"  FT232R           : max 3M\n"
            f"  CP2102 / CH340   : max 1M / 2M, often unreliable above 921600\n"
            f"Drop to the next rate down and set the SAME number in BAUD_RATE\n"
            f"on top_module, then re-implement."
        )

    with ser:
        ser.reset_input_buffer()
        ser.reset_output_buffer()

        print(f"port {args.port} @ {args.baud} baud")

        if args.wait:
            print("waiting for the centre push-button on the board ... (ctrl-C to quit)")
            deadline = time.time() + 3600.0
        else:
            print(f"requesting {'320x240' if args.half else '640x480'} frame ...")
            ser.write(b"d" if args.half else b"c")
            ser.flush()
            # the FPGA waits for the next frame boundary first, so allow ~100 ms
            deadline = time.time() + 10.0

        sync_to_magic(ser, deadline)

        hdr = read_exact(ser, HEADER_LEN - 4, "header")
        width, height, bpp, fmt = struct.unpack(">HHBB", hdr[:6])
        print(f"header: {width}x{height}, {bpp} bytes/pixel, format 0x{fmt:02X}")

        if bpp != 2 or width == 0 or height == 0 or width > 2048 or height > 2048:
            sys.exit(f"header looks corrupt ({width}x{height}, bpp={bpp}) -- baud rate mismatch?")

        n = width * height * bpp
        secs = n * 10 / args.baud
        print(f"receiving {n} bytes (~{secs:.0f} s at this baud) ...")
        payload = read_exact(ser, n, "pixel data", progress=True)

        tail = read_exact(ser, 2, "trailer")
        if tail != TRAILER:
            print(f"warning: trailer was {tail.hex()} not {TRAILER.hex()} "
                  f"-- the image may be truncated", file=sys.stderr)

    if args.raw:
        with open(args.raw, "wb") as f:
            f.write(payload)
        print(f"raw RGB565 -> {args.raw}")

    write_png(args.out, width, height, rgb565_to_rgb888(payload, args.byteswap))
    print(f"saved {width}x{height} image -> {args.out}")


if __name__ == "__main__":
    main()
