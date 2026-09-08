"""
Build the shared library for ctypes APIs and a CPython extension statically
linked to the Zig validator. Both use ReleaseFast; wheels are platform-specific.
"""

import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext
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


class BuildNative(build_ext):
    def run(self):
        command = ["zig", "build", "python-core", "-Doptimize=ReleaseFast"]
        if sys.platform == "win32":
            arch = "aarch64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
            command.append(f"-Dtarget={arch}-windows-msvc")
        subprocess.check_call(command, cwd=str(REPO_ROOT))
        archive = REPO_ROOT / "zig-out" / "lib" / ("scanio_python.lib" if sys.platform == "win32" else "libscanio_python.a")
        if sys.platform == "darwin":
            # Apple ld requires 8-byte Mach-O member alignment; Zig's ar
            # can emit a differently aligned member after symbol changes.
            aligned = Path(self.build_temp).resolve() / "libscanio_python.a"
            aligned.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory() as objects_dir:
                subprocess.check_call(["ar", "-x", str(archive)], cwd=objects_dir)
                objects = sorted(str(p) for p in Path(objects_dir).glob("*.o"))
                for obj in objects:
                    Path(obj).chmod(0o600)  # Zig archive members may carry mode 000.
                if not objects:
                    raise RuntimeError("Zig static library contains no object files")
                subprocess.check_call(["/usr/bin/libtool", "-static", "-o", str(aligned), *objects])
            archive = aligned
        for ext in self.extensions:
            ext.extra_objects = [str(archive)]
            ext.depends = [str(archive)]
        super().run()


setup(
    ext_modules=[Extension("libscanio._native", ["libscanio/_native.c"])],
    cmdclass={"build_py": BuildZigLib, "build_ext": BuildNative},
)
