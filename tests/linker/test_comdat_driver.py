"""Exercise COMDAT selection with hand-built COFF and independent Clang objects."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes


def object_bytes(sections, extra=()):
    symbols = []
    for number, section in enumerate(sections, 1):
        mode = section.get("mode", 0)
        aux = struct.pack("<IHHIHBBH", len(section["data"]), len(section.get("relocs", ())), 0,
                          0, section.get("parent", 0), mode, 0, 0)
        symbols.append(dict(name=section["name"], section=number, storage=3, aux=aux))
        if "key" in section:
            symbols.append(dict(name=section["key"], section=number, storage=section.get("key_storage", 2)))
        symbols.extend(dict(s, section=number) for s in section.get("symbols", ()))
    symbols.extend(extra)
    names = {s["name"] for s in symbols}
    for section in sections:
        for _, _, target in section.get("relocs", ()):
            if target not in names:
                symbols.append(dict(name=target, section=0))
                names.add(target)
    indices = {}
    count = 0
    strings = bytearray(b"\0" * 4)

    def field(name):
        name = name.encode("ascii")
        if len(name) <= 8:
            return name.ljust(8, b"\0")
        result = struct.pack("<II", 0, len(strings))
        strings.extend(name + b"\0")
        return result

    rows = bytearray()
    for symbol in symbols:
        indices[symbol["name"]] = count
        aux = symbol.get("aux", b"")
        rows += struct.pack("<8sIhHBB", field(symbol["name"]), symbol.get("value", 0), symbol["section"],
                            0, symbol.get("storage", 2), len(aux) // 18) + aux
        count += 1 + len(aux) // 18
    headers = bytearray()
    payload = bytearray()
    offset = 20 + len(sections) * 40
    for section in sections:
        name = section["name"].encode("ascii")
        if len(name) > 8:
            name_offset = len(strings)
            strings += name + b"\0"
            name = ("/" + str(name_offset)).encode("ascii")
        data = section["data"]
        refs = section.get("relocs", ())
        relocs = b"".join(struct.pack("<IIH", position, indices[target], kind) for position, kind, target in refs)
        flags = section.get("flags", 0x60500020)
        if section.get("mode", 0):
            flags |= 0x1000
        headers += struct.pack("<8sIIIIIIHHI", name.ljust(8, b"\0"), 0, 0, len(data), offset if data else 0,
                               offset + len(data) if relocs else 0, 0, len(refs), 0, flags)
        payload += data + relocs
        offset += len(data) + len(relocs)
    struct.pack_into("<I", strings, 0, len(strings))
    return struct.pack("<HHIIIHH", 0x8664, len(sections), 0, offset, count, 0, 0) + headers + payload + rows + strings


def code(value=42):
    return b"\xb8" + struct.pack("<I", value) + b"\xc3"


def text(value=42, mode=2, name=".text$answer", key="answer"):
    return dict(name=name, data=code(value), key=key, mode=mode)


def unwind(value=42):
    body = b"\x48\x83\xec\x28" + code(value)[:-1] + b"\x48\x83\xc4\x28\xc3"
    return [dict(text(value), data=body),
            dict(name=".xdata$answer", data=bytes.fromhex("01 04 01 00 04 42 00 00"),
                 flags=0x40300040, mode=5, parent=1),
            dict(name=".pdata$answer", data=struct.pack("<III", 0, len(body), 0),
                 flags=0x40300040, mode=5, parent=2,
                 relocs=[(0, 3, "answer"), (4, 3, "answer"), (8, 3, ".xdata$answer")])]


def check_comdat(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-comdat-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        source = root / "caller.wl"
        source.write_text('extern "c" { func answer() -> Int; }\n'
                          'func main() -> Int { if (answer() != 42) { return 1; }\n'
                          '    print("PASS: COMDAT answer"); return 0; }\n', encoding="ascii")

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(inputs, success=True, needle="", caller=source):
            nonlocal checks
            output = root / f"case-{checks}.exe"
            if not success:
                output.write_bytes(b"untouched")
            built = subprocess.run([str(compiler), str(caller), "--backend=machine", "--linker=white", "-o",
                                    str(output), *map(str, inputs)], cwd=repo, env=env, capture_output=True, timeout=40)
            text_output = (built.stdout + built.stderr).decode("utf-8", errors="replace")
            assert (built.returncode == 0) == success, (inputs, text_output)
            if needle:
                assert needle in text_output, text_output
            assert "InternalCompilerError" not in text_output, text_output
            if success:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, child
            else:
                assert output.read_bytes() == b"untouched"
            checks += 1
            return output.read_bytes()

        one = save("one.obj", object_bytes([text()]))
        two = save("two.obj", object_bytes([text(1)]))
        alone = run([one])
        assert run([one, two]) == alone
        assert run([one, one]) == alone
        run([save("one-file.obj", object_bytes([text(), text(1, name=".text$other")]))])
        run([save("same1.obj", object_bytes([text(mode=3)])),
             save("same2.obj", object_bytes([text(1, mode=3)]))])
        run([save("size-mismatch.obj", object_bytes([dict(text(mode=3), data=code() + b"\x90")])),
             save("same1.obj", object_bytes([text(mode=3)]))], False, "Conflicting COMDAT")
        run([save("unique1.obj", object_bytes([text(mode=1)])),
             save("unique2.obj", object_bytes([text(mode=1)]))], False, "Conflicting COMDAT")
        run([one, save("mixed.obj", object_bytes([text(mode=3)]))], False, "Conflicting COMDAT")
        run([one, save("ordinary.obj", object_bytes([text(mode=0)]))], False, "Duplicate external")
        for mode in (4, 6, 7, 8):
            run([save(f"mode-{mode}.obj", object_bytes([text(mode=mode)]))], False, "selection mode")

        a = save("unwind1.obj", object_bytes(unwind()))
        b = save("unwind2.obj", object_bytes(unwind(1)))
        original = run([a])
        assert run([a, b]) == original
        assert run([a, a]) == original
        # A discarded subtree must not introduce unresolved demands or damaged unwind data.
        damaged = unwind(1)
        damaged[1]["data"] = b"\xff" * 8
        damaged[2]["relocs"] = [(0, 3, "missing"), (4, 3, "missing"), (8, 3, "missing")]
        run([a, save("discarded-unwind.obj", object_bytes(damaged))])
        for label, change, needle in (
                ("parent-zero", 0, "parent"), ("parent-big", 99, "parent"),
                ("parent-self", 2, "parent")):
            broken = unwind()
            broken[1]["parent"] = change
            run([save(label + ".obj", object_bytes(broken))], False, needle)
        cycle = unwind()
        cycle[1]["parent"] = 3
        run([save("cycle.obj", object_bytes(cycle))], False, "parent cycle")
        plain_parent = unwind()
        plain_parent[0]["mode"] = 0
        run([save("plain-parent.obj", object_bytes(plain_parent))], False, "parent")
        high_parent = bytearray(object_bytes(unwind()))
        table = struct.unpack_from("<I", high_parent, 8)[0]
        struct.pack_into("<H", high_parent, table + 4 * 18 + 16, 1)
        run([save("high-parent.obj", high_parent)], False, "parent")

        damaged = bytearray(object_bytes([text()]))
        symbol_start = struct.unpack_from("<I", damaged, 8)[0]
        for label, offset, value, needle in (
                ("length", symbol_start + 18, struct.pack("<I", 999), "auxiliary length"),
                ("definition-class", symbol_start + 16, b"\x02", "section definition"),
                ("definition-value", symbol_start + 8, b"\x01", "section definition"),
                ("definition-name", symbol_start + 4, struct.pack("<I", 99999), "symbol name")):
            changed = bytearray(damaged)
            changed[offset:offset + len(value)] = value
            run([save(label + ".obj", changed)], False, needle)

        helper = dict(name=".text$helper", data=b"\xe9\0\0\0\0", key="helper", mode=0,
                      relocs=[(1, 4, "answer")])
        force = root / "helper.wl"
        force.write_text('extern "c" { func answer() -> Int; func helper() -> Int; }\n'
                         'func main() -> Int { if (answer() != 42 || helper() != 42) { return 1; }\n'
                         '    print("PASS: Archive COMDAT"); return 0; }\n', encoding="ascii")
        member = object_bytes([text(1), helper,
            dict(name=".rdata$bad", data=b"\0" * 8, flags=0x40400040, mode=5, parent=1,
                 relocs=[(0, 1, "missing")])])
        library = save("extra.lib", archive_bytes([("helper.obj", member, ["helper", "answer"])]))
        poison = save("poison.lib", archive_bytes([("missing.obj", b"bad COFF", ["missing"])]))
        run([one, library, poison], caller=force)
        run([library, one, poison], caller=force)
        provider = save("provider.lib", archive_bytes([("answer.obj", object_bytes([text()]), ["answer"])]))
        run([provider])

        # Retained relocations to local discarded storage cannot be guessed by byte offset.
        lost = text(1)
        lost["symbols"] = [dict(name="local", storage=3)]
        local_caller = dict(helper, relocs=[(1, 4, "local")])
        run([one, save("local-ref.obj", object_bytes([lost, local_caller]))], False, "discarded local")

        if clang:
            cpp = root / "inline.cpp"
            objects = []
            # The ordinary wrappers differ, the inline implementation is a duplicate COMDAT.
            for i, wrapper in enumerate(("answer", "helper")):
                cpp.write_text('inline int shared(int x) { volatile int v = x; return v + 1; }\n'
                               f'extern "C" int {wrapper}() {{ return shared(41); }}\n', encoding="ascii")
                obj = root / f"clang-{i}.obj"
                compiled = subprocess.run([str(clang), "--target=x86_64-pc-windows-msvc", "-c", "-O0",
                                           "-fno-exceptions", "-fno-rtti", str(cpp), "-o", str(obj)],
                                          capture_output=True, timeout=30)
                assert compiled.returncode == 0, compiled.stderr
                objects.append(obj)
            run(objects, caller=force)
    print(f"PASS: COFF COMDAT driver ({checks} checks)")


if __name__ == "__main__":
    check_comdat(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
