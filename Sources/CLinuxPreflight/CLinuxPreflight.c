#include "CLinuxPreflight.h"

#include <immintrin.h>
#include <string.h>

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

static inline size_t rg_linux_case_anchor(
    const uint8_t *folded_needle,
    size_t needle_count
) {
    size_t anchor = needle_count - 1;
    while (anchor > 0 && folded_needle[anchor] == folded_needle[0]) {
        anchor--;
    }
    return anchor == 0 ? needle_count - 1 : anchor;
}

static inline int rg_linux_case_matches(
    const uint8_t *bytes,
    const uint8_t *folded_needle,
    size_t needle_count
) {
    for (size_t offset = 0; offset < needle_count; offset++) {
        if (rg_linux_ascii_lower(bytes[offset]) != folded_needle[offset]) {
            return 0;
        }
    }
    return 1;
}

static inline void rg_linux_record_case_line(
    const uint8_t *bytes,
    size_t count,
    size_t candidate,
    size_t needle_count,
    size_t *matched_through,
    size_t *matched_lines
) {
    if (candidate < *matched_through) {
        return;
    }
    const uint8_t *newline = memchr(
        bytes + candidate + needle_count,
        '\n',
        count - candidate - needle_count
    );
    *matched_through = newline == NULL
        ? count
        : (size_t)(newline - bytes) + 1;
    (*matched_lines)++;
}

static int rg_linux_count_ascii_case_lines_sse2(
    const uint8_t *bytes,
    size_t count,
    const uint8_t *folded_needle,
    size_t needle_count,
    size_t *matched_lines
) {
    const size_t anchor = rg_linux_case_anchor(folded_needle, needle_count);
    const uint8_t first = folded_needle[0];
    const uint8_t first_upper = first >= 'a' && first <= 'z'
        ? (uint8_t)(first - ('a' - 'A'))
        : first;
    const uint8_t anchor_byte = folded_needle[anchor];
    const uint8_t anchor_upper = anchor_byte >= 'a' && anchor_byte <= 'z'
        ? (uint8_t)(anchor_byte - ('a' - 'A'))
        : anchor_byte;
    const __m128i zero = _mm_setzero_si128();
    const __m128i first_lower_vector = _mm_set1_epi8((char)first);
    const __m128i first_upper_vector = _mm_set1_epi8((char)first_upper);
    const __m128i anchor_lower_vector = _mm_set1_epi8((char)anchor_byte);
    const __m128i anchor_upper_vector = _mm_set1_epi8((char)anchor_upper);

    const size_t last_start = count - needle_count;
    size_t matched_through = 0;
    size_t total = 0;
    size_t cursor = 0;
    while (cursor + 15 <= last_start) {
        const __m128i first_bytes = _mm_loadu_si128((const __m128i *)(bytes + cursor));
        if (_mm_movemask_epi8(first_bytes) != 0
            || _mm_movemask_epi8(_mm_cmpeq_epi8(first_bytes, zero)) != 0) {
            return 0;
        }
        const __m128i anchor_bytes = _mm_loadu_si128(
            (const __m128i *)(bytes + cursor + anchor)
        );
        const __m128i first_matches = _mm_or_si128(
            _mm_cmpeq_epi8(first_bytes, first_lower_vector),
            _mm_cmpeq_epi8(first_bytes, first_upper_vector)
        );
        const __m128i anchor_matches = _mm_or_si128(
            _mm_cmpeq_epi8(anchor_bytes, anchor_lower_vector),
            _mm_cmpeq_epi8(anchor_bytes, anchor_upper_vector)
        );
        unsigned mask = (unsigned)_mm_movemask_epi8(
            _mm_and_si128(first_matches, anchor_matches)
        );
        while (mask != 0) {
            const size_t lane = (size_t)__builtin_ctz(mask);
            const size_t candidate = cursor + lane;
            if (candidate >= matched_through
                && rg_linux_case_matches(bytes + candidate, folded_needle, needle_count)) {
                rg_linux_record_case_line(
                    bytes, count, candidate, needle_count, &matched_through, &total
                );
            }
            mask &= mask - 1;
        }
        cursor += 16;
    }

    for (size_t offset = cursor; offset < count; offset++) {
        const uint8_t byte = bytes[offset];
        if (byte == 0 || byte >= 0x80) {
            return 0;
        }
        if (offset <= last_start
            && offset >= matched_through
            && rg_linux_ascii_lower(byte) == folded_needle[0]
            && rg_linux_ascii_lower(bytes[offset + anchor]) == folded_needle[anchor]
            && rg_linux_case_matches(bytes + offset, folded_needle, needle_count)) {
            rg_linux_record_case_line(
                bytes, count, offset, needle_count, &matched_through, &total
            );
        }
    }
    *matched_lines = total;
    return 1;
}

__attribute__((target("avx2")))
static int rg_linux_count_ascii_case_lines_avx2(
    const uint8_t *bytes,
    size_t count,
    const uint8_t *folded_needle,
    size_t needle_count,
    size_t *matched_lines
) {
    const size_t anchor = rg_linux_case_anchor(folded_needle, needle_count);

    const uint8_t first = folded_needle[0];
    const uint8_t first_upper = first >= 'a' && first <= 'z'
        ? (uint8_t)(first - ('a' - 'A'))
        : first;
    const uint8_t anchor_byte = folded_needle[anchor];
    const uint8_t anchor_upper = anchor_byte >= 'a' && anchor_byte <= 'z'
        ? (uint8_t)(anchor_byte - ('a' - 'A'))
        : anchor_byte;
    const __m256i zero = _mm256_setzero_si256();
    const __m256i first_lower_vector = _mm256_set1_epi8((char)first);
    const __m256i first_upper_vector = _mm256_set1_epi8((char)first_upper);
    const __m256i anchor_lower_vector = _mm256_set1_epi8((char)anchor_byte);
    const __m256i anchor_upper_vector = _mm256_set1_epi8((char)anchor_upper);

    const size_t last_start = count - needle_count;
    size_t matched_through = 0;
    size_t total = 0;
    size_t cursor = 0;
    while (cursor + 31 <= last_start) {
        const __m256i first_bytes = _mm256_loadu_si256((const __m256i *)(bytes + cursor));
        if (_mm256_movemask_epi8(first_bytes) != 0
            || _mm256_movemask_epi8(_mm256_cmpeq_epi8(first_bytes, zero)) != 0) {
            return 0;
        }
        const __m256i anchor_bytes = _mm256_loadu_si256(
            (const __m256i *)(bytes + cursor + anchor)
        );
        const __m256i first_matches = _mm256_or_si256(
            _mm256_cmpeq_epi8(first_bytes, first_lower_vector),
            _mm256_cmpeq_epi8(first_bytes, first_upper_vector)
        );
        const __m256i anchor_matches = _mm256_or_si256(
            _mm256_cmpeq_epi8(anchor_bytes, anchor_lower_vector),
            _mm256_cmpeq_epi8(anchor_bytes, anchor_upper_vector)
        );
        unsigned mask = (unsigned)_mm256_movemask_epi8(
            _mm256_and_si256(first_matches, anchor_matches)
        );
        while (mask != 0) {
            const size_t lane = (size_t)__builtin_ctz(mask);
            const size_t candidate = cursor + lane;
            if (candidate >= matched_through
                && rg_linux_case_matches(bytes + candidate, folded_needle, needle_count)) {
                rg_linux_record_case_line(
                    bytes, count, candidate, needle_count, &matched_through, &total
                );
            }
            mask &= mask - 1;
        }
        cursor += 32;
    }

    for (size_t offset = cursor; offset < count; offset++) {
        const uint8_t byte = bytes[offset];
        if (byte == 0 || byte >= 0x80) {
            return 0;
        }
        if (offset <= last_start
            && offset >= matched_through
            && rg_linux_ascii_lower(byte) == first
            && rg_linux_ascii_lower(bytes[offset + anchor]) == anchor_byte
            && rg_linux_case_matches(bytes + offset, folded_needle, needle_count)) {
            rg_linux_record_case_line(
                bytes, count, offset, needle_count, &matched_through, &total
            );
        }
    }
    *matched_lines = total;
    return 1;
}

int rg_linux_count_ascii_case_lines(
    const uint8_t *bytes,
    size_t count,
    const uint8_t *folded_needle,
    size_t needle_count,
    size_t *matched_lines
) {
    if (matched_lines == NULL
        || bytes == NULL
        || folded_needle == NULL
        || needle_count == 0
        || count < needle_count) {
        return 0;
    }
    if (__builtin_cpu_supports("avx2")) {
        return rg_linux_count_ascii_case_lines_avx2(
            bytes, count, folded_needle, needle_count, matched_lines
        );
    }
    return rg_linux_count_ascii_case_lines_sse2(
        bytes, count, folded_needle, needle_count, matched_lines
    );
}
