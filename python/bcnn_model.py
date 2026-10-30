"""
Binarized CNN for zebra crossing detection, plus everything that must agree
bit-for-bit with rtl/bcnn_core.v:

    preprocess_image()   any photo -> 40x30 uint8 (the bytes sent to the FPGA)
    BCNN                 PyTorch training model
    fold_model()         BatchNorm -> integer thresholds, weights -> ROM words
    int_forward()        integer golden model of the hardware
    write_mem_files()    bcnn_weights.mem / bcnn_thresh.mem for $readmemh

Network:
    40x30x1 (8-bit)  -conv3x3, 16, pad 0-  -> thr -> pool -> 20x15x16
                     -conv3x3, 32, pad -1- -> thr -> pool -> 10x7x32
                     -conv3x3, 32, pad -1- -> thr -> pool -> 5x3x32
                     -FC 480 -> 1 (5x3 valid conv)-> score, detect = score >= T
"""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

IMG_W, IMG_H = 40, 30
CAM_W, CAM_H = 640, 480          # OV7670 VGA frame; 16x16 blocks -> 40x30

def make_layers(img_h=30, img_w=40, channels=(16, 32, 32)):
    """Hardware layer table: 3x3 conv + 2x2 pool per entry of `channels`, then a
    fully connected output neuron done as a "valid" conv over the last map.

    Rows: (name, cin, cout, k_h, k_w, w_base, t_base). One weight word per
    (output channel, tap), so w_base advances by cout * k_h * k_w per layer.
    """
    rows, cin, h, w, wb, tb = [], 1, img_h, img_w, 0, 0
    for i, cout in enumerate(channels):
        rows.append((f"L{i}", cin, cout, 3, 3, wb, tb))
        wb, tb, cin, h, w = wb + cout * 9, tb + cout, cout, h // 2, w // 2
    rows.append((f"L{len(channels)}", cin, 1, h, w, wb, tb))
    return rows


# v1 network. Must match the case statement in rtl/bcnn_core.v.
LAYERS = make_layers()
W_ROM_DEPTH = 1024
T_ROM_DEPTH = 128


# ---------------------------------------------------------------------------
# Preprocessing (golden reference for the future camera pipeline too)
# ---------------------------------------------------------------------------

def gray_u8(rgb):
    """RGB uint8 (H,W,3) -> gray uint8 with shift-add friendly weights."""
    rgb = rgb.astype(np.uint32)
    return ((77 * rgb[..., 0] + 150 * rgb[..., 1] + 29 * rgb[..., 2]) >> 8).astype(np.uint8)


def block_mean(gray, block=16):
    """640x480 gray -> (480/block)x(640/block) by summing block x block pixels
    and shifting right by log2(block^2): 16 -> 40x30 (>> 8), 8 -> 80x60 (>> 6).

    This is exactly what the camera-side RTL will do (sum, shift, no divider).
    """
    h, w = gray.shape
    shift = 2 * (block.bit_length() - 1)
    g = gray.astype(np.uint32).reshape(h // block, block, w // block, block)
    return (g.sum(axis=(1, 3)) >> shift).astype(np.uint8)


def block_mean_16(gray):
    """640x480 gray -> 40x30 (16x16 blocks, >> 8)."""
    return block_mean(gray, 16)


def preprocess_image(img, block=16):
    """PIL image (any size) -> uint8 array, row-major as sent over UART.

    Centre-crop to 4:3, resize to 640x480 (what the camera would deliver),
    convert to gray, then block mean: block=16 -> 40x30, block=8 -> 80x60.
    """
    img = img.convert("RGB")
    w, h = img.size
    if w * 3 > h * 4:            # too wide: crop sides
        nw = h * 4 // 3
        img = img.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:                        # too tall: crop top/bottom
        nh = w * 3 // 4
        img = img.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    img = img.resize((CAM_W, CAM_H), Image.BILINEAR)
    return block_mean(gray_u8(np.asarray(img)), block)


# ---------------------------------------------------------------------------
# Training model
# ---------------------------------------------------------------------------

def binarize(x):
    """sign() with x >= 0 -> +1 forward; clipped straight-through backward."""
    clipped = torch.clamp(x, -1.0, 1.0)
    return torch.where(x >= 0, 1.0, -1.0) - clipped.detach() + clipped


class BCNN(nn.Module):
    def __init__(self, layers=None):
        super().__init__()
        self.layers = layers or LAYERS
        self.convs = nn.ParameterList()
        self.bns = nn.ModuleList()
        for _, cin, cout, kh, kw, _, _ in self.layers:
            w = torch.empty(cout, cin, kh, kw)
            nn.init.uniform_(w, -0.1, 0.1)
            self.convs.append(nn.Parameter(w))
            self.bns.append(nn.BatchNorm2d(cout))

    def forward(self, img):
        """img: (B,1,H,W) float tensor holding integer pixel values 0..255.

        Returns the output-layer logit (B,). detect = logit >= 0.
        """
        x = (img - 128.0) / 128.0
        # L0: real-valued pixels, binary weights, zero padding.
        y = F.conv2d(x, binarize(self.convs[0]), padding=1)
        a = F.max_pool2d(binarize(self.bns[0](y)), 2)
        # Hidden layers: binary in, binary weights, pad with -1 (bit 0 in hardware).
        for i in range(1, len(self.layers) - 1):
            a = F.pad(a, (1, 1, 1, 1), value=-1.0)
            y = F.conv2d(a, binarize(self.convs[i]))
            a = F.max_pool2d(binarize(self.bns[i](y)), 2)
        # Output: fully connected as a valid conv over the last map.
        y = F.conv2d(a, binarize(self.convs[-1]))
        return self.bns[-1](y).view(-1)

    def clamp_latent(self):
        """Keep latent weights inside the straight-through region."""
        for w in self.convs:
            w.data.clamp_(-1.0, 1.0)


# ---------------------------------------------------------------------------
# Folding: BatchNorm -> thresholds, weights -> ROM bits
# ---------------------------------------------------------------------------

def fold_model(model):
    """Return per-layer (weights, thresholds) for the integer model.

    weights:    int8 array (cout, cin, kh, kw) of +1/-1, with negative-gamma
                channels already flipped
    thresholds: int array (cout,). Neuron fires when acc >= threshold, where
                acc = sum(w * (pixel - 128)) for L0 and popcount(XNOR) otherwise.
    """
    folded = []
    for li, (name, cin, cout, kh, kw, _, _) in enumerate(model.layers):
        w = torch.where(model.convs[li].detach() >= 0, 1, -1).cpu().numpy().astype(np.int8)
        bn = model.bns[li]
        gamma = bn.weight.detach().double().cpu().numpy()
        beta = bn.bias.detach().double().cpu().numpy()
        mean = bn.running_mean.detach().double().cpu().numpy()
        std = np.sqrt(bn.running_var.detach().double().cpu().numpy() + bn.eps)
        n_in = cin * kh * kw

        thr = np.zeros(cout, dtype=np.int64)
        for c in range(cout):
            if gamma[c] == 0:
                # Constant output: always fire or never fire.
                thr[c] = -32768 if beta[c] >= 0 else 32767
                continue
            # BN(y) >= 0  <=>  y >= tau (gamma > 0)  or  y <= tau (gamma < 0)
            tau = mean[c] - beta[c] * std[c] / gamma[c]
            if gamma[c] < 0:
                w[c] = -w[c]          # y' = -y, condition y' >= -tau
                tau = -tau
            if li == 0:
                # Float y = y_int / 128 with y_int = sum(w * (pixel - 128)).
                thr[c] = int(np.ceil(tau * 128.0))
            else:
                # y = 2p - n_in  ->  p >= (n_in + tau) / 2
                thr[c] = int(np.ceil((n_in + tau) / 2.0))
                thr[c] = min(max(thr[c], 0), n_in + 1)
        thr = np.clip(thr, -32768, 32767)
        folded.append((w, thr))
    return folded


def rom_shape(layers):
    """(weight words, weight word bits, threshold words) the ROMs need, rounded up:
    depths to a power of two (at least the v1 sizes), width to a multiple of 32."""
    last = layers[-1]
    n_w = last[5] + last[2] * last[3] * last[4]
    n_t = last[6] + last[2]
    bits = 32 * -(-max(r[1] for r in layers) // 32)
    p2 = lambda n, lo: max(lo, 1 << (n - 1).bit_length())
    return p2(n_w, W_ROM_DEPTH), bits, p2(n_t, T_ROM_DEPTH)


def load_net(mem_dir):
    """(layers, img_h, img_w) of the network whose ROM files are in mem_dir,
    from the net.json written next to them (v1 when there is none)."""
    f = Path(mem_dir) / "net.json"
    if not f.exists():
        return LAYERS, IMG_H, IMG_W
    net = json.loads(f.read_text())
    return make_layers(net["img_h"], net["img_w"], tuple(net["channels"])), net["img_h"], net["img_w"]


def rtl_config(layers, img_h, img_w):
    """Hardware view of a layer table: per-layer loop sizes and memory bases,
    plus memory sizes. Feature maps are packed one after another from address 0."""
    w_depth, word, t_depth = rom_shape(layers)
    rows, h, w, base, prev = [], img_h, img_w, 0, 0
    for i, (name, cin, cout, kh, kw, w_base, t_base) in enumerate(layers):
        conv = i < len(layers) - 1
        r = dict(name=name, in_w=w, in_h=h, cout=cout, k_w=kw, k_h=kh, pad=int(conv), pool=int(conv),
                 byte_in=int(i == 0), pw=w // 2 if conv else 1, ph=h // 2 if conv else 1,
                 in_base=prev, out_base=base if conv else 0, w_base=w_base, t_base=t_base,
                 cin_mask=(1 << cin) - 1)
        if conv:
            prev, base, h, w = base, base + r["pw"] * r["ph"], h // 2, w // 2
        rows.append(r)
    bits = lambda n: max(1, (n - 1).bit_length())
    fmap_depth = 1 << bits(base)
    return dict(rows=rows, img_w=img_w, img_h=img_h, npix=img_w * img_h, word=word,
                w_depth=w_depth, t_depth=t_depth, fmap_depth=fmap_depth, map_words=base,
                img_aw=bits(img_w * img_h), w_aw=bits(w_depth), t_aw=bits(t_depth),
                fmap_aw=bits(fmap_depth), layer_bits=bits(len(rows)))


def write_rtl_config(layers, img_h, img_w, out_dir):
    """bcnn_config.vh: localparams and the layer table for rtl/bcnn_core.v."""
    c = rtl_config(layers, img_h, img_w)
    L = [f"// Generated by python/bcnn_model.py write_rtl_config() -- do not edit.",
         f"// Network: {img_w}x{img_h} input, channels "
         f"{[r['cout'] for r in c['rows'][:-1]]}, FC {c['rows'][-1]['k_w']}x{c['rows'][-1]['k_h']}.",
         "// Included twice by bcnn_core.v: plain for the localparams, and with",
         "// BCNN_LAYER_TABLE defined inside `case (layer)` for the layer table.",
         "`ifndef BCNN_LAYER_TABLE",
         f"localparam IMG_W = {img_w}, IMG_H = {img_h}, NPIX = {c['npix']}, IMG_AW = {c['img_aw']};",
         f"localparam WORD = {c['word']};",
         f"localparam W_DEPTH = {c['w_depth']}, W_AW = {c['w_aw']};",
         f"localparam T_DEPTH = {c['t_depth']}, T_AW = {c['t_aw']};",
         f"localparam FMAP_DEPTH = {c['fmap_depth']}, FMAP_AW = {c['fmap_aw']};",
         f"localparam MAP_WORDS = {c['map_words']};   // hidden feature-map words, packed from 0",
         f"localparam N_LAYERS = {len(c['rows'])}, LAYER_BITS = {c['layer_bits']};",
         "`else"]
    for i, r in enumerate(c["rows"]):
        head = f"{c['layer_bits']}'d{i}" if i < len(c["rows"]) - 1 else "default"
        L.append(f"    {head}: begin  // {r['name']}  out words {r['out_base']}..{r['out_base'] + r['pw'] * r['ph'] - 1}"
                 if i < len(c["rows"]) - 1 else f"    {head}: begin  // {r['name']} (output neuron)")
        L.append(f"        in_w = {r['in_w']}; in_h = {r['in_h']}; cout = {r['cout']}; "
                 f"k_w = {r['k_w']}; k_h = {r['k_h']}; pad = {r['pad']}; pool = {r['pool']};")
        L.append(f"        byte_in = {r['byte_in']}; pw = {r['pw']}; ph = {r['ph']};")
        L.append(f"        in_base = {r['in_base']}; out_base = {r['out_base']}; "
                 f"w_base = {r['w_base']}; t_base = {r['t_base']};")
        L.append(f"        cin_mask = {c['word']}'h{r['cin_mask']:x};")
        L.append("    end")
    L.append("`endif")
    (Path(out_dir) / "bcnn_config.vh").write_text("\n".join(L) + "\n")


def write_mem_files(folded, out_dir, layers=None, img_h=IMG_H, img_w=IMG_W):
    """Write bcnn_weights.mem and bcnn_thresh.mem (16-bit signed) for $readmemh,
    plus net.json and bcnn_config.vh describing the network to the RTL.
    v1: 1024 x 32 bit and 128 x 16 bit."""
    layers = layers or LAYERS
    channels = [r[2] for r in layers[:-1]]
    (Path(out_dir) / "net.json").write_text(json.dumps({"img_h": img_h, "img_w": img_w, "channels": channels}) + "\n")
    write_rtl_config(layers, img_h, img_w, out_dir)
    w_depth, w_bits, t_depth = rom_shape(layers)
    w_words = [0] * w_depth
    t_words = [0] * t_depth
    for (name, cin, cout, kh, kw, w_base, t_base), (w, thr) in zip(layers, folded):
        for co in range(cout):
            for ky in range(kh):
                for kx in range(kw):
                    word = 0
                    for ci in range(cin):
                        if w[co, ci, ky, kx] > 0:
                            word |= 1 << ci
                    w_words[w_base + co * kh * kw + ky * kw + kx] = word
            t_words[t_base + co] = int(thr[co]) & 0xFFFF
    with open(out_dir / "bcnn_weights.mem", "w") as f:
        f.write("\n".join(f"{v:0{w_bits // 4}x}" for v in w_words) + "\n")
    with open(out_dir / "bcnn_thresh.mem", "w") as f:
        f.write("\n".join(f"{v:04x}" for v in t_words) + "\n")


def read_mem_files(mem_dir, layers=None):
    """Inverse of write_mem_files: rebuild the folded model from the ROM images."""
    layers = layers or load_net(mem_dir)[0]
    w_words = [int(l, 16) for l in (mem_dir / "bcnn_weights.mem").read_text().split()]
    t_words = [int(l, 16) for l in (mem_dir / "bcnn_thresh.mem").read_text().split()]
    folded = []
    for name, cin, cout, kh, kw, w_base, t_base in layers:
        w = np.zeros((cout, cin, kh, kw), dtype=np.int8)
        for co in range(cout):
            for ky in range(kh):
                for kx in range(kw):
                    word = w_words[w_base + co * kh * kw + ky * kw + kx]
                    for ci in range(cin):
                        w[co, ci, ky, kx] = 1 if (word >> ci) & 1 else -1
        t = np.array([t_words[t_base + c] for c in range(cout)], dtype=np.int64)
        thr = np.where(t >= 0x8000, t - 0x10000, t)
        folded.append((w, thr))
    return folded


# ---------------------------------------------------------------------------
# Integer golden model (what the hardware computes)
# ---------------------------------------------------------------------------

def _conv_taps(x, w, pad_value, pad):
    """sum over taps of w[co,ci,ky,kx] * x[ci, y+ky, x+kx] -> (cout, H, W) int."""
    cout, cin, kh, kw = w.shape
    if pad:
        x = np.pad(x, ((0, 0), (1, 1), (1, 1)), constant_values=pad_value)
    oh, ow = x.shape[1] - kh + 1, x.shape[2] - kw + 1
    y = np.zeros((cout, oh, ow), dtype=np.int64)
    for ky in range(kh):
        for kx in range(kw):
            y += np.einsum("oc,chw->ohw", w[:, :, ky, kx].astype(np.int64),
                           x[:, ky:ky + oh, kx:kx + ow])
    return y


def _pool_or(bits):
    c, h, w = bits.shape
    b = bits[:, :h // 2 * 2, :w // 2 * 2].reshape(c, h // 2, 2, w // 2, 2)
    return b.any(axis=(2, 4))


def int_forward(img_u8, folded):
    """img_u8: (H,W) uint8. Returns (detect, score, [hidden-layer bool maps])."""
    maps = []
    x = img_u8.astype(np.int64)[None] - 128                       # (1,H,W)
    w, thr = folded[0]
    acc = _conv_taps(x, w, 0, pad=True)
    a = _pool_or(acc >= thr[:, None, None])
    maps.append(a)
    for li in range(1, len(folded) - 1):
        w, thr = folded[li]
        n_in = w.shape[1] * 9
        s = _conv_taps(a.astype(np.int64) * 2 - 1, w, -1, pad=True)
        p = (s + n_in) // 2                                          # popcount
        a = _pool_or(p >= thr[:, None, None])
        maps.append(a)
    w, thr = folded[-1]
    n_in = w.shape[1] * w.shape[2] * w.shape[3]
    s = _conv_taps(a.astype(np.int64) * 2 - 1, w, -1, pad=False)
    score = int((s[0, 0, 0] + n_in) // 2)
    return score >= thr[0], score, maps


def write_vectors(folded, images, labels, out_dir, layers=None):
    """Golden vectors for sim/tb_bcnn_core.v: test_images.hex (bytes),
    test_expected.hex ({detect, score[14:0]}), test_maps.hex (every hidden
    feature-map word, layers packed as in the RTL), test_labels.txt.
    Returns the integer model's predictions."""
    layers = layers or LAYERS
    hexw = rom_shape(layers)[1] // 4
    img, exp, maps_hex, preds = [], [], [], []
    for x in images:
        det, score, maps = int_forward(x, folded)
        img += [f"{v:02x}" for v in x.reshape(-1)]
        exp.append(f"{(int(det) << 15) | score:04x}")
        for m in maps:
            maps_hex += [f"{v:0{hexw}x}" for v in map_words(m)]
        preds.append(int(det))
    out_dir = Path(out_dir)
    for name, rows in (("test_images.hex", img), ("test_expected.hex", exp), ("test_maps.hex", maps_hex)):
        (out_dir / name).write_text("\n".join(rows) + "\n")
    (out_dir / "test_labels.txt").write_text("\n".join(str(int(v)) for v in labels) + "\n")
    return np.array(preds)


def map_words(bits):
    """(C,H,W) bool -> list of words in hardware order (y*W + x, bit c)."""
    c, h, w = bits.shape
    words = []
    for y in range(h):
        for x in range(w):
            v = 0
            for ci in range(c):
                if bits[ci, y, x]:
                    v |= 1 << ci
            words.append(v)
    return words
