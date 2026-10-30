# Results and evidence

Everything below was produced by scripts in this repository; the command is
given with each result so it can be re-run.

## 0. On the real board (EDGE Artix-7 + OV7670, 26 Oct 2026)

Programmed with `bitstream/zebracam.bit` (default: SDRAM I/O in the IOBs, BCNN at 66.7 MHz).

| check | result |
|---|---|
| `zebracam.py auto selftest` | **ALL PASS** (8/8) |
| camera | 27.5 frames/s committed, 640 × 480, 0 rejected |
| BCNN on the camera | 27 inferences/s - every camera frame, 0 skipped |
| golden vectors over UART (self-test) | 20/20 bit-exact |
| **T2, 115 street photos through the FPGA** (`hil vectors/t2`) | **115/115 bit-exact, accuracy 79.13 %** (= published) |
| **T1, 524 dashcam frames through the FPGA** (`hil vectors/t1`) | **524/524 bit-exact, accuracy 79.39 %** (= published) |
| photo upload round trip | 48.2 ms per 80×60 image (UART 5.33 Mbaud + 34 ms inference) |
| live camera, road without a crossing | NO CROSSING, margin -73 |
| VGA | live picture through the SDRAM + overlay (border, banner, network view) correct |
| LCD 16×2, LEDs | decision shown, LEDs as specified |

The default bitstream (IOB-packed SDRAM registers) works on the board, so the
proven-SDRAM fallback is not needed.

## 1. Verification (simulation, Vivado 2024.2 xsim)

| check | command | result |
|---|---|---|
| camera pins → 80×60, two real photos + a frame of random RGB565 pixels | `python sim/check_preproc.py` | 3/3 frames bit-exact vs `cam_golden.camera_input` |
| … PCLK running during blanking | `--pclk-blank` | bit-exact |
| … every other frame has a short line | `--bad-line 100 --frames 4` | broken frames rejected, the rest bit-exact |
| detection path end to end over a 5.33 Mbaud serial line: preprocessing, auto-contrast, BCNN, decision, every UART command; camera frames = a street photo and **a real OV7670 frame from this board** | `python sim/check_vision.py` | 20/20 checks pass: snapshot = `autocontrast(camera_input(frame))`, score = golden, auto-contrast levels = golden, photo upload reply = v3 golden vector, no stray bytes |
| same with auto-contrast off | `python sim/check_vision.py --raw` | pass |
| VGA overlay rendered to a PNG, LCD bus decoded by an HD44780 model | `python sim/check_display.py` | LCD `ZEBRA CROSSING!` / `S561 M+084 13FPS`, screen as designed (`docs/vga_*.png`) |
| PC tool parses the exact bytes the RTL sent | `python sim/check_host_replay.py` | pass |
| whole design: MMCM, resets, camera XCLK, UART pins shared with photo capture, LEDs | `python sim/check_top.py` | see §4 |
| BCNN core | training repository, `sim/run_sim.py core` | 639/639 images bit-exact incl. every feature-map word |

## 2. Implementation (Vivado 2024.2, XC7A35T-1FTG256C)

Default build `bitstream/zebracam.bit` (`vivado/build.tcl iob 12 bit`, BCNN 66.7 MHz):

| | |
|---|---|
| LUT | 3,370 (16.2 %) |
| FF | 2,730 (6.6 %) |
| BRAM tiles | 19 / 50 (BCNN 10, frame buffer 4, thumbnails 4, FIFOs 1.5) |
| DSP | 1 (auto-contrast scaling) |
| MMCM | 1 |
| Power (estimate) | 0.29 W |

| clock | frequency | setup slack | hold slack |
|---|---|---|---|
| camera / SDRAM / UART | 133.33 MHz | +0.835 ns | +0.062 ns |
| BCNN | 66.7 MHz | +2.616 ns | +0.028 ns |
| VGA | 25 MHz | +28.13 ns | +0.111 ns |
| camera XCLK (forwarded) | 21.33 MHz | – | – |
| SDRAM read (data sheet: tAC 5.4 ns, tOH 2.7 ns) | | +0.062 ns | +7.67 ns |
| SDRAM write (tIS 1.5 ns, tIH 0.8 ns) | | met | met |

All 67 SDRAM I/O registers are in the IOBs: output pad delay 1.6–4.2 ns
(proven build: 4.0–8.2 ns), input 1.5 ns (proven: 2.9–3.8 ns); the SDRAM
clock path is identical (4.022 ns).

Fallback build `bitstream/zebracam_proven.bit` (`build.tcl proven 12 bit`): the
52 SDRAM I/O registers on the slice sites of the hardware-proven build; all
internal clocks met; the SDRAM I/O paths show the same data-sheet violations as
the proven build itself (it works on the board at room temperature).

### Why the clocks are what they are
The proven camera build used three Spartan-6 `DCM_SP` cores. Vivado converted
them to MMCMs and *timed them as 200 MHz*; the routed checkpoint shows the real
settings (VCO 800 MHz, dividers 6 / 32 / 37.5 → 133.33 / 25 / 21.33 MHz), which
agree with the 5,333,333 baud measured on the board with our earlier capture design. This
design generates exactly these clocks with one native MMCM, so the camera,
SDRAM and UART run as before and the timing reports are now meaningful.

## 3. The real camera and auto-contrast

A frame captured from this board's OV7670 with our earlier capture design spans
gray 58–148 after the 80×60 reduction (`docs/fig_real_frame.png`): the sensor
setting gives flat, washed-out pictures. The v3 network was trained on photos
that use the full range. Measured with the bit-exact integer model of the FPGA
(`python python/robustness.py`, T1 = 524 dashcam frames, T2 = 115 street photos):

| condition | T1 | T2 |
|---|---|---|
| clean | 79.4 % | 79.1 % |
| contrast × 0.6 | 63.5 % | 82.6 % |
| camera-like (contrast × 0.4, like the real frame) | **47.7 %** | **67.0 %** |
| gamma 0.6 / 1.6 | 80.9 / 76.1 % | 70.4 / 73.9 % |
| focus blur 0.7 / 1.2 px (at 80×60) | 73.7 / 56.1 % | 73.0 / 68.7 % |
| sensor noise σ 4 | 76.3 % | 77.4 % |
| left-right mirror (the OV7670 setting) | 80.3 % | 81.7 % |

Auto-contrast variants (same sets):

| stretch | clean T1/T2 | camera-like T1/T2 | camera + lamp T1/T2 | real ceiling frame margin |
|---|---|---|---|---|
| none | 79.4 / 79.1 | 47.7 / 67.0 | 47.3 / 64.3 | −18 |
| min..max | 77.9 / 77.4 | 78.2 / 78.3 | 47.3 / 64.3 (lamp defeats it) | |
| 0.5 % trimmed, gain unlimited | 77.5 / 73.0 | 78.1 / 77.4 | 77.5 / 75.7 | +29 (texture blown up) |
| **0.5 % trimmed, gain ≤ 2.7× (deployed)** | 77.5 / 73.0 | **78.2 / 78.3** | 77.5 / 75.7 | **−11** |

The deployed stretch keeps accuracy near 78 % whatever the camera's contrast;
uploaded photos (already full-range) skip it and keep the published v3 numbers.
Focus matters: a blurred lens costs more than any tone change.

## 4. Whole-design simulation (`sim/check_top.py`)

MMCM locks, camera XCLK measured 21.333 MHz, results reported with the LED
pattern a person sees (LED 0 crossing, 1 not sure, 2 no crossing, 8–15 meter):

```
[104.56 ms] result 1: state 0 score 436 avg -41  LEDs 00000001_00000100
[150.15 ms] result 2: state 1 score 545 avg -14  LEDs 00000111_00010010
```

## 5. Model candidates for the camera

(`python python/compare_models.py` → `docs/model_compare.json`)

Accuracy, mean of T1 and T2 (%), bit-exact integer model; "stretch" = the FPGA's
auto-contrast in front of the network (the camera path); "raw" = without it.

| condition | v3 raw | v3 stretch | v3c raw | v3c stretch | v3cs stretch |
|---|---|---|---|---|---|
| clean | 79.3 | 75.3 | 79.5 | 78.6 | 77.5 |
| contrast 0.6 | 70.2 | 76.9 | 74.1 | 78.4 | 76.2 |
| camera-like 0.4 | 57.3 | 78.3 | 64.0 | 77.0 | 77.1 |
| camera + lamp | 55.8 | 76.8 | 65.0 | 74.8 | 75.8 |
| gamma 0.6 | 75.7 | 75.5 | 74.7 | 78.0 | 76.9 |
| gamma 1.6 | 75.0 | 78.1 | 76.9 | 78.5 | 78.5 |
| brighter +40 | 76.1 | 79.8 | 75.5 | 77.5 | 79.0 |
| darker -40 | 75.8 | 78.3 | 75.5 | 76.1 | 81.4 |
| blur 0.7 px | 73.4 | 73.7 | 75.6 | 76.2 | 71.9 |
| noise 4 | 76.9 | 74.8 | 74.5 | 77.1 | 76.8 |
| **average of the 9 camera effects** | **70.7** | **76.9** | **72.9** | **77.1** | **77.1** |
| real ceiling frame, margin (should be < 0) | -18 | -11 | -24 | -15 | -31 |

Models: **v3** = the published model; **v3c** = the same recipe (data, distillation, seed,
60 epochs) plus camera augmentation (gamma, focus blur, sensor noise; `python/train_camaug.py`);
**v3cs** = v3c trained on auto-contrasted images (`--stretch`).

Precision of the confident answers at equal coverage (camera path, % correct among the
most-confident x % of the test images):

| model | set | 30 % | 40 % | 50 % | 60 % | 80 % | 100 % |
|---|---|---|---|---|---|---|---|
| v3 | T1 | 92.4 | 93.8 | 91.6 | 90.4 | 83.5 | 77.5 |
| v3 | T2 | 97.1 | 95.7 | 93.1 | 88.4 | 81.5 | 73.0 |
| v3c | T1 | 94.9 | 93.3 | 91.6 | 90.1 | 87.4 | 80.7 |
| v3c | T2 | 94.1 | 89.1 | 84.5 | 84.1 | 80.4 | 76.5 |

**Decision: v3 stays on the FPGA.** v3c is ~3 points better as a plain yes/no through the
camera path, but when the network is confident v3 is right more often on the everyday
street photos (T2: 95.7 % vs 89.1 % at 40 % coverage), and the live demo shows the
confident answers with "not sure" in between; the differences are a few photos out of 115,
so the published, fully verified model is kept. v3c ships as `bitstream/extra/zebracam_v3c.bit`
(band −26 ≤ margin < 17, calibrated on validation photos) for trying on a new scene;
`python python/deploy_model.py models/v3c` makes it the default (then rebuild).
