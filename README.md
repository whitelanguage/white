# White Language

![License](https://img.shields.io/badge/license-Apache--2.0-red.svg)
![Version](https://img.shields.io/github/v/tag/whitelanguage/white?label=version&color=green&sort=semver)
![Status](https://img.shields.io/badge/status-bootstrapped-success.svg)

White is a statically typed language and a self-hosting compiler project.
Source files use the `.wl` extension. `wlc` lowers them to LLVM IR and uses
Clang for machine-code generation and linking.

The design target is fairly simple to state: native performance, a language
which stays pleasant to read, and safety checks which fail clearly instead of
turning mistakes into silent memory corruption. Those are design goals, not a
claim that a young compiler has already caught up with C++, Go, or Rust.

The compiler is written in White and bootstraps from the previous release. For
compiler changes I normally build two generations and compare normalized LLVM
IR. A compiler which can build itself once is useful; one which reaches a fixed
point is much easier to trust.

It is not a production-ready replacement for an established systems language.
The limitations near the end of this file are part of the project, not fine print.

## A small program

```rs
interface Named {
    func name() -> String;
}

class Project with Named {
    let project_name: String;
    let targets: Vector(String);

    init(name: String) {
        self.project_name = name;
        self.targets = [];
    }

    func name() -> String {
        return self.project_name;
    }

    func add_target(target: String) -> Void {
        self.targets.append(target);
    }

    deinit() {
        print("dropping ", self.project_name);
    }
}

func main() -> Int {
    let project = Project("White Language");
    project.add_target("windows");
    project.add_target("linux");
    project.add_target("macos");

    let get_name: Method() -> String = project.name;
    print(get_name(), " targets: ", project.targets);
    return 0;
}
```

There is no special demonstration machinery in that example. Interfaces use
dynamic dispatch, methods can be stored as values, class instances are managed
by ARC, and `deinit` runs when the last owning reference is released.

White 0.3.4 was the source transition release. White 0.3.5 uses `:` for
parameter, field and variable types, and uses `func` for functions and class
methods. The older `name -> Type`, `method`, and last-type-as-return callable
forms are no longer accepted. A declaration with an initializer may omit its
annotation, as in `let project = ...`; the compiler still resolves one concrete
static type before generating IR.

Class fields may omit a default when every initializer definitely assigns
them. The compiler rejects reads before initialization and initializers which
leave a field unset.

## What is implemented

The language currently has:

- signed and unsigned integers from 8 through 128 bits;
- UTF-8 strings, Unicode scalar `Char`, arrays, vectors and slices;
- structs, classes, inheritance, interfaces, enums and destructors;
- first-class functions, bound methods and closures;
- atomic reference counting for managed values;
- checked indexing, null checks and runtime arithmetic checks;
- fallible functions and user-defined error domains;
- modules, packages, private symbols and controlled wildcard imports;
- C and system ABI declarations, shared-library exports and linker search paths;
- a standard library covering strings, files, processes, environment access,
  standard I/O, dictionaries and JSON.

This list says what the compiler accepts, not that every subsystem is finished.
Generic functions, methods, structs, classes and interfaces are monomorphized,
and interface constraints are checked before an instance is emitted. `Dict(K,
V)` is fully typed and requires keys to implement `Hash` and `Eq(K)`. Built-in
scalar keys already provide those contracts; user classes opt in explicitly.
The standard library is still small.

## Errors

A fallible function returns `T?` or `Void?`. `?` either passes the value on or
transfers control to the following `catch` block:

```rs
import "file"

func read_config(path: String) -> String? {
    let input: file.File = file.open(path)?;
    let text = input.read_all()?;
    input.close_checked()?;
    return text;
}

func main() -> Int {
    let config = read_config("config.json")?;
    catch(err) {
        if (err == file.Error.NotFound) {
            print("config.json does not exist");
        } else {
            print("could not read config.json: ", err);
        }
        return 1;
    }

    print(config);
    return 0;
}
```

If the containing function is also fallible, leaving off the local `catch`
propagates the error. Error values keep both a domain and a member number, so
two libraries can define an error called `InvalidData` without making the
values equal.

Libraries declare their own domains with `error`:

```rs
error ParseError {
    UnexpectedToken,
    UnexpectedEnd
}

func parse_header() -> Int? {
    throw ParseError.UnexpectedToken;
}
```

The prelude `Error` type is reserved for failures produced by language
primitives, such as allocation, checked conversion and bounds handling.
Standard-library packages use their own domains: `file.Error`, `io.Error`,
`process.Error`, `sys.env.Error` and `json.JsonError`.

## Strings and slices

`String` is a UTF-8 byte string. `length()` and indexing are deliberately
byte-based and O(1):

```rs
let text = "A中😀";
print(text.length()); // 8

let first: Byte = text[0];
let chinese: Char = text.char_at(1)?;
catch(err) { return 1; }
```

`char_count`, `char_at`, `is_char_boundary` and `is_valid_utf8` are available
when code needs Unicode scalar operations. A byte slice is allowed to contain
invalid UTF-8; APIs which require text validate it at their boundary.

Slices use a left-closed, right-open range. Without `ref`, slicing copies the
element storage:

```rs
let values: Vector(Int) = [10, 20, 30];
let copy: Array(Int) = values[0:2];
copy[0] = 99;
print(values[0]); // 10
```

`ref` creates a shared view and keeps its backing storage alive:

```rs
let view: Array(Int) = ref values[0:2];
view[0] = 99;
print(values[0]); // 99
```

Strings use the same copy syntax. The zero-copy string form currently provided
is the complete `ref text[:]` alias; bounded string views are still on the
worklist.

## Standard I/O and JSON

`print` is in the prelude and is meant for convenient formatted output. It
keeps a `Void` return type for compatibility. Code which needs to observe short
writes, broken pipes, or end of input should use `io` instead:

```rs
import "io"

func main() -> Int {
    io.stdout.write_all("name: ")?;
    catch(err) { return 1; }

    let name = io.stdin.read_line()?;
    catch(err) { return 1; }

    io.stdout.write_line("hello, " + name)?;
    catch(err) { return 1; }
    return 0;
}
```

The prelude `input(prompt)` is a small wrapper around `io.stdin.read_line()`.
The `input` namespace also exposes prompted forms of byte reads, exact reads,
delimiter reads, whole-input reads and byte skipping.

The JSON package builds a mutable `json.Value` tree. It has strict UTF-8 and
number parsing, preserves object insertion order, and keeps the original text
of JSON numbers so that large integers survive a parse/encode round trip.

```rs
import "json"

let document: json.Value =
    json.decode("{\"name\":\"White Language\",\"version\":3}")?;
catch(err) {
    print("bad JSON: ", err);
    return 1;
}

let name: String = String(document.get("name")?)?;
catch(err) { return 1; }
print(name);
```

The full JSON API, including exact numbers, decoder positions and resource
limits, is documented in [docs/std/json.md](docs/std/json.md).

## Native code

Native declarations have block and single-function forms:

```rs
extern "C" in "mylib" {
    func native_add(left: Int, right: Int) -> Int;
}

extern func native_version() -> Int from "C" in "mylib";
```

The supported ABI names are `"C"` and `"system"`. `in "mylib"` adds a linker
library; `-L` adds a directory to the library search path:

```bash
wlc app.wl -L ./native/lib
```

On Windows, a DLL by itself is not normally enough for the link step. The
linker needs the matching `.lib` or `libname.a` import library. `wlc --shared`
creates an import library beside a DLL built from White source.

Extern functions keep their native symbol names. Ordinary White functions are
mangled. `@ExportLib` gives a shared-library entry point an unmangled exported
name.

Raw pointers and native declarations are outside the compiler's memory-safety
guarantees. A wrong extern signature is just as dangerous here as it is in C.

## Building a program

`WL_PATH` points to the root of an installed White Language tree:

```text
WhiteLanguage/
├── bin/
├── std/
└── tools/
```

Linux and macOS:

```bash
export WL_PATH=/path/to/WhiteLanguage
wlc hello.wl
./hello
```

Windows:

```powershell
wlc hello.wl
.\hello.exe
```
(The Windows installer configures PATH and WL_PATH automatically.)

The options used most often are:

```text
-o <file>       choose the output path
-O0 ... -O3     choose a speed optimization level
-Os / -Oz       optimize for binary size
-c              emit an object file
-S              emit assembly
--emit-llvm     emit LLVM IR
--shared        build a DLL, shared object, or dynamic library
--target <name> build for a target triple
--target-help   list supported target triples
--sysroot <dir> use a target system root when compiling and linking
-L <dir>        add a native library search path
--keep-temps    keep the temporary LLVM IR
```

Run `wlc --help` for the complete driver help.

The driver currently accepts these target triples:

```bash
wlc --target-help
```

```text
i686-pc-windows-msvc
x86_64-pc-windows-msvc
i686-unknown-linux-gnu
x86_64-unknown-linux-gnu
armv7-unknown-linux-gnueabihf
aarch64-unknown-linux-gnu
x86_64-apple-darwin
arm64-apple-darwin
```

`--target` is enough when emitting LLVM IR, assembly, or an object file. Linking
for another operating system also requires that system's libraries and SDK.
Pass a prepared system root with `--sysroot`; `wlc` does not bundle one.

On Windows, an x86 executable or DLL needs the x86 `kernel32` and `shell32`
import libraries. If Clang does not find the Windows SDK automatically, pass its
`um/x86` directory with `-L`.

The Linux target harness is in `ci/test-linux-targets.ps1`. It creates a native
compiler for x86-64, x86, ARMv7, or AArch64, bootstraps it twice in Docker, and
compares the two generated IR files before running the language tests. See
`ci/docker/README.md` for the short and full commands.

## Rebuilding the compiler

Bootstrapping requires an existing `wlc`, normally the compiler from the latest
release:

```bash
wlc src/wlc.wl -Oz -o wlc_new
```

On Windows the output name is normally `wlc_new.exe`.

The first generation is compiled by the old compiler even though it is reading
the new source. Syntax and ABI changes which need their own implementation must
therefore be staged. This is why some compiler changes land as explicit
bootstrap steps instead of one large commit.

For a fixed-point check, use `wlc_new` to compile the same source again and
compare normalized LLVM IR from the two new generations. Machine binaries are
not a useful byte-for-byte comparison because object metadata may differ.

Release compilers are built with `-Oz`. The compiler spends most of its time in
the frontend and emits a large LLVM module, so `-Oz` has produced a smaller
binary without a meaningful loss in compiler throughput.

## Platform runtime

Windows programs do not link MSVCRT or UCRT for White Language startup and
standard-library operation. Allocation, files, processes and console I/O call
native Windows APIs. The compiler emits `mainCRTStartup`, `DllMainCRTStartup`,
the stack probe and the small set of freestanding memory symbols required by
optimized code. There is no separate C runtime object.

Linux and macOS intentionally use the platform libc/POSIX interfaces for
allocation, files, processes and environment access. Replacing those stable
interfaces with handwritten system calls would add architecture-specific code
without improving ordinary White programs.

Windows x86-64 is the most heavily tested native ABI. The x86 compiler also
bootstraps, and its language and DLL tests run under WOW64. Linux and macOS have
been used for bootstrapping, including macOS on ARM64, but real 32-bit systems
still need separate ABI testing before general 32-bit support is advertised.

## Repository layout

```text
docs/           package and implementation notes
src/            self-hosted compiler
std/            standard library
tests/          diagnostics, language, memory, FFI and integration tests
```

## Editor tooling and releases

`wlls`, the White Language language server, lives in its own project. It reuses
the compiler frontend rather than maintaining a second grammar. The current VS
Code extension uses it for diagnostics, symbols, definitions and semantic
highlighting. Both are still under active development.

An official website and binary download portal also exist. Work there has been
slower while the compiler and standard library settle down, but the site has not been abandoned.

A package manager named `wlp` is planned(Maybe?). Today, dependencies are resolved from
the standard library, source-relative paths and `WL_PATH`.

## Known limitations

The important ones are:

- ARC cannot collect cycles, and weak references are not implemented.
- There is no borrow checker. Shared mutable objects require the same care they
  would in other ARC-based languages.
- A generic method is statically dispatched and does not occupy an interface
  vtable slot. Interface method declarations therefore cannot introduce their
  own type parameters.
- `Dict` is heterogeneous and uses an internal Variant. Use `Dict(K, V)` when the key and value types are known.
- Networking, threads, async I/O and a full filesystem package are missing.
- Unicode scalar operations exist, but normalization, grapheme clusters and
  the larger Unicode database do not.
- Raw pointers and incorrect extern declarations can cause undefined behaviour.
- The internal White ABI may change between compiler releases.
- Native ARM hardware coverage is still smaller than the x86 test matrix.

White is a good place to experiment with language design, work
on a self-hosted compiler, and write small native tools. Production deployment
still needs more time, more users and a wider platform test matrix.
But I don't have any users yet.

## License

White Language is licensed under the [Apache License 2.0](LICENSE).
