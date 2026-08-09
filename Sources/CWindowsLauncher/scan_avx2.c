#include <immintrin.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef int (*swift_rg_literal_candidate_callback)(size_t offset, void *context);

/* Compiled separately with /arch:AVX2 and called only after runtime dispatch. */
int swift_rg_scan_literal_avx2(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    swift_rg_literal_candidate_callback callback,
    void *context
) {
    if (literal_count == 0) return -1;
    const size_t last_start = count >= literal_count ? count - literal_count : 0;
    const int can_match = count >= literal_count;
    __m256i zero = _mm256_setzero_si256();
    __m256i first = _mm256_set1_epi8((char)literal[0]);
    size_t offset = 0;
    while (offset + 32 <= count) {
        __m256i block = _mm256_loadu_si256((const __m256i *)(bytes + offset));
        if (_mm256_movemask_epi8(_mm256_cmpeq_epi8(block, zero))) return -1;
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(_mm256_cmpeq_epi8(block, first));
        while (mask) {
            unsigned long bit = 0;
            _BitScanForward(&bit, mask);
            size_t candidate = offset + bit;
            if (can_match && candidate <= last_start
                && (literal_count == 1
                    || memcmp(bytes + candidate + 1, literal + 1, literal_count - 1) == 0)
                && !callback(candidate, context)) return -2;
            mask &= mask - 1;
        }
        offset += 32;
    }
    for (; offset < count; ++offset) {
        if (bytes[offset] == 0) return -1;
        if (can_match && offset <= last_start && bytes[offset] == literal[0]
            && (literal_count == 1
                || memcmp(bytes + offset + 1, literal + 1, literal_count - 1) == 0)
            && !callback(offset, context)) return -2;
    }
    return 0;
}

static unsigned char ascii_lower(unsigned char byte) {
    return byte >= 'A' && byte <= 'Z' ? (unsigned char)(byte + ('a' - 'A')) : byte;
}

int swift_rg_scan_ascii_case_insensitive_avx2(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    swift_rg_literal_candidate_callback callback,
    void *context
) {
    if (literal_count == 0) return -1;
    uint32_t frequencies[256] = {0};
    size_t sample_count = count < 64 * 1024 ? count : 64 * 1024;
    for (size_t index = 0; index < sample_count; ++index) {
        ++frequencies[ascii_lower(bytes[index])];
    }
    size_t anchor = 0;
    uint32_t best_frequency = UINT32_MAX;
    for (size_t index = 0; index < literal_count; ++index) {
        uint32_t frequency = frequencies[ascii_lower(literal[index])];
        if (frequency < best_frequency) {
            best_frequency = frequency;
            anchor = index;
        }
    }
    unsigned char lower = ascii_lower(literal[anchor]);
    unsigned char upper = lower >= 'a' && lower <= 'z'
        ? (unsigned char)(lower - ('a' - 'A')) : lower;
    const size_t last_start = count >= literal_count ? count - literal_count : 0;
    const int can_match = count >= literal_count;
    __m256i zero = _mm256_setzero_si256();
    __m256i lower_vector = _mm256_set1_epi8((char)lower);
    __m256i upper_vector = _mm256_set1_epi8((char)upper);
    size_t offset = 0;
    while (offset + 32 <= count) {
        __m256i block = _mm256_loadu_si256((const __m256i *)(bytes + offset));
        if (_mm256_movemask_epi8(block)
            || _mm256_movemask_epi8(_mm256_cmpeq_epi8(block, zero))) return -1;
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(_mm256_or_si256(
            _mm256_cmpeq_epi8(block, lower_vector),
            _mm256_cmpeq_epi8(block, upper_vector)));
        while (mask) {
            unsigned long bit = 0;
            _BitScanForward(&bit, mask);
            size_t anchor_offset = offset + bit;
            if (anchor_offset >= anchor) {
                size_t candidate = anchor_offset - anchor;
                if (can_match && candidate <= last_start) {
                    size_t index = 0;
                    while (index < literal_count
                        && ascii_lower(bytes[candidate + index]) == ascii_lower(literal[index])) ++index;
                    if (index == literal_count && !callback(candidate, context)) return -2;
                }
            }
            mask &= mask - 1;
        }
        offset += 32;
    }
    for (; offset < count; ++offset) {
        unsigned char byte = bytes[offset];
        if (byte == 0 || byte >= 0x80) return -1;
        if ((byte == lower || byte == upper) && offset >= anchor) {
            size_t candidate = offset - anchor;
            if (can_match && candidate <= last_start) {
                size_t index = 0;
                while (index < literal_count
                    && ascii_lower(bytes[candidate + index]) == ascii_lower(literal[index])) ++index;
                if (index == literal_count && !callback(candidate, context)) return -2;
            }
        }
    }
    return 0;
}
