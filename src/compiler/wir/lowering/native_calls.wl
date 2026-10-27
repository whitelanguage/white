// src/compiler/wir/lowering/native_calls.wl
import * from "../model.wl"
import * from "../builder.wl"
import * from "state.wl"
import * from "types.wl"
import * from "ownership.wl"
import * from "declarations.wl"
import * from "../../context.wl"


func wir_native_callable(ref types: WirTypeMap, ref source: Compiler, ref program: WirModule, info: FuncInfo, target: WirFuncID) -> WirFuncID {
// the callable's code pointer must accept White arguments and return White ownership
    let native = program.arena.functions[wir_id_index(UInt32(target))];
    if (native.abi == WirABI.White) { return target; }

    let name = "$native." + info.abi_name + "." + info.name;
    let existing = wir_find_function(program, name);
    if (existing != NO_WIR_FUNC) { return existing; }

    let params: Vector(WirParam) = [];
    let i = 0;
    while (i < native.parameters.length()) {
        let param = program.arena.values[wir_id_index(UInt32(native.parameters[i]))];
        params.append(wir_param(param.name, param.type_id));
        i++;
    }
    let result_type = program.arena.types[wir_id_index(UInt32(native.type_id))].result;
    let wrapper = wir_add_function(ref program, name, params, result_type, false, WirLinkage.Internal, WirABI.White);
    let entry = wir_add_block(ref program, wrapper, "entry", []);
    let state = WirFunctionLowering(
        function=wrapper, return_type=info.ret_type, entry=entry, block=entry,
        bindings=[], binding_indices=null, indexed_bindings=0, loops=[],
        error_targets=[], owned_values=[], errors=[], terminated=false,
        next_block=0, reference_checked=false
    );
    let args = program.arena.functions[wir_id_index(UInt32(wrapper))].parameters;
    let result = wir_call(ref program, entry, wir_function_value(ref program, target), args, "", no_wir_location());
    let returns: Vector(WirValueID) = [];
    if (result != NO_WIR_VALUE) {
        if (info.abi_name.length() != 0) {
            wir_native_ref_check(ref state, ref source, ref program, result, info.ret_type);
            wir_emit_ownership_value(ref state, ref types, ref source, ref program, result, info.ret_type, true);
        }
        returns.append(result);
    }
    wir_append(ref program, state.block, WirOpcode.Return, program.void_type, returns, [], no_wir_location());
    i = 0;
    while (i < state.errors.length()) {
        types.errors.append(state.errors[i]);
        i++;
    }
    return wrapper;
}
