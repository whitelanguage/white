// std/internal/platform/windows.wl
// raw windows bindings

import * from "../../sys/target.wl"
import "internal/runtime/string" as runtime_string

func startup_info_size() -> Int {
    return Int(size_of(AnyPtr) * UIntSize(9) + UIntSize(32));
}

extern "system" {
    func GetProcessHeap() -> AnyPtr;
    func GetCurrentProcessId() -> Int;
    func GetCommandLineW() -> AnyPtr;
    func CommandLineToArgvW(lpCmdLine: AnyPtr, pNumArgs: AnyPtr) -> AnyPtr;
    func LocalFree(hMem: AnyPtr) -> AnyPtr;
    func HeapAlloc(hHeap: AnyPtr, dwFlags: Int, dwBytes: UIntSize) -> AnyPtr;
    func HeapReAlloc(hHeap: AnyPtr, dwFlags: Int, lpMem: AnyPtr, dwBytes: UIntSize) -> AnyPtr;
    func HeapFree(hHeap: AnyPtr, dwFlags: Int, lpMem: AnyPtr) -> Int;
    func GetLastError() -> Int;
    func GetEnvironmentVariableW(lpName: AnyPtr, lpBuffer: AnyPtr, nSize: Int) -> Int;
    func CreateProcessW(lpApplicationName: AnyPtr, lpCommandLine: AnyPtr, lpProcessAttributes: AnyPtr, lpThreadAttributes: AnyPtr, bInheritHandles: Int, dwCreationFlags: Int, lpEnvironment: AnyPtr, lpCurrentDirectory: AnyPtr, lpStartupInfo: AnyPtr, lpProcessInformation: AnyPtr) -> Int;
    func WaitForSingleObject(hHandle: AnyPtr, dwMilliseconds: Int) -> Int;
    func GetExitCodeProcess(hProcess: AnyPtr, lpExitCode: AnyPtr) -> Int;
    func CloseHandle(hObject: AnyPtr) -> Int;
    func CreateFileW(lpFileName: AnyPtr, dwDesiredAccess: Int, dwShareMode: Int, lpSecurityAttributes: AnyPtr, dwCreationDisposition: Int, dwFlagsAndAttributes: Int, hTemplateFile: AnyPtr) -> AnyPtr;
    func GetFileAttributesW(lpFileName: AnyPtr) -> Int;
    func GetFileSizeEx(hFile: AnyPtr, lpFileSize: AnyPtr) -> Int;
    func ReadFile(hFile: AnyPtr, lpBuffer: AnyPtr, nNumberOfBytesToRead: Int, lpNumberOfBytesRead: AnyPtr, lpOverlapped: AnyPtr) -> Int;
    func WriteFile(hFile: AnyPtr, lpBuffer: AnyPtr, nNumberOfBytesToWrite: Int, lpNumberOfBytesWritten: AnyPtr, lpOverlapped: AnyPtr) -> Int;
    func SetFilePointerEx(hFile: AnyPtr, liDistanceToMove: Long, lpNewFilePointer: AnyPtr, dwMoveMethod: Int) -> Int;
    func DeleteFileW(lpFileName: AnyPtr) -> Int;
    func ExitProcess(uExitCode: Int) -> Void;
    func GetStdHandle(nStdHandle: Int) -> AnyPtr;
    func SetConsoleCP(wCodePageID: Int) -> Int;
    func SetConsoleOutputCP(wCodePageID: Int) -> Int;
    func GetConsoleMode(hConsoleHandle: AnyPtr, lpMode: AnyPtr) -> Int;
    func WriteConsoleW(hConsoleOutput: AnyPtr, lpBuffer: AnyPtr, nNumberOfCharsToWrite: Int, lpNumberOfCharsWritten: AnyPtr, lpReserved: AnyPtr) -> Int;
    func MultiByteToWideChar(CodePage: Int, dwFlags: Int, lpMultiByteStr: AnyPtr, cbMultiByte: Int, lpWideCharStr: AnyPtr, cchWideChar: Int) -> Int;
    func WideCharToMultiByte(CodePage: Int, dwFlags: Int, lpWideCharStr: AnyPtr, cchWideChar: Int, lpMultiByteStr: AnyPtr, cbMultiByte: Int, lpDefaultChar: AnyPtr, lpUsedDefaultChar: AnyPtr) -> Int;
}

const STD_INPUT_HANDLE: Int = -10;
const STD_OUTPUT_HANDLE: Int = -11;
const STD_ERROR_HANDLE: Int = -12;
const CP_UTF8: Int = 65001;
const MB_ERR_INVALID_CHARS: Int = 8;
const WC_ERR_INVALID_CHARS: Int = 128;
const HEAP_ZERO_MEMORY: Int = 8;
const ERROR_ENVVAR_NOT_FOUND: Int = 203;
const ERROR_HANDLE_EOF: Int = 38;
const ERROR_BROKEN_PIPE: Int = 109;

const INFINITE: Int = -1;
const WAIT_FAILED: Int = -1;

const GENERIC_READ: Int = -2147483647 - 1;
const GENERIC_WRITE: Int = 1073741824;
const FILE_SHARE_READ: Int = 1;
const FILE_SHARE_WRITE: Int = 2;
const FILE_SHARE_DELETE: Int = 4;
const CREATE_ALWAYS: Int = 2;
const OPEN_EXISTING: Int = 3;
const OPEN_ALWAYS: Int = 4;
const FILE_ATTRIBUTE_NORMAL: Int = 128;
const INVALID_FILE_ATTRIBUTES: Int = -1;
const FILE_BEGIN: Int = 0;
const FILE_CURRENT: Int = 1;
const FILE_END: Int = 2;

func is_invalid_handle(handle: AnyPtr) -> Bool {
    return handle is nullptr || IntSize(handle) == IntSize(-1);
}

func utf8_to_utf16(value: String) -> AnyPtr {
    if (OS != Os.Windows) { return nullptr; }
    if (!runtime_string.is_native_text(value)) { return nullptr; }

    let length: Int = value.length();
    let wide_length: Int = 0;
    if (length > 0) {
        wide_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, runtime_string.data(value), length, nullptr, 0);
        if (wide_length <= 0) { return nullptr; }
    }

    let buffer: AnyPtr = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, UIntSize(wide_length + 1) * UIntSize(2));
    if (buffer is nullptr) { return nullptr; }
    if (wide_length > 0 && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, runtime_string.data(value), length, buffer, wide_length) <= 0) {
        HeapFree(GetProcessHeap(), 0, buffer);
        return nullptr;
    }
    return buffer;
}

func utf16_to_utf8(value: AnyPtr, length: Int) -> String {
    if (OS != Os.Windows) { return null; }
    if (value is nullptr || length < 0) { return null; }
    if (length == 0) { return runtime_string.alloc(0L); }

    let utf8_length: Int = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length, nullptr, 0, nullptr, nullptr);
    if (utf8_length <= 0) { return null; }

    let result: String = runtime_string.alloc(Long(utf8_length));
    if (result is null) { return null; }
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length, runtime_string.data(result), utf8_length, nullptr, nullptr) <= 0) {
        return null;
    }
    return result;
}

func free_utf16(value: AnyPtr) -> Void {
    if (OS != Os.Windows) { return; }
    if (value is !nullptr) { HeapFree(GetProcessHeap(), 0, value); }
}
