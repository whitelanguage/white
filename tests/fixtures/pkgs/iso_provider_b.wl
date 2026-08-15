// Support: MODULE_ISOLATION_PROVIDER_B
// File: tests/fixtures/pkgs/iso_provider_b.wl
// Focus: Providing symbol 'str' for testing namespace isolation.

func str(s: String) -> String {
    return s;
}
