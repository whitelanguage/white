// Test: WIR_AGGREGATES
// File: tests/integration/tooling/test_wir_aggregates.wl
// Focus: Verifying typed field and fixed-array operations in the WIR model.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let point_type: WirTypeID = wir_struct_type(ref program, [i32_type, i32_type]);
    let array_type: WirTypeID = wir_array_type(ref program, i32_type, UIntSize(4U));
    let point_ptr: WirTypeID = wir_pointer_type(ref program, point_type);
    let array_ptr: WirTypeID = wir_pointer_type(ref program, array_type);
    let parameters: Vector(WirParam) = [
        wir_param("point", point_type),
        wir_param("point_ptr", point_ptr),
        wir_param("values", array_type),
        wir_param("values_ptr", array_ptr),
        wir_param("i", i32_type)
    ];
    let function_id: WirFuncID = wir_add_function(ref program, "aggregate_ops", parameters, i32_type, false, WirLinkage.Internal, WirABI.White);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let block: WirBlockID = wir_add_block(ref program, function_id, "entry", []);

    let x: WirValueID = wir_field(ref program, block, function.parameters[0], 0, "x", no_wir_location());
    let x_ptr: WirValueID = wir_field_address(ref program, block, function.parameters[1], 0, "x.addr", no_wir_location());
    let value: WirValueID = wir_index(ref program, block, function.parameters[2], function.parameters[4], "value", no_wir_location());
    let value_ptr: WirValueID = wir_index_address(ref program, block, function.parameters[3], function.parameters[4], "value.addr", no_wir_location());
    wir_store(ref program, block, x, x_ptr, no_wir_location());
    wir_store(ref program, block, value, value_ptr, no_wir_location());
    wir_return(ref program, block, x, no_wir_location());

    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: valid aggregate instructions were rejected: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: aggregate WIR could not be printed");
        return 1;
    }
    let expected: String = "type !t3 = {i32, i32}\n\ninternal func @aggregate_ops(%point:!t3, %point_ptr:ptr<!t3>, %values:[i32; 4], %values_ptr:ptr<[i32; 4]>, %i:i32) -> i32 {\n^entry:\n    %x:i32 = field %point, 0\n    %x.addr:ptr<i32> = field.addr %point_ptr, 0\n    %value:i32 = index %values, %i\n    %value.addr:ptr<i32> = index.addr %values_ptr, %i\n    store %x, %x.addr\n    store %value, %value.addr\n    ret %x\n}\n";
    if (text != expected) {
        print("FAIL: aggregate instruction text is not stable");
        print(text);
        return 1;
    }
    print("PASS: WIR aggregate operations");
    return 0;
}
