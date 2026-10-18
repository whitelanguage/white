// src/compiler/machine/x86_64/types.wl
import * from "model.wl"
import * from "../../wir/model.wl"
import * from "abi.wl"
import * from "abi/sysv.wl"
import wir_type_layouts from "../../wir/layout.wl"


func x86_sysv_call_locations(ref program: WirModule, signature: WirType, layouts: Vector(WirTypeLayout), hidden: Bool) -> Vector(X86ArgLocation) {
    let locations: Vector(X86ArgLocation) = [];
    let cursor: X86SysVArgCursor = X86SysVArgCursor(integer_index=0, float_index=0, stack_index=0);
    if hidden {
        locations.append(x86_sysv_arg(ref cursor, false));
    }
    let i: Int = 0;
    while (i < signature.parameters.length()) {
        let floating: Bool = x86_scalar_float(ref program, signature.parameters[i]) &&
            !x86_indirect_argument(ref program, signature.parameters[i], layouts, signature.abi);
        locations.append(x86_sysv_arg(ref cursor, floating));
        i += 1;
    }
    return locations;
}

func x86_scalar_size(ref program: WirModule, type_id: WirTypeID) -> Int {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return 0; }
    let kind: WirTypeKind = program.arena.types[index].kind;
    let bits: Int = program.arena.types[index].bits;
    if (kind == WirTypeKind.Pointer || kind == WirTypeKind.Function) { return 8; }
    if (kind == WirTypeKind.BoolType) { return 1; }
    if (kind == WirTypeKind.FloatType) {
        if (bits == 32) { return 4; }
        if (bits == 64) { return 8; }
        return 0;
    }
    if (kind != WirTypeKind.SignedInt && kind != WirTypeKind.UnsignedInt) { return 0; }
    if (bits == 8) { return 1; }
    if (bits == 16) { return 2; }
    if (bits == 32) { return 4; }
    if (bits == 64) { return 8; }
    return 0;
}

func x86_scalar_signed(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return false; }
    return program.arena.types[index].kind == WirTypeKind.SignedInt;
}

func x86_integer_immediate(value: WirValue, size: Int) -> Bool {
    if (value.kind != WirValueKind.Integer) { return false; }
    if (size <= 4) { return true; }
    // x86-64 sign extends the 32-bit field. Keep negative bit patterns on the
    // register path until WIR has one canonical signed-immediate query.
    return size == 8 && value.integer <= UInt128(2147483647U);
}

func x86_scalar_float(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    return index >= 0 && index < program.arena.types.length() && program.arena.types[index].kind == WirTypeKind.FloatType;
}

func x86_aggregate_type(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return false; }

    let kind = program.arena.types[index].kind;
    return kind == WirTypeKind.Struct || kind == WirTypeKind.Array;
}

func x86_wide_integer(ref program: WirModule, type_id: WirTypeID) -> Bool {
    let index: Int = wir_id_index(UInt32(type_id));
    if (index < 0 || index >= program.arena.types.length()) { return false; }

    let ptr type: WirType = ref program.arena.types[index];
    return (type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt) && type.bits == 128;
}

func x86_memory_value(ref program: WirModule, type_id: WirTypeID) -> Bool {
    return x86_aggregate_type(ref program, type_id) || x86_wide_integer(ref program, type_id);
}

func x86_abi_size(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Int {
    if (x86_aggregate_type(ref program, type_id)) {
        return x86_aggregate_size(layouts[wir_id_index(UInt32(type_id))]);
    }
    if (x86_wide_integer(ref program, type_id)) { return 16; }
    return x86_scalar_size(ref program, type_id);
}

func x86_native_sysv_abi(abi: WirABI) -> Bool {
    return x86_is_sysv_abi() && abi != WirABI.White;
}

func x86_native_abi_size(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout), abi: WirABI) -> Int {
    if (x86_native_sysv_abi(abi)) {
        let classification: X86SysVTypeClass = x86_sysv_classify(ref program, type_id, layouts);
        if (!classification.memory) { return classification.size; }
        return 0;
    }
    return x86_abi_size(ref program, type_id, layouts);
}

func x86_type_layouts(ref program: WirModule) -> Vector(WirTypeLayout) {
    return wir_type_layouts(program);
}

func x86_indirect_aggregate(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout)) -> Bool {
    return x86_aggregate_type(ref program, type_id) && x86_abi_size(ref program, type_id, layouts) == 0;
}

func x86_indirect_return(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout), abi: WirABI) -> Bool {
    if (x86_native_sysv_abi(abi)) {
        if (!x86_memory_value(ref program, type_id)) {
            return false;
        }
        return x86_sysv_classify(ref program, type_id, layouts).memory;
    }
    return x86_indirect_aggregate(ref program, type_id, layouts);
}

func x86_indirect_argument(ref program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout), abi: WirABI) -> Bool {
    if (x86_native_sysv_abi(abi)) { return false; }
    return x86_indirect_aggregate(ref program, type_id, layouts) || x86_wide_integer(ref program, type_id);
}

func x86_register_clobber(register: X86Register) -> UInt64 {
    if (register == X86Register.None) {
        return 0UL;
    }
    return 1UL << UInt64(Int(register));
}

func x86_comparison_opcode(opcode: WirOpcode) -> X86Opcode {
    if (opcode == WirOpcode.Equal) { return X86Opcode.Je; }
    if (opcode == WirOpcode.NotEqual) { return X86Opcode.Jne; }
    if (opcode == WirOpcode.SignedLess) { return X86Opcode.Jl; }
    if (opcode == WirOpcode.SignedLessEqual) { return X86Opcode.Jle; }
    if (opcode == WirOpcode.SignedGreater) { return X86Opcode.Jg; }
    if (opcode == WirOpcode.SignedGreaterEqual) { return X86Opcode.Jge; }
    if (opcode == WirOpcode.UnsignedLess) { return X86Opcode.Jb; }
    if (opcode == WirOpcode.UnsignedLessEqual) { return X86Opcode.Jbe; }
    if (opcode == WirOpcode.UnsignedGreater) { return X86Opcode.Ja; }
    if (opcode == WirOpcode.UnsignedGreaterEqual) { return X86Opcode.Jae; }
    return X86Opcode.Invalid;
}
