// Test: PE_IMAGE
// File: tests/linker/test_pe_image.wl
// Focus: PE32+ headers, contribution relocations, BSS and reproducible image bytes.
import "file"
import * from "../../src/linker/pe/model.wl"
import write_pe from "../../src/linker/pe/writer.wl"
import coff_u16, coff_u32 from "../../src/linker/coff/reader.wl"
import coff_u64 from "../../src/linker/coff/reloc.wl"
import * from "../fixtures/linker/pe_objects.wl"


func main(argc: Int, ptr argv: String) -> Int {
    let object = pe_leaf_object()?;
    catch(err) { print("FAIL: leaf object fixture"); return 1; }
    let options = PeOptions(entry="entry");
    let result = write_pe([object], options);
    if (result.image is null) { print("FAIL: PE leaf image"); return 1; }
    let leaf: PeImage = result.image;
    let pe = Int(coff_u32(leaf.bytes, 60));
    let optional = pe + 24;
    if (coff_u16(leaf.bytes, 0) != 23117U || coff_u32(leaf.bytes, pe) != 17744U || coff_u16(leaf.bytes, pe + 4) != 34404U ||
        coff_u16(leaf.bytes, pe + 6) != 1U || coff_u16(leaf.bytes, pe + 20) != 240U || coff_u16(leaf.bytes, optional) != 523U ||
        coff_u32(leaf.bytes, optional + 16) != 4096U || coff_u64(leaf.bytes, optional + 24) != options.image_base ||
        coff_u32(leaf.bytes, optional + 32) != 4096U || coff_u32(leaf.bytes, optional + 36) != 512U || leaf.fixed_base ||
        (coff_u16(leaf.bytes, optional + 70) & 96U) != 96U || (coff_u16(leaf.bytes, pe + 22) & 1U) != 0U || leaf.bytes.length() != 1024) {
        print("FAIL: PE32+ header fields");
        return 1;
    }
    let second = write_pe([object], options);
    if (second.image is null) { print("FAIL: repeated PE link"); return 1; }
    let repeat: PeImage = second.image;
    if (repeat.bytes.length() != leaf.bytes.length()) { return 1; }
    let i = 0;
    while (i < leaf.bytes.length()) {
        if (leaf.bytes[i] != repeat.bytes[i]) { print("FAIL: nondeterministic PE bytes"); return 1; }
        i++;
    }

    let pointer = pe_pointer_object()?;
    catch(err) { print("FAIL: pointer object fixture"); return 1; }
    result = write_pe([pointer], options);
    if (result.image is null) { print("FAIL: relocated PE image"); return 1; }
    let moved: PeImage = result.image;
    let layout = moved.layout;
    if (layout.sections.length() != 4) { print("FAIL: relocated section count"); return 1; }
    let data = layout.sections[2];
    let reloc = layout.sections[3];
    if (moved.fixed_base || layout.sections.length() != 4 || coff_u64(moved.bytes, Int(data.raw_offset)) != options.image_base + 8192UL ||
        coff_u32(moved.bytes, optional + 112 + 40) != reloc.rva || coff_u32(moved.bytes, optional + 116 + 40) != 12U ||
        coff_u32(moved.bytes, Int(reloc.raw_offset)) != data.rva || coff_u32(moved.bytes, Int(reloc.raw_offset) + 4) != 12U ||
        coff_u16(moved.bytes, Int(reloc.raw_offset) + 8) != 40960U || coff_u16(moved.bytes, Int(reloc.raw_offset) + 10) != 0U ||
        (coff_u16(moved.bytes, optional + 70) & 96U) != 96U) {
        print("FAIL: PE base relocation directory");
        return 1;
    }

    let caller = pe_caller_object()?;
    catch(err) { print("FAIL: caller object fixture"); return 1; }
    let answer = pe_answer_object()?;
    catch(err) { print("FAIL: answer object fixture"); return 1; }
    result = write_pe([caller, answer], options);
    if (result.image is null) { print("FAIL: multi-object PE link"); return 1; }
    let call: PeImage = result.image;
    if (call.entry_rva != 4112U || coff_u32(call.bytes, Int(call.layout.sections[0].raw_offset) + 21) != 4294967271U) {
        print("FAIL: sorted contributions or cross-object call displacement");
        return 1;
    }

    let bss = pe_bss_object()?;
    catch(err) { print("FAIL: BSS object fixture"); return 1; }
    result = write_pe([bss], options);
    if (result.image is null) { print("FAIL: BSS PE image"); return 1; }
    let zero: PeImage = result.image;
    if (zero.bytes.length() != 1024 || zero.layout.sections[1].raw_size != 0U || zero.layout.sections[1].raw_offset != 0U ||
        zero.layout.sections[1].size != 8192U || coff_u32(zero.bytes, optional + 12) != 8192U || zero.layout.image_size != 16384U) {
        print("FAIL: BSS was materialized in the file");
        return 1;
    }

    if (argc == 3) {
        let selected = leaf;
        if (argv[2] == "pointer") { selected = moved; }
        else if (argv[2] == "calls") { selected = call; }
        else if (argv[2] == "bss") { selected = zero; }
        let output = file.create(argv[1])?;
        catch(err) { print("FAIL: create PE fixture"); return 1; }
        output.write_bytes(selected.bytes)?;
        catch(err) { output.close(); print("FAIL: write PE fixture"); return 1; }
        output.close();
    }
    print("PASS: PE32+ image headers, relocations, BSS and reproducibility");
    return 0;
}
