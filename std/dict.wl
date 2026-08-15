// std/dict.wl
// dynamic hash table with type-aware keys and values

import "internal/runtime"
import Hash, Eq from "hash"

error Error {
    KeyNotFound
}

@CompilerIntrinsic
struct Variant(
    // compiler internal implementation
)

@CompilerLink("dict_key_hash")
func __key_hash(key: Variant) -> Int {
    // the previous compiler uses this body while bootstrapping the intrinsic
    let text: String = key;
    let hash: Int = 5381;
    let i: Int = 0;
    while (i < text.length()) {
        hash = ((hash << 5) + hash) ^ Int(text[i]);
        i++;
    }
    if (hash < 0) { hash = ~hash; }
    if (hash < 2) { hash += 2; }
    return hash;
}

@CompilerLink("dict_keys_equal")
func __keys_equal(left: Variant, right: Variant) -> Bool {
    let left_text: String = left;
    let right_text: String = right;
    return left_text == right_text;
}

class Dict {
    let ptr keys: Variant = nullptr; 
    let ptr values: Variant = nullptr;
    let ptr hashes: Int    = nullptr;
    let capacity: Int = 0;
    let size: Int = 0;
    let tombstones: Int = 0;

    init(cap: Int) {
        let actual_cap: Int = 8;
        while (actual_cap < cap) {
            if (actual_cap >= 1073741824) {
                runtime.panic_capacity_overflow("Dict");
                return;
            }
            actual_cap <<= 1;
        }

        let slot_size: UIntSize = runtime.pointer_size();
        let ptr new_keys: Variant = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * slot_size);
        let ptr new_values: Variant = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * slot_size);
        let ptr new_hashes: Int = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * UIntSize(4));
        if (new_keys is nullptr || new_values is nullptr || new_hashes is nullptr) {
            runtime.mem_dealloc(new_keys);
            runtime.mem_dealloc(new_values);
            runtime.mem_dealloc(new_hashes);
            runtime.panic_out_of_memory("Dict");
            return;
        }

        self.keys = new_keys;
        self.values = new_values;
        self.hashes = new_hashes;
        self.capacity = actual_cap;
    }

    func __hash(key: Variant) -> Int {
        let hash: Int = __key_hash(key);
        if (hash < 2) {
            runtime.panic("Dict key is not hashable");
            return 2;
        }
        return hash;
    }

    func __release_slots(ptr slot_keys: Variant, ptr slot_values: Variant, ptr slot_hashes: Int, cap: Int) -> Void {
        let i: Int = 0;
        while (i < cap) {
            if (slot_hashes[i] >= 2) {
                slot_keys[i] = null;
                slot_values[i] = null;
            }
            i += 1;
        }
    }

    func __rehash(new_cap: Int) -> Void {
        let old_cap: Int = self.capacity;
        let ptr old_keys: Variant = self.keys;
        let ptr old_values: Variant = self.values;
        let ptr old_hashes: Int = self.hashes;
        let slot_size: UIntSize = runtime.pointer_size();
        let ptr new_keys: Variant = runtime.mem_alloc_zeroed(UIntSize(new_cap) * slot_size);
        let ptr new_values: Variant = runtime.mem_alloc_zeroed(UIntSize(new_cap) * slot_size);
        let ptr new_hashes: Int = runtime.mem_alloc_zeroed(UIntSize(new_cap) * UIntSize(4));
        if (new_keys is nullptr || new_values is nullptr || new_hashes is nullptr) {
            runtime.mem_dealloc(new_keys);
            runtime.mem_dealloc(new_values);
            runtime.mem_dealloc(new_hashes);
            runtime.panic_out_of_memory("Dict");
            return;
        }

        self.capacity = new_cap;
        self.keys = new_keys;
        self.values = new_values;
        self.hashes = new_hashes;
        self.tombstones = 0;

        let mask: Int = new_cap - 1;
        let i: Int = 0;
        while (i < old_cap) {
            let hash: Int = old_hashes[i];
            if (hash >= 2) {
                let idx: Int = hash & mask;
                while (new_hashes[idx] != 0) { idx = (idx + 1) & mask; }
                new_hashes[idx] = hash;
                new_keys[idx] = old_keys[i];
                new_values[idx] = old_values[i];
            }
            i++;
        }

        self.__release_slots(old_keys, old_values, old_hashes, old_cap);
        runtime.mem_dealloc(old_keys);
        runtime.mem_dealloc(old_values);
        runtime.mem_dealloc(old_hashes);
    }

    func __prepare_insert() -> Bool {
        if ((self.size + self.tombstones + 1) * 3 < self.capacity * 2) { return false; }
        if ((self.size + 1) * 3 < self.capacity * 2) {
            self.__rehash(self.capacity);
            return true;
        }
        if (self.capacity >= 1073741824) {
            runtime.panic_capacity_overflow("Dict");
            return false;
        }
        self.__rehash(self.capacity << 1);
        return true;
    }

    func put(key: Variant, value: Variant) -> Void {
        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        let first_tombstone: Int = -1;

        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                if (self.__prepare_insert()) {
                    self.put(key, value);
                    return;
                }
                if (first_tombstone != -1) {
                    idx = first_tombstone;
                    self.tombstones--;
                }
                self.hashes[idx] = hash;
                self.keys[idx] = key;
                self.values[idx] = value;
                self.size++;
                return;
            }
            if (current == 1) {
                if (first_tombstone == -1) { first_tombstone = idx; }
            } else if (current == hash && __keys_equal(self.keys[idx], key)) {
                self.values[idx] = value;
                return;
            }
            idx = (idx + 1) & mask;
        }
    }

    func get(key: Variant) -> Variant {
        if (self.size == 0) { return null; }
        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) { return null; }
            if (current == hash && __keys_equal(self.keys[idx], key)) { return self.values[idx]; }
            idx = (idx + 1) & mask;
        }
        return null;
    }

    func remove(key: Variant) -> Void {
        if (self.size == 0) { return; }
        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) { return; }
            if (current == hash && __keys_equal(self.keys[idx], key)) {
                self.hashes[idx] = 1;
                self.keys[idx] = null;
                self.values[idx] = null;
                self.size--;
                self.tombstones++;
                return;
            }
            idx = (idx + 1) & mask;
        }
    }

    func contains_key(key: Variant) -> Bool {
        if (self.size == 0) { return false; }
        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) { return false; }
            if (current == hash && __keys_equal(self.keys[idx], key)) { return true; }
            idx = (idx + 1) & mask;
        }
        return false;
    }

    func length() -> Int {
        return self.size;
    }

    func is_empty() -> Bool {
        return self.size == 0;
    }

    func clear() -> Void {
        self.__release_slots(self.keys, self.values, self.hashes, self.capacity);
        runtime.mem_set(self.hashes, 0, UIntSize(self.capacity) * UIntSize(4));
        self.size = 0;
        self.tombstones = 0;
    }

    deinit() {
        if (self.keys is !nullptr && self.values is !nullptr && self.hashes is !nullptr) { self.__release_slots(self.keys, self.values, self.hashes, self.capacity); }
        if (self.keys is !nullptr) { runtime.mem_dealloc(self.keys); self.keys = nullptr; }
        if (self.values is !nullptr) { runtime.mem_dealloc(self.values); self.values = nullptr; }
        if (self.hashes is !nullptr) { runtime.mem_dealloc(self.hashes); self.hashes = nullptr; }
    }
}

class Dict<K: Hash + Eq(K), V> {
    let ptr keys: K = nullptr;
    let ptr values: V = nullptr;
    let ptr hashes: Int = nullptr;
    let capacity: Int = 0;
    let size: Int = 0;
    let tombstones: Int = 0;

    init() {
        let actual_cap: Int = 8;
        let ptr new_keys: K = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * size_of(K));
        let ptr new_values: V = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * size_of(V));
        let ptr new_hashes: Int = runtime.mem_alloc_zeroed(UIntSize(actual_cap) * size_of(Int));

        if (new_keys is nullptr || new_values is nullptr || new_hashes is nullptr) {
            runtime.mem_dealloc(new_keys);
            runtime.mem_dealloc(new_values);
            runtime.mem_dealloc(new_hashes);
            runtime.panic_out_of_memory("Dict");
            return;
        }

        self.keys = new_keys;
        self.values = new_values;
        self.hashes = new_hashes;
        self.capacity = actual_cap;
    }

    @CompilerLink("hash_value")
    func __hash(key: K) -> Int {
        return 0;
    }

    @CompilerLink("values_equal")
    func __equal(left: K, right: K) -> Bool {
        return false;
    }

    @CompilerLink("zero_value")
    func __zero_key() -> K {
        return null;
    }

    @CompilerLink("zero_value")
    func __zero_value() -> V {
        return null;
    }

    func __clear_slots(ptr slot_keys: K, ptr slot_values: V, ptr slot_hashes: Int, cap: Int) -> Void {
        let i: Int = 0;
        while (i < cap) {
            if (slot_hashes[i] >= 2) {
                slot_keys[i] = self.__zero_key();
                slot_values[i] = self.__zero_value();
            }
            i++;
        }
    }

    func __rehash(new_cap: Int) -> Void {
        let old_cap: Int = self.capacity;
        let ptr old_keys: K = self.keys;
        let ptr old_values: V = self.values;
        let ptr old_hashes: Int = self.hashes;
        let ptr new_keys: K = runtime.mem_alloc_zeroed(UIntSize(new_cap) * size_of(K));
        let ptr new_values: V = runtime.mem_alloc_zeroed(UIntSize(new_cap) * size_of(V));
        let ptr new_hashes: Int = runtime.mem_alloc_zeroed(UIntSize(new_cap) * size_of(Int));
    
        if (new_keys is nullptr || new_values is nullptr || new_hashes is nullptr) {
            runtime.mem_dealloc(new_keys);
            runtime.mem_dealloc(new_values);
            runtime.mem_dealloc(new_hashes);
            runtime.panic_out_of_memory("Dict");
            return;
        }

        self.capacity = new_cap;
        self.keys = new_keys;
        self.values = new_values;
        self.hashes = new_hashes;
        self.tombstones = 0;

        let mask: Int = new_cap - 1;
        let i: Int = 0;
        while (i < old_cap) {
            let hash: Int = old_hashes[i];
            if (hash >= 2) {
                let idx: Int = hash & mask;
                while (new_hashes[idx] != 0) { idx = (idx + 1) & mask; }
                new_hashes[idx] = hash;
                new_keys[idx] = old_keys[i];
                new_values[idx] = old_values[i];
            }
            i++;
        }

        self.__clear_slots(old_keys, old_values, old_hashes, old_cap);
        runtime.mem_dealloc(old_keys);
        runtime.mem_dealloc(old_values);
        runtime.mem_dealloc(old_hashes);
    }

    func __prepare_insert() -> Bool {
        if ((self.size + self.tombstones + 1) * 3 < self.capacity * 2) {
            return false;
        }
        if ((self.size + 1) * 3 < self.capacity * 2) {
            self.__rehash(self.capacity);
            return true;
        }
        if (self.capacity >= 1073741824) {
            runtime.panic_capacity_overflow("Dict");
            return false;
        }

        self.__rehash(self.capacity << 1);
        return true;
    }

    func put(key: K, value: V) -> Void {
        let hash: Int = self.__hash(key);
        if (hash < 2) {
            runtime.panic("Dict key is not hashable");
            return;
        }

        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        let first_tombstone: Int = -1;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                if (self.__prepare_insert()) {
                    self.put(key, value);
                    return;
                }
                if (first_tombstone != -1) {
                    idx = first_tombstone;
                    self.tombstones--;
                }

                self.hashes[idx] = hash;
                self.keys[idx] = key;
                self.values[idx] = value;
                self.size++;
                return;
            }
            if (current == 1) {
                if (first_tombstone == -1) {
                    first_tombstone = idx;
                }
            }
            else if (current == hash && self.__equal(self.keys[idx], key)) {
                self.values[idx] = value;
                return;
            }

            idx = (idx + 1) & mask;
        }
    }

    func get(key: K) -> V? {
        if (self.size == 0) {
            throw Error.KeyNotFound;
        }

        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                throw Error.KeyNotFound;
            }
            if (current == hash && self.__equal(self.keys[idx], key)) {
                return self.values[idx];
            }
            idx = (idx + 1) & mask;
        }
        throw Error.KeyNotFound;
    }

    func lookup(key: K) -> V {
        if (self.size == 0) {
            return self.__zero_value();
        }

        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                return self.__zero_value();
            }
            if (current == hash && self.__equal(self.keys[idx], key)) {
                return self.values[idx];
            }
            idx = (idx + 1) & mask;
        }
        return self.__zero_value();
    }

    func remove(key: K) -> Bool {
        if (self.size == 0) {
            return false;
        }

        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                return false;
            }

            if (current == hash && self.__equal(self.keys[idx], key)) {
                self.hashes[idx] = 1;
                self.keys[idx] = self.__zero_key();
                self.values[idx] = self.__zero_value();
                self.size--;
                self.tombstones++;
                return true;
            }

            idx = (idx + 1) & mask;
        }
        return false;
    }

    func contains_key(key: K) -> Bool {
        if (self.size == 0) {
            return false;
        }

        let hash: Int = self.__hash(key);
        let mask: Int = self.capacity - 1;
        let idx: Int = hash & mask;
        while true {
            let current: Int = self.hashes[idx];
            if (current == 0) {
                return false;
            }
            if (current == hash && self.__equal(self.keys[idx], key)) {
                return true;
            }
            idx = (idx + 1) & mask;
        }
        return false;
    }

    func length() -> Int {
        return self.size;
    }

    func is_empty() -> Bool {
        return self.size == 0;
    }

    func clear() -> Void {
        self.__clear_slots(self.keys, self.values, self.hashes, self.capacity);
        runtime.mem_set(self.hashes, 0, UIntSize(self.capacity) * size_of(Int));

        self.size = 0;
        self.tombstones = 0;
    }

    deinit() {
        if (self.keys is !nullptr && 
            self.values is !nullptr && 
            self.hashes is !nullptr) {
            self.__clear_slots(self.keys, self.values, self.hashes, self.capacity);
        }
        if (self.keys is !nullptr) {
            runtime.mem_dealloc(self.keys);
            self.keys = nullptr;
        }
        if (self.values is !nullptr) {
            runtime.mem_dealloc(self.values);
            self.values = nullptr;
        }
        if (self.hashes is !nullptr) {
            runtime.mem_dealloc(self.hashes);
            self.hashes = nullptr;
        }
    }
}
