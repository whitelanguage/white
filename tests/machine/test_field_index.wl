// Test: FIELD_INDEX
// File: tests/machine/test_field_index.wl
// Focus: Rejecting a WIR field index outside the compiler's Int range.

import * from "../../src/compiler/wir/model.wl"
import * from "../../src/compiler/wir/builder.wl"
import verify_wir from "../../src/compiler/wir/verify.wl"


func main() -> Int {
    let program = new_wir_module("x86_64-pc-windows-msvc", 64);
    let int = wir_signed_int_type(ref program, 32);
    let wide = wir_unsigned_int_type(ref program, 64);
    let record = wir_struct_type(ref program, [int]);
    let value = wir_const_int(ref program, int, UInt128(1U));
    let aggregate = wir_const_aggregate(ref program, record, [value]);
    let index = wir_const_int(ref program, wide, UInt128(4294967296UL));
    let function = wir_add_function(ref program, "main", [], int, false, WirLinkage.Exported, WirABI.White);
    let entry = wir_add_block(ref program, function, "entry", []);
    let field = wir_append(ref program, entry, WirOpcode.Field, int, [aggregate, index], [], no_wir_location());
    wir_return(ref program, entry, field, no_wir_location());

    let errors = verify_wir(program);
    if (errors.length() == 0) {
        print("FAIL: oversized field index accepted");
        return 1;
    }
    print("PASS: WIR field index range");
    return 0;
}
