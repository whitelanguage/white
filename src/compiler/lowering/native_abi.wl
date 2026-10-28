// src/compiler/lowering/native_abi.wl
import * from "../context.wl"
import get_target_triple, get_target_pointer_bits from "../target.wl"
import * from "../abi/llvm.wl"
import WirTypeID, WirABI, wir_id_index from "../wir/model.wl"
import new_wir_module, wir_function_type, wir_pointer_type from "../wir/builder.wl"
import new_wir_type_map, wir_lower_source_type from "../wir/lowering/types.wl"
import PARAM_VALUE from "../../frontend/ast.wl"
import emit_pointer_null_check from "ownership.wl"
import no_position from "../../frontend/diagnostics.wl"


func native_llvm_function(info: FuncInfo) -> Bool {
    return info.abi_name.length() != 0 || (info.ann_flags & FLAG_ANN_EXPORT) != 0;
}

func native_source_plan(ref c: Compiler, info: FuncInfo) -> NativeLLVMPlan {
// only the type graph is needed here, no WIR bodies or source expressions are lowered
    let params: Vector(NativeLLVMType) = [];
    let i = 0;
    if (!native_llvm_function(info) || !native_llvm_target(get_target_triple())) {
        while (i < info.arg_types.length()) { params.append(NativeLLVMType()); i++; }
        return NativeLLVMPlan(result=NativeLLVMType(), params=params);
    }
    let program = new_wir_module(get_target_triple(), get_target_pointer_bits());
    let types = new_wir_type_map();
    let result = wir_lower_source_type(ref types, ref c, ref program, info.ret_type);
    let arguments: Vector(WirTypeID) = [];
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        let id = wir_lower_source_type(ref types, ref c, ref program, param.type);
        if (param.pass_mode != PARAM_VALUE) { id = wir_pointer_type(ref program, id); }
        arguments.append(id);
        i++;
    }
    let signature = wir_function_type(ref program, arguments, result, info.is_varargs, WirABI.C);
    return native_llvm_plan(program, program.arena.types[wir_id_index(UInt32(signature))]);
}

func native_llvm_result_mode(ref c: Compiler, info: FuncInfo) -> Int {
    if (!native_llvm_function(info) || !native_llvm_target(get_target_triple())) { return 0; }
    return native_source_plan(ref c, info).result.mode;
}

func native_llvm_result_type(ref c: Compiler, info: FuncInfo) -> String {
    if (!native_llvm_function(info) || !native_llvm_target(get_target_triple())) { return get_llvm_type_str(ref c, info.ret_type); }
    let shape: NativeLLVMType = native_source_plan(ref c, info).result;
    if (shape.mode < 0) { return "void"; }
    if (shape.mode > 0) { return shape.physical; }
    let type = get_llvm_type_str(ref c, info.ret_type);
    if (shape.attr.length() != 0) { type = shape.attr + " " + type; }
    return type;
}

func native_llvm_param_type(ref c: Compiler, info: FuncInfo, param: TypeListNode, index: Int = 0, attributes: Bool = true) -> String {
    let plan = native_source_plan(ref c, info);
    let shape: NativeLLVMType = plan.params[index];
    let type = param_llvm_type(ref c, param);
    if (shape.mode < 0) {
        type = get_llvm_type_str(ref c, param.type) + "*";
        if (shape.mode == -2 && attributes) {
            let alignment = get_type_align_bytes(ref c, param.type);
            if (alignment < 8) { alignment = 8; }
            type += " byval(" + get_llvm_type_str(ref c, param.type) + ") align " + alignment;
        }
    } else if (shape.mode > 0) { type = shape.physical; }
    if (attributes && shape.attr.length() != 0) { type += " " + shape.attr; }
    return type;
}

func native_llvm_slot(ref c: Compiler, type_id: Int) -> String {
// allocate the rounded coercion size, odd-sized records must not overrun their home
    let bytes = align_to(get_type_size_bytes(ref c, type_id), 16);
    if (bytes < 16) { bytes = 16; }
    let storage = next_reg(ref c);
    let slot = next_reg(ref c);
    let buffer = "[" + bytes + " x i8]";
    write_ir(ref c, c.indent + storage + " = alloca " + buffer + ", align 16\n");
    write_ir(ref c, c.indent + "store " + buffer + " zeroinitializer, " + buffer + "* " + storage + "\n");
    write_ir(ref c, c.indent + slot + " = bitcast " + buffer + "* " + storage + " to " + get_llvm_type_str(ref c, type_id) + "*\n");
    return slot;
}

func native_llvm_sret_type(ref c: Compiler, info: FuncInfo) -> String {
    let type = get_llvm_type_str(ref c, info.ret_type);
    return type + "* sret(" + type + ") align " + get_type_align_bytes(ref c, info.ret_type);
}

func native_llvm_params(ref c: Compiler, info: FuncInfo, attributes: Bool = true) -> String {
    let params: String = "";
    if (native_llvm_result_mode(ref c, info) < 0) {
        if attributes { params = native_llvm_sret_type(ref c, info); }
        else { params = get_llvm_type_str(ref c, info.ret_type) + "*"; }
    }
    let i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        if (params.length() != 0) { params += ", "; }
        params += native_llvm_param_type(ref c, info, param, i, attributes);
        i++;
    }
    if (info.is_varargs) {
        if (params.length() != 0) { params += ", "; }
        params += "...";
    }
    return params;
}

func emit_native_arg(ref c: Compiler, info: FuncInfo, param: TypeListNode, value: String, index: Int = 0) -> String {
    let plan = native_source_plan(ref c, info);
    let shape: NativeLLVMType = plan.params[index];
    let logical = param_llvm_type(ref c, param);
    let physical = native_llvm_param_type(ref c, info, param, index);
    if (shape.mode == 0) { return physical + " " + value; }
    let slot = native_llvm_slot(ref c, param.type);
    write_ir(ref c, c.indent + "store " + logical + " " + value + ", " + logical + "* " + slot + "\n");
    if (shape.mode < 0) { return physical + " " + slot; }
    let address = next_reg(ref c);
    let bits = next_reg(ref c);
    write_ir(ref c, c.indent + address + " = bitcast " + logical + "* " + slot + " to " + shape.physical + "*\n");
    write_ir(ref c, c.indent + bits + " = load " + shape.physical + ", " + shape.physical + "* " + address + "\n");
    return physical + " " + bits;
}

func emit_native_call(ref c: Compiler, info: FuncInfo, args: String, callconv: String) -> String {
// sret is part of the call signature, LLVM cannot infer Clang's C lowering
    let logical = get_llvm_type_str(ref c, info.ret_type);
    let physical = native_llvm_result_type(ref c, info);
    let mode = native_llvm_result_mode(ref c, info);
    let slot: String = "";
    if (mode < 0) {
        slot = native_llvm_slot(ref c, info.ret_type);
        let hidden = native_llvm_sret_type(ref c, info) + " " + slot;
        if (args.length() != 0) { hidden += ", " + args; }
        args = hidden;
    }
    let prefix = callconv + physical;
    if (info.is_varargs) { prefix += " (" + native_llvm_params(ref c, info, false) + ")"; }
    let result: String = "";
    if (physical != "void") { result = next_reg(ref c); }
    let assignment: String = "";
    if (result.length() != 0) { assignment = result + " = "; }
    write_ir(ref c, c.indent + assignment + "call " + prefix + " @" + info.name + "(" + args + ")\n");

    if (mode < 0) {
        result = next_reg(ref c);
        write_ir(ref c, c.indent + result + " = load " + logical + ", " + logical + "* " + slot + "\n");
    } else if (mode > 0) {
        slot = native_llvm_slot(ref c, info.ret_type);
        let address = next_reg(ref c);
        let decoded = next_reg(ref c);
        write_ir(ref c, c.indent + address + " = bitcast " + logical + "* " + slot + " to " + physical + "*\n");
        write_ir(ref c, c.indent + "store " + physical + " " + result + ", " + physical + "* " + address + "\n");
        write_ir(ref c, c.indent + decoded + " = load " + logical + ", " + logical + "* " + slot + "\n");
        result = decoded;
    }
    return result;
}

func native_export_body(info: FuncInfo) -> String {
    return "$export.body." + info.name;
}

func emit_native_export(ref c: Compiler, info: FuncInfo, linkage: String) -> Void {
// the source body keeps its White signature, this entry reconstructs C arguments
    let saved = c.reg_count;
    c.reg_count = 0;
    let params: String = "";
    let result_mode = native_llvm_result_mode(ref c, info);
    if (result_mode < 0) { params = native_llvm_sret_type(ref c, info) + " %result.addr"; }
    let i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        if (params.length() != 0) { params += ", "; }
        params += native_llvm_param_type(ref c, info, param, i) + " %native.arg" + i;
        i++;
    }
    write_ir(ref c, "define " + linkage + native_llvm_result_type(ref c, info) + " @" + info.name + "(" + params + ") {\nentry:\n");

    let args: String = "";
    i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        let type = param_llvm_type(ref c, param);
        let plan = native_source_plan(ref c, info);
        let shape: NativeLLVMType = plan.params[i];
        let mode = shape.mode;
        let value = "%native.arg" + i;
        if (mode != 0) {
            let slot = value;
            if (mode > 0) {
                slot = native_llvm_slot(ref c, param.type);
                let address = next_reg(ref c);
                write_ir(ref c, c.indent + address + " = bitcast " + type + "* " + slot + " to " + shape.physical + "*\n");
                write_ir(ref c, c.indent + "store " + shape.physical + " " + value + ", " + shape.physical + "* " + address + "\n");
            } else {
                emit_pointer_null_check(ref c, value, get_ptr_type_id(ref c, param.type), no_position());
            }
            value = next_reg(ref c);
            write_ir(ref c, c.indent + value + " = load " + type + ", " + type + "* " + slot + "\n");
        }
        if (args.length() != 0) { args += ", "; }
        args += type + " " + value;
        i++;
    }
    let logical = get_llvm_type_str(ref c, info.ret_type);
    let result = next_reg(ref c);
    if (info.ret_type == TYPE_VOID) {
        write_ir(ref c, c.indent + "call void @" + native_export_body(info) + "(" + args + ")\n");
        write_ir(ref c, c.indent + "ret void\n");
    } else {
        if (result_mode < 0) {
            emit_pointer_null_check(ref c, "%result.addr", get_ptr_type_id(ref c, info.ret_type), no_position());
        }
        write_ir(ref c, c.indent + result + " = call " + logical + " @" + native_export_body(info) + "(" + args + ")\n");
        if (result_mode < 0) {
            write_ir(ref c, c.indent + "store " + logical + " " + result + ", " + logical + "* %result.addr\n");
            write_ir(ref c, c.indent + "ret void\n");
        } else if (result_mode > 0) {
            let slot = native_llvm_slot(ref c, info.ret_type);
            let address = next_reg(ref c);
            let bits = next_reg(ref c);
            let physical = native_source_plan(ref c, info).result.physical;
            write_ir(ref c, c.indent + "store " + logical + " " + result + ", " + logical + "* " + slot + "\n");
            write_ir(ref c, c.indent + address + " = bitcast " + logical + "* " + slot + " to " + physical + "*\n");
            write_ir(ref c, c.indent + bits + " = load " + physical + ", " + physical + "* " + address + "\n");
            write_ir(ref c, c.indent + "ret " + physical + " " + bits + "\n");
        } else {
            write_ir(ref c, c.indent + "ret " + logical + " " + result + "\n");
        }
    }
    write_ir(ref c, "}\n\n");
    c.reg_count = saved;
}
