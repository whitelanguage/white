"""Alternate names get a final chance after ordinary archive demands have drained."""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_archive_driver import archive_bytes
from test_comdat_driver import object_bytes, text, code
from test_directives_driver import directive
from test_import_driver import short_import
from test_weak_driver import alias, definition, object_bytes as weak_object


def check_alternates(compiler, clang=None):
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env['WL_PATH'] = str(repo)
    env['PATH'] = ''
    checks = 0
    with tempfile.TemporaryDirectory(prefix='white-alternates-') as temporary:
        root = Path(temporary)
        env['TEMP'] = env['TMP'] = str(root)
        caller = repo / 'tests/fixtures/linker/driver_object.wl'
        empty = root / 'empty.wl'
        empty.write_text('func main() -> Int { print("PASS: unused alternate"); return 0; }\n', encoding='ascii')

        def save(name, data):
            path = root / name
            path.write_bytes(data)
            return path

        def options(value):
            return save(f'options-{checks}.obj', object_bytes([directive(value)]))

        def library(name, members):
            return save(name, archive_bytes(members))

        def run(inputs, source=caller, success=True, needle='', flags=()):
            nonlocal checks
            output = root / f'case-{checks}.exe'
            if not success:
                output.write_bytes(b'untouched')
            built = subprocess.run([str(compiler), str(source), '--backend=machine', '--linker=white',
                                    '-o', str(output), *map(str, inputs), *map(str, flags)],
                                   cwd=root, env=env, capture_output=True, timeout=60)
            message = (built.stdout + built.stderr).decode('utf-8', errors='replace')
            assert (built.returncode == 0) == success, (checks, message)
            assert 'InternalCompilerError' not in message, message
            if needle:
                assert needle in message, message
            if success:
                child = subprocess.run([str(output)], capture_output=True, timeout=15)
                assert child.returncode == 0 and b'PASS:' in child.stdout, child
            else:
                assert output.read_bytes() == b'untouched'
            checks += 1

        fallback = save('fallback.obj', definition('fallback'))
        alternate = options('/alternatename:answer=fallback')
        run([alternate, fallback])
        run([fallback, alternate])
        run([alternate, alternate, fallback])
        run([options('-ALTERNATENAME:"answer=fallback"'), fallback])
        strong = save('strong.obj', definition('answer'))
        wrong = save('wrong.obj', definition('fallback', 7))
        run([alternate, wrong, strong])
        run([strong, alternate, wrong])
        run([alternate, strong, save('second.obj', definition('answer'))], success=False, needle='Duplicate external')
        run([alternate], success=False, needle='undefined')
        run([alternate], source=empty)
        unused = library('unused.lib', [('bad.obj', b'bad COFF', ['fallback'])])
        run([alternate, unused], source=empty)
        for value in ('/alternatename:', '/alternatename:answer', '/alternatename:=fallback', '/alternatename:answer='):
            run([options(value)], source=empty, success=False, needle='COFF')
        run([alternate, options('/alternatename:answer=other'), strong], success=False, needle='Conflicting COFF alternate')
        run([options('/alternatename:Answer=fallback'), fallback], success=False, needle='undefined')

        provider = library('fallback.lib', [('fallback.obj', definition('fallback'), ['fallback'])])
        run([alternate, provider])
        run([provider, alternate])
        both = library('both.lib', [('fallback.obj', definition('fallback', 7), ['fallback']),
                                    ('answer.obj', definition('answer'), ['answer'])])
        run([alternate, both])
        poison = library('poison.lib', [('bad.obj', b'bad COFF', ['answer'])])
        run([alternate, poison, provider], success=False, needle='Selected archive member')
        run([alternate, provider, poison], success=False, needle='Selected archive member')
        run([options('/alternatename:answer=middle /alternatename:middle=fallback'), provider])
        run([options('/alternatename:middle=fallback /alternatename:answer=middle'), provider])
        run([options('/alternatename:answer=middle /alternatename:middle=answer')], success=False, needle='alias cycle')
        run([options('/alternatename:answer=answer')], success=False, needle='alias cycle')
        run([options('/alternatename:answer=middle /alternatename:middle=answer'), strong])

        # A later ordinary demand loads the original definition, without touching a bad fallback.
        helper = library('helper.lib', [('helper.obj', object_bytes([
            text(key='helper', mode=0), directive('/include:answer')]), ['helper']),
            ('answer.obj', definition('answer'), ['answer'])])
        run([options('/include:helper /alternatename:answer=fallback'), helper, unused])
        late = library('late.lib', [('helper.obj', object_bytes([
            text(key='helper', mode=0), directive('/alternatename:answer=fallback')]), ['helper'])])
        run([options('/include:helper'), late, provider])
        run([options('/include:helper'), provider, late])
        ignored = library('ignored.lib', [('unused.obj', object_bytes([
            text(key='unused', mode=0), directive('/alternatename:answer=wrong')]), ['unused'])])
        run([alternate, ignored, provider])
        conflict = library('conflict.lib', [('helper.obj', object_bytes([
            text(key='helper', mode=0), directive('/alternatename:answer=other')]), ['helper'])])
        run([options('/include:helper /alternatename:answer=fallback'), conflict, provider],
            success=False, needle='Conflicting COFF alternate')

        # Newly discovered libraries still get to define the original name before fallback extraction.
        discovered = library('discovered.lib', [('answer.obj', definition('answer'), ['answer'])])
        discover = library('discover.lib', [('helper.obj', object_bytes([
            text(key='helper', mode=0), directive('/defaultlib:discovered')]), ['helper'])])
        run([options('/include:helper /alternatename:answer=fallback'), discover, unused])
        run([options('/defaultlib:fallback /alternatename:answer=fallback')])
        run([options('/defaultlib:discovered /alternatename:answer=fallback'), unused])

        # Weak COFF records keep their own fallback, including one loaded after a directive alias.
        run([alternate, save('weak.obj', alias('answer', 'actual')), wrong,
             save('actual.obj', definition('actual'))])
        weak_loader = library('weak-loader.lib', [('weak.obj', alias('answer', 'actual'), ['answer'])])
        run([alternate, weak_loader, save('actual.obj', definition('actual')), wrong])
        weak_member = weak_object([dict(name='helper', section=1), dict(name='answer', fallback='actual'),
                                   dict(name='actual')], code())
        weak_late = library('weak-late.lib', [('helper.obj', weak_member, ['helper'])])
        late_fallback = library('late-fallback.lib', [('fallback.obj', object_bytes([
            text(7, key='fallback', mode=0), directive('/include:helper')]), ['fallback'])])
        actual = library('actual.lib', [('actual.obj', definition('actual'), ['actual'])])
        run([alternate, late_fallback, weak_late, actual])

        # Selection rebuilds must retain the pending alias and its name-only query records.
        small = object_bytes([text(key='entry', mode=6), directive('/include:load_larger /alternatename:answer=fallback')])
        larger = object_bytes([dict(text(key='entry', mode=6), data=code() + b'\x90'), text(key='load_larger', mode=0)])
        replaced = library('replace.lib', [('larger.obj', larger, ['entry', 'load_larger']),
                                           ('fallback.obj', definition('fallback'), ['fallback'])])
        run([save('small.obj', small), replaced])
        chain = ' '.join(f'/alternatename:step{i}=step{i+1}' for i in range(4096))
        run([options('/alternatename:answer=step0 ' + chain + ' /alternatename:step4096=fallback'), fallback])
        imported = root / 'import.wl'
        imported.write_text('extern "c" in "kernel32" { func GetCurrentProcess() -> AnyPtr; }\n'
                            'extern "c" { func process_alias() -> AnyPtr; }\n'
                            'func main() -> Int { if (Long(process_alias()) != -1L) { return 1; } '
                            'print("PASS: DLL alternate"); return 0; }\n', encoding='ascii')
        run([options('/alternatename:process_alias=GetCurrentProcess')], source=imported)
        imports = library('kernel.lib', [('thread.obj', short_import('GetCurrentThreadId', dll='kernel32.dll'),
                                       ['GetCurrentThreadId', '__imp_GetCurrentThreadId'])])
        run([options('/include:thread_alias /alternatename:thread_alias=GetCurrentThreadId'), imports], source=empty)
        run([options('/include:pointer_alias /alternatename:pointer_alias=__imp_GetCurrentThreadId'), imports], source=empty)

        shared = root / 'shared.wl'
        shared.write_text('func harmless() -> Int { return 0; }\n', encoding='ascii')
        dll_path = root / 'alias.dll'
        built = subprocess.run([str(compiler), str(shared), '--backend=machine', '--linker=white', '--shared',
                                '-o', str(dll_path), str(options('/export:Public=answer /alternatename:answer=fallback')),
                                str(provider)], cwd=root, env=env, capture_output=True, timeout=60)
        assert built.returncode == 0, built.stdout + built.stderr
        dll = ctypes.WinDLL(str(dll_path))
        try:
            assert dll.Public() == 42
        finally:
            kernel = ctypes.windll.kernel32
            kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
            assert kernel.FreeLibrary(dll._handle)
        checks += 1

        if clang:
            native = root / 'native.c'
            native.write_text('#pragma comment(linker, "/alternatename:answer=fallback")\n'
                              'int fallback(void) { return 42; }\n', encoding='ascii')
            obj = root / 'native.obj'
            built = subprocess.run([str(clang), '--target=x86_64-pc-windows-msvc', '-c', '-O0',
                                    '-ffreestanding', str(native), '-o', str(obj)], capture_output=True, timeout=30)
            assert built.returncode == 0, built.stderr
            run([obj])
            # Use a standalone entry to check archive precedence against LLD's own resolution.
            lld = Path(clang).parent / 'lld-link.exe'
            entry = save('entry.obj', object_bytes([dict(name='.text$start', key='start',
                         data=b'\xe9\0\0\0\0', relocs=[(1, 4, 'answer')])]))
            for providers in ([obj], [alternate, both], [alternate, provider]):
                native_image = root / f'lld-{checks}.exe'
                linked = subprocess.run([str(lld), '/entry:start', '/subsystem:console', '/nodefaultlib',
                                         f'/out:{native_image}', str(entry), *map(str, providers)],
                                        capture_output=True, timeout=30)
                assert linked.returncode == 0, linked.stdout + linked.stderr
                child = subprocess.run([str(native_image)], capture_output=True, timeout=15)
                assert child.returncode == 42, child
                checks += 1
        assert not list(root.glob('wlc_tmp_*'))
    print(f'PASS: COFF alternate-name driver ({checks} checks)')


if __name__ == '__main__':
    check_alternates(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else None)
