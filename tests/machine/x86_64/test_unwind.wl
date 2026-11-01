// Test: X86_64_UNWIND
// File: tests/machine/x86_64/test_unwind.wl
// Focus: bounded probes, recorded prologue PCs and image-relative unwind relocations.
import "file"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/machine/x86_64/model.wl"
import * from "../../../src/compiler/machine/x86_64/encoder.wl"
import * from "../../../src/compiler/machine/x86_64/unwind.wl"
import x86_lower_module from "../../../src/compiler/machine/x86_64/module.wl"
import coff_object from "../../../src/compiler/machine/x86_64/coff.wl"
import elf_object from "../../../src/compiler/machine/x86_64/elf.wl"
import CoffObject from "../../../src/linker/coff/model.wl"
import read_coff, coff_u32 from "../../../src/linker/coff/reader.wl"
import * from "../../../src/linker/pe/model.wl"
import pe_check_unwind from "../../../src/linker/pe/unwind.wl"
import write_pe from "../../../src/linker/pe/writer.wl"


func add_frame(ref program: WirModule, name: String, size: Int) -> Void {
    let i32 = wir_signed_int_type(ref program, 32);
    let byte = wir_unsigned_int_type(ref program, 8);
    let array = wir_array_type(ref program, byte, UIntSize(size));
    let params = [wir_param("a", i32), wir_param("b", i32), wir_param("c", i32), wir_param("d", i32)];
    let id = wir_add_function(ref program, name, params, i32, false, WirLinkage.Exported, WirABI.System);
    let block = wir_add_block(ref program, id, "entry", []);
    wir_stack_alloc(ref program, block, array, "storage", no_wir_location());
    let args = program.arena.functions[wir_id_index(UInt32(id))].parameters;
    let sum = wir_binary(ref program, block, WirOpcode.Add, i32, args[0], args[1], "ab", no_wir_location());
    sum = wir_binary(ref program, block, WirOpcode.Add, i32, sum, args[2], "abc", no_wir_location());
    sum = wir_binary(ref program, block, WirOpcode.Add, i32, sum, args[3], "all", no_wir_location());
    wir_return(ref program, block, sum, no_wir_location());
}

func main(argc: Int, ptr argv: String) -> Int {
    let sizes = [16, 128, 144, 4096, 524272, 524288, 2147483632];
    for (let i = 0; i < sizes.length(); i++) {
        let output = x86_new_code_buffer();
        output.bytes.append(Byte(0x90));
        let info = x86_win64_frame(ref output, sizes[i]);
        let checked = pe_check_unwind(info, 0, info.length());
        if (checked.message.length() != 0 || Int(info[1]) != output.bytes.length() - 1 || info[1] > Byte(80)) {
            print("FAIL: stack allocation unwind format at ", sizes[i]);
            return 1;
        }
        let count = 3;
        if (sizes[i] > 128) { count = 4; }
        if (sizes[i] > 524280) { count = 5; }
        if (Int(info[2]) != count || info[3] != Byte(5) || info[4] != info[1] ||
            info[4 + count * 2 - 4] != Byte(4) || info[4 + count * 2 - 2] != Byte(1)) {
            print("FAIL: unwind slot count or instruction offsets");
            return 1;
        }
    }
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    add_frame(ref program, "Small", 32);
    add_frame(ref program, "Large", 65536);
    add_frame(ref program, "Huge", 524288);
    let lowered = x86_lower_module(ref program);
    if (lowered.errors.length() != 0) { print(lowered.errors[0]); return 1; }
    let encoded = coff_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) { print("FAIL: unwind COFF serialization"); return 1; }
    let parsed = read_coff(encoded);
    if (parsed.object is null) { print(parsed.message); return 1; }
    let object: CoffObject = parsed.object;
    let linked = write_pe([object], PeOptions(entry="", is_dll=true, image_name="machine-unwind.dll", exports=[PeExport(name="Small"), PeExport(name="Large"), PeExport(name="Huge")]));
    if (linked.image is null) {
        for (let e = 0; e < linked.errors.length(); e++) { print(linked.errors[e].message); }
        return 1;
    }
    let image: PeImage = linked.image;
    if (coff_u32(image.bytes, 224) == 0U || coff_u32(image.bytes, 228) != 36U) {
        print("FAIL: machine unwind exception directory");
        return 1;
    }
    let rejected = false;
    elf_object(X86Object(sections=lowered.sections, symbols=lowered.symbols, relocations=lowered.relocations))?;
    catch(err) { rejected = true; }
    if (!rejected) { print("FAIL: image-relative COFF relocation accepted in ELF"); return 1; }
    let leaf = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32 = wir_signed_int_type(ref leaf, 32);
    let id = wir_add_function(ref leaf, "Leaf", [], i32, false, WirLinkage.Exported, WirABI.System);
    let block = wir_add_block(ref leaf, id, "entry", []);
    wir_return(ref leaf, block, wir_const_int(ref leaf, i32, UInt128(42U)), no_wir_location());
    let leaf_code = x86_lower_module(ref leaf);
    if (leaf_code.errors.length() != 0 || leaf_code.sections.length() != 1 || leaf_code.relocations.length() != 0) {
        print("FAIL: a frameless leaf acquired unwind storage");
        return 1;
    }
    if (argc == 2) {
        let output = file.create(argv[1])?;
        catch(err) { return 1; }
        output.write_bytes(image.bytes)?;
        catch(err) { output.close(); return 1; }
        output.close();
    }
    let linux = new_wir_module("x86_64-unknown-linux-gnu", 64);
    add_frame(ref linux, "LinuxFrame", 65536);
    let linux_code = x86_lower_module(ref linux);
    if (linux_code.errors.length() != 0) { print(linux_code.errors[0]); return 1; }
    for (let s = 0; s < linux_code.sections.length(); s++) {
        if (linux_code.sections[s].name == ".pdata" || linux_code.sections[s].name == ".xdata") {
            print("FAIL: PE unwind metadata reached ELF");
            return 1;
        }
    }
    let elf = elf_object(X86Object(sections=linux_code.sections, symbols=linux_code.symbols, relocations=linux_code.relocations))?;
    catch(err) { print("FAIL: Linux frame ELF output"); return 1; }
    if (elf.length() == 0) { return 1; }
    print("PASS: machine unwind emission and White PE linking");
    return 0;
}
