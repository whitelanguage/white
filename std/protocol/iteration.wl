// end is normal iterator exhaustion; other errors still travel through T?

error IterationError {
    End
}

interface Iterator<T> {
    func next() -> T?;
}

interface Iterable<T> {
    func iterator() -> Iterator(T);
}
