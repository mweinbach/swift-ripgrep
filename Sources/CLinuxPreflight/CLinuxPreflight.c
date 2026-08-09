#include "CLinuxPreflight.h"

#include <immintrin.h>

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
