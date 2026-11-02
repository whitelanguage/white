"""Keep library discovery independent of PATH, host SDKs and DLL filename guesses."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes, object_bytes


def check_search(compiler):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["WL_PATH"] = str(repo)
    env["PATH"] = ""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="white-search-") as temporary:
        root = Path(temporary)
        env["TEMP"] = env["TMP"] = str(root)
        first, second = root / "first path", root / "second"
        first.mkdir()
        second.mkdir()
        third = root / "目录"
        third.mkdir()

        def save_library(path, value):
            code = b"\xb8" + value.to_bytes(4, "little") + b"\xc3"
            path.write_bytes(archive_bytes([("answer.obj", object_bytes("answer", code), ["answer"])]))

        def invoke(source, *flags, success=True, needle=""):
            nonlocal checks
            output = root / f"case-{checks}.exe"
            if not success:
                output.write_bytes(b"untouched")
            result = subprocess.run([str(compiler), str(source), "--backend=machine", "--linker=white",
                                     "-o", str(output), *map(str, flags)], cwd=root, env=env,
                                    capture_output=True, timeout=90)
            text = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            assert (result.returncode == 0) == success, (result.returncode, text, flags)
            assert "InternalCompilerError" not in text, text
            if needle:
                assert needle in text, text
            if not success:
                assert output.read_bytes() == b"untouched"
            checks += 1
            return output, text

        def run(name="answer.lib", expected=42, flags=()):
            source = root / f"source-{checks}.wl"
            source.write_text(f'extern "c" in "{name}" {{ func answer() -> Int; }}\n'
                              f'func main() -> Int {{ if (answer() != {expected}) {{ return 1; }} '
                              'print("PASS: Library search"); return 0; }\n', encoding="utf-8")
            output, text = invoke(source, *flags)
            executed = subprocess.run([str(output)], cwd=root, capture_output=True, timeout=15)
            assert executed.returncode == 0 and b"PASS:" in executed.stdout, executed
            return text

        save_library(first / "answer.lib", 42)
        save_library(second / "answer.lib", 7)
        save_library(root / "answer.lib", 3)
        save_library(third / "answer.lib", 42)
        run(flags=("-L", first, "-L", second))
        run(expected=7, flags=("-L", second, "-L", first))
        run(expected=3)
        run(flags=("-L", root / "not-present", "-L", first))
        run(flags=("--library-path", first))
        run(flags=("-L" + str(first),))
        run(flags=("-L", str(first) + "/"))
        run(flags=("-L", third))
        save_library(first / "Mixed.LiB", 42)
        save_library(first / "answer.A", 42)
        run("Mixed.LiB", flags=("-L", first))
        run("Mixed.LiB", flags=(first / "Mixed.LiB", "-L", first))
        run("answer.A", flags=("-L", first))

        # Explicit objects remain stronger than any named archive provider.
        strong = root / "strong.obj"
        strong.write_bytes(object_bytes("answer", bytes.fromhex("b8 2a 00 00 00 c3")))
        run(flags=(strong, "-L", second))
        text = run(flags=(first / "answer.lib", "-L", first, "-L", first, "--verbose"))
        assert text.count("Found library:") == 0, text

        source = root / "missing.wl"
        source.write_text('extern "c" in "missing.lib" { func answer() -> Int; }\n'
                          'func main() -> Int { return answer(); }\n', encoding="utf-8")
        invoke(source, "-L", first, success=False, needle="Could not find library 'missing.lib'")
        bad = root / "bad"
        bad.mkdir()
        (bad / "answer.lib").write_bytes(b"broken")
        selected = root / "selected.wl"
        selected.write_text('extern "c" in "answer.lib" { func answer() -> Int; }\n'
                            'func main() -> Int { return answer(); }\n', encoding="utf-8")
        invoke(selected, "-L", bad, "-L", first, success=False, needle=str(bad / "answer.lib"))
        blocked = root / "blocked"
        blocked.mkdir()
        (blocked / "answer.lib").mkdir()
        invoke(selected, "-L", blocked, "-L", first, success=False, needle="Could not open")
        invoke(selected, "-L", "", success=False, needle="Library search path cannot be empty")

        # Selecting an archive still decodes only members needed by relocations.
        lazy = root / "lazy"
        lazy.mkdir()
        (lazy / "answer.lib").write_bytes(archive_bytes([
            ("answer.obj", object_bytes("answer", bytes.fromhex("b8 2a 00 00 00 c3")), ["answer"]),
            ("unused.obj", b"invalid unused object", ["unused"])]))
        run(flags=("-L", lazy))

        # Dependencies can return to an earlier library without a second directory scan.
        (first / "bridge.lib").write_bytes(archive_bytes([
            ("answer.obj", object_bytes("answer", b"\xe9\0\0\0\0", [(1, 4, "helper")]), ["answer"])]))
        (first / "deps.a").write_bytes(archive_bytes([
            ("helper.obj", object_bytes("helper", bytes.fromhex("b8 2a 00 00 00 c3")), ["helper"])]))
        dependency = root / "dependency.wl"
        dependency.write_text('extern "c" in "deps.a" { func helper() -> Int; }\n'
                              'extern "c" in "bridge.lib" { func answer() -> Int; }\n'
                              'func main() -> Int { if (answer()!=42) { return 1; } return 0; }\n', encoding="utf-8")
        output, _ = invoke(dependency, "-L", first)
        executed = subprocess.run([str(output)], capture_output=True, timeout=15)
        assert executed.returncode == 0, executed

        # Library ownership survives loading an extern declaration from a source module.
        module = root / "native.wl"
        module.write_text('extern "c" in "answer.lib" { func answer() -> Int; }\n', encoding="utf-8")
        client = root / "client.wl"
        client.write_text('import answer from "native.wl"\n'
                          'func main() -> Int { if (answer()!=42) { return 1; } return 0; }\n', encoding="utf-8")
        output, _ = invoke(client, "-L", first)
        executed = subprocess.run([str(output)], capture_output=True, timeout=15)
        assert executed.returncode == 0, executed

        # The import library supplies the loader's DLL name, not the extern archive name.
        dll_source = root / "export.wl"
        dll_source.write_text('@ExportLib\nfunc answer() -> Int { return 42; }\n', encoding="utf-8")
        built = subprocess.run([str(compiler), str(dll_source), "--backend=machine", "--linker=white",
                                "--shared", "-o", str(root / "runtime.dll")], cwd=root, env=env,
                               capture_output=True, timeout=90)
        assert built.returncode == 0, built.stdout + built.stderr
        (first / "renamed.lib").write_bytes((root / "runtime.lib").read_bytes())
        run("renamed.lib", flags=("-L", first))

        # Bare names and explicit DLL declarations keep their existing semantics.
        (first / "runtime.lib").write_bytes(b"bad candidate, not requested")
        run("runtime", flags=("-L", first))
        run("runtime.dll", flags=("-L", first))
        assert not list(root.glob("wlc_tmp_*")), list(root.iterdir())
    print(f"PASS: Named library discovery ({checks} checks)")


if __name__ == "__main__":
    check_search(Path(sys.argv[1]).resolve())
