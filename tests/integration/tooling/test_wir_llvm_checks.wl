// Test: WIR_LLVM_CHECKS
// File: tests/integration/tooling/test_wir_llvm_checks.wl
// Focus: Lowering null and bounds checks without a C runtime dependency.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let i32_type: WirTypeID = wir_signed_int_type(ref program, 32);
    let main_id: WirFuncID = wir_add_function(ref program, "main", [], i32_type, false, WirLinkage.Exported, WirABI.White);
    let main_entry: WirBlockID = wir_add_block(ref program, main_id, "entry", []);
    let address: WirValueID = wir_stack_alloc(ref program, main_entry, i32_type, "address", no_wir_location());
    wir_append(ref program, main_entry, WirOpcode.NullCheck, program.void_type, [address], [], no_wir_location());
    let index: WirValueID = wir_const_int(ref program, i32_type, UInt128(1U));
    let length: WirValueID = wir_const_int(ref program, i32_type, UInt128(2U));
    wir_append(ref program, main_entry, WirOpcode.BoundsCheck, program.void_type, [index, length], [], no_wir_location());
    wir_return(ref program, main_entry, wir_const_int(ref program, i32_type, UInt128(42U)), no_wir_location());

    let checked_id: WirFuncID = wir_add_function(ref program, "checked", [wir_param("index", i32_type), wir_param("length", i32_type)], i32_type, false, WirLinkage.Internal, WirABI.White);
    let checked_entry: WirBlockID = wir_add_block(ref program, checked_id, "entry", []);
    let checked_exit: WirBlockID = wir_add_block(ref program, checked_id, "exit", [wir_param("value", i32_type)]);
    let checked: WirFunction = program.arena.functions[wir_id_index(UInt32(checked_id))];
    wir_append(ref program, checked_entry, WirOpcode.BoundsCheck, program.void_type, [checked.parameters[0], checked.parameters[1]], [], no_wir_location());
    wir_append(ref program, checked_entry, WirOpcode.Jump, program.void_type, [], [wir_edge(checked_exit, [checked.parameters[0]])], no_wir_location());
    let exit_block: WirBlock = program.arena.blocks[wir_id_index(UInt32(checked_exit))];
    wir_return(ref program, checked_exit, exit_block.parameters[0], no_wir_location());

    let u32_type: WirTypeID = wir_unsigned_int_type(ref program, 32);
    let unsigned_id: WirFuncID = wir_add_function(ref program, "checked_unsigned", [wir_param("index", u32_type), wir_param("length", u32_type)], u32_type, false, WirLinkage.Internal, WirABI.White);
    let unsigned_entry: WirBlockID = wir_add_block(ref program, unsigned_id, "entry", []);
    let unsigned: WirFunction = program.arena.functions[wir_id_index(UInt32(unsigned_id))];
    wir_append(ref program, unsigned_entry, WirOpcode.BoundsCheck, program.void_type, [unsigned.parameters[0], unsigned.parameters[1]], [], no_wir_location());
    wir_return(ref program, unsigned_entry, unsigned.parameters[0], no_wir_location());

    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) {
        print("FAIL: WIR safety checks could not be emitted as LLVM IR");
        return 1;
    }
    if (emitted.errors.length() != 0) {
        print("FAIL: valid WIR safety check was rejected: ", emitted.errors[0]);
        return 1;
    }
    let expected: String = "target triple = \"x86_64-pc-windows-msvc\"\n\ndeclare void @llvm.trap()\n\ndefine i32 @main() {\nb1:\n  %v2 = alloca i32\n  %check.null.2 = icmp eq ptr %v2, null\n  br i1 %check.null.2, label %check.trap.2, label %check.cont.2\ncheck.trap.2:\n  call void @llvm.trap()\n  unreachable\ncheck.cont.2:\n  %check.bounds.low.3 = icmp slt i32 1, 0\n  %check.bounds.high.3 = icmp sge i32 1, 2\n  %check.bounds.3 = or i1 %check.bounds.low.3, %check.bounds.high.3\n  br i1 %check.bounds.3, label %check.trap.3, label %check.cont.3\ncheck.trap.3:\n  call void @llvm.trap()\n  unreachable\ncheck.cont.3:\n  ret i32 42\n}\n\ndefine internal i32 @checked(i32 %v6, i32 %v7) {\nb2:\n  %check.bounds.low.5 = icmp slt i32 %v6, 0\n  %check.bounds.high.5 = icmp sge i32 %v6, %v7\n  %check.bounds.5 = or i1 %check.bounds.low.5, %check.bounds.high.5\n  br i1 %check.bounds.5, label %check.trap.5, label %check.cont.5\ncheck.trap.5:\n  call void @llvm.trap()\n  unreachable\ncheck.cont.5:\n  br label %b3\nb3:\n  %v9 = phi i32 [ %v6, %check.cont.5 ]\n  ret i32 %v9\n}\n\ndefine internal i32 @checked_unsigned(i32 %v10, i32 %v11) {\nb4:\n  %check.bounds.8 = icmp uge i32 %v10, %v11\n  br i1 %check.bounds.8, label %check.trap.8, label %check.cont.8\ncheck.trap.8:\n  call void @llvm.trap()\n  unreachable\ncheck.cont.8:\n  ret i32 %v10\n}\n";
    if (emitted.text != expected) {
        print("FAIL: WIR LLVM safety-check output is not stable");
        print(emitted.text);
        return 1;
    }
    print("PASS: WIR LLVM safety checks");
    return 0;
}
