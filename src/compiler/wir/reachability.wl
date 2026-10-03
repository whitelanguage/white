// compiler/wir/reachability.wl

import * from "model.wl"

struct WirReachability(
    functions: Vector(Bool),
    globals: Vector(Bool)
)

func wir_queue_function(program: WirModule, function_id: WirFuncID, ref live: Vector(Bool), ref queue: Vector(WirFuncID)) -> Void {
    let index: Int = wir_id_index(UInt32(function_id));
    if (index < 0 || index >= program.arena.functions.length() || live[index]) { return; }
    live[index] = true;
    queue.append(function_id);
}

func wir_find_function(program: WirModule, name: String) -> WirFuncID {
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        if (program.arena.functions[i].name == name) { return WirFuncID(UInt32(i + 1)); }
        i++;
    }
    return NO_WIR_FUNC;
}

func wir_queue_global(program: WirModule, global_id: WirGlobalID, ref live: Vector(Bool), ref queue: Vector(WirGlobalID)) -> Void {
    let index: Int = wir_id_index(UInt32(global_id));
    if (index < 0 || index >= program.arena.globals.length() || live[index]) { return; }
    live[index] = true;
    queue.append(global_id);
}

func wir_queue_value(program: WirModule, value_id: WirValueID, ref live: Vector(Bool), ref queue: Vector(WirValueID)) -> Void {
    let index: Int = wir_id_index(UInt32(value_id));
    if (index < 0 || index >= program.arena.values.length() || live[index]) { return; }
    live[index] = true;
    queue.append(value_id);
}

func wir_reachable_symbols(program: WirModule) -> WirReachability {
    let function_live: Vector(Bool) = [];
    let global_live: Vector(Bool) = [];
    let constant_live: Vector(Bool) = [];
    let value_live: Vector(Bool) = [];
    let function_queue: Vector(WirFuncID) = [];
    let global_queue: Vector(WirGlobalID) = [];
    let value_queue: Vector(WirValueID) = [];
    let retain_function: WirFuncID = wir_find_function(program, "__wl_retain");
    let release_function: WirFuncID = wir_find_function(program, "__wl_release");
    let null_failure: WirFuncID = wir_find_function(program, "__wl_fail_null");
    let bounds_failure: WirFuncID = wir_find_function(program, "__wl_fail_bounds");
    let i: Int = 0;
    while (i < program.arena.functions.length()) {
        function_live.append(false);
        i++;
    }
    i = 0;
    while (i < program.arena.globals.length()) {
        global_live.append(false);
        i++;
    }
    i = 0;
    while (i < program.arena.constants.length()) {
        constant_live.append(false);
        i++;
    }
    i = 0;
    while (i < program.arena.values.length()) {
        value_live.append(false);
        i++;
    }

    i = 0;
    while (i < program.arena.functions.length()) {
        let function: WirFunction = program.arena.functions[i];
        if (function.linkage == WirLinkage.Exported || function.export_symbol) {
            wir_queue_function(program, WirFuncID(UInt32(i + 1)), ref function_live, ref function_queue);
        }
        i++;
    }
    i = 0;
    while (i < program.arena.globals.length()) {
        let global: WirGlobal = program.arena.globals[i];
        if (global.linkage == WirLinkage.Exported || global.export_symbol) {
            wir_queue_global(program, WirGlobalID(UInt32(i + 1)), ref global_live, ref global_queue);
        }
        i++;
    }

    let function_cursor: Int = 0;
    let global_cursor: Int = 0;
    let value_cursor: Int = 0;
    while (function_cursor < function_queue.length() || global_cursor < global_queue.length() || value_cursor < value_queue.length()) {
        while (function_cursor < function_queue.length()) {
            let function: WirFunction = program.arena.functions[wir_id_index(UInt32(function_queue[function_cursor]))];
            function_cursor++;
            let block_index: Int = 0;
            while (block_index < function.blocks.length()) {
                let block: WirBlock = program.arena.blocks[wir_id_index(UInt32(function.blocks[block_index]))];
                let instruction_index: Int = 0;
                while (instruction_index < block.instructions.length()) {
                    let instruction: WirInstruction = program.arena.instructions[wir_id_index(UInt32(block.instructions[instruction_index]))];
                    if (instruction.opcode == WirOpcode.Retain) {
                        wir_queue_function(program, retain_function, ref function_live, ref function_queue);
                    } else if (instruction.opcode == WirOpcode.Release) {
                        wir_queue_function(program, release_function, ref function_live, ref function_queue);
                    } else if (instruction.opcode == WirOpcode.NullCheck) {
                        wir_queue_function(program, null_failure, ref function_live, ref function_queue);
                    } else if (instruction.opcode == WirOpcode.BoundsCheck) {
                        wir_queue_function(program, bounds_failure, ref function_live, ref function_queue);
                    }
                    let operand_index: Int = 0;
                    while (operand_index < instruction.operands.length()) {
                        wir_queue_value(program, instruction.operands[operand_index], ref value_live, ref value_queue);
                        operand_index++;
                    }
                    let edge_index: Int = 0;
                    while (edge_index < instruction.edges.length()) {
                        let argument_index: Int = 0;
                        while (argument_index < instruction.edges[edge_index].arguments.length()) {
                            wir_queue_value(program, instruction.edges[edge_index].arguments[argument_index], ref value_live, ref value_queue);
                            argument_index++;
                        }
                        edge_index++;
                    }
                    instruction_index++;
                }
                block_index++;
            }
        }
        while (global_cursor < global_queue.length()) {
            let global: WirGlobal = program.arena.globals[wir_id_index(UInt32(global_queue[global_cursor]))];
            global_cursor++;
            if (global.initializer != NO_WIR_VALUE) {
                wir_queue_value(program, global.initializer, ref value_live, ref value_queue);
            }
        }
        while (value_cursor < value_queue.length()) {
            let value: WirValue = program.arena.values[wir_id_index(UInt32(value_queue[value_cursor]))];
            value_cursor++;
            if (value.kind == WirValueKind.Function) {
                wir_queue_function(program, WirFuncID(value.owner), ref function_live, ref function_queue);
            } else if (value.kind == WirValueKind.Global) {
                wir_queue_global(program, WirGlobalID(value.owner), ref global_live, ref global_queue);
            } else if (value.kind == WirValueKind.Constant) {
                let constant_index: Int = wir_id_index(value.owner);
                if (constant_index >= 0 && constant_index < program.arena.constants.length() && !constant_live[constant_index]) {
                    constant_live[constant_index] = true;
                    let constant: WirConstant = program.arena.constants[constant_index];
                    if (constant.kind == WirConstKind.Address) {
                        wir_queue_value(program, constant.target, ref value_live, ref value_queue);
                    } else if (constant.kind == WirConstKind.Aggregate) {
                        let element_index: Int = 0;
                        while (element_index < constant.elements.length()) {
                            wir_queue_value(program, constant.elements[element_index], ref value_live, ref value_queue);
                            element_index++;
                        }
                    }
                }
            }
        }
    }
    return WirReachability(functions=function_live, globals=global_live);
}
