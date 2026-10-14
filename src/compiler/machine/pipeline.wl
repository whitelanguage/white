// src/compiler/machine/pipeline.wl
import * from "../context.wl"
import * from "../wir/model.wl"
import WirLoweringResult from "../wir/lowering/module.wl"
import lower_program_to_wir from "../wir/pipeline.wl"
import WirOptimizationStats, optimize_wir from "../wir/optimize.wl"
import verify_wir from "../wir/verify.wl"
import X86Object from "x86_64/model.wl"
import X86ModuleResult, x86_lower_module from "x86_64/lowering.wl"
import coff_object from "x86_64/coff.wl"
import elf_object from "x86_64/elf.wl"
import A64Object from "aarch64/model.wl"
import A64ModuleResult, a64_lower_module from "aarch64/lowering.wl"
import a64_elf_object from "aarch64/elf.wl"


struct MachinePipelineResult(bytes: Vector(Byte), errors: Vector(String))

func lower_program_to_machine(
    ref source: Compiler,
    erased_modules: Vector(Struct),
    target: String,
    pointer_bits: Int,
    verbose: Bool = false,
    opt_level: String = "-O2"
) -> MachinePipelineResult? {
    if verbose {
        print("Lowering source to WIR");
    }

    let lowered: WirLoweringResult = lower_program_to_wir(ref source, erased_modules, target, pointer_bits, verbose);
    if (lowered.errors.length() != 0) {
        return MachinePipelineResult(bytes=[], errors=lowered.errors);
    }

    if ((target != "x86_64-pc-windows-msvc" &&
         target != "x86_64-unknown-linux-gnu" &&
         target != "aarch64-unknown-linux-gnu") || pointer_bits != 64) {
        return MachinePipelineResult(bytes=[], errors=["The machine backend does not support target '" + target + "'."]);
    }

    if verbose {
        print("Optimizing WIR (", opt_level, ")", sep="");
    }

    let stats: WirOptimizationStats = optimize_wir(ref lowered.program, opt_level);
    if verbose {
        print(
            "Removed ", stats.instructions, " instructions and ", stats.blocks,
            " blocks, folded ", stats.constants, " constants and ", stats.branches,
            " branches, threaded ", stats.jumps, " jumps, propagated ", stats.copies,
            " copies and ", stats.checks, " checks, forwarded ", stats.loads,
            " loads, removed ", stats.slots, " stack slots and ", stats.parameters,
            " block parameters",
            sep=""
        );
        print("Reused ", stats.expressions, " integer expressions and recognized ", stats.idioms, " integer idioms", sep="");
    }

    // optimization tests verify every transformed module, avoid a second whole-program walk in release builds
    if (verbose && (stats.instructions != 0 || stats.blocks != 0 || stats.branches != 0 || stats.parameters != 0)) {
        let errors: Vector(String) = verify_wir(lowered.program);
        if (errors.length() != 0) {
            return MachinePipelineResult(bytes=[], errors=errors);
        }
    }

    if (target == "aarch64-unknown-linux-gnu") {
        if verbose {
            print("Lowering WIR to AArch64");
        }

        let arm: A64ModuleResult = a64_lower_module(ref lowered.program);
        if (arm.errors.length() != 0) {
            return MachinePipelineResult(bytes=[], errors=arm.errors);
        }

        if verbose {
            print("Encoding ELF object");
        }

        let encoded: Vector(Byte) = a64_elf_object(A64Object(sections=arm.sections, symbols=arm.symbols, relocations=arm.relocations))?;
        catch(err) {
            return MachinePipelineResult(bytes=[], errors=["Could not encode the machine object file."]);
        }

        return MachinePipelineResult(bytes=encoded, errors=[]);
    }

    if verbose {
        print("Lowering WIR to x86-64");
    }

    let machine: X86ModuleResult = x86_lower_module(ref lowered.program, verbose);
    if (machine.errors.length() != 0) {
        return MachinePipelineResult(bytes=[], errors=machine.errors);
    }
    let object: Vector(Byte) = [];
    if (target == "x86_64-unknown-linux-gnu") {
        if verbose {
            print("Encoding ELF object");
        }
        object = elf_object(X86Object(sections=machine.sections, symbols=machine.symbols, relocations=machine.relocations))?;
    } else {
        if verbose {
            print("Encoding COFF object");
        }
        object = coff_object(X86Object(sections=machine.sections, symbols=machine.symbols, relocations=machine.relocations))?;
    }
    catch(err) {
        return MachinePipelineResult(bytes=[], errors=["Could not encode the machine object file."]);
    }

    return MachinePipelineResult(bytes=object, errors=[]);
}
