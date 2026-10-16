// src/compiler/machine/aarch64/stack.wl
import * from "../../wir/model.wl"
import * from "allocator.wl"


struct A64StackSlot(value: WirValueID, offset: Int, size: Int)

struct A64StackIndex(
    slots: Vector(A64StackSlot),
    base: Int,
    indices: Vector(Int),
    sparse: Dict(UInt32, Int)
)

struct A64StackRegion(offset: Int, size: Int, alignment: Int, next: Int)

struct A64HomePool(
    size: Int,
    regions: Vector(A64StackRegion),
    free: Dict(UInt64, Int),
    ends: Vector(Int)
)

func a64_stack_index(slots: Vector(A64StackSlot), range: A64ValueRange) -> A64StackIndex {
// zero denotes a missing slot, SP+0 is a valid home after the outgoing arguments
    let indices: Vector(Int) = [];
    let sparse: Dict(UInt32, Int) = Dict();
    let count = range.count;
    // interleaved function construction can leave large gaps in arena IDs.
    // Keep the dense part proportional to actual homes, put outliers in the map.
    if (count > 256 && count / 4 > slots.length()) { count = 0; }

    let i = 0;
    while (i < count) {
        indices.append(0);
        i++;
    }

    i = 0;
    while (i < slots.length()) {
        let local = wir_id_index(UInt32(slots[i].value)) - range.base;
        if (local >= 0 && local < count) {
            indices[local] = i + 1;
        } else {
            sparse.put(UInt32(slots[i].value), i + 1);
        }
        i++;
    }

    return A64StackIndex(slots=slots, base=range.base, indices=indices, sparse=sparse);
}

func a64_find_stack_slot(stack: A64StackIndex, value: WirValueID) -> A64StackSlot {
    let local = wir_id_index(UInt32(value)) - stack.base;
    let index = 0;
    if (local >= 0 && local < stack.indices.length()) {
        index = stack.indices[local];
    } else {
        index = stack.sparse.lookup(UInt32(value));
    }

    if (index <= 0 || index > stack.slots.length()) {
        return A64StackSlot(value=NO_WIR_VALUE, offset=0, size=0);
    }
    return stack.slots[index - 1];
}

func a64_home_key(size: Int, alignment: Int) -> UInt64 {
    return (UInt64(UInt32(size)) << 32UL) | UInt64(UInt32(alignment));
}

func a64_reserve_stack(ref pool: A64HomePool, bytes: Int, alignment: Int) -> Int {
    if (bytes <= 0 || alignment <= 0) { return -1; }
    let padding = (alignment - pool.size % alignment) % alignment;
    if (bytes > 2147483647 - pool.size || padding > 2147483647 - pool.size - bytes) {
        return -1;
    }

    let offset = pool.size + padding;
    pool.size = offset + bytes;
    return offset;
}

func a64_begin_home_block(ref pool: A64HomePool, count: Int) -> Void {
    pool.ends = [];
    let i = 0;
    while (i <= count) {
        pool.ends.append(0);
        i++;
    }
}

func a64_expire_homes(ref pool: A64HomePool, position: Int) -> Void {
// each region appears on one expiry list, releasing homes costs one visit per lifetime
    let index = pool.ends[position];
    pool.ends[position] = 0;
    while (index != 0) {
        let region = pool.regions[index - 1];
        let next = region.next;
        let key = a64_home_key(region.size, region.alignment);
        region.next = pool.free.lookup(key);
        pool.regions[index - 1] = region;
        pool.free.put(key, index);
        index = next;
    }
}

func a64_reuse_home(ref pool: A64HomePool, bytes: Int, alignment: Int, last: Int) -> Int {
// exact layout buckets avoid a best-fit scan, input homes stay alive through the instruction
    if (last < 0 || last + 1 >= pool.ends.length()) { return -1; }
    let key = a64_home_key(bytes, alignment);
    let index = pool.free.lookup(key);
    let offset = -1;

    if (index != 0) {
        let region = pool.regions[index - 1];
        pool.free.put(key, region.next);
        offset = region.offset;
    } else {
        offset = a64_reserve_stack(ref pool, bytes, alignment);
        if (offset < 0) { return -1; }
        pool.regions.append(A64StackRegion(offset=offset, size=bytes, alignment=alignment, next=0));
        index = pool.regions.length();
    }

    let region = pool.regions[index - 1];
    region.next = pool.ends[last + 1];
    pool.regions[index - 1] = region;
    pool.ends[last + 1] = index;
    return offset;
}

func a64_pinned_homes(ref program: WirModule, order: Vector(WirBlockID)) -> Dict(UInt32, Bool) {
// block-local intervals cannot describe loop live-outs or the lifetime of an escaped address
    let definitions: Dict(UInt32, UInt32) = Dict();
    let pinned: Dict(UInt32, Bool) = Dict();
    let i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            if (inst.result != NO_WIR_VALUE) { definitions.put(UInt32(inst.result), UInt32(order[i])); }
            j++;
        }
        i++;
    }

    i = 0;
    while (i < order.length()) {
        let block = program.arena.blocks[wir_id_index(UInt32(order[i]))];
        let j = 0;
        while (j < block.instructions.length()) {
            let inst = program.arena.instructions[wir_id_index(UInt32(block.instructions[j]))];
            let k = 0;
            while (k < inst.operands.length()) {
                let value = UInt32(inst.operands[k]);
                let owner = definitions.lookup(value);
                if (owner != 0U && owner != UInt32(order[i])) { pinned.put(value, true); }
                if (inst.opcode == WirOpcode.FieldAddress || inst.opcode == WirOpcode.IndexAddress ||
                    inst.opcode == WirOpcode.Bitcast) {
                    pinned.put(value, true);
                }
                k++;
            }

            k = 0;
            while (k < inst.edges.length()) {
                let a = 0;
                while (a < inst.edges[k].arguments.length()) {
                    let value = UInt32(inst.edges[k].arguments[a]);
                    let owner = definitions.lookup(value);
                    if (owner != 0U && owner != UInt32(order[i])) { pinned.put(value, true); }
                    a++;
                }
                k++;
            }
            j++;
        }
        i++;
    }
    return pinned;
}
