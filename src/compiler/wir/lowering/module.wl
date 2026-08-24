// compiler/wir/lowering/module.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "../verify.wl"
import * from "types.wl"
import * from "declarations.wl"
import * from "globals.wl"
import * from "functions.wl"
import * from "../../context.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"

struct WirLoweringResult(
    program: WirModule,
    errors: Vector(String)
)

func wir_definition_info(ref source: Compiler, node: FunctionDefNode) -> FuncInfo {
    let key: String = node.name_tok.value;
    if (key != "main") { key = source.current_package_prefix + key; }
    return source.func_table.lookup(key);
}

func wir_extern_info(ref source: Compiler, node: ExternFuncNode) -> FuncInfo {
    let key: String = source.current_package_prefix + node.name_tok.value;
    let info: FuncInfo = source.func_table.lookup(key);
    if (!has_func(info)) { info = source.func_table.lookup(node.name_tok.value); }
    return info;
}

func wir_declare_extern(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: ExternFuncNode) -> Void {
    let info: FuncInfo = wir_extern_info(ref source, node);
    if (!has_func(info)) {
        types.errors.append("Extern function '" + node.name_tok.value + "' was not registered before WIR lowering");
        return;
    }
    wir_lower_function_decl(ref types, ref source, ref program, info);
}

func wir_declare_root_functions(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, root: BlockNode) -> Void {
    let i: Int = 0;
    while (i < root.stmts.length()) {
        let node: NodeID = root.stmts[i];
        let kind: Int = node_tag(node);
        if (kind == NODE_FUNC_DEF) {
            let definition: FunctionDefNode = get_func_def_node(source.arena, node);
            if (definition.type_params is null || definition.type_params.length() == 0) {
                let info: FuncInfo = wir_definition_info(ref source, definition);
                if (!has_func(info)) {
                    types.errors.append("Function '" + definition.name_tok.value + "' was not registered before WIR lowering");
                } else {
                    wir_lower_function_decl(ref types, ref source, ref program, info);
                }
            }
        } else if (kind == NODE_EXTERN_FUNC) {
            wir_declare_extern(ref types, ref source, ref program, get_extern_func_node(source.arena, node));
        } else if (kind == NODE_EXTERN_BLOCK) {
            let block: ExternBlockNode = get_extern_block_node(source.arena, node);
            let function_index: Int = 0;
            while (function_index < block.funcs.length()) {
                wir_declare_extern(ref types, ref source, ref program, get_extern_func_node(source.arena, block.funcs[function_index]));
                function_index++;
            }
        }
        i++;
    }
}

func wir_lower_root_items(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, root: BlockNode) -> Void {
    let i: Int = 0;
    while (i < root.stmts.length()) {
        let node: NodeID = root.stmts[i];
        let kind: Int = node_tag(node);
        if (kind == NODE_VAR_DECL) {
            wir_lower_global_decl(ref types, ref source, ref program, get_var_decl_node(source.arena, node));
        } else if (kind == NODE_FUNC_DEF) {
            let definition: FunctionDefNode = get_func_def_node(source.arena, node);
            if (definition.type_params is null || definition.type_params.length() == 0) {
                let info: FuncInfo = wir_definition_info(ref source, definition);
                if (has_func(info) && (info.ann_flags & FLAG_ANN_INTRINSIC) == 0) {
                    wir_lower_function_body(ref types, ref source, ref program, info, definition.body);
                }
            }
        }
        i++;
    }
}

func wir_lower_module(ref source: Compiler, root_node: NodeID, target: String, pointer_bits: Int) -> WirLoweringResult {
    let program: WirModule = new_wir_module(target, pointer_bits);
    let types: WirTypeMap = new_wir_type_map();
    if (!has_node(root_node) || node_tag(root_node) != NODE_BLOCK) {
        types.errors.append("WIR module root is not a block");
        return WirLoweringResult(program=program, errors=types.errors);
    }

    let root: BlockNode = get_block_node(source.arena, root_node);
    wir_declare_root_functions(ref types, ref source, ref program, root);
    wir_lower_root_items(ref types, ref source, ref program, root);
    if (types.errors.length() == 0) {
        let verify_errors: Vector(String) = verify_wir(program);
        let i: Int = 0;
        while (i < verify_errors.length()) {
            types.errors.append(verify_errors[i]);
            i++;
        }
    }
    return WirLoweringResult(program=program, errors=types.errors);
}
