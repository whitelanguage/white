"""Check generated DLL libraries with White and, when supplied, LLVM's linker."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import object_bytes


def read_library(data):
    assert data[:8] == b"!<arch>\n"
    members = {}
    directories = []
    pos = 8
    while pos < len(data):
        assert pos + 60 <= len(data) and data[pos + 58:pos + 60] == b"`\n"
        assert int(data[pos + 16:pos + 28].strip()) == 0
        size = int(data[pos + 48:pos + 58].strip())
        name = data[pos:pos + 16].rstrip()
        payload = data[pos + 60:pos + 60 + size]
        assert len(payload) == size
        if name == b"/":
            directories.append(payload)
        else:
            members[pos] = payload
        if size & 1:
            assert data[pos + 60 + size] == 10
        pos += 60 + size + (size & 1)
    assert pos == len(data) and len(directories) == 2
    first, second = directories
    count = struct.unpack_from(">I", first)[0]
    offsets = struct.unpack_from(f">{count}I", first, 4)
    names = first[4 + count * 4:].split(b"\0")
    assert names.pop() == b"" and len(names) == count
    entries = dict(zip(names, offsets))
    assert len(entries) == count and all(offset in members for offset in offsets)
    member_count = struct.unpack_from("<I", second)[0]
    member_offsets = struct.unpack_from(f"<{member_count}I", second, 4)
    assert list(member_offsets) == list(members)
    cursor = 4 + member_count * 4
    assert struct.unpack_from("<I", second, cursor)[0] == count
    indices = struct.unpack_from(f"<{count}H", second, cursor + 4)
    sorted_names = second[cursor + 4 + count * 2:].split(b"\0")
    assert sorted_names.pop() == b"" and sorted_names == sorted(names)
    for name, index in zip(sorted_names, indices):
        assert 1 <= index <= member_count and entries[name] == member_offsets[index - 1]
    return members, entries


def check_libraries(compiler, llvm=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-library-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)

        def invoke(*args, success=True):
            nonlocal checks
            result = subprocess.run([str(compiler), *map(str, args)], env=env, cwd=repo,
                                    capture_output=True, timeout=90)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (args, result.returncode, text)
            assert "InternalCompilerError" not in text, text
            checks += 1
            return text

        def execute(path):
            nonlocal checks
            result = subprocess.run([str(path)], capture_output=True, timeout=15)
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            checks += 1

        source = root / "sample.wl"
        source.write_text('@ExportLib\nfunc api_answer() -> Int { return 42; }\n'
                          '@ExportLib\nfunc api_direct() -> Int { return 42; }\n'
                          '@ExportLib\nlet api_data: Int = 42;\n', encoding="utf-8")
        dll = root / "sample.dll"
        lib = root / "sample.lib"
        invoke(source, "--backend=machine", "--linker=white", "--shared", "-O0", "-o", dll)
        first_dll = dll.read_bytes()
        first_lib = lib.read_bytes()
        invoke(source, "--backend=machine", "--linker=white", "--shared", "-O0", "-o", dll)
        assert dll.read_bytes() == first_dll and lib.read_bytes() == first_lib
        members, entries = read_library(first_lib)
        assert len(members) == 6 and len(entries) == 8
        assert entries[b"api_answer"] == entries[b"__imp_api_answer"]
        assert b"api_data" not in entries and b"__imp_api_data" in entries
        assert b"__IMPORT_DESCRIPTOR_sample" in entries and b"__NULL_IMPORT_DESCRIPTOR" in entries
        assert b"\x7fsample_NULL_THUNK_DATA" in entries
        for symbol in (b"api_answer", b"api_direct", b"__imp_api_data"):
            payload = members[entries[symbol]]
            sig1, sig2, version, machine, timestamp, size, hint, flags = struct.unpack_from("<HHHHIIHH", payload)
            assert (sig1, sig2, version, machine, timestamp) == (0, 65535, 0, 0x8664, 0)
            assert size + 20 == len(payload) and flags == (5 if symbol == b"__imp_api_data" else 4)
            assert payload[20:].split(b"\0")[1] == b"sample.dll"
        checks += 1

        # Both thunk and IAT calls consume the same short member once.
        wrapper = root / "caller.obj"
        wrapper.write_bytes(object_bytes("answer", bytes.fromhex("48 83 ec 28 e8 00000000 48 8b 0d 00000000 ff d1 48 83 c4 28 c3"),
                                        [(5, 4, "api_answer"), (12, 4, "__imp_api_answer")]))
        caller = root / "caller.exe"
        invoke(repo / "tests/fixtures/linker/driver_object.wl", "--backend=machine", "--linker=white",
               "-o", caller, wrapper, lib)
        execute(caller)
        data_wrapper = root / "data.obj"
        data_wrapper.write_bytes(object_bytes("answer", bytes.fromhex("48 8b 05 00000000 8b 00 c3"),
                                             [(3, 4, "__imp_api_data")]))
        data_caller = root / "data.exe"
        invoke(repo / "tests/fixtures/linker/driver_object.wl", "--backend=machine", "--linker=white",
               "-o", data_caller, data_wrapper, lib)
        execute(data_caller)

        # Validation failures must leave both old artifacts untouched.
        bad = root / "broken.obj"
        bad.write_bytes(b"broken")
        assert "LinkError:" in invoke(source, "--backend=machine", "--linker=white", "--shared",
                                       "-o", dll, bad, success=False)
        assert dll.read_bytes() == first_dll and lib.read_bytes() == first_lib
        no_exports = root / "empty.wl"
        no_exports.write_text("func helper() -> Int { return 0; }\n", encoding="utf-8")
        empty_dll = root / "empty.DLL"
        invoke(no_exports, "--backend=machine", "--linker=white", "--shared", "-o", empty_dll)
        empty_members, empty_entries = read_library(empty_dll.with_suffix(".lib").read_bytes())
        assert len(empty_members) == 3 and len(empty_entries) == 3
        blocked = root / "blocked.lib"
        blocked.mkdir()
        assert "Could not create" in invoke(source, "--backend=machine", "--linker=white", "--shared",
                                             "-o", root / "blocked.dll", success=False)

        if llvm:
            tools = Path(llvm).resolve()
            host_source = root / "host.c"
            host_source.write_text('__declspec(dllimport) int api_answer(void);\n'
                                   'int api_direct(void);\nextern __declspec(dllimport) int api_data;\n'
                                   'int main(void) { if (api_answer()!=42 || api_direct()!=42 || api_data!=42) return 1; '
                                   'api_data=43; return api_data!=43; }\n', encoding="ascii")
            host_object = root / "host.obj"
            compiled = subprocess.run([str(tools / "clang.exe"), "--target=x86_64-pc-windows-msvc", "-O0", "-c",
                                       str(host_source), "-o", str(host_object)], capture_output=True, timeout=30)
            assert compiled.returncode == 0, compiled.stderr
            executable = root / "c-host.exe"
            linked = subprocess.run([str(tools / "lld-link.exe"), "/entry:main", "/subsystem:console", "/nodefaultlib",
                                     f"/out:{executable}", str(host_object), str(lib)], capture_output=True, timeout=30)
            assert linked.returncode == 0, linked.stderr
            checks += 1
            execute(executable)

            # The unit writer covers explicit ordinals and public aliases, not just driver defaults.
            unit = root / "fixture-writer.exe"
            invoke(repo / "tests/linker/test_import_library.wl", "--backend=machine", "--linker=white", "-o", unit)
            fixture_dll, fixture_lib = root / "fixture.dll", root / "fixture.lib"
            emitted = subprocess.run([str(unit), str(fixture_dll), str(fixture_lib)], capture_output=True, timeout=15)
            assert emitted.returncode == 0 and b"PASS:" in emitted.stdout, emitted
            fixture_source = root / "fixture-host.c"
            fixture_source.write_text('__declspec(dllimport) int Alias(void);\n'
                                      '__declspec(dllimport) int Zen(void);\n'
                                      '__declspec(dllimport) int Answer(void);\n'
                                      'extern __declspec(dllimport) int Constant;\n'
                                      'int main(void) { return Alias()!=37 || Zen()!=37 || Answer()!=37 || Constant!=5; }\n', encoding="ascii")
            fixture_object = root / "fixture-host.obj"
            compiled = subprocess.run([str(tools / "clang.exe"), "--target=x86_64-pc-windows-msvc", "-c",
                                       str(fixture_source), "-o", str(fixture_object)], capture_output=True, timeout=30)
            assert compiled.returncode == 0, compiled.stderr
            fixture_exe = root / "fixture-host.exe"
            linked = subprocess.run([str(tools / "lld-link.exe"), "/entry:main", "/subsystem:console", "/nodefaultlib",
                                     f"/out:{fixture_exe}", str(fixture_object), str(fixture_lib)], capture_output=True, timeout=30)
            assert linked.returncode == 0, linked.stderr
            checks += 1
            execute(fixture_exe)
        assert not list(root.glob("wlc_tmp_*")), list(root.iterdir())
    print(f"PASS: DLL import library output ({checks} checks)")


if __name__ == "__main__":
    check_libraries(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
