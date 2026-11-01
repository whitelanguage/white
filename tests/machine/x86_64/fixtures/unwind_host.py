# tests/machine/x86_64/fixtures/unwind_host.py
# run test_unwind with a DLL output path, then pass that path to this Windows host
import ctypes
from pathlib import Path
import sys

library = ctypes.WinDLL(str(Path(sys.argv[1]).resolve()))
kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.RtlLookupFunctionEntry.argtypes = [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
kernel.RtlLookupFunctionEntry.restype = ctypes.c_void_p
kernel.RtlVirtualUnwind.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_void_p,
                                  ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
                                  ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
kernel.RtlVirtualUnwind.restype = ctypes.c_void_p

for name in ("Small", "Large", "Huge"):
    function = getattr(library, name)
    function.argtypes = [ctypes.c_int] * 4
    function.restype = ctypes.c_int
    assert function(10, 20, 5, 7) == 42, name
    start = ctypes.cast(function, ctypes.c_void_p).value
    base = ctypes.c_uint64()
    entry = kernel.RtlLookupFunctionEntry(start, ctypes.byref(base), None)
    assert entry and base.value == library._handle
    row = (ctypes.c_uint32 * 3).from_address(entry)
    info = ctypes.string_at(base.value + row[2], 16)
    prologue = info[1]
    kind, opinfo = info[5] & 15, info[5] >> 4
    if kind == 2:
        allocation = (opinfo + 1) * 8
    elif opinfo == 0:
        allocation = int.from_bytes(info[6:8], "little") * 8
    else:
        allocation = int.from_bytes(info[6:10], "little")
    code = ctypes.string_at(start, row[1] - row[0])
    assert code[-6:] == bytes.fromhex("488d65005dc3"), code[-6:]
    # At PC 4 the frame pointer is established. Probes do not adjust RSP.
    positions = [0, 1, 4, prologue, prologue + 1, len(code) - 6, len(code) - 2, len(code) - 1]
    if allocation >= 4096:
        positions += [7, 15, 22, 25, 31, 35, 40, 44]
    for pc_offset in positions:
        stack = ctypes.create_string_buffer(allocation + 4096)
        caller_rsp = (ctypes.addressof(stack) + allocation + 2048) & ~15
        old_rbp, return_pc = 0x88776655, 0x11223344
        ctypes.c_uint64.from_address(caller_rsp).value = return_pc
        ctypes.c_uint64.from_address(caller_rsp - 8).value = old_rbp
        raw = ctypes.create_string_buffer(1232 + 16)
        context = (ctypes.addressof(raw) + 15) & ~15
        ctypes.c_uint32.from_address(context + 48).value = 0x100003
        rsp, rbp = caller_rsp, old_rbp
        if pc_offset >= 1:
            rsp -= 8
        if pc_offset >= 4:
            rbp = caller_rsp - 8
        if pc_offset >= prologue:
            rsp -= allocation
        if pc_offset == len(code) - 2:
            rsp = caller_rsp - 8
        if pc_offset == len(code) - 1:
            rsp, rbp = caller_rsp, old_rbp
        ctypes.c_uint64.from_address(context + 152).value = rsp
        ctypes.c_uint64.from_address(context + 160).value = rbp
        ctypes.c_uint64.from_address(context + 248).value = start + pc_offset
        handler_data = ctypes.c_void_p()
        frame = ctypes.c_uint64()
        kernel.RtlVirtualUnwind(0, base.value, start + pc_offset, entry, context,
                                ctypes.byref(handler_data), ctypes.byref(frame), None)
        actual = tuple(ctypes.c_uint64.from_address(context + off).value for off in (152, 160, 248))
        assert actual == (caller_rsp + 8, old_rbp, return_pc), (name, pc_offset, actual)
    print(f"PASS: {name}, allocation={allocation}, prologue={prologue}, checked {len(positions)} PCs")
