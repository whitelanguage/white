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
        exact = save("exact.obj", object_bytes([text(mode=4)]))
        assert run([exact, exact]) == run([exact])
        run([exact, save("exact-different.obj", object_bytes([text(1, mode=4)]))], False, "Conflicting COMDAT")
        run([exact, save("exact-longer.obj", object_bytes([dict(text(mode=4), data=code() + b"\x90")]))],
            False, "Conflicting COMDAT")
        run([exact, one], False, "Conflicting COMDAT")

        small = save("small.obj", object_bytes([text(1, mode=6)]))
        large_section = dict(text(mode=6), data=code() + b"\x90")
        large = save("large.obj", object_bytes([large_section]))
        largest_alone = run([large])
        assert run([small, large]) == largest_alone
        assert run([large, small]) == largest_alone
        assert run([large, large]) == largest_alone
        tie = save("tie.obj", object_bytes([dict(large_section, data=code(1) + b"\x90")]))
        assert run([large, tie]) == largest_alone
        run([save("largest-one-file.obj", object_bytes([text(1, mode=6), large_section]))])
        for mode in (7, 8):
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

        # Replacing an earlier root also removes its transitive unwind and data contributions.
        old_tree = unwind(1)
        old_tree[0]["mode"] = 6
        old_tree[1]["data"] = b"\xff" * 8
        old_tree[2]["relocs"] = [(0, 3, "missing"), (4, 3, "missing"), (8, 3, "missing")]
        new_tree = unwind()
        new_tree[0]["mode"] = 6
        new_tree[0]["data"] += b"\x90"
        new_tree[2]["data"] = struct.pack("<III", 0, len(new_tree[0]["data"]), 0)
        new_unwind = save("largest-unwind.obj", object_bytes(new_tree))
        assert run([save("old-unwind.obj", object_bytes(old_tree)), new_unwind]) == run([new_unwind])
        old_data = dict(name=".rdata$old", data=b"\0" * 8, flags=0x40400040, mode=5, parent=1,
                        relocs=[(0, 1, "missing")])
        run([save("largest-one-file-tree.obj", object_bytes([text(1, mode=6), old_data, large_section]))])
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

        # A forced member replaces a root before its old dependency reaches the queue cursor.
        old_largest = object_bytes([text(1, mode=6),
            dict(name=".rdata$old", data=b"\0" * 8, flags=0x40400040, mode=5, parent=1,
                 relocs=[(0, 1, "missing")])])
        old_provider = save("old-largest.obj", old_largest)
        winning_member = object_bytes([large_section, helper])
        winning_lib = save("largest.lib", archive_bytes([("winner.obj", winning_member, ["helper", "answer"])]))
        run([old_provider, winning_lib, poison], caller=force)
        run([winning_lib, old_provider, poison], caller=force)

        # A retained wrapper used to reference storage defined in the revoked root.
        # It now needs an archive provider, even though the original relocation was not undefined.
        old_extra = dict(text(1, mode=6), symbols=[dict(name="extra", storage=2)])
        old_wrapper = dict(helper, relocs=[(1, 4, "extra")])
        extras = save("extras.lib", archive_bytes([("extra.obj", object_bytes([text(key="extra", mode=0)]), ["extra"])]))
        replacement = save("replacement.lib", archive_bytes([("winner.obj", object_bytes([large_section,
            dict(name=".text$force", data=code(), key="force", mode=0)]), ["answer", "force"])]))
        force_extra = root / "force-extra.wl"
        force_extra.write_text('extern "c" { func answer() -> Int; func force() -> Int; func helper() -> Int; }\n'
                               'func main() -> Int { if (helper() != 42 || force() != 42 || answer() != 42) { return 1; }\n'
                               '    print("PASS: Rebound COMDAT secondary symbol"); return 0; }\n', encoding="ascii")
        old_with_extra = save("old-extra.obj", object_bytes([old_extra, old_wrapper]))
        run([old_with_extra, replacement, extras], caller=force_extra)
        run([old_with_extra, replacement], False, "undefined or non-address", caller=force_extra)
        old_local = dict(old_extra, symbols=[dict(name="local", storage=3)])
        local_wrapper = dict(helper, relocs=[(1, 4, "local")])
        run([save("largest-lost-local.obj", object_bytes([old_local, local_wrapper])), replacement],
            False, "discarded local", caller=force_extra)

        # An extracted member's discarded definition is not a corrupt directory entry.
        # A later library may still provide the missing secondary name.
        old_extra_lib = save("old-extra.lib", archive_bytes([("old.obj", object_bytes([old_extra, old_wrapper]),
                                                            ["answer", "extra", "helper"])]))
        run([old_extra_lib, replacement, extras], caller=force_extra)
        run([old_extra_lib, replacement], False, "undefined or non-address", caller=force_extra)

        # The ordinary wrapper forces a second, larger replacement in the same library.
        last_section = dict(large_section, data=code() + b"\x90\x90")
        chain_lib = save("largest-chain.lib", archive_bytes([
            ("first.obj", object_bytes([dict(large_section, data=code(1) + b"\x90"),
                dict(helper, relocs=[(1, 4, "next")])]), ["answer", "helper"]),
            ("next.obj", object_bytes([last_section, dict(helper, key="next")]), ["answer", "next"])]))
        run([old_provider, chain_lib, poison], caller=force)

        # EXACT_MATCH follows link.exe/LLD payload comparison, symbol table indices and
        # relocation targets do not participate. Only the retained relocation is resolved.
        exact_jump = dict(text(mode=4), data=b"\xe9\0\0\0\0", relocs=[(1, 4, "target")])
        target = dict(text(key="target", mode=0), name=".text$target")
        exact_a = save("exact-reloc-a.obj", object_bytes([exact_jump, target]))
        exact_b = save("exact-reloc-b.obj", object_bytes([dict(exact_jump, relocs=[(1, 4, "missing")])]))
        run([exact_a, exact_b, poison])

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
