// Test: WIR_DOMINANCE
// File: tests/integration/tooling/test_wir_dominance.wl
// Focus: Checking dominance against path removal, including loops and 64-bit boundaries.

import * from "../../../src/compiler/wir/model.wl"
import * from "../../../src/compiler/wir/builder.wl"
import * from "../../../src/compiler/wir/verify.wl"

func paths_without(edges: Vector(Vector(Int)), removed: Int) -> Vector(Bool) {
    let seen: Vector(Bool) = [];
    let i = 0;
    while (i < edges.length()) { seen.append(false); i++; }
    let queue: Vector(Int) = [];
    if (removed != 0) { seen[0] = true; queue.append(0); }
    let cursor = 0;
    while (cursor < queue.length()) {
        let node: Int = queue[cursor];
        cursor++;
        i = 0;
        while (i < edges[node].length()) {
            let next: Int = edges[node][i];
            if (next != removed && !seen[next]) {
                seen[next] = true;
                queue.append(next);
            }
            i++;
        }
    }
    return seen;
}

func check_graph(count: Int, seed: Int) -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let function: WirFuncID = wir_add_function(ref program, "graph", [], program.void_type, false, WirLinkage.Internal, WirABI.White);
    let blocks: Vector(WirBlockID) = [];
    let edges: Vector(Vector(Int)) = [];
    let i = 0;
    while (i < count) {
        blocks.append(wir_add_block(ref program, function, "b" + i, []));
        edges.append([]);
        i++;
    }
    i = 0;
    while (i < count) {
        if (i + 1 == count) {
            wir_return(ref program, blocks[i], NO_WIR_VALUE, no_wir_location());
        } else {
            let next: Int = (i * 17 + seed * 7) % count;
            edges[i].append(i + 1);
            edges[i].append(next);
            wir_append(ref program, blocks[i], WirOpcode.Branch, program.void_type, [wir_const_bool(ref program, true)], [wir_edge(blocks[i + 1], []), wir_edge(blocks[next], [])], no_wir_location());
        }
        i++;
    }
    let current: WirFunction = program.arena.functions[wir_id_index(UInt32(function))];
    // block storage order is unrelated to dominance or control-flow order
    i = 1;
    while (i < count / 2) {
        let saved: WirBlockID = current.blocks[i];
        current.blocks[i] = current.blocks[count - i];
        current.blocks[count - i] = saved;
        i++;
    }
    program.arena.functions[wir_id_index(UInt32(function))] = current;
    let indices: Vector(Int) = wir_block_indices(program);
    let dominators: Vector(Vector(UInt64)) = wir_dominators(program, current, indices);
    let candidate = 0;
    while (candidate < count) {
        let paths: Vector(Bool) = paths_without(edges, candidate);
        let definition: Int = indices[wir_id_index(UInt32(blocks[candidate]))];
        i = 0;
        while (i < count) {
            let use: Int = indices[wir_id_index(UInt32(blocks[i]))];
            let actual: Bool = (dominators[use][definition / 64] & (1UL << UInt64(definition % 64))) != 0UL;
            if (actual == paths[i]) { return false; }
            i++;
        }
        candidate++;
    }
    let errors: Vector(String) = verify_wir(program);
    return errors.length() == 0;
}

func rejects_forward_use() -> Bool {
    let program: WirModule = new_wir_module("x86_64-pc-windows-msvc", 64);
    let integer: WirTypeID = wir_signed_int_type(ref program, 32);
    let function: WirFuncID = wir_add_function(ref program, "forward", [], integer, false, WirLinkage.Internal, WirABI.White);
    let entry: WirBlockID = wir_add_block(ref program, function, "entry", []);
    let one: WirValueID = wir_const_int(ref program, integer, UInt128(1U));
    let early: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, integer, one, one, "early", no_wir_location());
    let later: WirValueID = wir_binary(ref program, entry, WirOpcode.Add, integer, early, one, "later", no_wir_location());
    let instruction: Int = wir_id_index(program.arena.values[wir_id_index(UInt32(early))].owner);
    program.arena.instructions[instruction].operands[0] = later;
    wir_return(ref program, entry, later, no_wir_location());
    let errors: Vector(String) = verify_wir(program);
    let i = 0;
    while (i < errors.length()) {
        if (errors[i] == "instruction uses a value outside its SSA scope") { return true; }
        i++;
    }
    return false;
}

func main() -> Int {
    let seed = 0;
    while (seed < 12) {
        if (!check_graph(70, seed)) {
            print("FAIL: WIR dominance disagrees with reachability");
            return 1;
        }
        seed++;
    }
    if (!rejects_forward_use()) {
        print("FAIL: WIR accepted a use before its definition");
        return 1;
    }
    print("PASS: WIR dominance");
    return 0;
}
