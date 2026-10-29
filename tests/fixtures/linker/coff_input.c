/* Clang emits section auxiliaries, BSS, unwind records and COMDAT here. */
extern int outside(int);

int zero_storage[32];
int initialized_storage = 7;
int *data_address = &initialized_storage;

#pragma section(".rdata$white_linker", read)
__declspec(allocate(".rdata$white_linker")) const char section_data[] = "COFF reader";
__declspec(selectany) int shared_definition = 13;

int fixture_function_with_long_name(int value) {
    zero_storage[0] = value;
    return outside(value) + *data_address + shared_definition + section_data[0];
}
