// src/compiler/machine/homes.wl

struct StackRegion(offset: Int, size: Int, alignment: Int, next: Int)

struct StackHomes(size: Int, regions: Vector(StackRegion), free: Dict(UInt64, Int), ends: Vector(Int))


func stack_home_key(size: Int, alignment: Int) -> UInt64 {
    return (UInt64(UInt32(size)) << 32UL) | UInt64(UInt32(alignment));
}

func stack_reserve(ref pool: StackHomes, bytes: Int, alignment: Int, from_end: Bool = false) -> Int {
// RBP homes use an aligned end offset, SP homes use an aligned start offset
    if (bytes <= 0 || alignment <= 0) { return -1; }
    let padding = (alignment - pool.size % alignment) % alignment;
    if from_end {
        padding = (alignment - (pool.size % alignment + bytes % alignment) % alignment) % alignment;
    }
    if (bytes > 2147483647 - pool.size || padding > 2147483647 - pool.size - bytes) {
        return -1;
    }

    let offset = pool.size + padding;
    pool.size = offset + bytes;
    if from_end { return pool.size; }
    return offset;
}

func stack_begin_block(ref pool: StackHomes, count: Int) -> Void {
    pool.ends = [];
    for (let i = 0; i <= count; i++) {
        pool.ends.append(0);
    }
}

func stack_expire(ref pool: StackHomes, position: Int) -> Void {
// each region has one expiry link, a lifetime is visited once rather than scanned per result
    let index = pool.ends[position];
    pool.ends[position] = 0;
    while (index != 0) {
        let region = pool.regions[index - 1];
        let next = region.next;
        let key = stack_home_key(region.size, region.alignment);
        if (pool.free is null) { pool.free = Dict(); }
        region.next = pool.free.lookup(key);
        pool.regions[index - 1] = region;
        pool.free.put(key, index);
        index = next;
    }
}

func stack_reuse(ref pool: StackHomes, bytes: Int, alignment: Int, last: Int, from_end: Bool = false) -> Int {
// expire after the last instruction finishes, its input homes may still be needed for spills
    if (last < 0 || last + 1 >= pool.ends.length()) { return -1; }
    // exact layout buckets keep lookup bounded, mixed layouts can use more frame space.
    let key = stack_home_key(bytes, alignment);
    let index = 0;
    if (pool.free is !null) { index = pool.free.lookup(key); }
    let offset = -1;

    if (index != 0) {
        let region = pool.regions[index - 1];
        pool.free.put(key, region.next);
        offset = region.offset;
    } else {
        offset = stack_reserve(ref pool, bytes, alignment, from_end);
        if (offset < 0) { return -1; }
        pool.regions.append(StackRegion(offset=offset, size=bytes, alignment=alignment, next=0));
        index = pool.regions.length();
    }

    let region = pool.regions[index - 1];
    region.next = pool.ends[last + 1];
    pool.regions[index - 1] = region;
    pool.ends[last + 1] = index;
    return offset;
}
