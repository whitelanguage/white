// src/compiler/abi/llvm.wl
import * from "../wir/model.wl"
import wir_type_layouts from "../wir/layout.wl"
import is_win64_target, win64_register_bytes from "../native_abi.wl"
import X86SysVClass, x86_sysv_classify, x86_sysv_class_count from "sysv.wl"
import a64_hfa_type from "aapcs64.wl"


struct NativeLLVMType(mode: Int = 0, physical: String = "", attr: String = "")
struct NativeLLVMPlan(result: NativeLLVMType, params: Vector(NativeLLVMType))

func native_llvm_actual_signature(program: WirModule, signature: WirType, instruction: WirInstruction) -> WirType {
// anonymous arguments still need physical ABI classification, notably Win64 i128.
    if (!signature.variadic) { return signature; }
    let params: Vector(WirTypeID) = [];
    let i = 0;
    while (i < signature.parameters.length()) {
        params.append(signature.parameters[i]);
        i++;
    }
    while (i + 1 < instruction.operands.length()) {
        params.append(program.arena.values[wir_id_index(UInt32(instruction.operands[i + 1]))].type_id);
        i++;
    }
    signature.parameters = params;
    return signature;
}

func native_llvm_target(target: String) -> Bool {
    return is_win64_target(target) || ((target.starts_with("x86_64-") || target.starts_with("aarch64-")) && target.ends_with("linux-gnu"));
}

func native_float_mask(program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout), offset: Int, slot: Int) -> Int {
// distinguish one float from two packed floats in an SSE eightbyte
    let index = wir_id_index(UInt32(type_id));
    let type = program.arena.types[index];
    if (type.kind == WirTypeKind.FloatType) {
        if (offset / 8 != slot) { return 0; }
        if (type.bits == 64) { return 4; }
        return 1 << ((offset % 8) / 4);
    }
    let mask = 0;
    let i = 0;
    if (type.kind == WirTypeKind.Struct) {
        while (i < type.fields.length()) {
            mask |= native_float_mask(program, type.fields[i], layouts, offset + Int(layouts[index].field_offsets[i]), slot);
            i++;
        }
    } else if (type.kind == WirTypeKind.Array) {
        let stride = Int(layouts[wir_id_index(UInt32(type.element))].size);
        while (i < Int(type.length)) {
            mask |= native_float_mask(program, type.element, layouts, offset + i * stride, slot);
            i++;
        }
    }
    return mask;
}

func native_sysv_part(program: WirModule, type_id: WirTypeID, layouts: Vector(WirTypeLayout), slot: Int, floating: Bool) -> String {
    if floating {
        let mask = native_float_mask(program, type_id, layouts, 0, slot);
        if (mask == 1) { return "float"; }
        if (mask == 3) { return "<2 x float>"; }
        return "double";
    }
    let bytes = Int(layouts[wir_id_index(UInt32(type_id))].size) - slot * 8;
    if (bytes > 8) { bytes = 8; }
    return "i" + bytes * 8;
}

func native_llvm_classify(program: WirModule, abi: WirABI, type_id: WirTypeID, layouts: Vector(WirTypeLayout), result: Bool) -> NativeLLVMType {
// these are physical LLVM types at a foreign boundary, the WIR signature stays logical
    if (abi == WirABI.White || !native_llvm_target(program.target)) { return NativeLLVMType(); }
    let index = wir_id_index(UInt32(type_id));
    let type = program.arena.types[index];
    let aggregate = type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array;
    let wide = (type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt) && type.bits == 128;
    // zero-sized WIR records have no register payload, empty source structs use a byte.
    if (aggregate && layouts[index].size == 0UL) { return NativeLLVMType(); }
    if (is_win64_target(program.target)) {
        if wide {
            if result { return NativeLLVMType(mode=1, physical="<2 x i64>"); }
            return NativeLLVMType(mode=-1);
        }
        if (!aggregate) { return NativeLLVMType(); }
        let bytes = win64_register_bytes(layouts[index].size);
        if (bytes != 0) { return NativeLLVMType(mode=1, physical="i" + bytes * 8); }
        return NativeLLVMType(mode=-1);
    }
    if (program.target.starts_with("x86_64-")) {
        if (!aggregate) {
            if (type.kind == WirTypeKind.BoolType || ((type.kind == WirTypeKind.SignedInt || type.kind == WirTypeKind.UnsignedInt) && type.bits < 32)) {
                let attr = "zeroext";
                if (type.kind == WirTypeKind.SignedInt) { attr = "signext"; }
                return NativeLLVMType(attr=attr);
            }
            return NativeLLVMType();
        }
        let classified = x86_sysv_classify(ref program, type_id, layouts);
        if (classified.memory) {
            if result { return NativeLLVMType(mode=-1); }
            return NativeLLVMType(mode=-2);
        }
        let first = native_sysv_part(program, type_id, layouts, 0, classified.first == X86SysVClass.SSE);
        if (classified.count < 2) { return NativeLLVMType(mode=1, physical=first); }
        let second = native_sysv_part(program, type_id, layouts, 1, classified.second == X86SysVClass.SSE);
        return NativeLLVMType(mode=1, physical="{ " + first + ", " + second + " }");
    }
    if (!aggregate) { return NativeLLVMType(); }
    let hfa = a64_hfa_type(ref program, type_id, layouts);
    if (hfa.valid) {
        let base = "float";
        if (hfa.bits == 64) { base = "double"; }
        let attr = "";
        if (!result) { attr = "alignstack(8)"; }
        return NativeLLVMType(mode=1, physical="[" + hfa.count + " x " + base + "]", attr=attr);
    }
    let size = Int(layouts[index].size);
    if (size > 16) { return NativeLLVMType(mode=-1); }
    if (size <= 8) {
        let bits = 64;
        if result { bits = size * 8; }
        return NativeLLVMType(mode=1, physical="i" + bits);
    }
    if (layouts[index].alignment == 16) { return NativeLLVMType(mode=1, physical="i128"); }
    return NativeLLVMType(mode=1, physical="[2 x i64]");
}

func native_llvm_plan(program: WirModule, signature: WirType) -> NativeLLVMPlan {
    let native = signature.abi != WirABI.White && native_llvm_target(program.target);
    let layouts: Vector(WirTypeLayout) = [];
    if native { layouts = wir_type_layouts(program); }
    let result = NativeLLVMType();
    if native { result = native_llvm_classify(program, signature.abi, signature.result, layouts, true); }
    let params: Vector(NativeLLVMType) = [];
    let gp = 0;
    let fp = 0;
    if (result.mode < 0) { gp = 1; }
    let i = 0;
    while (i < signature.parameters.length()) {
        let id = signature.parameters[i];
        let param = NativeLLVMType();
        if native { param = native_llvm_classify(program, signature.abi, id, layouts, false); }
        if (native && program.target.starts_with("x86_64-") && !is_win64_target(program.target)) {
            // a SysV aggregate rolls back both register banks when either bank is full
            let classified = x86_sysv_classify(ref program, id, layouts);
            let ints = x86_sysv_class_count(classified, X86SysVClass.Integer);
            let floats = x86_sysv_class_count(classified, X86SysVClass.SSE);
            if (param.mode != -2 && (gp + ints > 6 || fp + floats > 8)) {
                let type = program.arena.types[wir_id_index(UInt32(id))];
                if (type.kind == WirTypeKind.Struct || type.kind == WirTypeKind.Array) { param = NativeLLVMType(mode=-2); }
            } else if (!classified.memory) {
                gp += ints;
                fp += floats;
            }
        }
        params.append(param);
        i++;
    }
    return NativeLLVMPlan(result=result, params=params);
}
