// compiler/wir/runtime.wl

// these offsets describe the payload pointer used by retain and release
const WIR_ARC_REFCOUNT_OFFSET: Int = -8;
const WIR_ARC_TYPE_OFFSET: Int = -4;
const WIR_ARC_DROP_OFFSET: Int = -16;
const WIR_STRING_HEADER_SIZE: Int = 8;
const WIR_OBJECT_HEADER_SIZE: Int = 16;
const WIR_STATIC_REFCOUNT: UInt32 = 4294967295U;
