"""
Tiny xvlog/xelab/xsim wrapper used by the check_*.py scripts.

    run_xsim(top, sources, run_dir, generics={"FRAMES": 3}, include=[mem_dir])

Sources are compiled in a fresh run_dir; files the testbench reads must be
put into run_dir by the caller. Returns xsim's stdout.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", r"C:\Xilinx\Vivado\2024.2\bin"))


def tool(name):
    exe = VIVADO_BIN / (name + (".bat" if os.name == "nt" else ""))
    if not exe.exists():
        sys.exit(f"cannot find {exe}; set VIVADO_BIN")
    return str(exe)


def _run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-6000:], r.stderr[-3000:])
        sys.exit(f"{Path(cmd[0]).name} failed in {cwd}")
    return r.stdout


def fresh_dir(run_dir):
    run_dir = Path(run_dir)
    shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True, exist_ok=True)
    for f in run_dir.iterdir():          # anything a locked folder kept
        (shutil.rmtree if f.is_dir() else os.remove)(f)
    return run_dir


def run_xsim(top, sources, run_dir, generics=None, include=(), defines=(), glbl=False):
    run_dir = Path(run_dir)
    vlog = [tool("xvlog")]
    for inc in include:
        vlog += ["-i", str(inc)]
    for d in defines:
        vlog += ["-d", d]
    srcs = [str(ROOT / s) if not Path(s).is_absolute() else str(s) for s in sources]
    if glbl:
        srcs.append(str(VIVADO_BIN.parent / "data" / "verilog" / "src" / "glbl.v"))
    _run(vlog + srcs, run_dir)
    # Options go through a file: xelab.bat runs under cmd.exe, which splits
    # "NAME=value" arguments at the "=".
    opts = [top] + (["glbl"] if glbl else []) + ["-s", top + "_sim", "-timescale", "1ns/1ps",
                                                  "-L", "unisims_ver"]
    for k, v in (generics or {}).items():
        opts += ["-generic_top", f'"{k}={v}"']
    (run_dir / "xelab_opts.f").write_text(" ".join(opts) + "\n")
    _run([tool("xelab"), "-f", "xelab_opts.f"], run_dir)
    return _run([tool("xsim"), top + "_sim", "--runall"], run_dir)
