// Test: WIR_BINDING_INDEX
// File: tests/integration/tooling/test_wir_bindings.wl
// Focus: Local name indexing through shadowing and restored catch scopes.

import * from "../../../src/compiler/wir/lowering/state.wl"
import wir_restore_bindings from "../../../src/compiler/wir/lowering/functions.wl"
import WirFuncID, WirBlockID, WirValueID from "../../../src/compiler/wir/model.wl"


func main() -> Int {
    let state = WirFunctionLowering(bindings=[], function=WirFuncID(0U), return_type=0, entry=WirBlockID(0U), block=WirBlockID(0U), binding_indices=null, indexed_bindings=0, loops=[], error_targets=[], owned_values=[], errors=[], terminated=false, next_block=0, reference_checked=false);
    state.bindings.append(WirBinding(name="outer", source_type=0, address=WirValueID(0U), is_const=false, is_const_access=false, owns_value=false, pending_init=false, is_reference=false));
    state.bindings.append(WirBinding(name="kept", source_type=0, address=WirValueID(0U), is_const=false, is_const_access=false, owns_value=false, pending_init=false, is_reference=false));
    if (wir_local_index(ref state, "outer") != 0 || wir_local_index(ref state, "missing") != -1) {
        print("FAIL: local name index missed a binding");
        return 1;
    }
    state.bindings.append(WirBinding(name="outer", source_type=0, address=WirValueID(0U), is_const=false, is_const_access=false, owns_value=false, pending_init=false, is_reference=false));
    if (wir_local_index(ref state, "outer") != 2) {
        print("FAIL: local name index lost a shadowing declaration");
        return 1;
    }
    wir_restore_bindings(ref state, 2);
    state.bindings.append(WirBinding(name="catch_value", source_type=0, address=WirValueID(0U), is_const=false, is_const_access=false, owns_value=false, pending_init=false, is_reference=false));
    if (wir_local_index(ref state, "outer") != 0 || wir_local_index(ref state, "catch_value") != 2 ||
        wir_local_index(ref state, "kept") != 1) {
        print("FAIL: a restored scope kept stale local indices");
        return 1;
    }
    wir_restore_bindings(ref state, 0);
    if (wir_local_index(ref state, "outer") != -1 || wir_local_index(ref state, "catch_value") != -1) {
        print("FAIL: an exited scope retained a name");
        return 1;
    }
    print("PASS: WIR local binding index");
    return 0;
}
