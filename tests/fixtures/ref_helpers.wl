// tests/fixtures/ref_helpers.wl

class Reader<T> {
    func read(values: Vector(T)) -> T {
        return values[0];
    }
}

class GenericReader {
    func read<T>(values: Vector(T)) -> T {
        return values[0];
    }
}

func count<T>(self: Vector(T), other: Vector(T)) -> Int {
    return self.length() + other.length();
}

func grow(self: Vector(Int), other: Vector(Int)) -> Void {
    other.append(3);
}
