// Test: UNION_VALUES
// File: tests/language/types/test_union_values.wl
// Focus: Inline union construction, assignment, widening and value passing.

type (Int | String | Null) as Mixed;

class Holder {
    let value: Optional(Int);

    init(value: Int) {
        self.value = value;
    }
}

func int_payload(ref value: Optional(Int)) -> Int {
// read the known Int arm to check payload copies before branch narrowing is added
    let ptr words: Int = AnyPtr(ref value);
    return words[1];
}

func maybe(value: Int) -> Optional(Int) {
    if (value < 0) { return null; }
    return value;
}

func relay(value: Optional(Int)) -> Optional(Int) {
    return value;
}

func widen(value: Optional(Int)) -> Mixed {
    return value;
}

func wide_payload(ref value: Optional(UInt128)) -> UInt128 {
    let ptr words: UInt128 = AnyPtr(ref value);
    return words[1];
}

func relay_wide(value: Optional(UInt128)) -> Optional(UInt128) {
    return value;
}

func float_payload(ref value: Optional(Float)) -> Float {
    let ptr words: Float = AnyPtr(ref value);
    return words[1];
}

func main() -> Int {
    let empty: Optional(Vector(String)) = [];
    let numbers: Optional(Vector(Int)) = [1, 2];
    if (empty is null || numbers is null) { return 1; }
    empty = null;
    numbers = null;

    let value: Optional(Int) = 42;
    if (value is null || int_payload(ref value) != 42) {
        print("FAIL: construct Int member");
        return 1;
    }
    value = null;
    if (null is !value) {
        print("FAIL: assign Null member");
        return 1;
    }
    value = -19;
    let copy = relay(value);
    value = null;
    if (copy is null || int_payload(ref copy) != -19) {
        print("FAIL: copy and parameter passing");
        return 1;
    }
    let wide: Mixed = widen(copy);
    if (wide is null || widen(maybe(-1)) is !null) {
        print("FAIL: remap union tags");
        return 1;
    }
    wide = "text";
    wide = null;
    if (wide is !null || maybe(7) is null) {
        print("FAIL: return and reassignment");
        return 1;
    }

    let holder = Holder(23);
    if (int_payload(ref holder.value) != 23) {
        print("FAIL: union field");
        return 1;
    }
    holder.value = null;
    if (holder.value is !null) { return 1; }

    let large: Optional(UInt128) = 340282366920938463463374607431768211455ULL;
    if (large is null || wide_payload(ref large) != 340282366920938463463374607431768211455ULL) {
        print("FAIL: UInt128 payload");
        return 1;
    }
    let large_copy = relay_wide(large);
    large = null;
    if (large_copy is null || wide_payload(ref large_copy) != 340282366920938463463374607431768211455ULL) { return 1; }
    let fraction: Optional(Float) = 1.25;
    if (fraction is null || float_payload(ref fraction) != 1.25) {
        print("FAIL: floating payload");
        return 1;
    }

    let i: Int = 0;
    while (i < 1000) {
        value = i;
        if (int_payload(ref value) != i) { return 1; }
        i++;
    }

    print("PASS: union values");
    return 0;
}
