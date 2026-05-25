#ifndef SWIFT_RIPGREP_CRIPGREPLATFORM_H
#define SWIFT_RIPGREP_CRIPGREPLATFORM_H

#include <stddef.h>
#include <stdint.h>

const uint8_t *rg_memmem_simple(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
);

const uint8_t *rg_memcasemem_ascii(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
);

const uint8_t *rg_memcasemem_ascii_prepared(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *folded_needle,
    size_t needle_len,
    const size_t shifts[256]
);

void rg_byte_set_init(
    uint8_t table[256],
    const uint8_t *needles,
    size_t needle_count
);

const uint8_t *rg_memchr_any_table(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t table[256]
);

size_t rg_memcount_byte(
    const uint8_t *haystack,
    size_t haystack_len,
    uint8_t byte
);

#endif
