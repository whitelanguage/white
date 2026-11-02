"""Exercise archive extraction without an external linker or librarian."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def object_bytes(name, code, references=()):
    # One text section is enough for dependency cycles and competing definitions.
    symbols = [(name, 1)] + [(target, 0) for _, _, target in references]
    strings = bytearray(b"\0" * 4)
    rows = bytearray()
    for symbol, section in symbols:
        spelling = symbol.encode("ascii")
        if len(spelling) <= 8:
            field = spelling.ljust(8, b"\0")
        else:
            field = struct.pack("<II", 0, len(strings))
            strings += spelling + b"\0"
        rows += struct.pack("<8sIhHBB", field, 0, section, 0x20, 2, 0)
    struct.pack_into("<I", strings, 0, len(strings))
    relocations = b"".join(struct.pack("<IIH", offset, i + 1, kind)
                           for i, (offset, kind, _) in enumerate(references))
    symbol_offset = 60 + len(code) + len(relocations)
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset, len(symbols), 0, 0)
    section = struct.pack("<8sIIIIIIHHI", b".text", 0, 0, len(code), 60,
                          60 + len(code) if relocations else 0, 0, len(references), 0, 0x60500020)
    return header + section + code + relocations + rows + strings


def member(name, data):
    header = (name.ljust(16).encode("ascii") + b"0           0     0     0       "
              + str(len(data)).ljust(10).encode("ascii") + b"`\n")
    assert len(header) == 60
    return header + data + (b"\n" if len(data) & 1 else b"")


def archive_bytes(items, second=False):
    # Directory records describe headers, never payload byte positions.
    longnames = bytearray()
    names = []
    for name, _, _ in items:
        if len(name) > 15:
            names.append("/" + str(len(longnames)))
            longnames += name.encode("ascii") + b"\0"
        else:
            names.append(name + "/")
    symbols = [(symbol, i) for i, (_, _, symbols) in enumerate(items) for symbol in symbols]
    first_size = 4 + 4 * len(symbols) + sum(len(name) + 1 for name, _ in symbols)
    sorted_symbols = sorted(symbols)
    second_size = 8 + 4 * len(items) + 2 * len(symbols) + sum(len(n) + 1 for n, _ in symbols)
    start = 8 + 60 + first_size + (first_size & 1)
    if second:
        start += 60 + second_size + (second_size & 1)
    if longnames:
        start += len(member("//", longnames))
    offsets = []
    for name, (_, data, _) in zip(names, items):
        offsets.append(start)
        start += len(member(name, data))
    first = struct.pack(">I", len(symbols))
    first += b"".join(struct.pack(">I", offsets[i]) for _, i in symbols)
    first += b"".join(name.encode("ascii") + b"\0" for name, _ in symbols)
    result = b"!<arch>\n" + member("/", first)
    if second:
        directory = struct.pack("<I", len(items))
        directory += b"".join(struct.pack("<I", n) for n in offsets)
        directory += struct.pack("<I", len(symbols))
        directory += b"".join(struct.pack("<H", i + 1) for _, i in sorted_symbols)
        directory += b"".join(name.encode("ascii") + b"\0" for name, _ in sorted_symbols)
        result += member("/", directory)
    if longnames:
        result += member("//", longnames)
    result += b"".join(member(n, data) for n, (_, data, _) in zip(names, items))
    return result


def check_archives(compiler, librarian=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-archive-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        fixture = repo / "tests/fixtures/linker/driver_object.wl"
        answer = object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "helper")])
        helper = object_bytes("helper", bytes.fromhex("b8 2a 00 00 00 c3") + b"\0" * 8, [(6, 1, "answer")])
        leaf = object_bytes("answer", bytes.fromhex("b8 2a 00 00 00 c3"))
        wrong = object_bytes("answer", bytes.fromhex("b8 01 00 00 00 c3"))

        def run(inputs, success=True, needle="", execute=True):
            nonlocal checks
            output = root / f"case-{checks}.exe"
            # Validation failures must not truncate an existing destination.
            if not success:
                output.write_bytes(b"untouched")
            result = subprocess.run([str(compiler), str(fixture), "--backend=machine",
                                     "--linker=white", "-o", str(output), *map(str, inputs)],
                                    cwd=repo, env=env, capture_output=True, timeout=30)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (inputs, text)
            if needle:
                assert needle in text, text
            if success and execute:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, child
            if not success:
                assert output.read_bytes() == b"untouched"
                assert "InternalCompilerError" not in text, text
            checks += 1

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        items = [("very_long_answer_member.obj", answer, ["answer"]),
                 ("helper.obj", helper, ["helper"]), ("unused.obj", b"not a COFF object", ["unused"])]
        for second in (False, True):
            lib = save(f"indexed-{second}.lib", archive_bytes(items, second))
            run([lib])
        a = save("answer.lib", archive_bytes([items[0]]))
        h = save("helper.lib", archive_bytes([items[1]], True))
        run([a, h])
        run([h, a])
        early = save("early.lib", archive_bytes([("answer.obj", leaf, ["answer"])]))
        late = save("late.lib", archive_bytes([("answer.obj", wrong, ["answer"])]))
        run([early, late])
        run([late, save("ordinary.obj", leaf)])
        run([save("two.lib", archive_bytes([("first.obj", leaf, ["answer"]),
                                             ("second.obj", wrong, ["answer"])]))])
        run([save("stale.lib", archive_bytes([("wrong.obj", leaf, ["answer", "helper"])])), h])
        run([save("lie.lib", archive_bytes([("wrong.obj", helper, ["answer"])]))],
            False, "does not define")
        run([save("bad-member.lib", archive_bytes([("bad.obj", b"bad", ["answer"])]))],
            False, "Selected archive member")
        # Short import objects are deliberately a separate follow-up batch.
        short_import = struct.pack("<HHHHIIHH", 0, 65535, 0, 0x8664, 0, 18, 0, 4) + b"answer\0sample.dll\0"
        run([save("import.lib", archive_bytes([("import.obj", short_import, ["answer"])]))],
            False, "import objects")
        run([save("thin.a", b"!<thin>\n")], False, "thin archives")
        run([save("no-index.a", b"!<arch>\n" + member("answer.obj/", leaf))], False, "no symbol directory")
        run([save("overflow.lib", b"!<arch>\n" + b"/".ljust(16) + b" " * 32 + b"9999999999`\n")],
            False, "member size")
        run([save("empty-index.lib", b"!<arch>\n" + member("/", b""))], False, "symbol directory")
        run([save("empty-second.lib", b"!<arch>\n" + member("/", b"\0" * 4) + member("/", b""))],
            False, "symbol directory")
        run([save("huge-count.lib", b"!<arch>\n" + member("/", b"\xff" * 4))], False, "symbol offsets")
        base = bytearray(archive_bytes(items, True))
        first_size = int(base[56:66].strip())
        second_header = 8 + 60 + first_size + (first_size & 1)
        second_data = second_header + 60
        for label, offset, replacement in (
                ("payload-offset", 72, struct.pack(">I", 9)),
                ("second-count", second_data, b"\xff" * 4),
                ("second-index", second_data + 8 + len(items) * 4, b"\0\0"),
                ("long-offset", int.from_bytes(base[72:76], "big"), b"/999".ljust(16)),
                ("terminator", 66, b"??")):
            mutated = bytearray(base)
            mutated[offset:offset + len(replacement)] = replacement
            run([save(label + ".lib", mutated)], False, "LinkError:")
        run([save("truncated.lib", base[:-1])], False, "LinkError:")
        run([save("many-unused.lib", archive_bytes(
            [(f"unused_member_{i}.obj", b"unused", [f"unused_symbol_{i}"]) for i in range(512)] + items[:2], True))])

        if librarian:
            # Independent MS and GNU writers cover both directory byte orders and long names.
            answer_file = save("independent_answer_with_long_name.obj", answer)
            helper_file = save("independent_helper_with_long_name.obj", helper)
            tools = Path(librarian).resolve().parent
            microsoft = root / "llvm-ms.lib"
            written = subprocess.run([str(librarian), f"/out:{microsoft}", str(answer_file), str(helper_file)],
                                     capture_output=True, timeout=30)
            assert written.returncode == 0, written.stderr
            run([microsoft])
            gnu = root / "llvm-gnu.a"
            subprocess.run([str(tools / "llvm-ar.exe"), "--format=gnu", "rcs", str(gnu),
                            str(answer_file), str(helper_file)], check=True, capture_output=True, timeout=30)
            run([gnu])
    print(f"PASS: Static archive driver ({checks} checks)")


if __name__ == "__main__":
    check_archives(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
