// compiler/wir/lowering/state.wl

import * from "../model.wl"
import * from "../../context.wl"

struct WirBinding(
    name: String,
    source_type: Int,
    address: WirValueID,
    is_const: Bool,
    owns_value: Bool
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
    loops: Vector(WirLoop),
    error_targets: Vector(WirErrorTarget),
    owned_values: Vector(WirOwnedValue),
    errors: Vector(String),
    terminated: Bool,
    next_block: Int
)

func wir_no_expr() -> WirExpr {
    return WirExpr(value=NO_WIR_VALUE, source_type=TYPE_POISON);
}

func wir_next_block_name(ref state: WirFunctionLowering, prefix: String) -> String {
    let name: String = prefix + state.next_block;
    state.next_block++;
    return name;
}
