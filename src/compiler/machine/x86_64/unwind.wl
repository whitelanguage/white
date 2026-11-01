// src/compiler/machine/x86_64/unwind.wl
import * from "model.wl"
import * from "encoder.wl"


func x86_probe_stack(ref output: X86CodeBuffer, size: Int) -> Bool {
// touch each page before moving RSP, so a fault in the probe still has the old frame
    x86_mov_register64(ref output, X86Register.R10, X86Register.RSP);
    if (!x86_lea(ref output, X86Register.R11, X86Register.RSP, X86Register.None, 1, -size)) { return false; }

    // R10/R11 are scratch in the Windows ABI, incoming arguments remain intact.
    // A counted probe keeps even a very large frame inside the 255-byte prologue limit.
    let loop = output.bytes.length();
    if (!x86_lea(ref output, X86Register.R10, X86Register.R10, X86Register.None, 1, -4096)) { return false; }
    x86_cmp_register64(ref output, X86Register.R10, X86Register.R11);
    let last = x86_jump_if_rel32(ref output, X86Opcode.Jbe);
    x86_emit_byte(ref output, Byte(0x41));
    x86_emit_byte(ref output, Byte(0xF6));
    x86_emit_byte(ref output, Byte(0x02));
    x86_emit_byte(ref output, Byte(0));
    let repeat = x86_jump_rel32(ref output);
    if (!x86_patch_i32(ref output, repeat, loop - repeat - 4) ||
        !x86_patch_i32(ref output, last, output.bytes.length() - last - 4)) {
        return false;
    }

    x86_emit_byte(ref output, Byte(0x41));
    x86_emit_byte(ref output, Byte(0xF6));
    x86_emit_byte(ref output, Byte(0x03));
    x86_emit_byte(ref output, Byte(0));
    return true;
}

func x86_win64_frame(ref output: X86CodeBuffer, size: Int) -> Vector(Byte) {
// record instruction ends as they are emitted, unwind offsets refer to these PCs
    if (size <= 0 || size % 16 != 0 || size > 2147483632) { return []; }
    let start = output.bytes.length();
    x86_push_rbp(ref output);
    let push_end = output.bytes.length() - start;
    x86_mov_rbp_rsp(ref output);
    let frame_end = output.bytes.length() - start;
    if (size >= 4096 && !x86_probe_stack(ref output, size)) { return []; }
    x86_sub_rsp_imm32(ref output, UInt32(size));
    let alloc_end = output.bytes.length() - start;
    if (alloc_end > 255) { return []; }

    let codes: Vector(Byte) = [Byte(alloc_end)];
    if (size <= 128) {
        codes.append(Byte(((size / 8 - 1) << 4) | 2));
    } else if (size <= 524280) {
        codes.append(Byte(1));
        x86_unwind_u16(codes, size / 8);
    } else {
        codes.append(Byte(0x11));
        x86_unwind_u32(codes, UInt32(size));
    }
    codes.append(Byte(frame_end));
    codes.append(Byte(3));
    codes.append(Byte(push_end));
    codes.append(Byte(0x50));

    let result: Vector(Byte) = [Byte(1), Byte(alloc_end), Byte(codes.length() / 2), Byte(5)];
    for (let i = 0; i < codes.length(); i++) { result.append(codes[i]); }
    while (result.length() % 4 != 0) { result.append(Byte(0)); }
    return result;
}

func x86_unwind_u16(bytes: Vector(Byte), value: Int) -> Void {
    bytes.append(Byte(value & 255));
    bytes.append(Byte((value >> 8) & 255));
}

func x86_unwind_u32(bytes: Vector(Byte), value: UInt32) -> Void {
    for (let i = 0; i < 4; i++) { bytes.append(Byte((value >> UInt32(i * 8)) & 255U)); }
}

func x86_emit_unwind(ref object: X86Object, records: Vector(X86UnwindRecord)) -> Bool {
// local anchors let all three runtime-function fields use image-relative COFF relocations
    if (records.length() == 0) { return true; }
    let code_anchor = "$wl.unwind.text";
    let info_anchor = "$wl.unwind.xdata";
    for (let s = 0; s < object.symbols.length(); s++) {
        if (object.symbols[s].name == code_anchor || object.symbols[s].name == info_anchor) { return false; }
    }
    let table: Vector(Byte) = [];
    let info: Vector(Byte) = [];
    for (let i = 0; i < records.length(); i++) {
        let record = records[i];
        if (record.begin < 0 || record.end <= record.begin || record.bytes.length() == 0 ||
            record.bytes.length() % 4 != 0 || (i > 0 && record.begin < records[i - 1].end)) { return false; }
        let at = UInt32(table.length());
        object.relocations.append(X86Relocation(section=".pdata", offset=at, kind=X86RelocationKind.Addr32NB, symbol=code_anchor, addend=Long(record.begin)));
        object.relocations.append(X86Relocation(section=".pdata", offset=at + 4U, kind=X86RelocationKind.Addr32NB, symbol=code_anchor, addend=Long(record.end)));
        object.relocations.append(X86Relocation(section=".pdata", offset=at + 8U, kind=X86RelocationKind.Addr32NB, symbol=info_anchor, addend=Long(info.length())));
        x86_unwind_u32(table, UInt32(record.begin));
        x86_unwind_u32(table, UInt32(record.end));
        x86_unwind_u32(table, UInt32(info.length()));
        for (let j = 0; j < record.bytes.length(); j++) { info.append(record.bytes[j]); }
    }
    object.symbols.append(X86Symbol(name=code_anchor, section=".text", offset=0U, external=false));
    object.symbols.append(X86Symbol(name=info_anchor, section=".xdata", offset=0U, external=false));
    object.sections.append(X86CodeSection(name=".pdata", bytes=table, alignment=4, executable=false, writable=false));
    object.sections.append(X86CodeSection(name=".xdata", bytes=info, alignment=4, executable=false, writable=false));
    return true;
}
