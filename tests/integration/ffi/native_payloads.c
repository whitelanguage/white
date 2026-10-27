#include <stdint.h>
#include <stddef.h>

typedef struct { void *text; } Box;
typedef struct { uint32_t tag; void *text; } OptionalText;
typedef struct { void *values[2]; } TextArray;
typedef struct { uint8_t failed; uint64_t error_type; int32_t error_code; void *text; } TextResult;
typedef struct { OptionalText values[2]; } OptionArray;

extern int exported_text(void *value);
extern int exported_optional(OptionalText *value);
extern int exported_box(Box *value);
extern int exported_array(TextArray *value);
extern int exported_result(TextResult *value);
extern int exported_option_array(OptionArray *value);

Box native_box(void *text) {
    Box value;
    value.text = text;
    return value;
}

int native_entry(int mode, void *data) {
    if (mode == 0) { return exported_text(data); }
    if (mode == 1 || mode == 2 || mode == 3) {
        OptionalText value;
        value.tag = ((OptionalText *)data)->tag;
        value.text = mode == 3 ? (void *)(uintptr_t)1 : NULL;
        if (mode == 2) { value.tag = UINT32_MAX; }
        return exported_optional(&value);
    }
    if (mode == 4) {
        Box value;
        value.text = data;
        return exported_box(&value);
    }
    if (mode == 5) {
        TextArray value;
        value.values[0] = data;
        value.values[1] = NULL;
        return exported_array(&value);
    }
    if (mode == 6 || mode == 7) {
        TextResult value;
        value.failed = mode == 7;
        value.error_type = 0;
        value.error_code = 1;
        value.text = mode == 7 ? (void *)(uintptr_t)1 : NULL;
        return exported_result(&value);
    }
    if (mode == 8) { return exported_optional(NULL); }
    if (mode == 9) {
        TextArray value;
        value.values[0] = data;
        value.values[1] = data;
        return exported_array(&value);
    }
    if (mode == 10 || mode == 11) {
        OptionArray value;
        value.values[0].tag = ((OptionalText *)data)->tag;
        value.values[0].text = (void *)(uintptr_t)1;
        value.values[1].tag = mode == 10 ? UINT32_MAX : ((OptionalText *)data)->tag;
        value.values[1].text = (void *)(uintptr_t)1;
        return exported_option_array(&value);
    }
    return -1;
}
