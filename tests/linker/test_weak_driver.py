"""COFF weak fallbacks, including aliases introduced by selected archive members."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes


def object_bytes(symbols, code=b"", references=()):
    # TagIndex counts auxiliary records, relocation indices have the same rule.
    indices = {}
    count = 0
    for symbol in symbols:
        indices[symbol["name"]] = count
        count += 1 + symbol.get("aux_count", 1 if "fallback" in symbol else 0)
    strings = bytearray(b"\0" * 4)
    rows = bytearray()
    for symbol in symbols:
        name = symbol["name"].encode("ascii")
        field = name.ljust(8, b"\0") if len(name) <= 8 else struct.pack("<II", 0, len(strings))
        if len(name) > 8:
            strings += name + b"\0"
        aux_count = symbol.get("aux_count", 1 if "fallback" in symbol else 0)
        rows += struct.pack("<8sIhHBB", field, symbol.get("value", 0), symbol.get("section", 0),
                            0x20, symbol.get("storage", 105 if "fallback" in symbol else 2), aux_count)
        if aux_count:
            tag = symbol.get("tag", indices.get(symbol.get("fallback"), 0))
            rows += struct.pack("<II10x", tag, symbol.get("search", 3)) + b"\0" * (18 * (aux_count - 1))
    struct.pack_into("<I", strings, 0, len(strings))
    relocs = b"".join(struct.pack("<IIH", offset, indices[name], kind) for offset, kind, name in references)
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, 60 + len(code) + len(relocs), count, 0, 0)
    section = struct.pack("<8sIIIIIIHHI", b".text", 0, 0, len(code), 60 if code else 0,
                          60 + len(code) if relocs else 0, 0, len(references), 0, 0x60500020)
    return header + section + code + relocs + rows + strings


def definition(name, value=42):
    return object_bytes([dict(name=name, section=1)], b"\xb8" + struct.pack("<I", value) + b"\xc3")


def alias(name="answer", fallback="fallback", **kwargs):
    return object_bytes([dict(name=name, fallback=fallback, **kwargs), dict(name=fallback)])


def check_weak(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-weak-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        fixture = repo / "tests/fixtures/linker/driver_object.wl"

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(inputs, success=True, needle="", source=fixture):
            nonlocal checks
            output = root / f"case-{checks}.exe"
            if not success:
                output.write_bytes(b"untouched")
            result = subprocess.run([str(compiler), str(source), "--backend=machine", "--linker=white",
                                     "-o", str(output), *map(str, inputs)], cwd=repo, env=env,
                                    capture_output=True, timeout=40)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (inputs, text)
            if needle:
                assert needle in text, text
            assert "InternalCompilerError" not in text, text
            if success:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, child
            else:
                assert output.read_bytes() == b"untouched"
            checks += 1

        fallback = save("fallback.obj", definition("fallback"))
        weak = save("weak.obj", alias())
        for mode in (1, 3):
            current = save(f"mode-{mode}.obj", alias(search=mode))
            run([current, fallback])
            run([fallback, current])
            run([current, save("strong.obj", definition("answer"))])
        run([save("local.obj", object_bytes([dict(name="answer", fallback="fallback"),
                                             dict(name="fallback", section=1)], bytes.fromhex("b8 2a 00 00 00 c3")))])
        run([weak, fallback, save("same-alias.obj", alias())])
        conflict = save("conflict.obj", alias(fallback="different"))
        run([weak, conflict, fallback], False, "Conflicting weak external fallbacks")
        run([weak, conflict, save("strong.obj", definition("answer"))])
        run([weak], False, "undefined")

        chain = [dict(name="answer", fallback="alias0")]
        chain += [dict(name=f"alias{i}", fallback=f"alias{i + 1}") for i in range(4096)]
        chain += [dict(name="alias4096", fallback="fallback"), dict(name="fallback", section=1)]
        run([save("chain.obj", object_bytes(chain, bytes.fromhex("b8 2a 00 00 00 c3")))])
        cycle = save("cycle.obj", object_bytes([dict(name="answer", fallback="loop"),
                                                dict(name="loop", fallback="answer")]))
        run([cycle], False, "alias cycle")
        run([cycle, save("strong.obj", definition("answer"))])
        run([save("self.obj", object_bytes([dict(name="answer", fallback="answer")]))], False, "alias cycle")

        for label, changes, needle in (
                ("no-aux", dict(aux_count=0), "weak external record"),
                ("two-aux", dict(aux_count=2), "weak external record"),
                ("bad-tag", dict(tag=99), "primary symbol"),
                ("aux-tag", dict(tag=1), "primary symbol"),
                ("defined", dict(section=1), "weak external record"),
                ("nonzero", dict(value=1), "weak external record"),
                ("library-search", dict(search=2), "search mode"),
                ("zero-search", dict(search=0), "search mode"),
                ("anti-dependency", dict(search=4), "search mode")):
            run([save(label + ".obj", alias(**changes)), fallback], False, needle)
        run([save("local-fallback.obj", object_bytes([dict(name="answer", fallback="local"),
                                                       dict(name="local", section=1, storage=3)], b"\xc3"))],
            False, "fallback must be external")

        provider = save("fallback.lib", archive_bytes([("fallback.obj", definition("fallback"), ["fallback"])]))
        poison = save("same-name.lib", archive_bytes([("answer.obj", b"bad COFF", ["answer"])]))
        run([weak, poison, provider])
        run([provider, poison, weak])
        run([save("no-library.obj", alias(search=1)), poison, provider])
        # A selected member can itself define a weak alias rather than executable code.
        weak_lib = save("weak.lib", archive_bytes([("weak.obj", alias(), ["answer"])]))
        run([weak_lib, provider])
        run([provider, weak_lib])
        delayed = object_bytes([dict(name="helper", section=1), dict(name="answer", fallback="fallback"),
                                dict(name="fallback")], b"\xc3")
        caller = object_bytes([dict(name="invoke", section=1), dict(name="helper")],
                              b"\xe9\0\0\0\0", [(1, 4, "helper")])
        late = save("late.lib", archive_bytes([("late.obj", delayed, ["helper"])]))
        run([save("demand.obj", caller), late, provider])
        unused = save("unused.obj", alias("unused", "bad_fallback"))
        unused_lib = save("unused.lib", archive_bytes([("bad.obj", b"bad COFF", ["bad_fallback"])]))
        run([save("strong.obj", definition("answer")), unused, unused_lib])

        # The unresolved diagnostic must carry the final fallback name to DLL selection.
        imported = root / "import.wl"
        imported.write_text('extern "c" in "kernel32" { func GetCurrentProcess() -> AnyPtr; }\n'
                            'extern "c" { func process_alias() -> AnyPtr; }\n'
                            'func main() -> Int {\n'
                            '    if (Long(process_alias()) != -1L) { return 1; }\n'
                            '    print("PASS: Weak DLL fallback");\n'
                            '    return 0;\n}\n', encoding="utf-8")
        run([save("import-alias.obj", alias("process_alias", "GetCurrentProcess"))], source=imported)

        if clang:
            assembly = root / "independent.s"
            assembly.write_text('.text\n.weak answer\n.set answer, fallback\n.globl fallback\n'
                                'fallback:\n movl $42, %eax\n retq\n', encoding="ascii")
            obj = root / "independent.obj"
            built = subprocess.run([str(clang), "--target=x86_64-pc-windows-msvc", "-c", str(assembly),
                                    "-o", str(obj)], capture_output=True, timeout=30)
            assert built.returncode == 0, built.stderr
            run([obj])
    print(f"PASS: COFF weak driver ({checks} checks)")


if __name__ == "__main__":
    check_weak(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
