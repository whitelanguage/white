"""Default libraries are discovered by loaded objects, never by scanning unused members."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes
from test_comdat_driver import object_bytes, text
from test_directives_driver import directive
from test_import_driver import short_import


def check_defaults(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env['WL_PATH'] = str(repo)
    env['PATH'] = ''
    checks = 0
    with tempfile.TemporaryDirectory(prefix='white-default-libs-') as temporary:
        root = Path(temporary)
        env['TEMP'] = env['TMP'] = str(root)
        first, second = root / 'first path', root / 'second'
        first.mkdir()
        second.mkdir()
        caller = root / 'caller.wl'
        caller.write_text('extern "c" { func answer() -> Int; }\n'
                          'func main() -> Int { if (answer()!=42) { return 1; } '
                          'print("PASS: default libraries"); return 0; }\n', encoding='ascii')
        empty = root / 'empty.wl'
        empty.write_text('func main() -> Int { print("PASS: suppressed defaults"); return 0; }\n', encoding='ascii')

        def save(path, data):
            path.write_bytes(data)
            return path

        def library(path, sections, symbols=('answer',)):
            return save(path, archive_bytes([('provider.obj', object_bytes(sections), list(symbols))]))

        def run(options, inputs=(), flags=(), source=caller, success=True, needle=''):
            nonlocal checks
            obj = save(root / f'directives-{checks}.obj', object_bytes([directive(options)]))
            out = root / f'case-{checks}.exe'
            if not success:
                out.write_bytes(b'untouched')
            result = subprocess.run([str(compiler), str(source), '--backend=machine', '--linker=white',
                                     '-o', str(out), str(obj), *map(str, inputs), *map(str, flags)],
                                    cwd=root, env=env, capture_output=True, timeout=60)
            message = (result.stdout + result.stderr).decode('utf-8', errors='replace')
            assert (result.returncode == 0) == success, (checks, options, message)
            assert 'InternalCompilerError' not in message, message
            if needle:
                assert needle in message, message
            if success:
                child = subprocess.run([str(out)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b'PASS:' in child.stdout, child
            else:
                assert out.read_bytes() == b'untouched'
            checks += 1
            return message

        provider = library(first / 'answer.lib', [text(mode=0)])
        library(second / 'answer.lib', [text(7, mode=0)])
        library(root / 'answer.lib', [text(mode=0)])
        run('/defaultlib:answer', flags=('-L', first, '-L', second))
        run('/defaultlib:answer.lib')
        run('/defaultlib:answer /include:answer', source=empty, flags=('-L', first))
        run('-DEFAULTLIB:"answer.lib"', flags=('-L', first))
        message = run('/defaultlib:answer /defaultlib:ANSWER.LIB /defaultlib:answer.lib',
                      flags=('-L', first, '--verbose'))
        assert message.count('Found default library:') == 1, message
        message = run('/defaultlib:answer', inputs=[provider], flags=('-L', first, '--verbose'))
        assert message.count('Found default library:') == 0, message
        # Explicit archives precede implicit providers and survive both exclusion forms.
        run('/defaultlib:answer /nodefaultlib', inputs=[provider])
        run('/defaultlib:answer /nodefaultlib:answer', inputs=[provider])
        run('/defaultlib:missing /nodefaultlib', source=empty)
        run('/defaultlib:missing /nodefaultlib:MISSING.LIB', source=empty)
        run('/nodefaultlib:missing /defaultlib:missing', source=empty)
        run('/defaultlib:missing /nodefaultlib:', source=empty, success=False, needle='Missing')
        run('/defaultlib:', source=empty, success=False, needle='Missing')
        run('/defaultlib:missing', source=empty, success=False, needle="Could not find library 'missing.lib'")
        run('/defaultlib:missing /nodefaultlib', success=False, needle='undefined')
        for spelling in ('/defaultlib:../answer', '/nodefaultlib:dir\\answer', '/defaultlib:c:answer',
                         '/defaultlib:answer.dll', '/nodefaultlib:answer.obj'):
            run(spelling, source=empty, success=False, needle='archive filename')
        library(first / 'Mixed.LiB', [text(mode=0)])
        run('/defaultlib:Mixed.LiB', flags=('-L', first))
        library(first / 'answer.a', [text(mode=0)])
        run('/defaultlib:answer.a', flags=('-L', first))
        run('/defaultlib:answer.a /nodefaultlib:ANSWER.A', source=empty)
        save(first / 'kernel.lib', archive_bytes([
            ('thread.obj', short_import('GetCurrentThreadId', dll='kernel32.dll'),
             ['GetCurrentThreadId', '__imp_GetCurrentThreadId'])]))
        for symbol in ('GetCurrentThreadId', '__imp_GetCurrentThreadId'):
            run('/defaultlib:kernel /include:' + symbol, source=empty, flags=('-L', first))
        bad = root / 'bad'
        bad.mkdir()
        save(bad / 'answer.lib', b'broken')
        run('/defaultlib:answer', flags=('-L', bad, '-L', first), success=False, needle=str(bad / 'answer.lib'))
        blocked = root / 'blocked'
        blocked.mkdir()
        (blocked / 'answer.lib').mkdir()
        run('/defaultlib:answer', flags=('-L', blocked, '-L', first), success=False, needle='Could not open')

        bridge = [dict(text(mode=0), data=b'\xe9\0\0\0\0', relocs=[(1, 4, 'helper')]),
                  directive('/defaultlib:deps')]
        library(first / 'bridge.lib', bridge)
        library(first / 'deps.lib', [text(key='helper', mode=0), directive('/defaultlib:bridge')], ['helper'])
        run('/defaultlib:bridge', flags=('-L', first))
        # An earlier unresolved include must revisit the newly admitted library.
        library(first / 'load.lib', [text(key='entry', mode=0), directive('/defaultlib:answer')], ['entry'])
        run('/include:answer /include:entry /defaultlib:load', flags=('-L', first))
        lazy = save(first / 'lazy.lib', archive_bytes([
            ('answer.obj', object_bytes([text(mode=0)]), ['answer']),
            ('unused.obj', object_bytes([text(key='unused', mode=0), directive('/defaultlib:missing')]), ['unused'])]))
        run('/defaultlib:lazy', flags=('-L', first))
        run('/defaultlib:lazy /include:unused', flags=('-L', first), success=False, needle='missing.lib')
        library(first / 'exclude.lib', [text(key='entry', mode=0),
                directive('/nodefaultlib:answer /include:answer')], ['entry'])
        run('/defaultlib:answer /defaultlib:exclude /include:entry', source=empty,
            flags=('-L', first), success=False, needle='Required linker symbol')
        run('/defaultlib:exclude /include:entry', inputs=[provider], flags=('-L', first))
        # All root-object exclusions are collected before any default-library file is opened.
        exclude_obj = save(root / 'exclude.obj', object_bytes([directive('/nodefaultlib:missing')]))
        run('/defaultlib:missing', inputs=[exclude_obj], source=empty)

        # A longer cycle must still load each member once and finish without recursive extraction.
        for index in range(32):
            name = 'answer' if index == 0 else f'part{index}'
            following = f'part{index + 1}' if index < 31 else 'answer'
            sections = [dict(text(key=name, mode=0), data=b'\xe9\0\0\0\0', relocs=[(1, 4, following)]),
                        directive(f'/defaultlib:chain{index + 1}' if index < 31 else '/defaultlib:chain0')]
            if index == 31:
                sections[0] = text(key=name, mode=0)
            library(first / f'chain{index}.lib', sections, [name])
        message = run('/defaultlib:chain0', flags=('-L', first, '--verbose'))
        assert message.count('Found default library:') == 32, message

        if clang:
            native = root / 'native.c'
            native.write_text('#pragma comment(lib, "answer")\nint unused_native(void) { return 0; }\n', encoding='ascii')
            obj = root / 'native.obj'
            compiled = subprocess.run([str(clang), '--target=x86_64-pc-windows-msvc', '-ffreestanding',
                                       '-c', str(native), '-o', str(obj)], capture_output=True, timeout=30)
            assert compiled.returncode == 0, compiled.stderr
            run('', inputs=[obj], flags=('-L', first))
        assert not list(root.glob('wlc_tmp_*'))
    print(f'PASS: COFF default libraries ({checks} checks)')


if __name__ == '__main__':
    check_defaults(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
