// src/compiler/wir/backend/llvm_native.wl
import "strings"
import * from "../model.wl"
import wir_type_layout from "../layout.wl"
import is_win64_target, win64_register_bytes from "../../native_abi.wl"
import llvm_write_type, llvm_write_value, llvm_write_typed_value, llvm_value_name, llvm_callconv, llvm_has_function from "llvm.wl"


func llvm_native_mode(program: WirModule, abi: WirABI, type_id: WirTypeID) -> Int {
// C classifies POD records by storage size, a float field still uses an integer register
    if (abi == WirABI.White || !is_win64_target(program.target)) { return 0; }
    let type = program.arena.types[wir_id_index(UInt32(type_id))];
    if (type.kind != WirTypeKind.Struct && type.kind != WirTypeKind.Array) { return 0; }
    let layout = wir_type_layout(program, type_id);
    let bytes = win64_register_bytes(layout.size);
    if (bytes != 0) { return bytes * 8; }
    return -1;
}

func llvm_native_signature(program: WirModule, signature: WirType) -> Bool {
    if (signature.abi == WirABI.White || !is_win64_target(program.target)) { return false; }
    if (llvm_native_mode(program, signature.abi, signature.result) != 0) { return true; }
    let i = 0;
    while (i < signature.parameters.length()) {
        if (llvm_native_mode(program, signature.abi, signature.parameters[i]) != 0) { return true; }
        i++;
    }
    return false;
}

func llvm_native_type(output: strings.Builder, program: WirModule, abi: WirABI, type_id: WirTypeID, result: Bool) -> Void? {
    let mode = llvm_native_mode(program, abi, type_id);
    if (mode < 0) {
        if result { output.write("void")?; }
        else { output.write("ptr")?; }
    } else if (mode > 0) { output.write("i" + mode)?; }
    else { llvm_write_type(output, program, type_id)?; }
    return;
}

func llvm_native_sret(output: strings.Builder, program: WirModule, type_id: WirTypeID) -> Void? {
    output.write("ptr sret(")?;
    llvm_write_type(output, program, type_id)?;
    output.write(") align " + wir_type_layout(program, type_id).alignment)?;
    return;
}

func llvm_native_slot(output: strings.Builder, program: WirModule, name: String, type_id: WirTypeID) -> Void? {
    output.write("  " + name + " = alloca ")?;
    llvm_write_type(output, program, type_id)?;
    output.write(", align 16\n")?;
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
    let name: String = "";
    if (llvm_native_mode(program, signature.abi, signature.result) < 0) { name = "abi.ok.result"; }
    let i = 0;
    while (i < signature.parameters.length()) {
        if (llvm_native_mode(program, signature.abi, signature.parameters[i]) < 0) { name = "abi.ok.arg." + i; }
        i++;
    }
    return name;
}

func llvm_native_storage(output: strings.Builder, program: WirModule, function: WirFunction) -> Void? {
// call scratch belongs to entry, repeated calls in a loop must not grow the stack
    if (!is_win64_target(program.target)) { return; }
    let signature = program.arena.types[wir_id_index(UInt32(function.type_id))];
    if (llvm_native_mode(program, signature.abi, signature.result) > 0) {
        llvm_native_slot(output, program, "%abi.result", signature.result)?;
    }
    let i = 0;
    while (i < signature.parameters.length()) {
        if (llvm_native_mode(program, signature.abi, signature.parameters[i]) > 0) {
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
                let prefix = "%abi.call." + UInt32(id);
                if (llvm_native_mode(program, call.abi, call.result) != 0) {
                    llvm_native_slot(output, program, prefix + ".result", call.result)?;
                }
                let arg = 0;
                while (arg < call.parameters.length()) {
                    if (llvm_native_mode(program, call.abi, call.parameters[arg]) != 0) {
                        llvm_native_slot(output, program, prefix + ".arg." + arg, call.parameters[arg])?;
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
    if (llvm_native_mode(program, signature.abi, signature.result) < 0) {
        llvm_native_check(output, program, "%abi.result.addr", "result")?;
    }
    let i = 0;
    while (i < signature.parameters.length()) {
        let type_id = signature.parameters[i];
        let mode = llvm_native_mode(program, signature.abi, type_id);
        let name = "%abi.arg." + i;
        if (mode > 0) {
            output.write("  store i" + mode + " " + name + ", ptr " + name + ".slot\n")?;
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
    let prefix = "%abi.call." + UInt32(id);
    let i = 0;
    while (i < signature.parameters.length()) {
        let mode = llvm_native_mode(program, signature.abi, signature.parameters[i]);
        if (mode != 0) {
            let slot = prefix + ".arg." + i;
            llvm_native_store(output, program, inst.operands[i + 1], slot)?;
            if (mode > 0) { output.write("  " + slot + ".bits = load i" + mode + ", ptr " + slot + "\n")?; }
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
            llvm_native_type(output, program, signature.abi, signature.parameters[param], false)?;
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
        let arg_mode = 0;
        if (i <= signature.parameters.length()) { arg_mode = llvm_native_mode(program, signature.abi, signature.parameters[i - 1]); }
        if (arg_mode < 0) { output.write("ptr " + prefix + ".arg." + (i - 1))?; }
        else if (arg_mode > 0) { output.write("i" + arg_mode + " " + prefix + ".arg." + (i - 1) + ".bits")?; }
        else { llvm_write_typed_value(output, program, inst.operands[i])?; }
        i++;
    }
    output.write(")\n")?;
    if (mode > 0) { output.write("  store i" + mode + " " + prefix + ".bits, ptr " + prefix + ".result\n")?; }
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
        output.write("  " + name + " = load i" + mode + ", ptr %abi.result\n  ret i" + mode + " " + name + "\n")?;
    }
    return;
}
