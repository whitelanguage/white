// Test: COFF_RELOCATIONS
// File: tests/linker/test_coff_reloc.wl
// Focus: AMD64 field formulas, rebasing records and checked range failures.

import * from "../../src/linker/coff/model.wl"
import * from "../../src/linker/coff/link_model.wl"
import coff_resolve_symbols from "../../src/linker/coff/symbols.wl"
import coff_apply_section, coff_u64, coff_reloc_overlap from "../../src/linker/coff/reloc.wl"
import read_coff, coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import * from "../../src/compiler/machine/x86_64/model.wl"
import coff_object from "../../src/compiler/machine/x86_64/coff.wl"


func object_for(provider: Bool, addend: Long) -> CoffObject? {
    let bytes: Vector(Byte) = [];
    let i: Int = 0;
    while (i < 16) { bytes.append(Byte(0)); i++; }
    let symbols: Vector(X86Symbol) = [X86Symbol(name="entry", section=".data", offset=0U, external=true), X86Symbol(name="target", section="", offset=0U, external=true)];
    let relocs: Vector(X86Relocation) = [X86Relocation(section=".data", offset=0U, kind=X86RelocationKind.Abs64, symbol="target", addend=addend)];
    if provider {
        symbols = [X86Symbol(name="target", section=".data", offset=4U, external=true)];
        relocs = [];
    }
    let encoded = coff_object(X86Object(sections=[X86CodeSection(name=".data", bytes=bytes, alignment=8, executable=false, writable=true)], symbols=symbols, relocations=relocs))?;
    let result = read_coff(encoded);
    if (result.object is null) { throw Error.InvalidArgument; }
    return result.object;
}

func is_overflow(result: CoffPatchResult) -> Bool {
    if (result.patch is !null || result.diagnostic is null) { return false; }
    return result.diagnostic.status == CoffLinkStatus.RelocationOverflow;
}

func main() -> Int {
    let caller = object_for(false, 7L)?;
    catch(err) { print("FAIL: relocation caller"); return 1; }
    let target = object_for(true, 0L)?;
    catch(err) { print("FAIL: relocation target"); return 1; }
    let layout: Vector(Vector(CoffPlacement)) = [[CoffPlacement(4096U, 1)], [CoffPlacement(12320U, 2, 32U)]];
    let objects: Vector(CoffObject) = [caller, target];
    let symbols = coff_resolve_symbols(objects);
    let result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: ADDR64 application"); return 1; }
    let patch: CoffPatch = result.patch;
    if (coff_u64(patch.bytes, 0) != 5368721451UL || patch.base_relocs.length() != 1 || patch.base_relocs[0].rva != 4096U || patch.base_relocs[0].kind != 10U ||
        coff_u64(caller.bytes, caller.sections[0].data.offset) != 7UL) {
        print("FAIL: ADDR64, base relocation or original input changed");
        return 1;
    }
    result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: repeated relocation"); return 1; }
    patch = result.patch;
    if (coff_u64(patch.bytes, 0) != 5368721451UL) { print("FAIL: addend was applied twice"); return 1; }

    let negative = object_for(false, -4L)?;
    catch(err) { print("FAIL: signed ADDR64 fixture"); return 1; }
    let negative_result = coff_apply_section([negative, target], symbols, layout, 5368709120UL, 0, 0);
    if (negative_result.patch is null) { print("FAIL: signed ADDR64 application"); return 1; }
    let negative_patch: CoffPatch = negative_result.patch;
    if (coff_u64(negative_patch.bytes, 0) != 5368721440UL) { print("FAIL: signed ADDR64 addend"); return 1; }

    caller.sections[0].relocs[0].kind = 2U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 4194304UL, 0, 0);
    if (result.patch is null) { print("FAIL: ADDR32 application"); return 1; }
    patch = result.patch;
    if (coff_u32(patch.bytes, 0) != 4206635U || patch.base_relocs[0].kind != 3U) { print("FAIL: ADDR32 result"); return 1; }
    if (!is_overflow(coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0))) { print("FAIL: truncated ADDR32 address"); return 1; }

    caller.sections[0].relocs[0].kind = 3U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: ADDR32NB application"); return 1; }
    patch = result.patch;
    if (coff_u32(patch.bytes, 0) != 12331U || patch.base_relocs.length() != 0) { print("FAIL: image-relative RVA"); return 1; }

    let bad_layout: Vector(Vector(CoffPlacement)) = [[CoffPlacement(0U, 1)], [CoffPlacement(12320U, 2, 32U)]];
    result = coff_apply_section(objects, symbols, bad_layout, 18446744073709547519UL, 0, 0);
    if (result.patch is !null || result.diagnostic is null) { print("FAIL: overflowing target VA"); return 1; }
    if (result.diagnostic.status != CoffLinkStatus.InvalidLayout) { print("FAIL: target VA overflow diagnostic"); return 1; }

    caller.sections[0].relocs[0].kind = 10U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: SECTION application"); return 1; }
    patch = result.patch;
    if (coff_u16(patch.bytes, 0) != 9U) { print("FAIL: output section index"); return 1; }

    caller.sections[0].relocs[0].kind = 11U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: SECREL application"); return 1; }
    patch = result.patch;
    if (coff_u32(patch.bytes, 0) != 43U) { print("FAIL: output-section contribution offset"); return 1; }

    caller = object_for(false, -4L)?;
    catch(err) { print("FAIL: negative addend fixture"); return 1; }
    let kind: UInt32 = 4U;
    while (kind <= 9U) {
        caller.sections[0].relocs[0].kind = kind;
        objects = [caller, target];
        result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
        if (result.patch is null) { print("FAIL: REL32_n application", kind); return 1; }
        patch = result.patch;
        if (coff_u32(patch.bytes, 0) != 8224U - kind || patch.base_relocs.length() != 0) { print("FAIL: REL32_n field end", kind); return 1; }
        kind++;
    }

    caller = object_for(false, 0L)?;
    catch(err) { print("FAIL: range fixture"); return 1; }
    caller.sections[0].relocs[0].kind = 4U;
    objects = [caller, target];
    layout[1][0].rva = 2147487743U;
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is null) { print("FAIL: INT32_MAX displacement"); return 1; }
    patch = result.patch;
    if (coff_u32(patch.bytes, 0) != 2147483647U) { print("FAIL: positive displacement boundary"); return 1; }
    layout[1][0].rva++;
    if (!is_overflow(coff_apply_section(objects, symbols, layout, 0UL, 0, 0))) { print("FAIL: displacement overflow"); return 1; }
    layout[0][0].rva = 2147483648U;
    layout[1][0] = CoffPlacement(0U, 2);
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is null) { print("FAIL: INT32_MIN displacement"); return 1; }
    patch = result.patch;
    if (coff_u32(patch.bytes, 0) != 2147483648U) { print("FAIL: negative displacement boundary"); return 1; }
    layout[0][0].rva++;
    if (!is_overflow(coff_apply_section(objects, symbols, layout, 0UL, 0, 0))) { print("FAIL: negative displacement overflow"); return 1; }

    layout = [[CoffPlacement(4096U, 1)], [CoffPlacement(12320U, 2, 32U)]];
    target.symbols[0].section = -1;
    target.symbols[0].value = 4660U;
    caller.sections[0].relocs[0].kind = 1U;
    objects = [caller, target];
    symbols = coff_resolve_symbols(objects);
    result = coff_apply_section(objects, symbols, layout, 5368709120UL, 0, 0);
    if (result.patch is null) { print("FAIL: absolute target"); return 1; }
    patch = result.patch;
    if (coff_u64(patch.bytes, 0) != 4660UL || patch.base_relocs.length() != 0) { print("FAIL: absolute symbol was rebased"); return 1; }
    caller.sections[0].relocs[0].kind = 4U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is null) { print("FAIL: absolute relative target"); return 1; }
    patch = result.patch;
    if (!patch.fixed_base || coff_u32(patch.bytes, 0) != 560U) { print("FAIL: fixed-base relative relocation"); return 1; }

    caller.sections[0].relocs[0].kind = 13U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is !null || result.diagnostic is null) { print("FAIL: unsupported application"); return 1; }
    if (result.diagnostic.status != CoffLinkStatus.Unsupported) { print("FAIL: unsupported relocation diagnostic"); return 1; }

    caller.sections[0].relocs[0].kind = 1U;
    caller.sections[0].relocs[0].offset = 9U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is !null || result.diagnostic is null) { print("FAIL: field beyond data"); return 1; }
    caller.sections[0].relocs[0].offset = 0U;
    objects = [caller, target];
    result = coff_apply_section(objects, symbols, layout, 18446744073709551615UL, 0, 0);
    if (result.patch is !null || result.diagnostic is null) { print("FAIL: overflowing placement"); return 1; }
    symbols.errors.append(CoffLinkError(status=CoffLinkStatus.UndefinedSymbol, object=0));
    result = coff_apply_section(objects, symbols, layout, 0UL, 0, 0);
    if (result.patch is !null || result.diagnostic is null) { print("FAIL: patching unresolved symbols"); return 1; }

    if (coff_reloc_overlap([CoffReloc(8U, 0, 4U), CoffReloc(0U, 0, 4U), CoffReloc(4U, 0, 4U)]) != -1 ||
        coff_reloc_overlap([CoffReloc(8U, 0, 4U), CoffReloc(0U, 0, 1U), CoffReloc(4U, 0, 4U)]) < 0) {
        print("FAIL: relocation field overlap validation");
        return 1;
    }

    print("PASS: COFF relocation formulas, rebasing and range checks");
    return 0;
}
