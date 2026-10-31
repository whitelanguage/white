# tests/fixtures/linker/imports.s
# optional native fixture, link Answer at ordinal 7 with NONAME and Constant as DATA
.text
.globl Answer
Answer:
    movl $37, %eax
    retq

.data
.globl Constant
Constant:
    .long 5
