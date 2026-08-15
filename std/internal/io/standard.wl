// std/internal/io/standard.wl
// standard stream access shared by builtin and io

import "sys"
import "internal/platform/windows"
import "internal/platform/posix"
import "internal/platform/errors" as platform_errors
import Error as CoreError from "errors"
import Error as IoError from "../../io/errors.wl"

const STDIN: Int = 0;
const STDOUT: Int = 1;
const STDERR: Int = 2;

let stdin_ready: Bool = false;
let stdout_ready: Bool = false;
let stderr_ready: Bool = false;

func __from_platform(kind: platform_errors.Kind) -> IoError {
    if (kind == platform_errors.Kind.OutOfMemory) { return IoError.OutOfMemory; }
    if (kind == platform_errors.Kind.PermissionDenied) { return IoError.PermissionDenied; }
    if (kind == platform_errors.Kind.Interrupted) { return IoError.Interrupted; }
    if (kind == platform_errors.Kind.WouldBlock) { return IoError.WouldBlock; }
    if (kind == platform_errors.Kind.TimedOut) { return IoError.TimedOut; }
    if (kind == platform_errors.Kind.Cancelled) { return IoError.Cancelled; }
    if (kind == platform_errors.Kind.BrokenPipe) { return IoError.BrokenPipe; }
    if (kind == platform_errors.Kind.StorageFull || kind == platform_errors.Kind.QuotaExceeded) { return IoError.StorageFull; }
    return IoError.Unknown;
}

func __windows_handle(stream: Int) -> AnyPtr {
    if (stream == STDIN) { return windows.GetStdHandle(windows.STD_INPUT_HANDLE); }
    if (stream == STDOUT) { return windows.GetStdHandle(windows.STD_OUTPUT_HANDLE); }
    if (stream == STDERR) { return windows.GetStdHandle(windows.STD_ERROR_HANDLE); }
    return nullptr;
}

func __prepare_windows_stream(stream: Int, handle: AnyPtr) -> Void {
// only touch the code page when the handle belongs to a console
    let mode: Int = 0;
    if (windows.GetConsoleMode(handle, ref mode) == 0) { return; }

    if (stream == STDIN && !stdin_ready) {
        windows.SetConsoleCP(windows.CP_UTF8);
        stdin_ready = true;
    } else if (stream == STDOUT && !stdout_ready) {
        windows.SetConsoleOutputCP(windows.CP_UTF8);
        stdout_ready = true;
    } else if (stream == STDERR && !stderr_ready) {
        windows.SetConsoleOutputCP(windows.CP_UTF8);
        stderr_ready = true;
    }
}

func read(stream: Int, data: AnyPtr, length: Int) -> Int? {
// read performs one blocking operation and may return fewer bytes than requested
    if (stream != STDIN || length < 0 || (length > 0 && data is nullptr)) {
        throw CoreError.InvalidArgument;
    }
    if (length == 0) { return 0; }

    if (sys.OS == sys.Os.Windows) {
        let handle: AnyPtr = __windows_handle(stream);
        if (windows.is_invalid_handle(handle)) { throw IoError.InvalidStream; }
        __prepare_windows_stream(stream, handle);

        let bytes_read: Int = 0;
        if (windows.ReadFile(handle, data, length, ref bytes_read, nullptr) != 0) {
            return bytes_read;
        }
        let code: Int = windows.GetLastError();
        if (code == windows.ERROR_HANDLE_EOF || code == windows.ERROR_BROKEN_PIPE) {
            return 0;
        }
        throw __from_platform(platform_errors.from_windows(code));
    }

    while true {
        let count: IntSize = posix.read(0, data, UIntSize(length));
        if (count >= IntSize(0)) { return Int(count); }
        let err: platform_errors.Kind = platform_errors.last();
        if (err != platform_errors.Kind.Interrupted) { throw __from_platform(err); }
    }
}

func write(stream: Int, data: AnyPtr, length: Int) -> Int? {
// write exposes short writes so callers can choose between progress and all-or-error
    if ((stream != STDOUT && stream != STDERR) || length < 0 || (length > 0 && data is nullptr)) {
        throw CoreError.InvalidArgument;
    }
    if (length == 0) { return 0; }

    if (sys.OS == sys.Os.Windows) {
        let handle: AnyPtr = __windows_handle(stream);
        if (windows.is_invalid_handle(handle)) { throw IoError.InvalidStream; }
        __prepare_windows_stream(stream, handle);

        let bytes_written: Int = 0;
        if (windows.WriteFile(handle, data, length, ref bytes_written, nullptr) == 0) {
            throw __from_platform(platform_errors.last());
        }
        return bytes_written;
    }

    let fd: Int = 1;
    if (stream == STDERR) { fd = 2; }
    while true {
        let count: IntSize = posix.write(fd, data, UIntSize(length));
        if (count >= IntSize(0)) { return Int(count); }
        let err: platform_errors.Kind = platform_errors.last();
        if (err != platform_errors.Kind.Interrupted) { throw __from_platform(err); }
    }
}

func write_all(stream: Int, data: AnyPtr, length: Int) -> Void? {
// keep writing until the entire buffer reaches the stream
    if (length < 0 || (length > 0 && data is nullptr)) { throw CoreError.InvalidArgument; }
    let ptr bytes: Byte = data;
    let offset: Int = 0;
    while (offset < length) {
        let count: Int = write(stream, ref bytes[offset], length - offset)?;
        if (count == 0) { throw IoError.WriteZero; }
        offset += count;
    }
    return;
}

func flush(stream: Int) -> Void? {
// standard streams are currently unbuffered at this layer
    if (stream != STDOUT && stream != STDERR) { throw CoreError.InvalidArgument; }
    return;
}
