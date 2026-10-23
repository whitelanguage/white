// Test: REF_UNION_OWNER
// File: tests/diagnostics/failures/test_ref_union_owner.wl
// Focus: Replacing an Optional owner cannot release storage behind an active element reference.
// Expected Error: "TypeError: Cannot replace managed storage while element reference 'first' is active."

struct Owner(values: Vector(Int))

func main() -> Int {
    let values: Vector(Int) = [1, 2];
    let owner: Optional(Owner) = Owner(values);
    let first = ref values[0];
    owner = null;
    return first;
}
