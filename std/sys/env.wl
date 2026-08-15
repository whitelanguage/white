// std/sys/env.wl
// system environment access

import * from "target.wl"
import "internal/platform/windows"
import "internal/platform/posix"
import "internal/platform/errors" as platform_errors
import "internal/runtime/string" as runtime_string
import Error as CoreError from "errors"

error Error {
    Unknown,
    NotFound,
    PermissionDenied,
    InvalidName,
    InvalidData,
}

func __from_platform(kind: platform_errors.Kind) -> Error {
    if (kind == platform_errors.Kind.NotFound) { return Error.NotFound; }
    if (kind == platform_errors.Kind.PermissionDenied) { return Error.PermissionDenied; }
    if (kind == platform_errors.Kind.InvalidArgument) { return Error.InvalidName; }
    return Error.Unknown;
}

func get(name: String) -> String? {
    if (!runtime_string.is_native_text(name) || name.length() == 0) { throw Error.InvalidName; }
    let i: Int = 0;
    while (i < name.length()) {
        if (name[i] == Byte(61)) { throw Error.InvalidName; }
        i += 1;
    }
    if (OS == Os.Windows) {
        let wide_name: AnyPtr = windows.utf8_to_utf16(name);
        if (wide_name is nullptr) { throw CoreError.OutOfMemory; }

        let required: Int = windows.GetEnvironmentVariableW(wide_name, nullptr, 0);
        if (required <= 0) {
            let code: Int = windows.GetLastError();
            windows.free_utf16(wide_name);
            if (code == windows.ERROR_ENVVAR_NOT_FOUND) { throw Error.NotFound; }
            throw __from_platform(platform_errors.from_windows(code));
        }

        let wide_value: AnyPtr = windows.HeapAlloc(windows.GetProcessHeap(), windows.HEAP_ZERO_MEMORY, UIntSize(required) * UIntSize(2));
        if (wide_value is nullptr) {
            windows.free_utf16(wide_name);
            throw CoreError.OutOfMemory;
        }

        let length: Int = windows.GetEnvironmentVariableW(wide_name, wide_value, required);
        windows.free_utf16(wide_name);
        if (length <= 0 || length >= required) {
            let err: Error = __from_platform(platform_errors.last());
            windows.free_utf16(wide_value);
            throw err;
        }

        let result: String = windows.utf16_to_utf8(wide_value, length);
        windows.free_utf16(wide_value);
        if (result is null) { throw CoreError.OutOfMemory; }
        return result;
    }

    let native_value: AnyPtr = posix.getenv(runtime_string.data(name));
    let result: String = runtime_string.from_c_string(native_value);
    if (result is null) { throw Error.NotFound; }
    if (!runtime_string.is_native_text(result)) { throw Error.InvalidData; }
    return result;
}

func get_env(name: String) -> String {
    let result: String = get(name)?;
    catch(err) {
        return null;
    }
    return result;
}
