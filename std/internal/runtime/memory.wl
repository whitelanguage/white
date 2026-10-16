// std/internal/runtime/memory.wl
// compiler memory hooks

import "sys"
import "internal/platform/windows"
import "internal/platform/posix"


func pointer_size() -> UIntSize {
    return size_of(AnyPtr);
}

func __win32_alloc(size: UIntSize, flags: Int) -> AnyPtr {
    // HeapAlloc only promises eight-byte alignment on Win32, LLVM expects
    // sixteen for i128 and records containing it. Keep the heap address and
    // requested size just before the aligned payload for free and resize.
    let extra: UIntSize = UIntSize(23);
    if (size > ~UIntSize(0) - extra) { return nullptr; }
    let raw: AnyPtr = windows.HeapAlloc(windows.GetProcessHeap(), flags, size + extra);
    if (raw is nullptr) { return nullptr; }

    let address: UIntSize = (UIntSize(raw) + extra) & ~UIntSize(15);
    let ptr header: UIntSize = AnyPtr(address - UIntSize(8));
    header[0] = UIntSize(raw);
    header[1] = size;

    return AnyPtr(address);
}

@CompilerLink("memory_alloc")
func mem_alloc(size: UIntSize) -> AnyPtr {
    if (size == UIntSize(0)) { size = UIntSize(1); }
    if (sys.OS == sys.Os.Windows) {
        if (size_of(AnyPtr) == UIntSize(4)) {
            return __win32_alloc(size, 0);
        }
        return windows.HeapAlloc(windows.GetProcessHeap(), 0, size);
    }
    return posix.malloc(size);
}

@CompilerLink("memory_alloc_zeroed")
func mem_alloc_zeroed(size: UIntSize) -> AnyPtr {
    if (size == UIntSize(0)) { size = UIntSize(1); }
    if (sys.OS == sys.Os.Windows) {
        if (size_of(AnyPtr) == UIntSize(4)) {
            return __win32_alloc(size, windows.HEAP_ZERO_MEMORY);
        }
        return windows.HeapAlloc(windows.GetProcessHeap(), windows.HEAP_ZERO_MEMORY, size);
    }
    return posix.calloc(UIntSize(1), size);
}

@CompilerLink("memory_resize")
func mem_resize(block: AnyPtr, size: UIntSize) -> AnyPtr {
    if (block is nullptr) {
        return mem_alloc(size);
    }
    if (size == UIntSize(0)) { size = UIntSize(1); }
    if (sys.OS == sys.Os.Windows) {
        if (size_of(AnyPtr) == UIntSize(4)) {
            let next: AnyPtr = __win32_alloc(size, 0);
            if (next is nullptr) { return nullptr; }

            let ptr header: UIntSize = AnyPtr(UIntSize(block) - UIntSize(8));
            let count: UIntSize = header[1];
            if (count > size) { count = size; }
            mem_copy(next, block, count);
            windows.HeapFree(windows.GetProcessHeap(), 0, AnyPtr(header[0]));

            return next;
        }
        return windows.HeapReAlloc(windows.GetProcessHeap(), 0, block, size);
    }
    return posix.realloc(block, size);
}

@CompilerLink("memory_free")
func mem_dealloc(block: AnyPtr) -> Void {
    if (block is nullptr) { return; }
    if (sys.OS == sys.Os.Windows) {
        if (size_of(AnyPtr) == UIntSize(4)) {
            let ptr header: UIntSize = AnyPtr(UIntSize(block) - UIntSize(8));
            windows.HeapFree(windows.GetProcessHeap(), 0, AnyPtr(header[0]));
            return;
        }
        windows.HeapFree(windows.GetProcessHeap(), 0, block);
        return;
    }
    posix.free(block);
}

@CompilerLink("memory_copy")
func mem_copy(dest: AnyPtr, src: AnyPtr, count: UIntSize) -> AnyPtr {
    if (dest is nullptr || src is nullptr || count == UIntSize(0)) { return dest; }
    let ptr d: Byte = dest;
    let ptr s: Byte = src;
    let i: UIntSize = UIntSize(0);
    while (i < count) {
        let idx: Int = Int(i);
        d[idx] = s[idx];
        i += UIntSize(1);
    }
    return dest;
}

@CompilerLink("memory_set")
func mem_set(dest: AnyPtr, value: Byte, count: UIntSize) -> AnyPtr {
    if (dest is nullptr || count == UIntSize(0)) { return dest; }
    let ptr d: Byte = dest;
    let i: UIntSize = UIntSize(0);
    while (i < count) {
        d[Int(i)] = value;
        i += UIntSize(1);
    }
    return dest;
}
