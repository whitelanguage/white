// src/compiler/lowering/native_abi.wl
import * from "../context.wl"
import get_target_triple from "../target.wl"
import is_win64_target, win64_register_bytes from "../native_abi.wl"
import PARAM_VALUE from "../../frontend/ast.wl"
import emit_pointer_null_check from "ownership.wl"
import no_position from "../../frontend/diagnostics.wl"


func native_llvm_function(info: FuncInfo) -> Bool {
    return info.abi_name.length() != 0 || (info.ann_flags & FLAG_ANN_EXPORT) != 0;
}

func native_llvm_aggregate(ref c: Compiler, type_id: Int) -> Bool {
    let type = get_repr_type(ref c, type_id);
    if (type == TYPE_ANY_ERROR || is_union_type(ref c, type) || is_fallible_type(ref c, type)) {
        return true;
    }
    if (type < 100) { return false; }
    let array = c.array_info_map.lookup(type);
    if (array is !null) { return array.size >= 0; }
    let record = c.struct_id_map.lookup(type);
    return record is !null && !record.is_class && !record.is_enum;
}

func native_llvm_mode(ref c: Compiler, info: FuncInfo, type_id: Int) -> Int {
// 0 keeps the source LLVM type, positive values are integer coercion widths,
// -1 passes caller-owned storage. White's implementation ABI is unchanged.
    if (!native_llvm_function(info) || !is_win64_target(get_target_triple()) || !native_llvm_aggregate(ref c, type_id)) {
        return 0;
    }
    let bytes = win64_register_bytes(UInt64(get_type_size_bytes(ref c, type_id)));
    if (bytes != 0) { return bytes * 8; }
    return -1;
}

func native_llvm_arg_mode(ref c: Compiler, info: FuncInfo, param: TypeListNode) -> Int {
    if (param.pass_mode != PARAM_VALUE) { return 0; }
    return native_llvm_mode(ref c, info, param.type);
}

func native_llvm_result_type(ref c: Compiler, info: FuncInfo) -> String {
    let mode = native_llvm_mode(ref c, info, info.ret_type);
    if (mode < 0) { return "void"; }
    if (mode > 0) { return "i" + mode; }
    return get_llvm_type_str(ref c, info.ret_type);
}

func native_llvm_param_type(ref c: Compiler, info: FuncInfo, param: TypeListNode) -> String {
    let mode = native_llvm_arg_mode(ref c, info, param);
    if (mode < 0) { return get_llvm_type_str(ref c, param.type) + "*"; }
    if (mode > 0) { return "i" + mode; }
    return param_llvm_type(ref c, param);
}

func native_llvm_sret_type(ref c: Compiler, info: FuncInfo) -> String {
    let type = get_llvm_type_str(ref c, info.ret_type);
    return type + "* sret(" + type + ") align " + get_type_align_bytes(ref c, info.ret_type);
}

func native_llvm_params(ref c: Compiler, info: FuncInfo, attributes: Bool = true) -> String {
    let params: String = "";
    if (native_llvm_mode(ref c, info, info.ret_type) < 0) {
        if attributes { params = native_llvm_sret_type(ref c, info); }
        else { params = get_llvm_type_str(ref c, info.ret_type) + "*"; }
    }
    let i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        if (params.length() != 0) { params += ", "; }
        params += native_llvm_param_type(ref c, info, param);
        i++;
    }
    if (info.is_varargs) {
        if (params.length() != 0) { params += ", "; }
        params += "...";
    }
    return params;
}

func emit_native_arg(ref c: Compiler, info: FuncInfo, param: TypeListNode, value: String) -> String {
    let mode = native_llvm_arg_mode(ref c, info, param);
    let logical = param_llvm_type(ref c, param);
    if (mode == 0) { return logical + " " + value; }

    let slot = next_reg(ref c);
    write_ir(ref c, c.indent + slot + " = alloca " + logical + ", align 16\n");
    write_ir(ref c, c.indent + "store " + logical + " " + value + ", " + logical + "* " + slot + "\n");
    if (mode < 0) { return logical + "* " + slot; }

    let physical = "i" + mode;
    let address = next_reg(ref c);
    let bits = next_reg(ref c);
    write_ir(ref c, c.indent + address + " = bitcast " + logical + "* " + slot + " to " + physical + "*\n");
    write_ir(ref c, c.indent + bits + " = load " + physical + ", " + physical + "* " + address + "\n");
    return physical + " " + bits;
}

func emit_native_call(ref c: Compiler, info: FuncInfo, args: String, callconv: String) -> String {
// sret is part of the call signature, LLVM cannot infer Clang's C lowering
    let logical = get_llvm_type_str(ref c, info.ret_type);
    let physical = native_llvm_result_type(ref c, info);
    let mode = native_llvm_mode(ref c, info, info.ret_type);
    let slot: String = "";
    if (mode < 0) {
        slot = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + logical + ", align 16\n");
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
        slot = next_reg(ref c);
        let address = next_reg(ref c);
        let decoded = next_reg(ref c);
        write_ir(ref c, c.indent + slot + " = alloca " + logical + ", align 16\n");
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
    let result_mode = native_llvm_mode(ref c, info, info.ret_type);
    if (result_mode < 0) { params = native_llvm_sret_type(ref c, info) + " %result.addr"; }
    let i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        if (params.length() != 0) { params += ", "; }
        params += native_llvm_param_type(ref c, info, param) + " %native.arg" + i;
        i++;
    }
    write_ir(ref c, "define " + linkage + native_llvm_result_type(ref c, info) + " @" + info.name + "(" + params + ") {\nentry:\n");

    let args: String = "";
    i = 0;
    while (i < info.arg_types.length()) {
        let param: TypeListNode = info.arg_types[i];
        let type = param_llvm_type(ref c, param);
        let mode = native_llvm_arg_mode(ref c, info, param);
        let value = "%native.arg" + i;
        if (mode != 0) {
            let slot = value;
            if (mode > 0) {
                slot = next_reg(ref c);
                let address = next_reg(ref c);
                write_ir(ref c, c.indent + slot + " = alloca " + type + ", align 16\n");
                write_ir(ref c, c.indent + address + " = bitcast " + type + "* " + slot + " to i" + mode + "*\n");
                write_ir(ref c, c.indent + "store i" + mode + " " + value + ", i" + mode + "* " + address + "\n");
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
            let slot = next_reg(ref c);
            let address = next_reg(ref c);
            let bits = next_reg(ref c);
            let physical = "i" + result_mode;
            write_ir(ref c, c.indent + slot + " = alloca " + logical + ", align 16\n");
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
