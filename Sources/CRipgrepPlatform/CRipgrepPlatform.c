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

    const uint8_t first = rg_ascii_lower(needle[0]);
    const uint8_t *cursor = haystack;
    const uint8_t *end = haystack + haystack_len - needle_len + 1;
    while (cursor < end) {
        while (cursor < end && rg_ascii_lower(*cursor) != first) {
            cursor++;
        }
        if (cursor >= end) {
            return NULL;
        }
        size_t offset = 1;
        while (offset < needle_len
               && rg_ascii_lower(cursor[offset]) == rg_ascii_lower(needle[offset])) {
            offset++;
        }
        if (offset == needle_len) {
            return cursor;
        }
        cursor++;
    }
    return NULL;
}
