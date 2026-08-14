// std/hash.wl
// contracts for values used by hash-based collections

interface Hash {
    method hash() -> Int;
}

interface Eq<T> {
    method equals(other -> T) -> Bool;
}
