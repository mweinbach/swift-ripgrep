#include "CRipgrepPlatform.h"

#include <string.h>

static inline uint8_t rg_ascii_lower(uint8_t byte) {
    return byte >= 'A' && byte <= 'Z' ? (uint8_t)(byte + ('a' - 'A')) : byte;
}

const uint8_t *rg_memmem_simple(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    if (needle_len == 0) {
        return haystack;
    }
    if (haystack_len < needle_len) {
        return NULL;
    }
    if (needle_len == 1) {
        return memchr(haystack, needle[0], haystack_len);
    }

    const uint8_t first = needle[0];
    const uint8_t *cursor = haystack;
    const uint8_t *end = haystack + haystack_len - needle_len + 1;
    while (cursor < end) {
        const size_t remaining = (size_t)(end - cursor);
        const uint8_t *candidate = memchr(cursor, first, remaining);
        if (candidate == NULL) {
            return NULL;
        }
        if (memcmp(candidate + 1, needle + 1, needle_len - 1) == 0) {
            return candidate;
        }
        cursor = candidate + 1;
    }
    return NULL;
}

const uint8_t *rg_memcasemem_ascii(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    if (needle_len == 0) {
        return haystack;
    }
    if (haystack_len < needle_len) {
        return NULL;
    }
    if (needle_len == 1) {
        const uint8_t folded = rg_ascii_lower(needle[0]);
        for (size_t index = 0; index < haystack_len; ++index) {
            if (rg_ascii_lower(haystack[index]) == folded) {
                return haystack + index;
            }
        }
        return NULL;
    }

    size_t shifts[256];
    for (size_t index = 0; index < 256; ++index) {
        shifts[index] = needle_len;
    }
    for (size_t index = 0; index + 1 < needle_len; ++index) {
        shifts[rg_ascii_lower(needle[index])] = needle_len - 1 - index;
    }

    size_t cursor = 0;
    while (cursor + needle_len <= haystack_len) {
        const uint8_t tail = rg_ascii_lower(haystack[cursor + needle_len - 1]);
        if (tail == rg_ascii_lower(needle[needle_len - 1])) {
            size_t offset = 0;
            while (offset < needle_len
                   && rg_ascii_lower(haystack[cursor + offset]) == rg_ascii_lower(needle[offset])) {
                offset++;
            }
            if (offset == needle_len) {
                return haystack + cursor;
            }
        }
        const size_t shift = shifts[tail];
        cursor += shift == 0 ? 1 : shift;
    }
    return NULL;
}

void rg_byte_set_init(
    uint8_t table[256],
    const uint8_t *needles,
    size_t needle_count
) {
    memset(table, 0, 256);
    for (size_t index = 0; index < needle_count; ++index) {
        table[needles[index]] = 1;
    }
}

const uint8_t *rg_memchr_any_table(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t table[256]
) {
    size_t index = 0;
    for (; index + 8 <= haystack_len; index += 8) {
        if (table[haystack[index]]) {
            return haystack + index;
        }
        if (table[haystack[index + 1]]) {
            return haystack + index + 1;
        }
        if (table[haystack[index + 2]]) {
            return haystack + index + 2;
        }
        if (table[haystack[index + 3]]) {
            return haystack + index + 3;
        }
        if (table[haystack[index + 4]]) {
            return haystack + index + 4;
        }
        if (table[haystack[index + 5]]) {
            return haystack + index + 5;
        }
        if (table[haystack[index + 6]]) {
            return haystack + index + 6;
        }
        if (table[haystack[index + 7]]) {
            return haystack + index + 7;
        }
    }
    for (; index < haystack_len; ++index) {
        if (table[haystack[index]]) {
            return haystack + index;
        }
    }
    return NULL;
}

size_t rg_memcount_byte(
    const uint8_t *haystack,
    size_t haystack_len,
    uint8_t byte
) {
    size_t count = 0;
    size_t index = 0;
    for (; index + 8 <= haystack_len; index += 8) {
        count += haystack[index] == byte;
        count += haystack[index + 1] == byte;
        count += haystack[index + 2] == byte;
        count += haystack[index + 3] == byte;
        count += haystack[index + 4] == byte;
        count += haystack[index + 5] == byte;
        count += haystack[index + 6] == byte;
        count += haystack[index + 7] == byte;
    }
    for (; index < haystack_len; index++) {
        count += haystack[index] == byte;
    }
    return count;
}
