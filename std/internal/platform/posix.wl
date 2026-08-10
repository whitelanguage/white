// std/internal/platform/posix.wl
// native posix and libc bindings

import * from "../../sys/target.wl"

extern func malloc(size -> UIntSize) -> AnyPtr from "C";
extern func calloc(count -> UIntSize, size -> UIntSize) -> AnyPtr from "C";
extern func realloc(block -> AnyPtr, size -> UIntSize) -> AnyPtr from "C";
extern func free(block -> AnyPtr) -> Void from "C";

extern func write(fd -> Int, buf -> AnyPtr, count -> UIntSize) -> IntSize from "C";
extern func read(fd -> Int, buf -> AnyPtr, count -> UIntSize) -> IntSize from "C";
extern func getenv(name -> AnyPtr) -> AnyPtr from "C";
extern func system(command -> AnyPtr) -> Int from "C";
extern func exit(status -> Int) -> Void from "C";
extern func __errno_location() -> AnyPtr from "C";
extern func __error() -> AnyPtr from "C";
extern func getpid() -> Int from "C";
extern func fork() -> Int from "C";
extern func execvp(file -> AnyPtr, argv -> AnyPtr) -> Int from "C";
extern func waitpid(pid -> Int, status -> AnyPtr, options -> Int) -> Int from "C";
extern func _exit(status -> Int) -> Void from "C";

extern func fopen(filename -> AnyPtr, mode -> AnyPtr) -> AnyPtr from "C";
extern func fclose(stream -> AnyPtr) -> Int from "C";
extern func fread(p -> AnyPtr, size -> UIntSize, count -> UIntSize, stream -> AnyPtr) -> UIntSize from "C";
extern func fwrite(p -> AnyPtr, size -> UIntSize, count -> UIntSize, stream -> AnyPtr) -> UIntSize from "C";
extern func fseek(stream -> AnyPtr, offset -> IntSize, origin -> Int) -> Int from "C";
extern func ftell(stream -> AnyPtr) -> IntSize from "C";
extern func rewind(stream -> AnyPtr) -> Void from "C";
extern func remove(filename -> AnyPtr) -> Int from "C";

func last_errno() -> Int {
    let address -> AnyPtr = nullptr;
    if (OS == Os.Linux) { address = __errno_location(); }
    else if (OS == Os.MacOS) { address = __error(); }
    if (address is nullptr) { return 0; }
    let ptr value -> Int = address;
    return value[0];
}
