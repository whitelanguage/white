// src/compiler/externs.wl
import * from "../frontend/ast.wl"
import * from "../frontend/arena.wl"
import * from "../frontend/diagnostics.wl"
import * from "context.wl"
import check_duplicate_params, register_extern_library from "validation.wl"


func normalize_extern_abi(name: String, pos: Position) -> String {
    if (name == "C" || name == "c") { return "C"; }
    if (name == "system" || name == "System" || name == "SYSTEM") { return "system"; }
    throw_extern_error(pos, "Unsupported extern ABI '" + name + "'. Expected 'C' or 'system'.");
    return "C";
}

func register_extern(ref c: Compiler, node: ExternFuncNode) -> Void {
// imports need the source name before any backend declares the native symbol
    let name = c.current_package_prefix + node.name_tok.value;
    if (c.func_table.contains_key(name) || c.generic_funcs.contains_key(name)) {
        throw_name_error(node.pos, "Function '" + name + "' is already defined.");
        return;
    }

    let abi = normalize_extern_abi(node.abi_name, node.pos);
    if (node.is_varargs && abi != "C") {
        throw_extern_error(node.pos, "Variadic extern functions require the C ABI.");
        return;
    }
    let result = resolve_type(ref c, node.ret_type_tok);
    if (result == TYPE_POISON) { return; }
    if (result == TYPE_AUTO) {
        throw_extern_error(node.pos, "Extern functions cannot use Auto as a return type.");
        return;
    }
    if (!check_duplicate_params(node.params, "extern function '" + node.name_tok.value + "'", node.pos)) {
        return;
    }

    let types: Vector(Struct) = [];
    let names: Vector(String) = [];
    let i = 0;
    while (i < node.params.length()) {
        let param = node.params[i];
        if (param.pass_mode == PARAM_REF) {
            throw_extern_error(param.pos, "Extern functions cannot use reference parameters; declare a pointer parameter instead.");
            return;
        }
        let type = resolve_type(ref c, param.type_tok);
        if (type == TYPE_POISON) { return; }
        if (type == TYPE_AUTO) {
            throw_type_error(param.pos, "Extern functions cannot use Auto parameters.");
            return;
        }
        if (get_repr_type(ref c, type) == TYPE_VOID) {
            throw_type_error(param.pos, "Extern parameters cannot have type Void.");
            return;
        }
        types.append(TypeListNode(type=type, pass_mode=PARAM_VALUE));
        names.append(param.name_tok.value);
        i++;
    }

    c.func_table.put(name, FuncInfo(name=node.name_tok.value, base_name=node.name_tok.value,
        ret_type=result, arg_types=types, arg_names=names, is_varargs=node.is_varargs,
        abi_name=abi, mutates_self=false, ann_flags=0, compiler_link_name="",
        variadic_param=0, default_args=[], ref_body=NodeID(0U), ref_context=null, ref_bindings=null));
    register_extern_library(ref c, node.link_name, node.pos);
    if (node.link_name.length() != 0) {
        c.extern_libraries.append(ExternLibrary(symbol=node.name_tok.value, library=node.link_name));
    }
}

func register_extern_block(ref c: Compiler, node: ExternBlockNode) -> Void {
    let i = 0;
    while (i < node.funcs.length()) {
        register_extern(ref c, get_extern_func_node(ref c.arena, node.funcs[i]));
        i++;
    }
}
