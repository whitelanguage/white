// Test: WIR_ARC_RUNTIME
// File: tests/integration/tooling/test_wir_arc_runtime.wl
// Focus: Building retain and release from primitive WIR control flow and atomics.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"
import * from "../../../src/compiler/wir/lowering/declarations.wl"
import * from "../../../src/compiler/wir/lowering/ownership_runtime.wl"
import * from "../../../src/compiler/wir/backend/llvm.wl"

func opcode_count(program: WirModule, function_id: WirFuncID, opcode: WirOpcode) -> Int {
    let count: Int = 0;
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_id))];
    let i: Int = 0;
    while (i < function.blocks.length()) {
        let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j: Int = 0;
        while (j < block.instructions.length()) {
            let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (instruction.opcode == opcode) { count++; }
            j++;
        }
        i++;
    }
    return count;
}

func main() -> Int {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let raw_pointer: WirTypeID = wir_pointer_type(ref program, program.void_type);
    let deallocator: WirFuncID = wir_add_function(ref program, "memory_free", [wir_param("block", raw_pointer)], program.void_type, false, WirLinkage.External, WirABI.C);
    let user: WirFuncID = wir_add_function(ref program, "use_object", [wir_param("object", raw_pointer)], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, user, "entry", []);
    let function: WirFunction = program.arena.functions[wir_id_index(UInt32(user))];
    wir_retain(ref program, entry, function.parameters[0], no_wir_location());
    wir_release(ref program, entry, function.parameters[0], no_wir_location());
    wir_return(ref program, entry, NO_WIR_VALUE, no_wir_location());

    wir_emit_ownership_runtime(ref program, deallocator, 5);
    let retain: WirFuncID = wir_find_function(program, "__wl_retain");
    let release: WirFuncID = wir_find_function(program, "__wl_release");
    if (retain == NO_WIR_FUNC || release == NO_WIR_FUNC) { print("FAIL: ARC runtime functions were not emitted"); return 1; }
    if (opcode_count(program, retain, WirOpcode.AtomicLoad) != 1 || opcode_count(program, retain, WirOpcode.AtomicRmw) != 1) {
        print("FAIL: retain does not use the expected atomic operations");
        return 1;
    }
    if (opcode_count(program, release, WirOpcode.AtomicLoad) != 1 || opcode_count(program, release, WirOpcode.AtomicRmw) != 1) {
        print("FAIL: release does not use the expected atomic operations");
        return 1;
    }
    let errors: Vector(String) = verify_wir(program);
    if (errors.length() != 0) { print("FAIL: ARC runtime produced invalid WIR: ", errors[0]); return 1; }
    let emitted: WirLLVMResult = emit_wir_llvm(program)?;
    catch(err) { print("FAIL: ARC runtime LLVM emission failed"); return 1; }
    if (emitted.errors.length() != 0) { print("FAIL: ARC runtime LLVM was rejected: ", emitted.errors[0]); return 1; }
    print("PASS: WIR ARC runtime");
    return 0;
}
