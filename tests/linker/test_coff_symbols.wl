// Test: COFF_SYMBOLS
// File: tests/linker/test_coff_symbols.wl
// Focus: External binding, object-local names, hash collisions and link diagnostics.

import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import * from "../../src/linker/coff/symbols.wl"
import read_coff from "../../src/linker/coff/reader.wl"
import * from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"


func decode(source: X86Object) -> CoffObject? {
    let bytes = coff_object(source)?;
    let result = read_coff(bytes);
    if (result.object is null) { throw Error.InvalidArgument; }
    return result.object;
}

func fixture(provider: Bool) -> CoffObject? {
    let data: Vector(Byte) = [];
    let i: Int = 0;
    while (i < 16) { data.append(Byte(0)); i++; }
    let symbols: Vector(X86Symbol) = [];
    let relocs: Vector(X86Relocation) = [];
    if provider {
        symbols = [X86Symbol(name="shared", section=".data", offset=4U, external=true), X86Symbol(name="local", section=".data", offset=2U, external=false), X86Symbol(name="unused", section="", offset=0U, external=true)];
        relocs = [X86Relocation(section=".data", offset=8U, kind=X86RelocationKind.Abs64, symbol="local", addend=0L)];
    } else {
        symbols = [X86Symbol(name="entry", section=".data", offset=0U, external=true), X86Symbol(name="local", section=".data", offset=1U, external=false), X86Symbol(name="shared", section="", offset=0U, external=true)];
        relocs = [X86Relocation(section=".data", offset=0U, kind=X86RelocationKind.Abs64, symbol="shared", addend=0L), X86Relocation(section=".data", offset=8U, kind=X86RelocationKind.Abs64, symbol="shared", addend=0L)];
    }
    return decode(X86Object(sections=[X86CodeSection(name=".data", bytes=data, alignment=8, executable=false, writable=true)], symbols=symbols, relocations=relocs))?;
}

func main() -> Int {
    let caller = fixture(false)?;
    catch(err) { print("FAIL: caller fixture"); return 1; }
    let provider = fixture(true)?;
    catch(err) { print("FAIL: provider fixture"); return 1; }
    let objects: Vector(CoffObject) = [caller, provider];
    let result = coff_resolve_symbols(objects);
    if (result.errors.length() != 0 || result.targets[0][2].object != 1 || result.targets[0][2].symbol != 0 ||
        result.targets[0][1].object != 0 || result.targets[1][1].object != 1 || result.targets[1][2].object != -1) {
        print("FAIL: global binding or local symbol isolation");
        return 1;
    }
    result = coff_resolve_symbols([provider, caller]);
    if (result.errors.length() != 0 || result.targets[1][2].object != 0) { print("FAIL: input order"); return 1; }
    result = coff_resolve_symbols([caller]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.UndefinedSymbol || result.errors[0].symbol != 2) {
        print("FAIL: unresolved diagnostics were missing or repeated for every relocation");
        return 1;
    }
    result = coff_resolve_symbols([provider, provider]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.DuplicateSymbol || result.errors[0].other.object != 0 || result.errors[0].object != 1) {
        print("FAIL: duplicate definition diagnostic");
        return 1;
    }

    let index: CoffNameIndex = CoffNameIndex();
    let first: Int = coff_name_slot(objects, ref index, CoffSymbolRef(0, 0));
    let hash: UInt64 = coff_name_hash(provider.bytes, provider.symbols[0].name);
    // force two different byte names into the same bucket, their definitions stay distinct.
    index.buckets.put(hash, first);
    let second: Int = coff_name_slot(objects, ref index, CoffSymbolRef(1, 0));
    if (first == second || coff_name_slot(objects, ref index, CoffSymbolRef(0, 2)) != second || index.entries[second].next != first) {
        print("FAIL: hash collision changed symbol identity");
        return 1;
    }

    let changed = fixture(true)?;
    catch(err) { print("FAIL: mutable fixture"); return 1; }
    changed.symbols[0].section = 0;
    changed.symbols[0].value = 8U;
    result = coff_resolve_symbols([changed]);
    if (result.errors.length() != 0 || result.targets[0][0].object != 0 || result.targets[0][0].symbol != 0) { print("FAIL: common symbol"); return 1; }
    changed.symbols[0].value = 0U;
    changed.symbols[0].storage = Byte(105);
    result = coff_resolve_symbols([changed]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.InvalidObject) { print("FAIL: malformed weak external"); return 1; }
    changed.symbols[0].storage = Byte(2);
    changed.symbols[0].section = 1;
    changed.sections[0].flags |= 4096U;
    result = coff_resolve_symbols([changed]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.Unsupported) { print("FAIL: COMDAT"); return 1; }
    changed.sections[0].flags &= ~4096U;
    changed.symbols[0].value = 17U;
    result = coff_resolve_symbols([changed]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.InvalidObject) { print("FAIL: defined symbol range"); return 1; }
    changed.symbols[0].value = 7U;
    changed.symbols[0].section = -1;
    result = coff_resolve_symbols([caller, changed]);
    if (result.errors.length() != 0 || result.targets[0][2].object != 1) { print("FAIL: absolute external definition"); return 1; }
    changed.symbols[0].section = 1;
    changed.sections[0].relocs[0].symbol = 99;
    result = coff_resolve_symbols([changed]);
    if (result.errors.length() != 1 || result.errors[0].status != CoffLinkStatus.InvalidObject) { print("FAIL: invalid relocation index"); return 1; }

    // object names are bytes, even names that cannot be decoded as UTF-8 bind exactly.
    caller.bytes[caller.symbols[2].name.offset] = Byte(255);
    provider.bytes[provider.symbols[0].name.offset] = Byte(255);
    result = coff_resolve_symbols([caller, provider]);
    if (result.errors.length() != 0 || result.targets[0][2].object != 1) { print("FAIL: byte-name resolution"); return 1; }

    print("PASS: COFF symbol resolution and link diagnostics");
    return 0;
}
