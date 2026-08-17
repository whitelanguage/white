// comparison contracts used by generic algorithms and ordered collections

enum Ordering {
    Less,
    Equal,
    Greater
}

interface Equal {
    func equals(other: Self) -> Bool;
}

interface Comparable with Equal {
    func compare(other: Self) -> Ordering;
}
