// compiler/machine/pipeline.wl

import * from "../context.wl"
import * from "../wir/model.wl"
import WirLoweringResult from "../wir/lowering/module.wl"
import lower_program_to_wir from "../wir/pipeline.wl"
import WirOptimizationStats, optimize_wir from "../wir/optimize.wl"
import verify_wir from "../wir/verify.wl"
import X86Object from "x86_64/model.wl"
import X86ModuleResult, x86_lower_module from "x86_64/lowering.wl"
import coff_object from "x86_64/coff.wl"

struct MachinePipelineResult(bytes: Vector(Byte), errors: Vector(String))

func lower_program_to_machine(ref source: Compiler, erased_modules: Vector(Struct), target: String, pointer_bits: Int, verbose: Bool = false, opt_level: String = "-O2") -> MachinePipelineResult? {
    if verbose {
        print("Lowering source to WIR");
    }

    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits, verbose);
    if (lowered.errors.length() != 0) {
        return MachinePipelineResult(bytes=[], errors=lowered.errors);
    }

    if (target != "x86_64-pc-windows-msvc" || pointer_bits != 64) {
        return MachinePipelineResult(bytes=[], errors=["The machine backend does not support target '" + target + "'."]);
    }

    if verbose {
        print("Optimizing WIR (", opt_level, ")", sep="");
    }

    let stats: WirOptimizationStats = optimize_wir(ref lowered.program, opt_level);
    if (verbose) {
        print("Removed ", stats.instructions, " instructions and ", stats.blocks, " blocks; folded ", stats.constants, " constants and ", stats.branches, " branches; threaded ", stats.jumps, " jumps; propagated ", stats.copies, " copies and ", stats.checks, " checks; forwarded ", stats.loads, " loads, removed ", stats.slots, " stack slots and ", stats.parameters, " block parameters", sep="");
        print("Reused ", stats.expressions, " integer expressions", sep="");
    }

    // optimization tests verify every transformed module; avoid a second whole-program walk in release builds
    if (verbose && (stats.instructions != 0 || stats.blocks != 0 || stats.branches != 0 || stats.parameters != 0)) {
        let errors: Vector(String) = verify_wir(lowered.program);
        if (errors.length() != 0) { return MachinePipelineResult(bytes=[], errors=errors); }
    }

    if verbose {
        print("Lowering WIR to x86-64");
    }

    let machine: X86ModuleResult = x86_lower_module(ref lowered.program, verbose);
    if (machine.errors.length() != 0) { return MachinePipelineResult(bytes=[], errors=machine.errors); }
    if verbose {
        print("Encoding COFF object");
    }

    let object: Vector(Byte) = coff_object(X86Object(sections=machine.sections, symbols=machine.symbols, relocations=machine.relocations))?;
    catch(err) {
        return MachinePipelineResult(bytes=[], errors=["Could not encode the machine object file."]);
    }

    return MachinePipelineResult(bytes=object, errors=[]);
}
