// src/linker/coff/link_model.wl

struct CoffSymbolRef(object: Int = -1, symbol: Int = -1)
struct CoffAlias(source: CoffSymbolRef, target: CoffSymbolRef)

enum CoffLinkStatus {
    InvalidObject,
    Unsupported,
    DuplicateSymbol,
    UndefinedSymbol,
    InvalidLayout,
    RelocationOverflow
}

struct CoffLinkError(
    status: CoffLinkStatus,
    object: Int,
    section: Int = -1,
    symbol: Int = -1,
    offset: UInt32 = 0U,
    other: CoffSymbolRef = CoffSymbolRef(),
    message: String = ""
)

struct CoffSymbolResult(
    targets: Vector(Vector(CoffSymbolRef)) = [],
    errors: Vector(CoffLinkError) = []
)

// rva points to this input contribution, offset locates it in the output section.
// keeping both is needed when several .text$... contributions share a section.
struct CoffPlacement(rva: UInt32, section: Int, offset: UInt32 = 0U)

struct CoffBaseReloc(rva: UInt32, kind: UInt32)

struct CoffPatch(
    bytes: Vector(Byte) = [],
    base_relocs: Vector(CoffBaseReloc) = [],
    fixed_base: Bool = false
)

struct CoffPatchResult(
    patch: Optional(CoffPatch) = null,
    diagnostic: Optional(CoffLinkError) = null
)
