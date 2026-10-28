// src/compiler/wir/backend/llvm_native.wl
import "strings"
import * from "../model.wl"
import wir_type_layout, wir_type_layouts from "../layout.wl"
import * from "../../abi/llvm.wl"
import llvm_write_type, llvm_write_value, llvm_write_typed_value, llvm_value_name, llvm_callconv, llvm_has_function from "llvm.wl"


func llvm_native_shape(program: WirModule, abi: WirABI, type_id: WirTypeID, result: Bool) -> NativeLLVMType {
    if (abi == WirABI.White || !native_llvm_target(program.target)) { return NativeLLVMType(); }
    return native_llvm_classify(program, abi, type_id, wir_type_layouts(program), result);
}

func llvm_native_mode(program: WirModule, abi: WirABI, type_id: WirTypeID) -> Int {
    return llvm_native_shape(program, abi, type_id, true).mode;
}

func llvm_native_signature(program: WirModule, signature: WirType) -> Bool {
    if (signature.abi == WirABI.White || !native_llvm_target(program.target)) { return false; }
    let plan = native_llvm_plan(program, signature);
    if (plan.result.mode != 0 || plan.result.attr.length() != 0) { return true; }
    let i = 0;
    while (i < plan.params.length()) {
        if (plan.params[i].mode != 0 || plan.params[i].attr.length() != 0) { return true; }
        i++;
    }
    return false;
}

func llvm_native_type(output: strings.Builder, program: WirModule, abi: WirABI, type_id: WirTypeID, result: Bool) -> Void? {
    let shape: NativeLLVMType = llvm_native_shape(program, abi, type_id, result);
    if (result && shape.attr.length() != 0) { output.write(shape.attr + " ")?; }
    if (shape.mode < 0) {
        if result { output.write("void")?; }
        else { output.write("ptr")?; }
    } else if (shape.mode > 0) { output.write(shape.physical)?; }
    else { llvm_write_type(output, program, type_id)?; }
    return;
}

func llvm_native_param(output: strings.Builder, program: WirModule, signature: WirType, index: Int, attributes: Bool = true) -> Void? {
    if (signature.abi == WirABI.White || !native_llvm_target(program.target)) {
        llvm_write_type(output, program, signature.parameters[index])?;
        return;
    }
    let plan = native_llvm_plan(program, signature);
    let shape: NativeLLVMType = plan.params[index];
    let id = signature.parameters[index];
    if (shape.mode < 0) {
        output.write("ptr")?;
        if (attributes && shape.mode == -2) {
            output.write(" byval(")?;
            llvm_write_type(output, program, id)?;
            let alignment = wir_type_layout(program, id).alignment;
            if (alignment < 8) { alignment = 8; }
            output.write(") align " + alignment)?;
        }
    } else if (shape.mode > 0) { output.write(shape.physical)?; }
    else { llvm_write_type(output, program, id)?; }
    if (attributes && shape.attr.length() != 0) { output.write(" " + shape.attr)?; }
    return;
}

func llvm_native_sret(output: strings.Builder, program: WirModule, type_id: WirTypeID) -> Void? {
    output.write("ptr sret(")?;
    llvm_write_type(output, program, type_id)?;
    output.write(") align " + wir_type_layout(program, type_id).alignment)?;
    return;
}

func llvm_native_slot(output: strings.Builder, program: WirModule, name: String, type_id: WirTypeID) -> Void? {
// rounded C coercions may include padding beyond the logical record's last byte
    let bytes = Int(wir_type_layout(program, type_id).size);
    if (bytes < 1) { bytes = 1; }
    bytes = (bytes + 15) & -16;
    output.write("  " + name + " = alloca [" + bytes + " x i8], align 16\n")?;
    output.write("  store [" + bytes + " x i8] zeroinitializer, ptr " + name + "\n")?;
    return;
}

func llvm_native_store(output: strings.Builder, program: WirModule, value: WirValueID, slot: String) -> Void? {
    output.write("  store ")?;
    llvm_write_typed_value(output, program, value)?;
    output.write(", ptr " + slot + "\n")?;
    return;
}

func llvm_native_load(output: strings.Builder, program: WirModule, type_id: WirTypeID, slot: String, value: String) -> Void? {
    output.write("  " + value + " = load ")?;
    llvm_write_type(output, program, type_id)?;
    output.write(", ptr " + slot + "\n")?;
    return;
}

func llvm_native_check(output: strings.Builder, program: WirModule, pointer: String, suffix: String) -> Void? {
// indirect C arguments have to be checked before the logical aggregate is loaded
    output.write("  %abi.null." + suffix + " = icmp eq ptr " + pointer + ", null\n")?;
    output.write("  br i1 %abi.null." + suffix + ", label %abi.trap." + suffix + ", label %abi.ok." + suffix + "\n")?;
    output.write("abi.trap." + suffix + ":\n  call void @")?;
    if (llvm_has_function(program, "__wl_fail_null")) { output.write("__wl_fail_null()")?; }
    else { output.write("llvm.trap()")?; }
    output.write("\n  unreachable\nabi.ok." + suffix + ":\n")?;
    return;
}

func llvm_native_entry_exit(program: WirModule, function: WirFunction) -> String {
// entry coercion checks split the LLVM block, PHIs must use the final predecessor
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (signature.abi == WirABI.White || !native_llvm_target(program.target)) { return ""; }
    let name: String = "";
    if (llvm_native_mode(program, signature.abi, signature.result) < 0) { name = "abi.ok.result"; }
    let i = 0;
    while (i < signature.parameters.length()) {
        if (llvm_native_param_mode(program, signature, i) < 0) { name = "abi.ok.arg." + i; }
        i++;
    }
    return name;
}

func llvm_native_storage(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
// call scratch belongs to entry, repeated calls in a loop must not grow the stack
    if (!native_llvm_target(program.target)) { return; }
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (llvm_native_mode(program, signature.abi, signature.result) > 0) {
        llvm_native_slot(output, program, "%abi.result", signature.result)?;
    }
    let i = 0;
    while (i < signature.parameters.length()) {
        if (llvm_native_param_mode(program, signature, i) > 0) {
            llvm_native_slot(output, program, "%abi.arg." + i + ".slot", signature.parameters[i])?;
        }
        i++;
    }
    i = 0;
    while (i < function.blocks.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(function.blocks[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let id = block.instructions[j];
            let inst = program.arena.instructions[wir_id_index(UInt32(id))];
            if (inst.opcode == WirOpcode.Call) {
                let call = program.arena.types[wir_id_index(UInt32(inst.call_type))];
                let actual = native_llvm_actual_signature(program, call, inst);
                let prefix = "%abi.call." + UInt32(id);
                if (llvm_native_mode(program, call.abi, call.result) != 0) {
                    llvm_native_slot(output, program, prefix + ".result", call.result)?;
                }
                let arg = 0;
                while (arg < actual.parameters.length()) {
                    if (llvm_native_param_mode(program, actual, arg) != 0) {
                        llvm_native_slot(output, program, prefix + ".arg." + arg, actual.parameters[arg])?;
                    }
                    arg++;
                }
            }
            j++;
        }
        i++;
    }
    return;
}

func llvm_native_entry(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (signature.abi == WirABI.White || !native_llvm_target(program.target)) { return; }
    if (llvm_native_mode(program, signature.abi, signature.result) < 0) {
        llvm_native_check(output, program, "%abi.result.addr", "result")?;
    }
    let i = 0;
    while (i < signature.parameters.length()) {
        let type_id = signature.parameters[i];
        let plan = native_llvm_plan(program, signature);
        let shape: NativeLLVMType = plan.params[i];
        let mode = shape.mode;
        let name = "%abi.arg." + i;
        if (mode > 0) {
            output.write("  store " + shape.physical + " " + name + ", ptr " + name + ".slot\n")?;
            llvm_native_load(output, program, type_id, name + ".slot", llvm_value_name(function.parameters[i]))?;
        } else if (mode < 0) {
            llvm_native_check(output, program, name, "arg." + i)?;
            llvm_native_load(output, program, type_id, name, llvm_value_name(function.parameters[i]))?;
        }
        i++;
    }
    return;
}

func llvm_native_call(output: strings.Builder, program: WirModule, id: WirInstID, inst: WirInstruction) -> Void? {
    let signature = program.arena.types[wir_id_index(UInt32(inst.call_type))];
    let actual = native_llvm_actual_signature(program, signature, inst);
    let plan = native_llvm_plan(program, actual);
    let prefix = "%abi.call." + UInt32(id);
    let i = 0;
    while (i < actual.parameters.length()) {
        let shape: NativeLLVMType = plan.params[i];
        let mode = shape.mode;
        if (mode != 0) {
            let slot = prefix + ".arg." + i;
            llvm_native_store(output, program, inst.operands[i + 1], slot)?;
            if (mode > 0) { output.write("  " + slot + ".bits = load " + shape.physical + ", ptr " + slot + "\n")?; }
        }
        i++;
    }
    let mode = llvm_native_mode(program, signature.abi, signature.result);
    output.write("  ")?;
    if (mode > 0) { output.write(prefix + ".bits = ")?; }
    else if (mode == 0 && inst.result != NO_WIR_VALUE) { output.write(llvm_value_name(inst.result) + " = ")?; }
    output.write("call " + llvm_callconv(program, signature.abi))?;
    llvm_native_type(output, program, signature.abi, signature.result, true)?;
    if (signature.variadic) {
        output.write(" (")?;
        if (mode < 0) { output.write("ptr, ")?; }
        let param = 0;
        while (param < signature.parameters.length()) {
            llvm_native_param(output, program, signature, param, false)?;
            output.write(", ")?;
            param++;
        }
        output.write("...)")?;
    }
    output.write(" ")?;
    llvm_write_value(output, program, inst.operands[0])?;
    output.write("(")?;
    let first = true;
    if (mode < 0) {
        llvm_native_sret(output, program, signature.result)?;
        output.write(" " + prefix + ".result")?;
        first = false;
    }
    i = 1;
    while (i < inst.operands.length()) {
        if (!first) { output.write(", ")?; }
        first = false;
        if (i <= actual.parameters.length()) {
            let arg = plan.params[i - 1];
            llvm_native_param(output, program, actual, i - 1)?;
            output.write(" ")?;
            if (arg.mode < 0) { output.write(prefix + ".arg." + (i - 1))?; }
            else if (arg.mode > 0) { output.write(prefix + ".arg." + (i - 1) + ".bits")?; }
            else { llvm_write_value(output, program, inst.operands[i])?; }
        } else { llvm_write_typed_value(output, program, inst.operands[i])?; }
        i++;
    }
    output.write(")\n")?;
    if (mode > 0) { output.write("  store " + llvm_native_shape(program, signature.abi, signature.result, true).physical + " " + prefix + ".bits, ptr " + prefix + ".result\n")?; }
    if (mode != 0) { llvm_native_load(output, program, signature.result, prefix + ".result", llvm_value_name(inst.result))?; }
    return;
}

func llvm_native_return(output: strings.Builder, program: WirModule, function: WirFunction, id: WirInstID, inst: WirInstruction) -> Void? {
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    let mode = llvm_native_mode(program, signature.abi, signature.result);
    if (mode < 0) {
        llvm_native_store(output, program, inst.operands[0], "%abi.result.addr")?;
        output.write("  ret void\n")?;
    } else {
        llvm_native_store(output, program, inst.operands[0], "%abi.result")?;
        let name = "%abi.return." + UInt32(id);
        let physical = llvm_native_shape(program, signature.abi, signature.result, true).physical;
        output.write("  " + name + " = load " + physical + ", ptr %abi.result\n  ret " + physical + " " + name + "\n")?;
    }
    return;
}

func llvm_native_param_mode(program: WirModule, signature: WirType, index: Int) -> Int {
    if (signature.abi == WirABI.White || !native_llvm_target(program.target)) { return 0; }
    let plan = native_llvm_plan(program, signature);
    return plan.params[index].mode;
}
