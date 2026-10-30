// Test: PE_ERRORS
// File: tests/linker/test_pe_errors.wl
// Focus: Entry selection, image options and fixed-base relocation requirements.
import "file"
import * from "../../src/linker/coff/link_model.wl"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import * from "../fixtures/linker/pe_objects.wl"


func rejected(result: PeImageResult, status: CoffLinkStatus) -> Bool {
    return result.image is null && result.errors.length() == 1 && result.errors[0].status == status;
}

func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_leaf_object()?;
    catch(err) { return 1; }
    let options = PeOptions(entry="entry");
    if (!rejected(write_pe([object], PeOptions(entry="missing")), CoffLinkStatus.UndefinedSymbol) ||
        !rejected(write_pe([object], PeOptions(entry="")), CoffLinkStatus.InvalidLayout) ||
        !rejected(write_pe([object], PeOptions(entry="entry", image_base=1UL)), CoffLinkStatus.InvalidLayout) ||
        !rejected(write_pe([object], PeOptions(entry="entry", stack_commit=0UL)), CoffLinkStatus.InvalidLayout) ||
        !rejected(write_pe([object], PeOptions(entry="entry", heap_reserve=1UL)), CoffLinkStatus.InvalidLayout) ||
        !rejected(write_pe([], options), CoffLinkStatus.InvalidLayout)) {
        print("FAIL: image option or entry diagnostics");
        return 1;
    }

    let big = pe_bss_object()?;
    catch(err) { return 1; }
    big.sections[1].size = 65536U;
    if (!rejected(write_pe([big], PeOptions(entry="entry", image_base=18446744073709486080UL)), CoffLinkStatus.InvalidLayout)) {
        print("FAIL: overflowing image address range");
        return 1;
    }

    object.symbols[0].value = object.sections[0].size;
    if (!rejected(write_pe([object], options), CoffLinkStatus.InvalidLayout)) { print("FAIL: entry at section end"); return 1; }
    object.symbols[0].value = 0U;
    object.sections[0].flags = 0x40000040U;
    if (!rejected(write_pe([object], options), CoffLinkStatus.InvalidLayout)) { print("FAIL: non-executable entry"); return 1; }
    object.sections[0].flags = 0x60000020U;
    object.symbols[0].storage = Byte(3);
    if (!rejected(write_pe([object], options), CoffLinkStatus.UndefinedSymbol)) { print("FAIL: local entry accepted"); return 1; }

    let caller = pe_caller_object()?;
    catch(err) { return 1; }
    if (!rejected(write_pe([caller], options), CoffLinkStatus.UndefinedSymbol)) { print("FAIL: undefined target"); return 1; }
    let duplicate = pe_leaf_object()?;
    catch(err) { return 1; }
    if (!rejected(write_pe([duplicate, duplicate], options), CoffLinkStatus.DuplicateSymbol)) { return 1; }

    let pointer = pe_pointer_object()?;
    catch(err) { return 1; }
    pointer.sections[1].relocs[0].kind = 2U;
    if (!rejected(write_pe([pointer], options), CoffLinkStatus.RelocationOverflow)) {
        print("FAIL: ADDR32 silently truncated a high image address");
        return 1;
    }
    let low = write_pe([pointer], PeOptions(entry="entry", image_base=4194304UL));
    if (low.image is null) { print("FAIL: low ADDR32 image"); return 1; }
    let fixed: PeImage = low.image;
    let pe = Int(coff_u32(fixed.bytes, 60));
    let optional = pe + 24;
    if (!fixed.fixed_base || fixed.layout.sections.length() != 3 || (coff_u16(fixed.bytes, pe + 22) & 1U) == 0U ||
        (coff_u16(fixed.bytes, optional + 70) & 96U) != 0U || coff_u32(fixed.bytes, optional + 152) != 0U) {
        print("FAIL: fixed-base header claims ASLR support");
        return 1;
    }

    // discarded contributions have no image address, a live reference must diagnose that.
    pointer.sections[2].flags |= 2048U;
    if (!rejected(write_pe([pointer], PeOptions(entry="entry", image_base=4194304UL)), CoffLinkStatus.InvalidLayout)) {
        print("FAIL: relocation to a removed section accepted");
        return 1;
    }
    let absolute = pe_pointer_object()?;
    catch(err) { return 1; }
    absolute.symbols[1].section = -1;
    absolute.symbols[1].value = 4194304U;
    let anchored = write_pe([absolute], PeOptions(entry="entry", image_base=4194304UL));
    if (anchored.image is null) { print("FAIL: absolute REL32 image"); return 1; }
    let anchor: PeImage = anchored.image;
    if (!anchor.fixed_base || anchor.layout.sections.length() != 3) {
        print("FAIL: absolute REL32 image claims it can be rebased");
        return 1;
    }
    if (argc == 2) {
        let output = file.create(argv[1])?;
        catch(err) { return 1; }
        output.write_bytes(fixed.bytes)?;
        catch(err) { output.close(); return 1; }
        output.close();
    }
    print("PASS: PE entry, options and relocation errors");
    return 0;
}
