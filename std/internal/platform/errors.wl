// std/internal/platform/errors.wl
// platform error conversion

import * from "../../sys/target.wl"
import "windows.wl"
import "posix.wl"

enum Kind {
    None,
    Unknown,
    InvalidArgument,
    OutOfMemory,
    Unsupported,
    Interrupted,
    WouldBlock,
    InProgress,
    TimedOut,
    Cancelled,
    NotFound,
    PermissionDenied,
    AlreadyExists,
    ResourceBusy,
    ReadOnlyFilesystem,
    BrokenPipe,
    StorageFull,
    QuotaExceeded,
    FileTooLarge,
    TooManyOpenFiles,
    NotSeekable,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    NameTooLong,
    CrossDevice,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    NotConnected,
    AddressInUse,
    AddressNotAvailable,
    NetworkDown,
    NetworkUnreachable,
    HostUnreachable,
}

func from_windows(code: Int) -> Kind {
    if (code == 0) { return Kind.None; }
    if (code == 2 || code == 3 || code == 15) { return Kind.NotFound; }
    if (code == 5 || code == 10013) { return Kind.PermissionDenied; }
    if (code == 80 || code == 183) { return Kind.AlreadyExists; }
    if (code == 8 || code == 14) { return Kind.OutOfMemory; }
    if (code == 19) { return Kind.ReadOnlyFilesystem; }
    if (code == 32 || code == 33) { return Kind.ResourceBusy; }
    if (code == 39 || code == 112) { return Kind.StorageFull; }
    if (code == 50) { return Kind.Unsupported; }
    if (code == 109) { return Kind.BrokenPipe; }
    if (code == 145) { return Kind.DirectoryNotEmpty; }
    if (code == 206) { return Kind.NameTooLong; }
    if (code == 995) { return Kind.Cancelled; }
    if (code == 996 || code == 997) { return Kind.InProgress; }
    if (code == 87) { return Kind.InvalidArgument; }
    if (code == 10004) { return Kind.Interrupted; }
    if (code == 10035) { return Kind.WouldBlock; }
    if (code == 10036) { return Kind.InProgress; }
    if (code == 10048) { return Kind.AddressInUse; }
    if (code == 10049) { return Kind.AddressNotAvailable; }
    if (code == 10050) { return Kind.NetworkDown; }
    if (code == 10051) { return Kind.NetworkUnreachable; }
    if (code == 10053) { return Kind.ConnectionAborted; }
    if (code == 10054) { return Kind.ConnectionReset; }
    if (code == 10057) { return Kind.NotConnected; }
    if (code == 10060) { return Kind.TimedOut; }
    if (code == 10061) { return Kind.ConnectionRefused; }
    if (code == 10065) { return Kind.HostUnreachable; }
    return Kind.Unknown;
}

func from_posix(code: Int) -> Kind {
    if (code == 0) { return Kind.None; }
    if (code == 2) { return Kind.NotFound; }
    if (code == 1 || code == 13) { return Kind.PermissionDenied; }
    if (code == 17) { return Kind.AlreadyExists; }
    if (code == 12) { return Kind.OutOfMemory; }
    if (code == 4) { return Kind.Interrupted; }
    if (code == 16) { return Kind.ResourceBusy; }
    if (code == 18) { return Kind.CrossDevice; }
    if (code == 20) { return Kind.NotADirectory; }
    if (code == 21) { return Kind.IsADirectory; }
    if (code == 22) { return Kind.InvalidArgument; }
    if (code == 23 || code == 24) { return Kind.TooManyOpenFiles; }
    if (code == 27) { return Kind.FileTooLarge; }
    if (code == 28) { return Kind.StorageFull; }
    if (code == 29) { return Kind.NotSeekable; }
    if (code == 30) { return Kind.ReadOnlyFilesystem; }
    if (code == 32) { return Kind.BrokenPipe; }

    if (OS == Os.MacOS) {
        if (code == 35) { return Kind.WouldBlock; }
        if (code == 36) { return Kind.InProgress; }
        if (code == 45) { return Kind.Unsupported; }
        if (code == 48) { return Kind.AddressInUse; }
        if (code == 49) { return Kind.AddressNotAvailable; }
        if (code == 50) { return Kind.NetworkDown; }
        if (code == 51) { return Kind.NetworkUnreachable; }
        if (code == 53) { return Kind.ConnectionAborted; }
        if (code == 54) { return Kind.ConnectionReset; }
        if (code == 57) { return Kind.NotConnected; }
        if (code == 60) { return Kind.TimedOut; }
        if (code == 61) { return Kind.ConnectionRefused; }
        if (code == 63) { return Kind.NameTooLong; }
        if (code == 65) { return Kind.HostUnreachable; }
        if (code == 66) { return Kind.DirectoryNotEmpty; }
        if (code == 69) { return Kind.QuotaExceeded; }
        return Kind.Unknown;
    }

    if (code == 11) { return Kind.WouldBlock; }
    if (code == 36) { return Kind.NameTooLong; }
    if (code == 38 || code == 95) { return Kind.Unsupported; }
    if (code == 39) { return Kind.DirectoryNotEmpty; }
    if (code == 98) { return Kind.AddressInUse; }
    if (code == 99) { return Kind.AddressNotAvailable; }
    if (code == 100) { return Kind.NetworkDown; }
    if (code == 101) { return Kind.NetworkUnreachable; }
    if (code == 103) { return Kind.ConnectionAborted; }
    if (code == 104) { return Kind.ConnectionReset; }
    if (code == 107) { return Kind.NotConnected; }
    if (code == 110) { return Kind.TimedOut; }
    if (code == 111) { return Kind.ConnectionRefused; }
    if (code == 113) { return Kind.HostUnreachable; }
    if (code == 115) { return Kind.InProgress; }
    if (code == 122) { return Kind.QuotaExceeded; }
    return Kind.Unknown;
}

func last() -> Kind {
    if (OS == Os.Windows) {
        return from_windows(windows.GetLastError());
    }
    return from_posix(posix.last_errno());
}
