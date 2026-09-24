// Test: WIR_REACHABILITY
// File: tests/machine/x86_64/test_reachability.wl
// Focus: Keep transitive code and data references while dropping unused platform symbols.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import WirReachability, wir_reachable_symbols from "../../../src/compiler/wir/reachability.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let pointer_type: WirTypeID = wir_pointer_type(ref program, program.void_type);
    let dead_external: WirFuncID = wir_add_function(ref program, "unused_posix", [], int_type, false, WirLinkage.External, WirABI.C);
    let live_external: WirFuncID = wir_add_function(ref program, "WriteFile", [], int_type, false, WirLinkage.External, WirABI.System);
    let callback: WirFuncID = wir_add_function(ref program, "callback", [], int_type, false, WirLinkage.Internal, WirABI.White);
    let callback_entry: WirBlockID = wir_add_block(ref program, callback, "entry", []);
    wir_return(ref program, callback_entry, wir_const_int(ref program, int_type, UInt128(7U)), no_wir_location());

    let callback_address: WirValueID = wir_function_value(program, callback);
    let callback_pointer: WirValueID = wir_const_address(ref program, pointer_type, callback_address, 0L);
    let callback_global: WirGlobalID = wir_add_global(ref program, "callback.slot", pointer_type, callback_pointer, WirLinkage.Internal, true);

    let root: WirFuncID = wir_add_function(ref program, "main", [], int_type, false, WirLinkage.Exported, WirABI.White);
    let root_entry: WirBlockID = wir_add_block(ref program, root, "entry", []);
    wir_load(ref program, root_entry, wir_global_value(program, callback_global), "callback", no_wir_location());
    wir_call(ref program, root_entry, wir_function_value(program, live_external), [], "", no_wir_location());
    wir_return(ref program, root_entry, wir_const_int(ref program, int_type, UInt128(0U)), no_wir_location());

    let reachable: WirReachability = wir_reachable_symbols(program);
    if (!reachable.functions[wir_id_index(UInt32(root))] || !reachable.functions[wir_id_index(UInt32(callback))] || !reachable.functions[wir_id_index(UInt32(live_external))]) {
        print("FAIL: reachable WIR functions were removed");
        return 1;
    }
    if (reachable.functions[wir_id_index(UInt32(dead_external))] || !reachable.globals[wir_id_index(UInt32(callback_global))]) {
        print("FAIL: WIR reachability kept dead code or removed live data");
        return 1;
    }
    print("PASS: WIR symbol reachability");
    return 0;
}
