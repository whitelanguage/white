// std/hash.wl
// contracts for values used by hash-based collections

interface Hash {
    func hash() -> Int;
}

interface Eq<T> {
    func equals(other: T) -> Bool;
}
