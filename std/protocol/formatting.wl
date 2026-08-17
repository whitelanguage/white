// display is for user-facing text; debug is for diagnostics and inspection

interface Display {
    func display() -> String;
}

interface Debug {
    func debug() -> String;
}
