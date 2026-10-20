// src/compiler/wir/pipeline.wl

import * from "../context.wl"
import * from "model.wl"
import * from "lowering/module.wl"
import * from "backend/llvm.wl"
import optimize_wir from "optimize.wl"
import print_wir from "print.wl"
import GLOBAL_ERROR_COUNT from "../../frontend/diagnostics.wl"


struct WirPipelineResult(text: String, errors: Vector(String))

func lower_program_to_wir(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int, verbose: Bool = false) -> WirLoweringResult {
    let modules: Vector(ParsedModule) = [];
    let i: Int = 0;
    while (i < erased_modules.length()) {
        modules.append(erased_modules[i]);
        i++;
    }
    return wir_lower_program(ref source, modules, target, pointer_bits, verbose);
}

func lower_program_to_llvm(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int) -> WirPipelineResult? {
// keep WIR verification between source lowering and backend emission
    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits);
    if (GLOBAL_ERROR_COUNT > 0 || lowered.errors.length() != 0) {
        return WirPipelineResult(text="", errors=lowered.errors);
    }
    let emitted: WirLLVMResult = emit_wir_llvm(lowered.program)?;
    return WirPipelineResult(text=emitted.text, errors=emitted.errors);
}

func lower_program_to_wir_text(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int, opt_level: String) -> WirPipelineResult? {
    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits);
    if (GLOBAL_ERROR_COUNT > 0 || lowered.errors.length() != 0) {
        return WirPipelineResult(text="", errors=lowered.errors);
    }

    optimize_wir(ref lowered.program, opt_level);
    return WirPipelineResult(text=print_wir(lowered.program)?, errors=[]);
}
