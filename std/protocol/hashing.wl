// hash keys must use the same notion of equality as their hash function

import Equal from "comparison.wl"

interface Hash with Equal {
    func hash() -> Int;
}
