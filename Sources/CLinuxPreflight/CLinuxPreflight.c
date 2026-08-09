#include "CLinuxPreflight.h"

#include <immintrin.h>

static inline uint8_t rg_linux_ascii_lower(uint8_t byte) {
    return byte >= 'A' && byte <= 'Z'
        ? (uint8_t)(byte + ('a' - 'A'))
        : byte;
}

static const uint8_t *rg_linux_find_either_sse2(
    const uint8_t *bytes,
    size_t count,
    uint8_t first,
    uint8_t second,
    int *matched_second
) {
    const __m128i first_vector = _mm_set1_epi8((char)first);
    const __m128i second_vector = _mm_set1_epi8((char)second);
    size_t offset = 0;
    while (offset + 16 <= count) {
        const __m128i block = _mm_loadu_si128((const __m128i *)(bytes + offset));
        const __m128i matches = _mm_or_si128(
            _mm_cmpeq_epi8(block, first_vector),
            _mm_cmpeq_epi8(block, second_vector)
        );
        const unsigned mask = (unsigned)_mm_movemask_epi8(matches);
        if (mask != 0) {
            const size_t lane = (size_t)__builtin_ctz(mask);
            const uint8_t *found = bytes + offset + lane;
            *matched_second = *found == second;
            return found;
        }
        offset += 16;
    }
    while (offset < count) {
        if (bytes[offset] == first || bytes[offset] == second) {
            *matched_second = bytes[offset] == second;
            return bytes + offset;
        }
        offset++;
    }
    return NULL;
}

__attribute__((target("avx2")))
static const uint8_t *rg_linux_find_either_avx2(
    const uint8_t *bytes,
    size_t count,
    uint8_t first,
    uint8_t second,
    int *matched_second
) {
    const __m256i first_vector = _mm256_set1_epi8((char)first);
    const __m256i second_vector = _mm256_set1_epi8((char)second);
    size_t offset = 0;
    while (offset + 32 <= count) {
        const __m256i block = _mm256_loadu_si256((const __m256i *)(bytes + offset));
        const __m256i matches = _mm256_or_si256(
            _mm256_cmpeq_epi8(block, first_vector),
            _mm256_cmpeq_epi8(block, second_vector)
        );
        const unsigned mask = (unsigned)_mm256_movemask_epi8(matches);
        if (mask != 0) {
            const size_t lane = (size_t)__builtin_ctz(mask);
            const uint8_t *found = bytes + offset + lane;
            *matched_second = *found == second;
            return found;
        }
        offset += 32;
    }
    return rg_linux_find_either_sse2(
        bytes + offset,
        count - offset,
        first,
        second,
        matched_second
    );
}

const uint8_t *rg_linux_find_either_byte(
    const uint8_t *bytes,
    size_t count,
    uint8_t first,
    uint8_t second,
    int *matched_second
) {
    if (bytes == NULL || matched_second == NULL || count == 0) {
        return NULL;
    }
    if (__builtin_cpu_supports("avx2")) {
        return rg_linux_find_either_avx2(bytes, count, first, second, matched_second);
    }
    return rg_linux_find_either_sse2(bytes, count, first, second, matched_second);
}

static int rg_linux_bytes_are_ascii_text_sse2(const uint8_t *bytes, size_t count) {
    const __m128i zero = _mm_setzero_si128();
    size_t offset = 0;
    while (offset + 16 <= count) {
        const __m128i block = _mm_loadu_si128((const __m128i *)(bytes + offset));
        if (_mm_movemask_epi8(block) != 0
            || _mm_movemask_epi8(_mm_cmpeq_epi8(block, zero)) != 0) {
            return 0;
        }
        offset += 16;
    }
    while (offset < count) {
        if (bytes[offset] == 0 || bytes[offset] >= 0x80) {
            return 0;
        }
        offset++;
    }
    return 1;
}

__attribute__((target("avx2")))
static int rg_linux_bytes_are_ascii_text_avx2(const uint8_t *bytes, size_t count) {
    const __m256i zero = _mm256_setzero_si256();
    size_t offset = 0;
    while (offset + 32 <= count) {
        const __m256i block = _mm256_loadu_si256((const __m256i *)(bytes + offset));
        if (_mm256_movemask_epi8(block) != 0
            || _mm256_movemask_epi8(_mm256_cmpeq_epi8(block, zero)) != 0) {
            return 0;
        }
        offset += 32;
    }
    return rg_linux_bytes_are_ascii_text_sse2(bytes + offset, count - offset);
}

int rg_linux_bytes_are_ascii_text(const uint8_t *bytes, size_t count) {
    if (bytes == NULL) {
        return count == 0;
    }
    if (__builtin_cpu_supports("avx2")) {
        return rg_linux_bytes_are_ascii_text_avx2(bytes, count);
    }
    return rg_linux_bytes_are_ascii_text_sse2(bytes, count);
}

static const uint8_t *rg_linux_find_ascii_case_sse2(
    const uint8_t *bytes,
    size_t count,
    uint8_t folded
) {
    const uint8_t upper = folded >= 'a' && folded <= 'z'
        ? (uint8_t)(folded - ('a' - 'A'))
        : folded;
    const __m128i lower_vector = _mm_set1_epi8((char)folded);
    const __m128i upper_vector = _mm_set1_epi8((char)upper);
    size_t offset = 0;
    while (offset + 16 <= count) {
        const __m128i block = _mm_loadu_si128((const __m128i *)(bytes + offset));
        const unsigned mask = (unsigned)_mm_movemask_epi8(_mm_or_si128(
            _mm_cmpeq_epi8(block, lower_vector),
            _mm_cmpeq_epi8(block, upper_vector)
        ));
        if (mask != 0) {
            return bytes + offset + (size_t)__builtin_ctz(mask);
        }
        offset += 16;
    }
    while (offset < count) {
        if (bytes[offset] == folded || bytes[offset] == upper) {
            return bytes + offset;
        }
        offset++;
    }
    return NULL;
}

__attribute__((target("avx2")))
static const uint8_t *rg_linux_find_ascii_case_avx2(
    const uint8_t *bytes,
    size_t count,
    uint8_t folded
) {
    const uint8_t upper = folded >= 'a' && folded <= 'z'
        ? (uint8_t)(folded - ('a' - 'A'))
        : folded;
    const __m256i lower_vector = _mm256_set1_epi8((char)folded);
    const __m256i upper_vector = _mm256_set1_epi8((char)upper);
    size_t offset = 0;
    while (offset + 32 <= count) {
        const __m256i block = _mm256_loadu_si256((const __m256i *)(bytes + offset));
        const unsigned mask = (unsigned)_mm256_movemask_epi8(_mm256_or_si256(
            _mm256_cmpeq_epi8(block, lower_vector),
            _mm256_cmpeq_epi8(block, upper_vector)
        ));
        if (mask != 0) {
            return bytes + offset + (size_t)__builtin_ctz(mask);
        }
        offset += 32;
    }
    return rg_linux_find_ascii_case_sse2(bytes + offset, count - offset, folded);
}

const uint8_t *rg_linux_find_ascii_case_byte(
    const uint8_t *bytes,
    size_t count,
    uint8_t folded
) {
    if (bytes == NULL || count == 0) {
        return NULL;
    }
    if (__builtin_cpu_supports("avx2")) {
        return rg_linux_find_ascii_case_avx2(bytes, count, folded);
    }
    return rg_linux_find_ascii_case_sse2(bytes, count, folded);
}

const uint8_t *rg_linux_memcasemem_ascii(
    const uint8_t *bytes,
    size_t count,
    const uint8_t *folded_needle,
    size_t needle_count
) {
    if (bytes == NULL || folded_needle == NULL || needle_count == 0) {
        return needle_count == 0 ? bytes : NULL;
    }
    if (count < needle_count) {
        return NULL;
    }
    if (needle_count == 1) {
        return rg_linux_find_ascii_case_byte(bytes, count, folded_needle[0]);
    }

    size_t shifts[256];
    for (size_t index = 0; index < 256; ++index) {
        shifts[index] = needle_count;
    }
    for (size_t index = 0; index + 1 < needle_count; ++index) {
        shifts[folded_needle[index]] = needle_count - 1 - index;
    }

    size_t cursor = 0;
    while (cursor + needle_count <= count) {
        const uint8_t tail = rg_linux_ascii_lower(bytes[cursor + needle_count - 1]);
        if (tail == folded_needle[needle_count - 1]) {
            size_t offset = 0;
            while (offset < needle_count
                   && rg_linux_ascii_lower(bytes[cursor + offset]) == folded_needle[offset]) {
                offset++;
            }
            if (offset == needle_count) {
                return bytes + cursor;
            }
        }
        const size_t shift = shifts[tail];
        cursor += shift == 0 ? 1 : shift;
    }
    return NULL;
}
