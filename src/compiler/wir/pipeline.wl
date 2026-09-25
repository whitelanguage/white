// compiler/wir/pipeline.wl

import * from "../context.wl"
import * from "model.wl"
import * from "lowering/module.wl"
import * from "backend/llvm.wl"

struct WirPipelineResult(text: String, errors: Vector(String))

func lower_program_to_wir(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int) -> WirLoweringResult {
    let modules: Vector(ParsedModule) = [];
    let i: Int = 0;
    while (i < erased_modules.length()) {
        modules.append(erased_modules[i]);
        i++;
    }
    return wir_lower_program(ref source, modules, target, pointer_bits);
}

func lower_program_to_llvm(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int) -> WirPipelineResult? {
    // keep WIR verification between source lowering and backend emission
    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits);
    if (lowered.errors.length() != 0) { return WirPipelineResult(text="", errors=lowered.errors); }
    let emitted: WirLLVMResult = emit_wir_llvm(lowered.program)?;
    return WirPipelineResult(text=emitted.text, errors=emitted.errors);
}
