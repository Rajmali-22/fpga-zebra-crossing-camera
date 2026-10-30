"""
Golden model of the camera -> network-input path (rtl/vision/cam_preproc.v).

The OV7670 delivers 640x480 RGB565. The FPGA turns that into the 80x60 gray
image the v3 BCNN was trained on, with the same formulas as training:

    RGB565 -> RGB888 by bit replication      (capture_host.py does the same)
    gray = (77 R + 150 G + 29 B) >> 8        (bcnn_model.gray_u8)
    80x60 = 8x8 block sum >> 6               (bcnn_model.block_mean, block 8)

So a photo taken through the FPGA and a photo preprocessed on the PC differ
only by the 565 quantisation of the camera itself.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from bcnn_model import CAM_H, CAM_W, block_mean, gray_u8

NET_W, NET_H, BLOCK = 80, 60, 8


def rgb_to_565(rgb):
    """(H,W,3) uint8 -> (H,W) uint16 RGB565 (truncation, as a sensor would)."""
    rgb = rgb.astype(np.uint16)
    return ((rgb[..., 0] >> 3) << 11) | ((rgb[..., 1] >> 2) << 5) | (rgb[..., 2] >> 3)


def expand_565(px):
    """(H,W) uint16 RGB565 -> (H,W,3) uint8 by bit replication."""
    px = px.astype(np.uint16)
    r5, g6, b5 = (px >> 11) & 0x1F, (px >> 5) & 0x3F, px & 0x1F
    return np.stack([(r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)],
                    axis=-1).astype(np.uint8)


def camera_input(frame565):
    """640x480 RGB565 frame -> 80x60 uint8, exactly what cam_preproc.v writes."""
    assert frame565.shape == (CAM_H, CAM_W)
    return block_mean(gray_u8(expand_565(frame565)), BLOCK)


def autocontrast(img, k=24, min_range=96):
    """What bcnn_engine.v does to every camera frame before the network:
    lo / hi = the (k+1)-th darkest / brightest pixel, then
    p' = min(255, (max(p - lo, 0) * (65280 // max(hi - lo, min_range))) >> 8).
    Returns (image, lo, hi)."""
    flat = np.sort(np.asarray(img, np.uint8).reshape(-1))
    lo, hi = int(flat[k]), int(flat[-1 - k])
    scale = 65280 // max(hi - lo, min_range)
    d = np.clip(img.astype(np.int64) - lo, 0, None)
    return np.minimum((d * scale) >> 8, 255).astype(np.uint8), lo, hi


def network_input(frame565, stretch=True):
    """640x480 RGB565 camera frame -> the 80x60 bytes bcnn_core receives."""
    x = camera_input(frame565)
    return autocontrast(x)[0] if stretch else x


def photo_to_rgb(img):
    """Any PIL image -> 640x480 RGB uint8, the same crop/resize as training."""
    img = img.convert("RGB")
    w, h = img.size
    if w * 3 > h * 4:
        nw = h * 4 // 3
        img = img.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = w * 3 // 4
        img = img.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return np.asarray(img.resize((CAM_W, CAM_H), Image.BILINEAR))


def photo_to_frame565(img):
    """Any PIL image -> what the OV7670 would deliver for it (640x480 RGB565)."""
    return rgb_to_565(photo_to_rgb(img))


def write_frame_hex(frame565, path):
    """One 4-digit hex word per pixel, row-major, for $readmemh."""
    Path(path).write_text("\n".join(f"{v:04x}" for v in frame565.reshape(-1)) + "\n")


def write_bytes_hex(arr, path):
    Path(path).write_text("\n".join(f"{v:02x}" for v in np.asarray(arr, np.uint8).reshape(-1)) + "\n")


def read_bytes_hex(path):
    return np.array([int(v, 16) for v in Path(path).read_text().split()], dtype=np.uint8)
