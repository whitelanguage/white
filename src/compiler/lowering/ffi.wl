// compiler/lowering/ffi.wl
import "sys"
import * from "../../frontend/ast.wl"
import * from "../../frontend/arena.wl"
import * from "../context.wl"
import * from "../../frontend/diagnostics.wl"
import * from "../target.wl"
import * from "../validation.wl"

func normalize_extern_abi(name: String, pos: Position) -> String {
    if (name == "C" || name == "c") { return "C"; }
    if (name == "system" || name == "System" || name == "SYSTEM") { return "system"; }
    throw_extern_error(pos, "Unsupported extern ABI '" + name + "'. Expected 'C' or 'system'.");
    return "C";
}
func extern_callconv(abi_name: String) -> String {
    if (abi_name == "system" && get_target_os() == sys.Os.Windows) {
        if (get_target_arch() == sys.Arch.X86) { return "x86_stdcallcc "; }
        if (get_target_arch() == sys.Arch.X86_64) { return "win64cc "; }
    }
    return "ccc ";
}
func func_callconv(info: FuncInfo) -> String {
    if (!has_func(info) || info.abi_name is null || info.abi_name.length() == 0) { return ""; }
    return extern_callconv(info.abi_name);
}
func register_extern_library(c: Compiler, name: String, pos: Position) -> Void {
    if (name is null || name.length() == 0) { return; }

    let i: Int = 0;
    while (i < name.length()) {
        let ch: Char = name[i];
        let valid: Bool = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                            (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' ||
                            ch == '+' || ch == '.';
        if (!valid) {
            throw_extern_error(pos, "Invalid extern library name '" + name + "'. Use a linker library name without paths or flags.");
            return;
        }
        i += 1;
    }

    i = 0;
    while (i < c.extra_libs.length()) {
        if (c.extra_libs[i] == name) { return; }
        i += 1;
    }
    c.extra_libs.append(name);
}

func backend_symbol_signature(name: String) -> String {
    if (get_target_os() != sys.Os.Windows) { return ""; }
    let size_ty: String = get_size_llvm_type();
    if (name == "memcpy" || name == "memmove") { return "ccc i8* (i8*, i8*, " + size_ty + ")"; }
    if (name == "memset") { return "ccc i8* (i8*, i32, " + size_ty + ")"; }
    return "";
}
func compile_extern_func(c: Compiler, node: ExternFuncNode) -> CompileResult {
    let func_name: String = node.name_tok.value;
    let abi_name: String = normalize_extern_abi(node.abi_name, node.pos);
    let ret_type_id: Int = resolve_type(c, node.ret_type_tok);
    if (ret_type_id == TYPE_AUTO) {
        throw_extern_error(node.pos, "Extern functions cannot use Auto as a return type.");
        return void_result();
    }
    if (node.is_varargs && abi_name != "C") {
        throw_extern_error(node.pos, "Variadic extern functions require the C ABI.");
        return void_result();
    }

    let arg_types: Vector(Struct) = [];
    let arg_names: Vector(String) = [];
    let params: Vector(ParamNode) = node.params;
    if (!check_duplicate_params(params, "extern function '" + func_name + "'", node.pos)) {
        return void_result();
    }
    let p_len: Int = 0; if (params is !null) { p_len = params.length(); }
    let p_idx: Int = 0;
    let params_str: String = "";

    while (p_idx < p_len) {
        let p: ParamNode = params[p_idx];
        let p_id: Int = resolve_type(c, p.type_tok);
        if (p_id == TYPE_AUTO) {
            throw_type_error(p.pos, "Extern functions cannot use Auto parameters.");
            return void_result();
        }

        arg_types.append(TypeListNode(type=p_id));
        arg_names.append(p.name_tok.value);
        if (p_idx > 0) { params_str += ", "; }
        params_str += get_llvm_type_str(c, p_id);
        p_idx += 1;
    }

    if (node.is_varargs) {
        if (p_len > 0) { params_str += ", "; }
        params_str += "...";
    }

    let full_func_name: String = func_name;
    if (c.current_package_prefix.length() > 0) { full_func_name = c.current_package_prefix + func_name; }

    let existing_func: FuncInfo = c.func_table.lookup(full_func_name);
    if (has_func(existing_func)) {
        throw_name_error(node.pos, "Function '" + full_func_name + "' is already defined.");
        return void_result();
    }

    let callconv: String = extern_callconv(abi_name);
    let ret_llvm: String = get_llvm_type_str(c, ret_type_id);
    let signature: String = callconv + ret_llvm + " (" + params_str + ")";
    let backend_signature: String = backend_symbol_signature(func_name);
    if (backend_signature.length() > 0 && signature != backend_signature) {
        throw_extern_error(node.pos, "Extern declaration for compiler-provided symbol '" + func_name + "' has an incompatible signature.");
        return void_result();
    }
    let existing_decl: StringConstant = c.declared_externs.lookup(func_name);
    if (!has_string_constant(existing_decl)) {
        if (backend_signature.length() == 0) { c.output_file.write("declare " + callconv + ret_llvm + " @" + func_name + "(" + params_str + ")\n"); }
        c.declared_externs.put(func_name, StringConstant(id=0, value=signature));
    } else if (existing_decl.value.length() > 0 && existing_decl.value != signature) {
        throw_extern_error(node.pos, "Conflicting extern declaration for symbol '" + func_name + "'.");
        return void_result();
    }

    c.func_table.put(full_func_name, FuncInfo(name=func_name, base_name=func_name, ret_type=ret_type_id, arg_types=arg_types, arg_names=arg_names, is_varargs=node.is_varargs, abi_name=abi_name, mutates_self=false));
    register_extern_library(c, node.link_name, node.pos);
    return void_result();
}
func compile_extern_block(c: Compiler, node: ExternBlockNode) -> CompileResult {
    let funcs: Vector(NodeID) = node.funcs;
    let len: Int = 0; if (funcs is !null) { len = funcs.length(); }
    let i: Int = 0;
    while (i < len) {
        let f_node: ExternFuncNode = get_extern_func_node(c.arena, funcs[i]);
        compile_extern_func(c, f_node);
        i += 1;
    }
    return void_result();
}


