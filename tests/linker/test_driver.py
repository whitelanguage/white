"""Run with a freshly built wlc, all image linking in this suite uses White."""
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def check_driver(compiler):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    # No portable LLVM lives in the source tree, an accidental fallback cannot find Clang.
    env["PATH"] = ""
    checks = 0

    with tempfile.TemporaryDirectory(prefix="white-link-") as temporary:
        root = Path(temporary)
        env["TMP"] = env["TEMP"] = str(root)
        output = root / "program.exe"

        def invoke(*args, success=True):
            nonlocal checks
            result = subprocess.run([str(compiler), *map(str, args)], env=env, cwd=repo,
                                    capture_output=True, timeout=90)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (args, result.returncode, text)
            checks += 1
            return text

        def build(source, *flags, success=True):
            return invoke(source, "--backend=machine", "--linker=white", "-o", output,
                          *flags, success=success)

        args_source = repo / "tests/integration/os/test_process_args.wl"
        for opt in ("-O0", "-O2"):
            output = root / ("args" + opt + ".exe")
            build(args_source, opt)
            result = subprocess.run([str(output), "", "hello world", "你好", 'quote" slash\\ tail'],
                                    capture_output=True, timeout=15)
            assert result.returncode == 0 and b"PASS:" in result.stdout, result
            checks += 1

        dll = root / "exported.dll"
        invoke(repo / "tests/integration/ffi/test_lib_export.wl", "--backend=machine",
               "--linker", "white", "--shared", "-o", dll)
        library = ctypes.WinDLL(str(dll))
        library.add.argtypes = [ctypes.c_int, ctypes.c_int]
        library.add.restype = ctypes.c_int
        library.factorial.argtypes = [ctypes.c_int]
        library.factorial.restype = ctypes.c_int
        library.multiply_float.argtypes = [ctypes.c_double, ctypes.c_double]
        library.multiply_float.restype = ctypes.c_double
        library.read_count.restype = ctypes.c_int
        assert library.add(19, 23) == 42
        assert library.factorial(6) == 720
        assert library.multiply_float(2.5, 4.0) == 10.0
        assert library.read_count() == 42
        assert not dll.with_suffix(".lib").exists()
        ctypes.windll.kernel32.FreeLibrary.argtypes = [ctypes.c_void_p]
        assert ctypes.windll.kernel32.FreeLibrary(library._handle)
        checks += 1

        # A six-byte leaf isolates object-file ingestion from White source lowering.
        code = bytes.fromhex("b8 2a 00 00 00 c3")
        header = struct.pack("<HHIIIHH", 0x8664, 1, 0, 60 + len(code), 1, 0, 0)
        section = struct.pack("<8sIIIIIIHHI", b".text", 0, 0, len(code), 60, 0, 0, 0, 0, 0x60500020)
        symbol = struct.pack("<8sIhHBB", b"answer", 0, 1, 0x20, 2, 0)
        object_file = root / "answer.obj"
        object_file.write_bytes(header + section + code + symbol + struct.pack("<I", 4))
        fixture = repo / "tests/fixtures/linker/driver_object.wl"
        output = root / "object.exe"
        build(fixture, object_file)
        result = subprocess.run([str(output)], capture_output=True, timeout=15)
        assert result.returncode == 0 and b"PASS:" in result.stdout, result
        checks += 1

        before = output.read_bytes()
        text = build(fixture, success=False)
        assert "LinkError:" in text and "InternalCompilerError" not in text
        assert output.read_bytes() == before
        assert "Archive declaration" in build(repo / "tests/fixtures/linker/driver_archive.wl", success=False)
        assert output.read_bytes() == before
        broken = root / "broken.obj"
        broken.write_bytes(b"broken")
        assert "LinkError:" in build(fixture, broken, success=False)
        assert output.read_bytes() == before
        for flags in (("unused.lib",), ("-L", root), ("--sysroot", root),
                      ("--ldflags", "-lkernel32"), ("--emit-wir",),
                      ("--backend=llvm",), ("--target=x86_64-unknown-linux-gnu",)):
            assert "Error:" in build(args_source, *flags, success=False)
            assert output.read_bytes() == before
        for value in ("", "unknown"):
            assert "Unsupported linker" in invoke(args_source, "--linker=" + value, success=False)
        assert "requires an argument" in invoke(args_source, "--linker", success=False)

        output = root / "imports.exe"
        build(repo / "tests/fixtures/linker/driver_import.wl")
        result = subprocess.run([str(output)], capture_output=True, timeout=15)
        assert result.returncode == 0 and b"PASS:" in result.stdout, result
        checks += 1

        # The ordinary native link path keeps bytes in memory, no .ll or .obj is left in TMP.
        assert not list(root.glob("wlc_tmp_*")), list(root.iterdir())

    print(f"PASS: White linker driver ({checks} checks)")


if __name__ == "__main__":
    if sys.platform != "win32":
        raise SystemExit("This host suite executes Windows x64 images.")
    check_driver(Path(sys.argv[1]).resolve())
