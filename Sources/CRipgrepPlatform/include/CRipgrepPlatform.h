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

#endif
