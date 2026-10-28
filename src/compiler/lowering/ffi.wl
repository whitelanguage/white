// src/compiler/lowering/ffi.wl
import "sys"
import * from "../../frontend/ast.wl"
import * from "../../frontend/arena.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"
import * from "../validation.wl"
import * from "ownership.wl"
import emit_native_value_check from "native_values.wl"
import * from "native_abi.wl"
import native_llvm_target from "../abi/llvm.wl"


func extern_callconv(abi_name: String) -> String {
    if (abi_name == "system" && get_target_os() == sys.Os.Windows) {
        if (get_target_arch() == sys.Arch.X86) {
            return "x86_stdcallcc ";
        }
        if (get_target_arch() == sys.Arch.X86_64) { return "win64cc "; }
    }
    return "ccc ";
}
func func_callconv(info: FuncInfo) -> String {
    if (!has_func(info) || info.abi_name.length() == 0) {
        return "";
    }
    return extern_callconv(info.abi_name);
}
func backend_symbol_signature(name: String) -> String {
    if (get_target_os() != sys.Os.Windows) {
        return "";
    }
    let size_ty: String = get_size_llvm_type();
    if (name == "memcpy" || name == "memmove") {
        return "ccc i8* (i8*, i8*, " + size_ty + ")";
    }
    if (name == "memset") {
        return "ccc i8* (i8*, i32, " + size_ty + ")";
    }
    return "";
}
func compile_extern_func(ref c: Compiler, node: ExternFuncNode) -> CompileResult {
    let func_name: String = node.name_tok.value;
    let full_func_name = c.current_package_prefix + func_name;
    let info: Optional(FuncInfo) = c.func_table.lookup(full_func_name);
    if (info is null) { return void_result(); }
    let meta: FuncInfo = info;
    let abi_name = meta.abi_name;
    let params_str = native_llvm_params(ref c, meta);
    let callconv: String = extern_callconv(abi_name);
    let ret_llvm = native_llvm_result_type(ref c, meta);
    let signature: String = callconv + ret_llvm + " (" + params_str + ")";
    let backend_signature: String = backend_symbol_signature(func_name);
    if (backend_signature.length() > 0 && signature != backend_signature) {
        throw_extern_error(node.pos, "Extern declaration for compiler-provided symbol '" + func_name + "' has an incompatible signature.");
        return void_result();
    }
    let existing_decl: Optional(StringConstant) = c.declared_externs.lookup(func_name);
    if (!(existing_decl is !null)) {
        if (backend_signature.length() == 0) {
            write_ir(ref c, "declare " + callconv + ret_llvm + " @" + func_name + "(" + params_str + ")\n");
        }
        c.declared_externs.put(func_name, StringConstant(id=0, value=signature));
    } else if (existing_decl.value.length() > 0 && existing_decl.value != signature) {
        throw_extern_error(node.pos, "Conflicting extern declaration for symbol '" + func_name + "'.");
        return void_result();
    }

    return void_result();
}
func compile_extern_block(ref c: Compiler, node: ExternBlockNode) -> CompileResult {
    let funcs: Vector(NodeID) = node.funcs;
    let len: Int = funcs.length();
    let i: Int = 0;
    while (i < len) {
        let f_node: ExternFuncNode = get_extern_func_node(ref c.arena, funcs[i]);
        compile_extern_func(ref c, f_node);
        i += 1;
    }
    return void_result();
}

func native_callable_name(ref c: Compiler, info: FuncInfo) -> String {
// a Function value uses White's calling convention and returns an owned result
    if (info.abi_name.length() == 0 &&
        ((info.ann_flags & FLAG_ANN_EXPORT) == 0 || !native_llvm_target(get_target_triple()))) {
        return info.name;
    }
    let name = "$native." + info.abi_name + "." + info.name;
    if (info.abi_name.length() == 0) { name = "$native.export." + info.name; }
    if (!c.native_adapters.contains_key(name)) {
        c.native_adapters.put(name, info);
    }
    return name;
}

func emit_native_adapters(ref c: Compiler) -> Void {
// emitting after source bodies keeps wrapper definitions out of the active function
    let saved_reg = c.reg_count;
    let saved_indent = c.indent;
    c.indent = "  ";

    let i = 0;
    while (i < c.native_adapters.capacity) {
        if (c.native_adapters.hashes[i] < 2) {
            i++;
            continue;
        }
        let name = c.native_adapters.keys[i];
        let info: FuncInfo = c.native_adapters.values[i];
        let params: String = "";
        let arg_idx = 0;
        while (arg_idx < info.arg_types.length()) {
            let param: TypeListNode = info.arg_types[arg_idx];
            let type = param_llvm_type(ref c, param);
            if (arg_idx != 0) {
                params += ", ";
            }
            let arg = type + " %arg" + arg_idx;
            params += arg;
            arg_idx++;
        }

        c.reg_count = 0;
        let result_type = get_llvm_type_str(ref c, info.ret_type);
        write_ir(ref c, "define internal " + result_type + " @" + name + "(" + params + ") {\nentry:\n");
        let args: String = "";
        arg_idx = 0;
        while (arg_idx < info.arg_types.length()) {
            let param: TypeListNode = info.arg_types[arg_idx];
            if (arg_idx != 0) { args += ", "; }
            args += emit_native_arg(ref c, info, param, "%arg" + arg_idx, arg_idx);
            arg_idx++;
        }
        let result = emit_native_call(ref c, info, args, func_callconv(info));
        if (info.ret_type == TYPE_VOID) {
            write_ir(ref c, c.indent + "ret void\n}\n\n");
        } else {
            if (info.abi_name.length() != 0) {
                emit_native_value_check(ref c, result, info.ret_type, no_position());
                emit_retain_value(ref c, result, info.ret_type);
            }
            write_ir(ref c, c.indent + "ret " + result_type + " " + result + "\n}\n\n");
        }
        i++;
    }

    c.reg_count = saved_reg;
    c.indent = saved_indent;
}
