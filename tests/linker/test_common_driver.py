"""Check common storage without asking another linker to allocate it."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes
from test_comdat_driver import object_bytes, text


def common(name, size):
    return dict(name=name, section=0, value=size)


def accessors(state="state", buffer="buffer"):
    return [dict(name=".text$read", key="read_state", data=b"\x8b\x05\0\0\0\0\xc3",
                 relocs=[(2, 4, state)]),
            dict(name=".text$write", key="write_state", data=b"\x89\x0d\0\0\0\0\xc3",
                 relocs=[(2, 4, state)]),
            dict(name=".text$address", key="storage", data=b"\x48\x8d\x05\0\0\0\0\xc3",
                 relocs=[(3, 4, buffer)])]


def bss_size(image):
    pe = struct.unpack_from("<I", image, 60)[0]
    count = struct.unpack_from("<H", image, pe + 6)[0]
    header = pe + 24 + struct.unpack_from("<H", image, pe + 20)[0]
    sizes = []
    for i in range(count):
        section = header + 40 * i
        if image[section:section + 8].rstrip(b"\0") == b".bss":
            virtual_size = struct.unpack_from("<I", image, section + 8)[0]
            assert struct.unpack_from("<I", image, section + 16)[0] == 0
            sizes.append(virtual_size)
    return sum(sizes)


def check_common(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-common-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        source = root / "caller.wl"

        def caller(initial=0, size=300, helper=False):
            source.write_text(
                'extern "c" { func read_state() -> Int; func write_state(value: Int) -> Void;\n'
                '    func storage() -> AnyPtr;' + (' func helper() -> Int;' if helper else '') + ' }\n'
                'func main() -> Int {\n'
                f'    if (read_state() != {initial}) {{ return 1; }}\n'
                '    write_state(42); if (read_state() != 42) { return 2; }\n'
                '    let address = storage(); let ptr data: Byte = address;\n'
                '    if ((UInt64(address) & 31UL) != 0UL) { return 3; }\n'
                f'    for (let i = 0; i < {size}; i++) {{\n'
                '        if (data[i] != Byte(0)) { return 4; }\n'
                '        data[i] = Byte(i % 256);\n'
                '    }\n' + ('    if (helper() != 42) { return 5; }\n' if helper else '') +
                '    print("PASS: Common storage"); return 0;\n}\n', encoding="ascii")

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(inputs, success=True, needle=""):
            nonlocal checks
            output = root / f"case-{checks}.exe"
            if not success:
                output.write_bytes(b"untouched")
            built = subprocess.run([str(compiler), str(source), "--backend=machine", "--linker=white", "-o",
                                    str(output), *map(str, inputs)], cwd=repo, env=env, capture_output=True, timeout=40)
            message = (built.stdout + built.stderr).decode("utf-8", errors="replace")
            assert (built.returncode == 0) == success, (inputs, message)
            assert "InternalCompilerError" not in message, message
            if needle:
                assert needle in message, message
            if success:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b"PASS:" in child.stdout, (inputs, child)
            else:
                assert output.read_bytes() == b"untouched"
            checks += 1
            return output.read_bytes()

        caller()
        code = save("access.obj", object_bytes(accessors()))
        small = save("small.obj", object_bytes([], [common("state", 4), common("buffer", 300)]))
        large = save("large.obj", object_bytes([], [common("state", 32), common("buffer", 600)]))
        baseline = run([code, small])
        assert bss_size(baseline) >= 304
        assert run([code, small, small]) == baseline
        assert run([small, code]) == baseline
        larger = run([code, small, large])
        assert bss_size(larger) >= 632
        assert len(larger) == len(baseline)
        run([code, large, small])

        # A real definition wins even when the common's requested size cannot fit an image.
        strong = save("strong.obj", object_bytes([
            dict(name=".data", data=struct.pack("<I", 7), key="state", flags=0xC0300040)]))
        huge_state = save("huge-state.obj", object_bytes([], [common("state", 0xffffffff)]))
        caller(initial=7)
        run([code, small, strong, huge_state])
        run([strong, code, huge_state, small])
        run([code, small, strong, strong], False, "Duplicate external")
        caller()
        huge = save("huge.obj", object_bytes([], [common("buffer", 0xffffffff)]))
        run([code, small, huge], False, "Common storage exceeds")
        accumulated = save("accumulated.obj", object_bytes([], [common("left", 0x60000000), common("right", 0x60000000)]))
        run([code, small, accumulated], False, "Common storage exceeds")
        empty = save("empty-name.obj", object_bytes([], [common("", 1)]))
        run([code, small, empty], False, "Invalid COFF symbol name")

        # Library extraction must recognize commons as definitions, not unsatisfied references.
        poison = save("poison.lib", archive_bytes([("bad.obj", b"invalid", ["state", "buffer"])]))
        run([code, small, poison])
        provider = save("provider.lib", archive_bytes([("common.obj", small.read_bytes(), ["state", "buffer"])]))
        run([code, provider])
        helper = dict(text(name=".text$helper", key="helper"), mode=0)
        promoted = save("promoted.lib", archive_bytes([("helper.obj", object_bytes([helper],
            [common("state", 32), common("buffer", 600)]), ["helper", "state", "buffer"])]))
        caller(helper=True, size=600)
        run([code, small, promoted])
        override = save("override.lib", archive_bytes([("helper.obj", object_bytes([helper,
            dict(name=".data", data=struct.pack("<I", 7), key="state", flags=0xC0300040)]), ["helper", "state"])]))
        caller(initial=7, helper=True)
        run([code, small, override])
        run([override, code, small])
        caller()

        # Weak fallback chains and absolute declarations use the same final common allocation.
        weak = dict(name="alias", section=0, storage=105, aux=struct.pack("<II10x", 2, 3))
        aliased = save("aliased.obj", object_bytes([], [weak, common("state", 4), common("buffer", 300)]))
        alias_code = save("alias-access.obj", object_bytes(accessors(state="alias")))
        run([alias_code, aliased])
        absolute = save("absolute.obj", object_bytes([], [dict(name="state", section=-1, value=0)]))
        run([code, absolute, small])
        run([code, small, absolute])

        if clang:
            c = root / "common.c"
            c.write_text('int state; unsigned char buffer[300];\n'
                         'int read_state(void) { return state; }\n'
                         'void write_state(int value) { state = value; }\n'
                         'void *storage(void) { return buffer; }\n', encoding="ascii")
            obj = root / "clang-common.obj"
            built = subprocess.run([str(clang), "--target=x86_64-pc-windows-msvc", "-fcommon", "-fno-stack-protector",
                                    "-c", "-O0", str(c), "-o", str(obj)], capture_output=True, timeout=30)
            assert built.returncode == 0, built.stderr
            raw = obj.read_bytes()
            start, count = struct.unpack_from("<II", raw, 8)
            index = 0
            commons = 0
            while index < count:
                row = start + index * 18
                value, section = struct.unpack_from("<Ih", raw, row + 8)
                if section == 0 and value and raw[row + 16] == 2:
                    commons += 1
                index += 1 + raw[row + 17]
            assert commons == 2, "fixture must contain real COFF common symbols"
            run([obj])
    print(f"PASS: COFF common driver ({checks} checks)")


if __name__ == "__main__":
    check_common(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
