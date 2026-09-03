"""
Build script: invokes `zig build c-lib -Doptimize=ReleaseFast` to compile
libscanio.dylib/.so/scanio.dll, then copies it into the package directory
so it's included in the wheel.
"""

import shutil
import subprocess
import sys
from pathlib import Path

from setuptools import setup
from setuptools.command.build_py import build_py

REPO_ROOT = Path(__file__).parent.parent  # python/ -> repo root
PKG_DIR = Path(__file__).parent / "libscanio"


def _lib_name() -> str:
    if sys.platform == "darwin":
        return "libscanio.dylib"
    if sys.platform == "win32":
        return "scanio.dll"
    return "libscanio.so"


def _lib_src_dir() -> Path:
    # Same Windows/POSIX split as csvql's own setup.py: a Windows DLL
    # lands in zig-out/bin, the POSIX .so/.dylib in zig-out/lib.
    if sys.platform == "win32":
        return REPO_ROOT / "zig-out" / "bin"
    return REPO_ROOT / "zig-out" / "lib"


class BuildZigLib(build_py):
    def run(self):
        subprocess.check_call(
            ["zig", "build", "c-lib", "-Doptimize=ReleaseFast"],
            cwd=str(REPO_ROOT),
        )
        src = _lib_src_dir() / _lib_name()
        dst = PKG_DIR / _lib_name()
        if not src.exists():
            raise FileNotFoundError(
                f"Expected {src} after `zig build c-lib`. Is Zig installed and on PATH?"
            )
        shutil.copy2(src, dst)
        super().run()


setup(cmdclass={"build_py": BuildZigLib})
