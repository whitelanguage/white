// src/compiler/machine/data.wl
import * from "../wir/model.wl"
import * from "object.wl"


struct MachineDataRelocation(
    section: String,
    offset: UInt32,
    symbol: String,
    addend: Long
)

struct MachineDataResult(
    sections: Vector(MachineSection),
    symbols: Vector(MachineSymbol),
    relocations: Vector(MachineDataRelocation),
    message: String
)

func machine_data_error(message: String) -> MachineDataResult {
    return MachineDataResult(sections=[], symbols=[], relocations=[], message=message);
}

func machine_address_symbol(ref program: WirModule, value_id: WirValueID) -> String {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) { return ""; }

    let value: WirValue = program.arena.values[index];
    let owner: Int = wir_id_index(value.owner);

    if (value.kind == WirValueKind.Global && owner >= 0 && owner < program.arena.globals.length()) {
        return program.arena.globals[owner].name;
    }
    if (value.kind == WirValueKind.Function && owner >= 0 && owner < program.arena.functions.length()) {
        return program.arena.functions[owner].name;
    }

    return "";
}

func machine_write_initializer(
    ref program: WirModule,
    layouts: Vector(WirTypeLayout),
    ref section: MachineSection,
    ref relocations: Vector(MachineDataRelocation),
    value_id: WirValueID,
    offset: Int,
    depth: Int
) -> String {
// Section storage starts zeroed, so zero and null constants need no writes.
    if (depth > 256) { return "global initializer nesting exceeds 256 levels"; }

    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length()) {
        return "global initializer refers to an unknown value";
    }

    let value: WirValue = program.arena.values[index];
    let layout: WirTypeLayout = layouts[wir_id_index(UInt32(value.type_id))];
    if (!layout.valid || layout.size > 2147483647UL || offset < 0 ||
        Long(offset) + Long(layout.size) > Long(section.bytes.length())) {
        return "global initializer does not fit its storage";
    }

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
        let symbol: String = machine_address_symbol(ref program, value_id);
        if (layout.size != 8UL || symbol.length() == 0) {
            return "address initializer has no linkable target";
        }

        relocations.append(MachineDataRelocation(section=section.name, offset=UInt32(offset), symbol=symbol, addend=0L));
        return "";
    }

    if (value.kind != WirValueKind.Constant) {
        return "global initializer is not a constant";
    }

    let owner: Int = wir_id_index(value.owner);
    if (owner < 0 || owner >= program.arena.constants.length()) {
        return "global initializer refers to an unknown constant";
    }

    let constant: WirConstant = program.arena.constants[owner];
    if (constant.kind == WirConstKind.Zero) { return ""; }

    if (constant.kind == WirConstKind.Address) {
        let symbol: String = machine_address_symbol(ref program, constant.target);
        if (layout.size != 8UL || symbol.length() == 0) {
            return "address initializer has no linkable target";
        }

        relocations.append(MachineDataRelocation(section=section.name, offset=UInt32(offset), symbol=symbol, addend=constant.addend));
        return "";
    }

    if (constant.kind == WirConstKind.Bytes) {
        if (UInt64(constant.bytes.length()) != layout.size) {
            return "byte initializer length does not match its storage";
        }

        let i: Int = 0;
        while (i < constant.bytes.length()) {
            section.bytes[offset + i] = constant.bytes[i];
            i++;
        }

        return "";
    }

    if (constant.kind != WirConstKind.Aggregate) {
        return "unsupported global initializer kind";
    }

    let type: WirType = program.arena.types[wir_id_index(UInt32(value.type_id))];
    let count: Int = type.fields.length();
    let stride: UInt64 = 0UL;

    if (type.kind == WirTypeKind.Array) {
        if (type.length > UIntSize(2147483647)) {
            return "array initializer exceeds the object size limit";
        }
        count = Int(type.length);
        stride = layouts[wir_id_index(UInt32(type.element))].size;
    } else if (type.kind != WirTypeKind.Struct) {
        return "aggregate initializer requires an array or struct";
    }

    if (constant.elements.length() != count) {
        return "aggregate initializer element count does not match its type";
    }

    let i: Int = 0;
    while (i < count) {
        let member_offset: UInt64 = UInt64(i) * stride;
        if (type.kind == WirTypeKind.Struct) { member_offset = layout.field_offsets[i]; }

        let message: String = machine_write_initializer(
            ref program,
            layouts,
            ref section,
            ref relocations,
            constant.elements[i],
            offset + Int(member_offset),
            depth + 1
        );
        if (message.length() != 0) { return message; }
        i++;
    }

    return "";
}

func machine_emit_globals(
    ref program: WirModule,
    layouts: Vector(WirTypeLayout),
    readonly_name: String,
    readonly_writable: Bool
) -> MachineDataResult {
// The caller selects the target's read-only relocation section name. ELF uses
// .data.rel.ro because loaders must write absolute addresses before RELRO seals it.
    let readonly: MachineSection = MachineSection(name=readonly_name, bytes=[], alignment=1, executable=false, writable=readonly_writable);
    let writable: MachineSection = MachineSection(name=".data", bytes=[], alignment=1, executable=false, writable=true);
    let symbols: Vector(MachineSymbol) = [];
    let relocations: Vector(MachineDataRelocation) = [];
    let has_readonly: Bool = false;
    let has_writable: Bool = false;
    let i: Int = 0;

    while (i < program.arena.globals.length()) {
        let global: WirGlobal = program.arena.globals[i];
        if (global.linkage == WirLinkage.External) {
            symbols.append(MachineSymbol(name=global.name, section="", offset=0U, external=true));
            i++;
            continue;
        }

        let layout: WirTypeLayout = layouts[wir_id_index(UInt32(global.type_id))];
        if (!layout.valid || layout.size > 2147483647UL) {
            return machine_data_error("global '" + global.name + "' has an unsupported storage layout");
        }

        let alignment: Int = layout.alignment;
        if (global.alignment > alignment) { alignment = global.alignment; }
        if (alignment < 1 || alignment > 8192 || (alignment & (alignment - 1)) != 0) {
            return machine_data_error("global alignment cannot be represented in the object file");
        }

        let section: MachineSection = writable;
        if (global.is_const) { section = readonly; }
        if (alignment > section.alignment) { section.alignment = alignment; }
        while (section.bytes.length() % alignment != 0) { section.bytes.append(Byte(0)); }

        let offset: Int = section.bytes.length();
        if (Long(offset) + Long(layout.size) > 2147483647L) {
            return machine_data_error("global data exceeds the object size limit");
        }

        let byte: Int = 0;
        while (byte < Int(layout.size)) {
            section.bytes.append(Byte(0));
            byte++;
        }

        let message: String = machine_write_initializer(ref program, layouts, ref section, ref relocations, global.initializer, offset, 0);
        if (message.length() != 0) { return machine_data_error(message); }

        symbols.append(MachineSymbol(name=global.name, section=section.name, offset=UInt32(offset), external=global.linkage == WirLinkage.Exported));
        if (global.is_const) {
            readonly = section;
            has_readonly = true;
        } else {
            writable = section;
            has_writable = true;
        }
        i++;
    }

    let sections: Vector(MachineSection) = [];
    if has_readonly { sections.append(readonly); }
    if has_writable { sections.append(writable); }

    return MachineDataResult(sections=sections, symbols=symbols, relocations=relocations, message="");
}
