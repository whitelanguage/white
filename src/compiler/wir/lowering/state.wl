// src/compiler/wir/lowering/state.wl

import * from "../model.wl"
import * from "../../context.wl"


struct WirBinding(
    name: String,
    source_type: Int,
    address: WirValueID,
    is_const: Bool,
    is_const_access: Bool,
    owns_value: Bool,
    pending_init: Bool,
    is_reference: Bool
)

struct WirExpr(
    value: WirValueID,
    source_type: Int
)

struct WirLoop(
    continue_block: WirBlockID,
    break_block: WirBlockID,
    binding_count: Int
)

struct WirOwnedValue(
    value: WirValueID,
    source_type: Int
)

struct WirErrorTarget(
    block: WirBlockID,
    address: WirValueID,
    binding_count: Int,
    owned_count: Int
)

struct WirFunctionLowering(
    function: WirFuncID,
    return_type: Int,
    entry: WirBlockID,
    block: WirBlockID,
    bindings: Vector(WirBinding),
    binding_indices: Optional(Dict(String, Int)),
    indexed_bindings: Int,
    loops: Vector(WirLoop),
    error_targets: Vector(WirErrorTarget),
    owned_values: Vector(WirOwnedValue),
    errors: Vector(String),
    terminated: Bool,
    next_block: Int,
    reference_checked: Bool
)

func wir_local_index(ref state: WirFunctionLowering, name: String) -> Int {
// append-only scopes can extend the index, restoring a scope invalidates it
    if (state.binding_indices is null || state.indexed_bindings > state.bindings.length()) {
        state.binding_indices = Dict();
        state.indexed_bindings = 0;
    }
    let found = state.binding_indices;
    if (found is null) { return -1; }
    let indices: Dict(String, Int) = found;

    while (state.indexed_bindings < state.bindings.length()) {
        let index = state.indexed_bindings;
        indices.put(state.bindings[index].name, index + 1);
        state.indexed_bindings++;
    }
    let index = indices.lookup(name);
    if (index is !null) { return index - 1; }
    return -1;
}

func wir_no_expr() -> WirExpr {
    return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_POISON);
}

func wir_next_block_name(ref state: WirFunctionLowering, prefix: String) -> String {
    let name: String = prefix + state.next_block;
    state.next_block++;
    return name;
}
