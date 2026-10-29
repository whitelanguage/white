// tests/fixtures/native_storage.c
#include <stdint.h>

static void *missing;
void **native_missing_slot(void) { return &missing; }
void *native_echo_slot(void *slot) { return slot; }
void native_write_bool(void *slot) { *(uint8_t *)slot = 2; }

typedef struct { void *text; } TextRecord;
static TextRecord record;
TextRecord *native_missing_record(void) { return &record; }

typedef struct { uint32_t tag; void *payload; } OptionalText;
static OptionalText invalid_tag = {99, 0};
static OptionalText absent;
OptionalText *native_invalid_optional(void) { return &invalid_tag; }
OptionalText *native_absent_optional(void) { return &absent; }

static uint8_t invalid_bool = 2;
uint8_t *native_bool_slot(void) { return &invalid_bool; }
typedef struct { uint8_t flag; } BoolRecord;
static BoolRecord bad_flag = {2};
BoolRecord *native_bool_record(void) { return &bad_flag; }
typedef struct { uint8_t flags[3]; } BoolArray;
static BoolArray bad_flags = {{0, 1, 2}};
BoolArray *native_bool_array(void) { return &bad_flags; }
typedef struct { uint32_t tag; uint8_t flag; } OptionalBool;
static OptionalBool bad_optional = {1, 2};
static OptionalBool inactive_optional = {0, 2};
OptionalBool *native_bool_optional(void) { return &bad_optional; }
OptionalBool *native_inactive_bool(void) { return &inactive_optional; }
static uint32_t invalid_char = 0xD800;
uint32_t *native_char_slot(void) { return &invalid_char; }
uint32_t native_char(void) { return invalid_char; }
uint32_t native_valid_char(void) { return 0x10FFFF; }
uint32_t native_char_out_of_range(void) { return 0x110000; }
typedef struct { uint32_t letter; } CharRecord;
static CharRecord bad_letter = {0xDFFF};
CharRecord *native_char_record(void) { return &bad_letter; }
extern int exported_native_char(uint32_t);
int native_bad_char_export(void) { return exported_native_char(invalid_char); }
int native_good_char_export(void) { return exported_native_char(0x10FFFF); }

// domains are numeric identities, an unknown domain must not become an address.
typedef struct { uint64_t domain; int32_t code; } NativeError;
typedef struct { uint8_t failed; NativeError error; } FailedVoid;
static FailedVoid bad_failure = {2, {0, 0}};
FailedVoid *native_failure_slot(void) { return &bad_failure; }
FailedVoid native_unknown_error(void) {
    FailedVoid value = {1, {0xDEADBEEF00112233ULL, 19}};
    return value;
}
