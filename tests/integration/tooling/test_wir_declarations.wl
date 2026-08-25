// Test: WIR_DECLARATIONS
// File: tests/integration/tooling/test_wir_declarations.wl
// Focus: Lowering resolved function signatures, linkage and ABI to WIR.

import * from "../../../src/compiler/context.wl"
import PARAM_VALUE, PARAM_REF from "../../../src/frontend/ast.wl"
import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/print.wl"
import * from "../../../src/compiler/wir/lowering/types.wl"
import * from "../../../src/compiler/wir/lowering/declarations.wl"

func main() -> Int {
    let source: Compiler = Compiler(ptr_base_map=Dict());
    source.ptr_base_map.put("100", SymbolInfo(reg="", type=TYPE_BYTE));
    let program: WirModule = new_wir_module("i686-pc-windows-msvc", 32);
    let types: WirTypeMap = new_wir_type_map();

    let write_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE), TypeListNode(type=100, pass_mode=PARAM_VALUE), TypeListNode(type=TYPE_UINTSIZE, pass_mode=PARAM_VALUE)];
    let write: FuncInfo = FuncInfo(name="write", base_name="write", ret_type=TYPE_INT, arg_types=write_args, arg_names=["fd", "data", "length"], is_varargs=false, abi_name="C");
    wir_lower_function_decl(ref types, ref source, ref program, write);

    let handle_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_VALUE)];
    let handle: FuncInfo = FuncInfo(name="GetStdHandle", base_name="GetStdHandle", ret_type=TYPE_ANYPTR, arg_types=handle_args, arg_names=["kind"], is_varargs=false, abi_name="system");
    wir_lower_function_decl(ref types, ref source, ref program, handle);

    let printf_args: Vector(Struct) = [TypeListNode(type=100, pass_mode=PARAM_VALUE)];
    let printf: FuncInfo = FuncInfo(name="printf", base_name="printf", ret_type=TYPE_INT, arg_types=printf_args, arg_names=["format"], is_varargs=true, abi_name="C");
    wir_lower_function_decl(ref types, ref source, ref program, printf);

    let touch_args: Vector(Struct) = [TypeListNode(type=TYPE_INT, pass_mode=PARAM_REF)];
    let touch: FuncInfo = FuncInfo(name="touch", base_name="touch", ret_type=TYPE_VOID, arg_types=touch_args, arg_names=["value"], is_varargs=false, abi_name="");
    let touch_id: WirFuncID = wir_lower_function_decl(ref types, ref source, ref program, touch);
    let touch_entry: WirBlockID = wir_add_block(ref program, touch_id, "entry", []);
    wir_append(ref program, touch_entry, WirOpcode.Return, program.void_type, [], [], no_wir_location());

    let main_info: FuncInfo = FuncInfo(name="main", base_name="main", ret_type=TYPE_INT, arg_types=[], arg_names=[], is_varargs=false, ann_flags=FLAG_ANN_EXPORT, abi_name="");
    let main_id: WirFuncID = wir_lower_function_decl(ref types, ref source, ref program, main_info);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let zero: WirValueID = wir_const_int(ref program, wir_signed_int_type(ref program, 32), UInt128(0U));
    wir_append(ref program, main_entry, WirOpcode.Return, program.void_type, [zero], [], no_wir_location());

    if (types.errors.length() != 0) {
        print("FAIL: valid White declarations were rejected");
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) {
        print("FAIL: lowered declarations produced invalid WIR: ", errors[0]);
        return 1;
    }

    let text: String = print_wir(program)?;
    catch(err) {
        print("FAIL: lowered declarations could not be printed");
        return 1;
    }
    let expected: String = "extern c func @write(i32, ptr<u8>, u32) -> i32\n\nextern system func @GetStdHandle(i32) -> ptr<void>\n\nextern c func @printf(ptr<u8>, ...) -> i32\n\ninternal func @touch(%value:ptr<i32>) -> void {\n^entry:\n    ret\n}\n\npub func @main() -> i32 {\n^entry:\n    ret 0\n}\n";
    if (text != expected) {
        print("FAIL: lowered declaration text is not stable");
        print(text);
        return 1;
    }

    print("PASS: WIR declarations");
    return 0;
}
