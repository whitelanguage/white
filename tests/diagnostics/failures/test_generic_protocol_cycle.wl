// Test: GENERIC_PROTOCOL_CYCLE
// File: tests/diagnostics/failures/test_generic_protocol_cycle.wl
// Focus: Rejecting cycles formed by concrete generic interface instances.
// Expected Error: "TypeError: Generic interface inheritance cycle involving 'Right(Int)'."

interface Left<T> with Right(T) {
}

interface Right<T> with Left(T) {
}

class Value with Left(Int) {
}

func main() -> Int {
    return 0;
}
