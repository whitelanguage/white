// src/linker/coff/library_model.wl

struct CoffLibraryPart(bytes: Vector(Byte), symbols: Vector(String))
struct CoffLibraryEntry(name: String, member: Int)
struct CoffLibraryResult(bytes: Vector(Byte) = [], message: String = "")
