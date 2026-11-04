"""Link directive-bearing objects without a host linker on the compiler PATH."""
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_comdat_driver import object_bytes, text, code
from test_archive_driver import archive_bytes
from test_import_driver import short_import
from test_weak_driver import alias


def directive(data, **kwargs):
    if isinstance(data, str):
        data = data.encode("ascii")
    return dict(name=".drectve", data=data, flags=0x00100A00, **kwargs)


def check_directives(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-directives-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        source = root / "main.wl"
        source.write_text('func main() -> Int { print("PASS: COFF directives"); return 0; }\n', encoding="ascii")

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def run(inputs, success=True, needle="", shared=False):
            nonlocal checks
            output = root / (f"case-{checks}.dll" if shared else f"case-{checks}.exe")
            library = output.with_suffix(".lib")
            if not success:
                output.write_bytes(b"untouched")
                if shared:
                    library.write_bytes(b"untouched library")
            args = [str(compiler), str(source), "--backend=machine", "--linker=white", "-o", str(output)]
            if shared:
                args.append("--shared")
            built = subprocess.run([*args, *map(str, inputs)], cwd=repo, env=env,
                                   capture_output=True, timeout=45)
            message = (built.stdout + built.stderr).decode("utf-8", errors="replace")
            assert (built.returncode == 0) == success, (inputs, message)
            assert "InternalCompilerError" not in message, message
            if needle:
                assert needle in message, message
            if not success:
                assert output.read_bytes() == b"untouched"
                if shared:
                    assert library.read_bytes() == b"untouched library"
            else:
                image = output.read_bytes()
                pe = struct.unpack_from("<I", image, 60)[0]
                count = struct.unpack_from("<H", image, pe + 6)[0]
                section_start = pe + 24 + struct.unpack_from("<H", image, pe + 20)[0]
                names = [image[section_start + i * 40:section_start + i * 40 + 8].rstrip(b"\0")
                         for i in range(count)]
                assert b".drectve" not in names, names
                if not shared:
                    child = subprocess.run([str(output)], capture_output=True, timeout=15)
                    assert child.returncode == 0 and b"PASS:" in child.stdout, child
                else:
                    assert library.read_bytes().startswith(b"!<arch>\n")
            checks += 1
            return output

        def exports(path, names=(), ordinals=(), data=()):
            nonlocal checks
            dll = ctypes.WinDLL(str(path))
            kernel = ctypes.windll.kernel32
            kernel.GetProcAddress.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            kernel.GetProcAddress.restype = ctypes.c_void_p
            kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
            kernel.FreeLibrary.restype = ctypes.c_int
            try:
                for name in names:
                    function = getattr(dll, name)
                    function.restype = ctypes.c_int
                    assert function() == 42
                for ordinal in ordinals:
                    address = kernel.GetProcAddress(dll._handle, ordinal)
                    assert address and ctypes.CFUNCTYPE(ctypes.c_int)(address)() == 42
                for name in data:
                    assert ctypes.c_int.in_dll(dll, name).value == 42
            finally:
                assert kernel.FreeLibrary(dll._handle)
            checks += 1

        provider = object_bytes([text(mode=0)])
        library = save("provider.lib", archive_bytes([("answer.obj", provider, ["answer"])]))
        for spelling in ('/include:answer', '-INCLUDE:answer', '"/include:answer"', '/include:"answer"'):
            run([save("include.obj", object_bytes([directive(spelling)])), library])
        run([save("include.obj", object_bytes([directive('/include:answer /include:answer')])), library])
        run([save("missing.obj", object_bytes([directive('/include:missing')]))], False, "Required linker symbol")
        run([save("direct.obj", object_bytes([text(mode=0), directive('/include:answer')]))])
        imports = save("kernel.lib", archive_bytes([
            ("thread.obj", short_import("GetCurrentThreadId", dll="kernel32.dll"),
             ["GetCurrentThreadId", "__imp_GetCurrentThreadId"])]))
        for symbol in ("GetCurrentThreadId", "__imp_GetCurrentThreadId"):
            run([save("import-root.obj", object_bytes([directive('/include:' + symbol)])), imports])
        run([save("weak-root.obj", object_bytes([directive('/include:weak_answer')])),
             save("weak.obj", alias("weak_answer", "answer")), library])
        run([save("weak-missing.obj", object_bytes([directive('/include:weak_answer')])),
             save("weak.obj", alias("weak_answer", "missing"))], False, "Required linker symbol")

        # Directives in an extracted member can load another member, an untouched member stays lazy.
        entry = object_bytes([text(key="entry", mode=0), directive('/include:answer')])
        nested = save("nested.lib", archive_bytes([
            ("entry.obj", entry, ["entry"]), ("answer.obj", provider, ["answer"]),
            ("unused.obj", object_bytes([text(key="unused", mode=0), directive('/defaultlib:missing')]), ["unused"])]))
        run([save("start.obj", object_bytes([directive('/include:entry')])), nested])
        run([save("load-bad.obj", object_bytes([directive('/include:unused')])), nested], False, "Could not find library")
        # A larger COMDAT restarts the demand queue, directive-only roots must survive it.
        small = object_bytes([text(key="entry", mode=6), directive('/include:load_larger')])
        # The directory's second name is a real ordinary definition in the selected member.
        replacement = object_bytes([dict(text(key="entry", mode=6), data=code() + b'\x90'),
                                    text(key="load_larger", mode=0), directive('/include:answer')])
        replaced = save("replace.lib", archive_bytes([
            ("larger.obj", replacement, ["entry", "load_larger"]),
            ("answer.obj", provider, ["answer"])]))
        run([save("small.obj", small), replaced])
        conflict_member = object_bytes([text(key="entry", mode=0), directive('/failifmismatch:runtime=other')])
        conflict_archive = save("conflict.lib", archive_bytes([("entry.obj", conflict_member, ["entry"])]))
        run([save("match-root.obj", object_bytes([directive('/include:entry /failifmismatch:runtime=white')])),
             conflict_archive], False, "mismatch requirement conflicts")

        # An export is itself a root, its provider need not have an ordinary code reference.
        exported = save("export.obj", object_bytes([directive('/export:answer')]))
        exports(run([exported, library], shared=True), names=["answer"])
        exports(run([exported, exported, library], shared=True), names=["answer"])
        alias_object = save("alias.obj", object_bytes([directive('-EXPORT:"Public Answer=answer,@7" /export:Other=answer,@9,NONAME')]))
        exports(run([alias_object, library], shared=True), names=["Public Answer"], ordinals=[7, 9])
        constant = dict(name=".data", data=struct.pack("<I", 42), key="answer", flags=0xC0300040)
        exports(run([save("data.obj", object_bytes([constant, directive('/export:answer,DATA')]))], shared=True), data=["answer"])
        run([save("not-data.obj", object_bytes([text(mode=0), directive('/export:answer,DATA')]))],
            False, "DATA export", shared=True)
        for argument, needle in (
            ('', 'Missing'), ('=answer', 'Invalid COFF export'), ('Public=', 'Invalid COFF export'),
            ('answer,@0', 'ordinal'), ('answer,@65536', 'ordinal'), ('answer,@42949672960', 'ordinal'),
            ('answer,@1,@2', 'attribute'), ('answer,NONAME', 'requires an ordinal'),
            ('answer,PRIVATE', 'attribute'), ('answer,CONSTANT', 'attribute'), ('answer,', 'attribute'),
            ('Public=other.answer', 'Forwarded')):
            run([save("invalid-export.obj", object_bytes([text(mode=0), directive('/export:' + argument)]))],
                False, needle, shared=True)
        run([save("conflict.obj", object_bytes([text(mode=0), directive('/export:answer /export:answer=other')]))],
            False, "Conflicting", shared=True)
        run([save("ordinal-conflict.obj", object_bytes([text(mode=0), directive('/export:One=answer,@7 /export:Two=answer,@7')]))],
            False, "Duplicate PE export ordinal", shared=True)

        mismatch = save("match.obj", object_bytes([directive('/failifmismatch:"runtime=white version"')]))
        run([mismatch, mismatch])
        run([mismatch, save("bad-match.obj", object_bytes([directive('/failifmismatch:runtime=other')]))], False, "mismatch requirement conflicts")
        run([save("keys.obj", object_bytes([directive('/failifmismatch:A=one /failifmismatch:a=two')]))])
        run([save("escape.obj", object_bytes([directive(r'/failifmismatch:"key=slash\and\"quote" /failifmismatch:"key=slash\and""quote"')]))])
        bom = b'\xef\xbb\xbf' + '/failifmismatch:"name=中文"'.encode("utf-8")
        run([save("bom.obj", object_bytes([directive(bom)]))])
        for spelling in ('/failifmismatch:key', '/failifmismatch:=value', '/failifmismatch:key='):
            run([save("bad-requirement.obj", object_bytes([directive(spelling)]))], False, "mismatch requirement")

        for data, needle in (
            (b'/include:', 'Missing'), (b'/include:"answer', 'Unterminated quote'),
            (b'/include:"an\0swer"', 'control byte'), (b'/include:an\x01swer', 'control byte'),
            (b'/include:\x80', 'BOM'), (b'\xef\xbb\xbf/include:\xff', 'UTF-8'),
            (b'@response.txt', 'Invalid COFF'), (b'/defaultlib:crt.lib', 'Could not find library'),
            (b'/alternatename:one=two', 'Unsupported'), (b'/merge:.data=.text', 'Unsupported')):
            run([save("bad-token.obj", object_bytes([directive(data)]))], False, needle)
        run([save("padding.obj", object_bytes([directive(b' \t\r\n\0\0')]))])
        run([save("empty.obj", object_bytes([directive(b'')]))])
        bad_flags = directive('/include:answer')
        bad_flags['flags'] &= ~512
        run([save("bad-flags.obj", object_bytes([bad_flags]))], False, "directive section")
        bad_comdat = directive('/include:answer', mode=2, key="directive_key")
        run([save("comdat.obj", object_bytes([bad_comdat]))], False, "directive section")
        suffix = directive('/include:answer')
        suffix['name'] = '.drectve$extra'
        run([save("suffix.obj", object_bytes([suffix]))], False, "processing before PE layout")
        reloc = directive(b' ' * 8, relocs=[(0, 1, 'answer')])
        run([save("reloc.obj", object_bytes([text(mode=0), reloc]))], False, "directive section")
        lines = bytearray(object_bytes([directive(b' ' * 8)]))
        struct.pack_into('<I', lines, 20 + 28, 60)
        struct.pack_into('<H', lines, 20 + 34, 1)
        run([save("lines.obj", lines)], False, "directive section")

        if clang:
            native = root / "native.c"
            native.write_text('__declspec(dllexport) int answer(void) { return 42; }\n'
                              '__declspec(dllexport) int global_value = 42;\n'
                              '#pragma comment(linker, "/failifmismatch:fixture=white")\n', encoding="ascii")
            obj = root / "native.obj"
            built = subprocess.run([str(clang), '--target=x86_64-pc-windows-msvc', '-c', '-O0',
                                    '-ffreestanding', str(native), '-o', str(obj)], capture_output=True, timeout=30)
            assert built.returncode == 0, built.stderr
            exports(run([obj], shared=True), names=['answer'], data=['global_value'])
        assert not list(root.glob('wlc_tmp_*'))
    print(f"PASS: COFF directives driver ({checks} checks)")


if __name__ == '__main__':
    check_directives(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
