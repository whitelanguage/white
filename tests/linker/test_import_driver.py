"""Short import libraries must work with Clang absent from the compiler's PATH."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes, object_bytes


def short_import(symbol, name_mode=1, kind=0, ordinal=0, dll="sample.dll", export=""):
    payload = symbol.encode("ascii") + b"\0" + dll.encode("ascii") + b"\0"
    if name_mode == 4:
        payload += export.encode("ascii") + b"\0"
    return struct.pack("<HHHHIIHH", 0, 65535, 0, 0x8664, 0, len(payload), ordinal,
                       kind | (name_mode << 2)) + payload


def export_ordinal(data, wanted):
    pe = struct.unpack_from("<I", data, 60)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    sections = pe + 24 + optional_size

    def at(rva):
        for s in range(count):
            _, virtual_size, address, size, raw = struct.unpack_from("<8sIIII", data, sections + s * 40)
            if address <= rva < address + max(size, virtual_size):
                return raw + rva - address
        raise AssertionError(("missing RVA", rva))

    table = at(struct.unpack_from("<I", data, pe + 24 + 112)[0])
    base, _, names, _, names_rva, ordinals_rva = struct.unpack_from("<IIIIII", data, table + 16)
    for i in range(names):
        text = at(struct.unpack_from("<I", data, at(names_rva) + i * 4)[0])
        if data[text:data.index(0, text)].decode("ascii") == wanted:
            return base + struct.unpack_from("<H", data, at(ordinals_rva) + i * 2)[0]
    raise AssertionError("export not found")


def check_imports(compiler, dlltool=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-import-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        source = root / "sample.wl"
        source.write_text('@ExportLib\nfunc api_answer() -> Int { return 42; }\n'
                          '@ExportLib\nlet api_data: Int = 42;\n', encoding="utf-8")
        dll = root / "sample.dll"
        result = subprocess.run([str(compiler), str(source), "--backend=machine", "--linker=white",
                                 "--shared", "-o", str(dll)], env=env, cwd=repo,
                                capture_output=True, timeout=90)
        assert result.returncode == 0, result.stdout + result.stderr
        ordinal = export_ordinal(dll.read_bytes(), "api_answer")
        fixture = repo / "tests/fixtures/linker/driver_object.wl"

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(items, wrapper, success=True, needle="", extras=()):
            nonlocal checks
            lib = save(f"import-{checks}.lib", archive_bytes(items, second=True))
            obj = save(f"wrapper-{checks}.obj", wrapper)
            out = root / f"case-{checks}.exe"
            if not success:
                out.write_bytes(b"untouched")
            result = subprocess.run([str(compiler), str(fixture), "--backend=machine", "--linker=white",
                                     "-o", str(out), str(obj), str(lib), *map(str, extras)],
                                    env=env, cwd=repo, capture_output=True, timeout=90)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (checks, text)
            if success:
                child = subprocess.run([str(out)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, (checks, child)
            else:
                assert needle in text and "InternalCompilerError" not in text, text
                assert out.read_bytes() == b"untouched"
            checks += 1

        # One selected member defines both names, the second demand must not reload it.
        both = object_bytes("answer", bytes.fromhex("48 83 ec 28 e8 00000000 48 8b 0d 00000000 ff d1 48 83 c4 28 c3"),
                            [(5, 4, "api_answer"), (12, 4, "__imp_api_answer")])
        imported = short_import("api_answer", ordinal=9)
        entry = ("import.obj", imported, ["api_answer", "__imp_api_answer"])
        run([entry], both)
        run([entry, ("unused.obj", short_import("unused", dll="not-installed.dll"), ["unused"])], both)
        for mode, symbol, export in ((0, "by_ordinal", ""), (2, "_api_answer", ""),
                                     (3, "_api_answer@0", ""), (4, "local_alias", "api_answer")):
            payload = short_import(symbol, mode, ordinal=ordinal if mode == 0 else 0, export=export)
            wrapper = object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, symbol)])
            run([("alias.obj", payload, [symbol, "__imp_" + symbol])], wrapper)
        data_reader = object_bytes("answer", bytes.fromhex("48 8b 05 00000000 8b 00 c3"),
                                   [(3, 4, "__imp_api_data")])
        for kind in (1, 2):
            run([("data.obj", short_import("api_data", kind=kind), ["__imp_api_data"])], data_reader)
        const_reader = object_bytes("answer", bytes.fromhex("48 8b 05 00000000 8b 00 c3"),
                                    [(3, 4, "api_data")])
        run([("const.obj", short_import("api_data", kind=2), ["api_data", "__imp_api_data"])], const_reader)
        const_strong = save("const-strong.obj", object_bytes("api_data", bytes.fromhex("b8 01 000000 c3")))
        run([("const.obj", short_import("api_data", kind=2), ["api_data", "__imp_api_data"])],
            data_reader, extras=[const_strong])
        bare_data = object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "api_data")])
        run([("lying-data.obj", short_import("api_data", kind=1), ["api_data"])], bare_data,
            False, "does not define")
        run([("lying.obj", imported, ["another_name"])],
            object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "another_name")]), False, "does not define")
        # Imports reached through a static member still participate in the same dependency queue.
        static = object_bytes("bridge", b"\xe9\0\0\0\0", [(1, 4, "api_answer")])
        run([("bridge.obj", static, ["bridge"]), entry],
            object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "bridge")]))
        strong = save("strong.obj", object_bytes("api_answer", bytes.fromhex("b8 2a 000000 c3")))
        run([("absent.obj", short_import("api_answer", dll="not-installed.dll"), ["api_answer"])],
            object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "api_answer")]), extras=[strong])

        for label, offset, value, needle in (
                ("version", 4, b"\x02\0", "bigobj"), ("machine", 6, b"\x4c\x01", "AMD64"),
                ("size", 12, b"\xff" * 4, "payload size"), ("reserved", 18, b"\x24\0", "reserved bits"),
                ("kind", 18, b"\x07\0", "import type"), ("mode", 18, b"\x14\0", "name mode")):
            bad = bytearray(imported)
            bad[offset:offset + len(value)] = value
            run([(label + ".obj", bad, ["api_answer"])], both, False, needle)
        run([("missing-nul.obj", imported[:-1], ["api_answer"])], both, False, "payload size")
        for bad_symbol in ("", "__imp_api_answer"):
            run([("bad-name.obj", short_import(bad_symbol), ["api_answer"])], both, False, "import")
        run([("bad-dll.obj", short_import("api_answer", dll="../sample.dll"), ["api_answer"])],
            both, False, "DLL")

        if dlltool:
            definition = root / "sample.def"
            definition.write_text(f"LIBRARY sample.dll\nEXPORTS\n api_answer @{ordinal}\n api_data DATA\n", encoding="ascii")
            lib = root / "independent.lib"
            generated = subprocess.run([str(dlltool), "-m", "i386:x86-64", "-d", str(definition), "-l", str(lib)],
                                       capture_output=True, timeout=30)
            assert generated.returncode == 0, generated.stderr
            # An unused first library cannot supply either requested symbol.
            run([("unused.obj", b"bad", ["unused"])], both, extras=[lib])
            run([("unused.obj", b"bad", ["unused"])], data_reader, extras=[lib])
    print(f"PASS: Short import library driver ({checks} checks)")


if __name__ == "__main__":
    check_imports(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
