// compiler/wir/pipeline.wl

import * from "../context.wl"
import * from "model.wl"
import * from "lowering/module.wl"
import * from "backend/llvm.wl"

func lower_program_to_llvm(ref source: Compiler, modules: Vector(ParsedModule), target: String, pointer_bits: Int) -> WirLLVMResult? {
    // keep WIR verification between source lowering and backend emission
    let lowered: WirLoweringResult = wir_lower_program(ref source, modules, target, pointer_bits);
    if (lowered.errors.length() != 0) { return WirLLVMResult(text="", errors=lowered.errors); }
    return emit_wir_llvm(lowered.program)?;
}
