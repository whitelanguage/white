// src/linker/coff/model.wl

struct CoffSpan(offset: Int = 0, size: Int = 0)

struct CoffReloc(offset: UInt32, symbol: Int, kind: UInt32)

struct CoffSection(
    name: CoffSpan,
    size: UInt32,
    address: UInt32,
    data: CoffSpan,
    flags: UInt32,
    alignment: Int,
    relocs: Vector(CoffReloc),
    lines: CoffSpan,
    selection: UInt32 = 0U,
    leader: Int = -1,
    parent: Int = -1,
    selected: Bool = false,
    discarded: Bool = false
)

struct CoffSymbol(
    name: CoffSpan,
    value: UInt32,
    section: Int,
    type: UInt32,
    storage: Byte,
    table_index: Int,
    aux: CoffSpan,
    weak_target: Int = -1,
    weak_search: UInt32 = 0U
)

// names, section bytes and auxiliary records refer into this retained buffer.
// callers must keep the buffer unchanged while using the decoded tables.
struct CoffObject(
    bytes: Vector(Byte) = [],
    sections: Vector(CoffSection) = [],
    symbols: Vector(CoffSymbol) = [],
    symbol_map: Vector(Int) = [],
    timestamp: UInt32 = 0U,
    flags: UInt32 = 0U
)

enum CoffError {
    None,
    InvalidObject,
    UnsupportedObject
}

struct CoffResult(
    object: Optional(CoffObject) = null,
    status: CoffError = CoffError.None,
    offset: Int = 0,
    message: String = ""
)
