func total(values: Int..., base: Int = 0) -> Int {
    let result: Int = base;
    let i: Int = 0;
    while (i < values.length()) {
        result += values[i];
        i++;
    }
    return result;
}
