"""Check collection roots and discarded dependencies with the native PE writer."""
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_comdat_driver import object_bytes, text, code, unwind
from test_directives_driver import directive
from test_archive_driver import archive_bytes
from test_import_driver import short_import


def check_gc(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env.update(WL_PATH=str(repo), PATH="")
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-gc-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        source = root / "caller.wl"
        source.write_text('extern "c" { func answer() -> Int; }\n'
                          'func main() -> Int { if (answer() != 42) { return 1; }\n'
                          '    print("PASS: collected image"); return 0; }\n', encoding="ascii")

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(inputs, opt="-Oz", success=True, needle="", shared=False):
            nonlocal checks
            output = root / (f"case-{checks}.dll" if shared else f"case-{checks}.exe")
            if not success:
                output.write_bytes(b"untouched")
            command = [str(compiler), str(source), "--backend=machine", "--linker=white", opt,
                       "-o", str(output), *map(str, inputs)]
            if shared:
                command.append("--shared")
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, timeout=60)
            message = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (inputs, opt, message)
            assert "InternalCompilerError" not in message, message
            if needle:
                assert needle in message, message
            if success and not shared:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, child
            if not success:
                assert output.read_bytes() == b"untouched"
            checks += 1
            return output

        one = save("answer.obj", object_bytes([text()]))
        dead = dict(text(key="dead", name=".text$dead"), data=code() + b"\x90" * 65536)
        unused = save("unused.obj", object_bytes([dead]))
        baseline = run([one], "-Oz").read_bytes()
        assert run([one, unused], "-Oz").read_bytes() == baseline
        assert run([one, unused], "-Os").stat().st_size < run([one, unused], "-O0").stat().st_size - 60000
        assert run([one, unused], "-Oz").read_bytes() == baseline

        missing = dict(text(key="dead", name=".text$dead"), data=b"\xe9\0\0\0\0",
                       relocs=[(1, 4, "missing")])
        poisoned = save("dead-missing.obj", object_bytes([missing]))
        assert run([one, poisoned]).read_bytes() == baseline
        run([one, poisoned], "-O0", False, "undefined")
        run([one, save("ordinary-missing.obj", object_bytes([dict(missing, mode=0)]))],
            success=False, needle="undefined")
        run([one, save("root-missing.obj", object_bytes([missing, directive("/include:dead")]))],
            success=False, needle="undefined")

        include = save("include.obj", object_bytes([directive("/include:dead")]))
        retained_size = run([one, unused, include]).stat().st_size
        assert retained_size > len(baseline) + 60000
        print(f"GC fixture: {retained_size} -> {len(baseline)} bytes")
        alias_include = save("alias-include.obj", object_bytes([
            directive("/alternatename:keep=dead /include:keep")]))
        assert run([one, unused, alias_include]).stat().st_size > len(baseline) + 60000

        # Taking a function address through a retained ordinary table is also a root.
        address = dict(name=".rdata$ptr", data=b"\0" * 8, flags=0x40300040, relocs=[(0, 1, "dead")])
        assert run([one, unused, save("address.obj", object_bytes([address]))]).stat().st_size > len(baseline) + 60000

        a = dict(text(key="a", name=".text$a"), data=b"\xe9\0\0\0\0", relocs=[(1, 4, "b")])
        b = dict(text(key="b", name=".text$b"), data=b"\xe9\0\0\0\0", relocs=[(1, 4, "a")])
        assert run([one, save("cycle.obj", object_bytes([a, b]))]).read_bytes() == baseline
        debug = dict(name=".debug$S", data=b"\0" * 8, flags=0x42100040, relocs=[(0, 1, "dead")])
        assert run([one, unused, save("debug.obj", object_bytes([debug]))]).read_bytes() == baseline

        records = unwind()
        live_unwind = save("live-unwind.obj", object_bytes(records))
        with_unwind = run([live_unwind]).read_bytes()
        optional = struct.unpack_from("<I", with_unwind, 60)[0] + 24
        exception_rva, exception_size = struct.unpack_from("<II", with_unwind, optional + 136)
        base_optional = struct.unpack_from("<I", baseline, 60)[0] + 24
        base_exception_size = struct.unpack_from("<I", baseline, base_optional + 140)[0]
        assert exception_rva != 0 and exception_size == base_exception_size + 12
        for section in records:
            section["name"] = section["name"].replace("answer", "dead")
            if "key" in section:
                section["key"] = "dead"
            if "relocs" in section:
                section["relocs"] = [(p, k, n.replace("answer", "dead")) for p, k, n in section["relocs"]]
        assert run([one, save("dead-unwind.obj", object_bytes(records))]).read_bytes() == baseline

        # A missing import referenced only by dead code must not reach the loader.
        imported = dict(missing, relocs=[(1, 4, "absent_import")])
        library = save("dead-import.lib", archive_bytes([("import.obj", short_import("absent_import", dll="not-installed.dll"), ["absent_import"])]))
        assert run([one, save("dead-import.obj", object_bytes([imported])), library]).read_bytes() == baseline

        exported = save("export.obj", object_bytes([text(key="exported", name=".text$exported"),
                                                   directive("/export:exported")]))
        dll = run([one, exported], shared=True)
        loaded = ctypes.WinDLL(str(dll))
        loaded.exported.restype = ctypes.c_int
        assert loaded.exported() == 42
        ctypes.windll.kernel32.FreeLibrary.argtypes = [ctypes.c_void_p]
        assert ctypes.windll.kernel32.FreeLibrary(loaded._handle)
        checks += 1

        run([one, save("duplicate.obj", object_bytes([text() | {"mode": 0}]))],
            success=False, needle="Duplicate external")
        assert run([one, save("second-answer.obj", object_bytes([text(1)]))]).read_bytes() == baseline
        unique = dict(text(key="unique", name=".text$unique"), mode=1)
        run([one, save("unique-a.obj", object_bytes([unique])), save("unique-b.obj", object_bytes([unique]))],
            success=False, needle="Conflicting COMDAT")
        malformed = bytearray(object_bytes([missing]))
        relocs = struct.unpack_from("<I", malformed, 44)[0]
        struct.pack_into("<I", malformed, relocs + 4, 0xFFFFFFFF)
        run([one, save("bad-reloc.obj", malformed)], success=False, needle="relocation")
        if clang:
            cpp = root / "functions.cpp"
            cpp.write_text('extern "C" int answer() { return 42; }\n'
                           'extern "C" int unused() { return 1; }\n', encoding="ascii")
            obj = root / "clang.obj"
            result = subprocess.run([str(clang), "--target=x86_64-pc-windows-msvc", "-O0", "-c",
                                     "-ffunction-sections", "-fno-exceptions", str(cpp), "-o", str(obj)],
                                    capture_output=True, timeout=30)
            assert result.returncode == 0, result.stderr
            run([obj])
    print(f"PASS: COFF section collection driver ({checks} checks)")


if __name__ == "__main__":
    check_gc(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
