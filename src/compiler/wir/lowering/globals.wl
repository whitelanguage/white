// compiler/wir/lowering/globals.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "types.wl"
import * from "static_data.wl"
import * from "../../context.wl"
import eval_const_bool, eval_const_float, eval_const_long, eval_const_wide from "../../constants.wl"
import * from "../../../frontend/ast.wl"
import * from "../../../frontend/arena.wl"

struct WirSourceGlobal(
    name: String,
    source_type: Int,
    is_const: Bool
)

func no_wir_source_global() -> WirSourceGlobal {
    return WirSourceGlobal(name="", source_type=TYPE_POISON, is_const=false);
}

func has_wir_source_global(global: WirSourceGlobal) -> Bool {
    return global.name.length() != 0 && global.source_type != TYPE_POISON;
}

func wir_record_numeric_constant(ref source: Compiler, node: VarDeclareNode, source_type: Int, name: String) -> Void {
    if (!node.is_const || !has_node(node.value)) { return; }
    let value_node: NodeID = node.value;
    if (node_tag(value_node) == NODE_CALL) {
        let call: CallNode = get_call_node(source.arena, value_node);
        let target: Int = wir_static_cast_target(ref source, call.callee);
        if (target != 0 && call.args is !null && call.args.length() == 1) {
            let argument: ArgNode = call.args[0];
            if ((argument.name is null || argument.name.length() == 0) && !argument.is_spread &&
                get_repr_type(ref source, target) == get_repr_type(ref source, source_type)) {
                value_node = argument.val;
            }
        }
    }
    let repr: Int = get_repr_type(ref source, source_type);
    if (repr == TYPE_FLOAT || repr == TYPE_FLOAT32) {
        let value: Float = eval_const_float(ref source, value_node, node.pos);
        if (repr == TYPE_FLOAT32) { value = Float(Float32(value)); }
        if (source.constant_nums is !null) { source.constant_nums.put(name, value); }
        return;
    }
    if (get_type_bitwidth(repr) == 128 && is_integer_type(repr)) {
        if (source.constant_wide_integers is !null) { source.constant_wide_integers.put(name, eval_const_wide(ref source, value_node, node.pos, is_unsigned_integer(repr))); }
        return;
    }
    if (is_integer_type(repr) || repr == TYPE_CHAR || repr == TYPE_BOOL) {
        let value: Long = 0L;
        if (repr == TYPE_BOOL) { value = Long(eval_const_bool(ref source, value_node, node.pos)); }
        else if (repr == TYPE_CHAR && node_tag(value_node) == NODE_CHAR) {
            value = Long(string_to_int(get_char_node(source.arena, value_node).tok.value, node.pos));
        }
        else { value = eval_const_long(ref source, value_node, node.pos); }
        if (source.constant_integers is !null) { source.constant_integers.put(name, value); }
        if (source.constant_nums is !null) { source.constant_nums.put(name, Float(value)); }
    }
}

func wir_source_global(ref source: Compiler, name: String) -> WirSourceGlobal {
    if (source.global_symbol_table is null) { return no_wir_source_global(); }

    let key: String = name;
    let info: SymbolInfo = SymbolInfo();
    if (source.current_package_prefix.length() != 0) {
        key = source.current_package_prefix + name;
        info = source.global_symbol_table.lookup(key);
    }
    if (!has_symbol(info)) {
        key = name;
        info = source.global_symbol_table.lookup(key);
    }
    if (!has_symbol(info) && source.current_file_global_aliases is !null) {
        let mapped: String = source.current_file_global_aliases.lookup(name);
        if (mapped is !null) {
            key = mapped;
            info = source.global_symbol_table.lookup(key);
        }
    }
    if (!has_symbol(info) && source.global_var_aliases is !null) {
        let mapped: String = source.global_var_aliases.lookup(name);
        if (mapped is !null) {
            key = mapped;
            info = source.global_symbol_table.lookup(key);
        }
    }
    if (!has_symbol(info)) { return no_wir_source_global(); }

    let wir_name: String = key;
    if (info.reg is !null && info.reg.starts_with("@")) { wir_name = info.reg.slice(1, info.reg.length()); }
    return WirSourceGlobal(name=wir_name, source_type=info.type, is_const=info.is_const);
}

func wir_find_global(program: WirModule, name: String) -> WirGlobalID {
    let i: Int = 0;
    while (i < program.arena.globals.length()) {
        if (program.arena.globals[i].name == name) { return WirGlobalID(UInt32(i + 1)); }
        i++;
    }
    return NO_WIR_GLOBAL;
}

func wir_global_initializer(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: VarDeclareNode, source_type: Int) -> WirValueID {
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (type_id == NO_WIR_TYPE) { return NO_WIR_VALUE; }
    let repr: Int = get_repr_type(ref source, source_type);

    if (!has_node(node.value)) {
        if (repr == TYPE_BOOL) { return wir_const_bool(ref program, false); }
        if (is_integer_type(repr) || repr == TYPE_CHAR) { return wir_const_int(ref program, type_id, UInt128(0U)); }
        if (repr == TYPE_FLOAT || repr == TYPE_FLOAT32) { return wir_const_float(ref program, type_id, 0.0); }
        if (is_pointer_type(ref source, source_type) || source_type == TYPE_ANYPTR) { return wir_null(ref program, type_id); }
        types.errors.append("Global '" + node.name_tok.value + "' needs an initializer that WIR can represent");
        return NO_WIR_VALUE;
    }

    let value: WirValueID = wir_lower_static_value(ref types, ref source, ref program, node.value, source_type, node.pos);
    if (value != NO_WIR_VALUE) { return value; }
    types.errors.append("Global '" + node.name_tok.value + "' does not have a WIR initializer yet");
    return NO_WIR_VALUE;
}

func wir_lower_global_decl(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, node: VarDeclareNode) -> WirGlobalID {
    let source_type: Int = resolve_type(ref source, node.type_node);
    if (source_type == TYPE_AUTO) { source_type = get_expr_type(ref source, node.value); }
    if (source_type == TYPE_AUTO || source_type == TYPE_POISON || source_type == TYPE_VOID) {
        types.errors.append("Cannot determine the type of global '" + node.name_tok.value + "'");
        return NO_WIR_GLOBAL;
    }

    let annotations: SystemAnnResult = consume_annotations(ref source, node.annotations, node.name_tok.value);
    if ((annotations.ann_flags & FLAG_ANN_INTRINSIC) != 0) {
        let source_name: String = source.current_package_prefix + node.name_tok.value;
        source.global_symbol_table.put(source_name, SymbolInfo(reg="$intrinsic." + annotations.intrinsic_name, type=source_type, origin_type=source_type, is_const=true));
        return NO_WIR_GLOBAL;
    }
    let name: String = source.current_package_prefix + node.name_tok.value;
    let linkage: WirLinkage = WirLinkage.Internal;
    if ((annotations.ann_flags & FLAG_ANN_EXPORT) != 0) {
        name = node.name_tok.value;
        linkage = WirLinkage.Exported;
    }

    let initializer: WirValueID = wir_global_initializer(ref types, ref source, ref program, node, source_type);
    if (initializer == NO_WIR_VALUE) { return NO_WIR_GLOBAL; }
    let type_id: WirTypeID = wir_lower_source_type(ref types, ref source, ref program, source_type);
    if (type_id == NO_WIR_TYPE) { return NO_WIR_GLOBAL; }
    let global_id: WirGlobalID = wir_add_global(ref program, name, type_id, initializer, linkage, node.is_const);
    if (source.is_shared && (annotations.ann_flags & FLAG_ANN_EXPORT) != 0) {
        program.arena.globals[wir_id_index(UInt32(global_id))].export_symbol = true;
    }
    let source_name: String = source.current_package_prefix + node.name_tok.value;
    let register_name: String = "@" + name;
    let symbol: SymbolInfo = SymbolInfo(reg=register_name, type=source_type, origin_type=source_type, is_const=node.is_const);
    update_symbol(ref source, source_name, symbol);
    wir_record_numeric_constant(ref source, node, source_type, register_name);
    return global_id;
}
