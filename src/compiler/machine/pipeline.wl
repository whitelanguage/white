// compiler/machine/pipeline.wl

import * from "../context.wl"
import * from "../wir/model.wl"
import WirLoweringResult from "../wir/lowering/module.wl"
import lower_program_to_wir from "../wir/pipeline.wl"
import X86Object from "x86_64/model.wl"
import X86ModuleResult, x86_lower_module from "x86_64/lowering.wl"
import coff_object from "x86_64/coff.wl"

struct MachinePipelineResult(bytes: Vector(Byte), errors: Vector(String))

func lower_program_to_machine(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int, verbose: Bool = false) -> MachinePipelineResult? {
    if (verbose) { print("Lowering source to WIR"); }
    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits, verbose);
    if (lowered.errors.length() != 0) { return MachinePipelineResult(bytes=[], errors=lowered.errors); }
    if (target != "x86_64-pc-windows-msvc" || pointer_bits != 64) {
        return MachinePipelineResult(bytes=[], errors=["The machine backend does not support target '" + target + "'."]);
    }

    if (verbose) { print("Lowering WIR to x86-64"); }
    let machine: X86ModuleResult = x86_lower_module(ref lowered.program, verbose);
    if (machine.errors.length() != 0) { return MachinePipelineResult(bytes=[], errors=machine.errors); }
    if (verbose) { print("Encoding COFF object"); }
    let object: Vector(Byte) = coff_object(X86Object(sections=machine.sections, symbols=machine.symbols, relocations=machine.relocations))?;
    catch(err) {
        return MachinePipelineResult(bytes=[], errors=["Could not encode the machine object file."]);
    }
    return MachinePipelineResult(bytes=object, errors=[]);
}
