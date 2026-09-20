// compiler/machine/x86_64/data.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import wir_type_layout from "../../wir/layout.wl"

func x86_address_symbol(program: WirModule, value_id: WirValueID) -> String {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return ""; }
    let value: WirValue = program.arena.values[index];
    let owner: Int = wir_id_index(value.owner);
    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) { return program.arena.globals[owner].name; }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) { return program.arena.functions[owner].name; }
    return "";
}

func x86_write_initializer(program: WirModule, ref section: X86CodeSection, ref relocations: Vector(X86Relocation), value_id: WirValueID, offset: Int, depth: Int) -> String {
    // storage is zero-filled first, including aggregate padding
    if (depth > 256) { return "global initializer nesting exceeds 256 levels"; }
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return "global initializer refers to an unknown value"; }
    let value: WirValue = program.arena.values[index];
    let layout: WirTypeLayout = wir_type_layout(program, value.type_id);
    if (!layout.valid || layout.size > 2147483647UL || offset < 0 || Long(offset) + Long(layout.size) > Long(section.bytes.length())) { return "global initializer does not fit its storage"; }
    if (value.kind == WirValueKind.Null) { return ""; }
    if (value.kind == WirValueKind.Integer || value.kind == WirValueKind.BoolValue || value.kind == WirValueKind.FloatValue) {
        if (layout.size > 16UL) { return "scalar initializer exceeds 128 bits"; }
        let bits: UInt128 = value.integer;
        if (value.kind == WirValueKind.FloatValue) { bits = UInt128(value.float_bits); }
        let i: Int = 0;
        while (i < Int(layout.size)) {
            section.bytes[offset + i] = Byte((bits >> UInt128(i * 8)) & UInt128(255U));
            i++;
        }
        return "";
    }
    if (value.kind == WirValueKind.Global || value.kind == WirValueKind.Function) {
        if (layout.size != 8UL) { return "address initializer must occupy 8 bytes"; }
        relocations.append(X86Relocation(section=section.name, offset=UInt32(offset), kind=X86RelocationKind.Abs64, symbol=x86_address_symbol(program, value_id), addend=0L));
        return "";
    }
    if (value.kind != WirValueKind.Constant) { return "global initializer is not a constant"; }
    let owner: Int = wir_id_index(value.owner);
    if (owner < 0 || owner >= program.arena.constants.length()) { return "global initializer refers to an unknown constant"; }
    let constant: WirConstant = program.arena.constants[owner];
    if (constant.kind == WirConstKind.Zero) { return ""; }
    if (constant.kind == WirConstKind.Address) {
        let symbol: String = x86_address_symbol(program, constant.target);
        if (layout.size != 8UL || symbol.length() == 0) { return "address initializer has no linkable target"; }
        relocations.append(X86Relocation(section=section.name, offset=UInt32(offset), kind=X86RelocationKind.Abs64, symbol=symbol, addend=constant.addend));
        return "";
    }
    if (constant.kind == WirConstKind.Bytes) {
        if (UInt64(constant.bytes.length()) != layout.size) { return "byte initializer length does not match its storage"; }
        let i: Int = 0;
        while (i < constant.bytes.length()) {
            section.bytes[offset + i] = constant.bytes[i];
            i++;
        }
        return "";
    }
    if (constant.kind != WirConstKind.Aggregate) { return "unsupported global initializer kind"; }
    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    let count: Int = type.fields.length();
    let stride: UInt64 = 0UL;
    if (type.kind == WirTypeKind.Array) {
        if (type.length > UIntSize(2147483647)) { return "array initializer exceeds the object size limit"; }
        count = Int(type.length);
        stride = wir_type_layout(program, type.element).size;
    } else if (type.kind != WirTypeKind.Struct) { return "aggregate initializer requires an array or struct"; }
    if (constant.elements.length() != count) { return "aggregate initializer element count does not match its type"; }
    let i: Int = 0;
    while (i < count) {
        let member_offset: UInt64 = UInt64(i) * stride;
        if (type.kind == WirTypeKind.Struct) { member_offset = layout.field_offsets[i]; }
        let message: String = x86_write_initializer(program, ref section, ref relocations, constant.elements[i], offset + Int(member_offset), depth + 1);
        if (message.length() != 0) { return message; }
        i++;
    }
    return "";
}

func x86_emit_globals(program: WirModule, ref object: X86Object) -> String {
    let readonly_data: X86CodeSection = X86CodeSection(name=".rdata", bytes=[], alignment=1, executable=false, writable=false);
    let writable_data: X86CodeSection = X86CodeSection(name=".data", bytes=[], alignment=1, executable=false, writable=true);
    let has_readonly: Bool = false;
    let has_writable: Bool = false;
    let i: Int = 0;
    while (i < program.arena.globals.length()) {
        let global: WirGlobal = program.arena.globals[i];
        if (global.linkage == WirLinkage.External) {
            object.symbols.append(X86Symbol(name=global.name, section="", offset=0U, external=true));
        } else {
            let layout: WirTypeLayout = wir_type_layout(program, global.type_id);
            if (!layout.valid || layout.size > 2147483647UL) { return "global '" + global.name + "' has an unsupported storage layout"; }
            let alignment: Int = layout.alignment;
            if (global.alignment > alignment) { alignment = global.alignment; }
            if (alignment < 1 || alignment > 8192 || (alignment & (alignment - 1)) != 0) { return "global alignment cannot be represented in COFF"; }
            let section: X86CodeSection = writable_data;
            if (global.is_const) { section = readonly_data; }
            if (alignment > section.alignment) { section.alignment = alignment; }
            while (section.bytes.length() % alignment != 0) { section.bytes.append(Byte(0)); }
            let offset: Int = section.bytes.length();
            if (Long(offset) + Long(layout.size) > 2147483647L) { return "global data exceeds the object size limit"; }
            let j: Int = 0;
            while (j < Int(layout.size)) {
                section.bytes.append(Byte(0));
                j++;
            }
            let message: String = x86_write_initializer(program, ref section, ref object.relocations, global.initializer, offset, 0);
            if (message.length() != 0) { return message; }
            object.symbols.append(X86Symbol(name=global.name, section=section.name, offset=UInt32(offset), external=global.linkage == WirLinkage.Exported));
            if (global.is_const) {
                readonly_data = section;
                has_readonly = true;
            } else {
                writable_data = section;
                has_writable = true;
            }
        }
        i++;
    }
    if (has_readonly) { object.sections.append(readonly_data); }
    if (has_writable) { object.sections.append(writable_data); }
    return "";
}
