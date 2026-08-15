// Support: MODULE_ISOLATION_PROVIDER_A
// File: tests/fixtures/pkgs/iso_provider_a.wl
// Focus: Providing symbol 'str' for testing namespace isolation.

func str(s: String) -> String {
    return s;
}
