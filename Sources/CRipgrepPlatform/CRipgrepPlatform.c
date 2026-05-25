#include "CRipgrepPlatform.h"

#ifdef __APPLE__
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#include <errno.h>
#include <string.h>

static inline uint8_t rg_ascii_lower(uint8_t byte) {
    return byte >= 'A' && byte <= 'Z' ? (uint8_t)(byte + ('a' - 'A')) : byte;
}

static inline int rg_ascii_is_alpha(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z');
}

#if defined(__APPLE__) && defined(__aarch64__)
static const uint8_t *rg_memmem_neon_candidates(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    const uint8_t first = needle[0];
    const uint8_t tail = needle[needle_len - 1];
    const uint8x16_t first_vector = vdupq_n_u8(first);
    const uint8x16_t tail_vector = vdupq_n_u8(tail);
    uint8_t matching_lanes[16];

    size_t cursor = 0;
    const size_t vector_limit = haystack_len >= needle_len + 15
        ? haystack_len - needle_len - 15 + 1
        : 0;
    while (cursor < vector_limit) {
        const uint8x16_t candidate_lanes = vandq_u8(
            vceqq_u8(vld1q_u8(haystack + cursor), first_vector),
            vceqq_u8(vld1q_u8(haystack + cursor + needle_len - 1), tail_vector)
        );

        if (vmaxvq_u8(candidate_lanes) != 0) {
            vst1q_u8(matching_lanes, candidate_lanes);
            for (int lane = 0; lane < 16; ++lane) {
                if (matching_lanes[lane] == 0) {
                    continue;
                }
                const uint8_t *candidate = haystack + cursor + (size_t)lane;
                if (needle_len <= 2 || memcmp(candidate + 1, needle + 1, needle_len - 2) == 0) {
                    return candidate;
                }
            }
        }

        cursor += 16;
    }

    const size_t max_start = haystack_len - needle_len + 1;
    while (cursor < max_start) {
        if (haystack[cursor] == first
            && haystack[cursor + needle_len - 1] == tail
            && (needle_len <= 2 || memcmp(haystack + cursor + 1, needle + 1, needle_len - 2) == 0)) {
            return haystack + cursor;
        }
        cursor++;
    }

    return NULL;
}
#endif

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
#if defined(__APPLE__) && defined(__aarch64__)
    return rg_memmem_neon_candidates(haystack, haystack_len, needle, needle_len);
#endif

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

#if defined(__APPLE__) && defined(__aarch64__)
static inline uint8x16_t rg_neon_fold_ascii_for_compare(uint8x16_t bytes, int is_alpha) {
    return is_alpha ? vorrq_u8(bytes, vdupq_n_u8(0x20)) : bytes;
}

static const uint8_t *rg_memcasemem_ascii_neon_candidates(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *folded_needle,
    size_t needle_len
) {
    if (needle_len == 0) {
        return haystack;
    }
    if (haystack_len < needle_len) {
        return NULL;
    }

    const uint8_t first = folded_needle[0];
    const uint8_t tail = folded_needle[needle_len - 1];
    const int first_is_alpha = rg_ascii_is_alpha(first);
    const int tail_is_alpha = rg_ascii_is_alpha(tail);
    const uint8x16_t first_vector = vdupq_n_u8(first);
    const uint8x16_t tail_vector = vdupq_n_u8(tail);
    uint8_t matching_lanes[16];

    size_t cursor = 0;
    const size_t vector_limit = haystack_len >= needle_len + 15
        ? haystack_len - needle_len - 15 + 1
        : 0;
    while (cursor < vector_limit) {
        const uint8x16_t first_bytes = rg_neon_fold_ascii_for_compare(vld1q_u8(haystack + cursor), first_is_alpha);
        const uint8x16_t tail_bytes = rg_neon_fold_ascii_for_compare(vld1q_u8(haystack + cursor + needle_len - 1), tail_is_alpha);
        const uint8x16_t candidate_lanes = vandq_u8(
            vceqq_u8(first_bytes, first_vector),
            vceqq_u8(tail_bytes, tail_vector)
        );

        if (vmaxvq_u8(candidate_lanes) != 0) {
            vst1q_u8(matching_lanes, candidate_lanes);
            for (int lane = 0; lane < 16; ++lane) {
                if (matching_lanes[lane] == 0) {
                    continue;
                }
                const uint8_t *candidate = haystack + cursor + (size_t)lane;
                size_t offset = 1;
                while (offset + 1 < needle_len
                       && rg_ascii_lower(candidate[offset]) == folded_needle[offset]) {
                    offset++;
                }
                if (offset + 1 == needle_len) {
                    return candidate;
                }
            }
        }

        cursor += 16;
    }

    const size_t max_start = haystack_len - needle_len + 1;
    while (cursor < max_start) {
        if (rg_ascii_lower(haystack[cursor]) == first
            && rg_ascii_lower(haystack[cursor + needle_len - 1]) == tail) {
            size_t offset = 1;
            while (offset + 1 < needle_len
                   && rg_ascii_lower(haystack[cursor + offset]) == folded_needle[offset]) {
                offset++;
            }
            if (offset + 1 == needle_len) {
                return haystack + cursor;
            }
        }
        cursor++;
    }

    return NULL;
}
#endif

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

const uint8_t *rg_memcasemem_ascii_prepared(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *folded_needle,
    size_t needle_len,
    const size_t shifts[256]
) {
    if (needle_len == 0) {
        return haystack;
    }
    if (haystack_len < needle_len) {
        return NULL;
    }
#if defined(__APPLE__) && defined(__aarch64__)
    if (needle_len > 1) {
        return rg_memcasemem_ascii_neon_candidates(haystack, haystack_len, folded_needle, needle_len);
    }
#endif
    if (needle_len == 1) {
        const uint8_t folded = folded_needle[0];
        for (size_t index = 0; index < haystack_len; ++index) {
            if (rg_ascii_lower(haystack[index]) == folded) {
                return haystack + index;
            }
        }
        return NULL;
    }

    size_t cursor = 0;
    while (cursor + needle_len <= haystack_len) {
        const uint8_t tail = rg_ascii_lower(haystack[cursor + needle_len - 1]);
        if (tail == folded_needle[needle_len - 1]) {
            size_t offset = 0;
            while (offset < needle_len
                   && rg_ascii_lower(haystack[cursor + offset]) == folded_needle[offset]) {
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

static void rg_byte_set_init(
    uint8_t table[256],
    const uint8_t *needles,
    size_t needle_count
) {
    memset(table, 0, 256);
    for (size_t index = 0; index < needle_count; ++index) {
        table[needles[index]] = 1;
    }
}

static const uint8_t *rg_memchr_any_table(
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

const uint8_t *rg_memchr_any_bytes(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needles,
    size_t needle_count
) {
    if (needle_count == 0) {
        return NULL;
    }
    if (needle_count == 1) {
        return memchr(haystack, needles[0], haystack_len);
    }
#if defined(__APPLE__) && defined(__aarch64__)
    size_t index = 0;
    uint8_t matching_lanes[16];
    for (; index + 16 <= haystack_len; index += 16) {
        const uint8x16_t bytes = vld1q_u8(haystack + index);
        uint8x16_t matches = vceqq_u8(bytes, vdupq_n_u8(needles[0]));
        for (size_t needle_index = 1; needle_index < needle_count; ++needle_index) {
            matches = vorrq_u8(matches, vceqq_u8(bytes, vdupq_n_u8(needles[needle_index])));
        }
        if (vmaxvq_u8(matches) != 0) {
            vst1q_u8(matching_lanes, matches);
            for (int lane = 0; lane < 16; ++lane) {
                if (matching_lanes[lane] != 0) {
                    return haystack + index + (size_t)lane;
                }
            }
        }
    }
    for (; index < haystack_len; ++index) {
        for (size_t needle_index = 0; needle_index < needle_count; ++needle_index) {
            if (haystack[index] == needles[needle_index]) {
                return haystack + index;
            }
        }
    }
    return NULL;
#else
    uint8_t table[256];
    rg_byte_set_init(table, needles, needle_count);
    return rg_memchr_any_table(haystack, haystack_len, table);
#endif
}

size_t rg_memcount_byte(
    const uint8_t *haystack,
    size_t haystack_len,
    uint8_t byte
) {
#if defined(__APPLE__) && defined(__aarch64__)
    size_t index = 0;
    size_t count = 0;
    const uint8x16_t target = vdupq_n_u8(byte);
    const uint8x16_t one = vdupq_n_u8(1);
    for (; index + 64 <= haystack_len; index += 64) {
        const uint8x16_t matches0 = vandq_u8(vceqq_u8(vld1q_u8(haystack + index), target), one);
        const uint8x16_t matches1 = vandq_u8(vceqq_u8(vld1q_u8(haystack + index + 16), target), one);
        const uint8x16_t matches2 = vandq_u8(vceqq_u8(vld1q_u8(haystack + index + 32), target), one);
        const uint8x16_t matches3 = vandq_u8(vceqq_u8(vld1q_u8(haystack + index + 48), target), one);
        count += vaddvq_u8(matches0) + vaddvq_u8(matches1) + vaddvq_u8(matches2) + vaddvq_u8(matches3);
    }
    for (; index + 16 <= haystack_len; index += 16) {
        const uint8x16_t matches = vandq_u8(vceqq_u8(vld1q_u8(haystack + index), target), one);
        count += vaddvq_u8(matches);
    }

    for (; index < haystack_len; index++) {
        count += haystack[index] == byte;
    }
    return count;
#else
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
#endif
}

#ifdef __APPLE__
static rg_darwin_literal_file_result rg_darwin_write_literal_bytes(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len,
    const size_t shifts[256],
    int ascii_case_insensitive
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };

    if (haystack_len >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) {
        return result;
    }
    if (haystack_len >= 2
        && ((base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF))) {
        return result;
    }

    const size_t binary_check_len = haystack_len < (64 * 1024) ? haystack_len : (64 * 1024);
    if (memchr(base, 0, binary_check_len) != NULL) {
        return result;
    }

    size_t search_offset = 0;
    size_t last_emitted_line_start = (size_t)-1;
    while (search_offset < haystack_len) {
        const uint8_t *found = ascii_case_insensitive
            ? rg_memcasemem_ascii_prepared(base + search_offset, haystack_len - search_offset, needle, needle_len, shifts)
            : rg_memmem_simple(base + search_offset, haystack_len - search_offset, needle, needle_len);
        if (found == NULL) {
            break;
        }

        const size_t match_start = (size_t)(found - base);
        result.total_match_count++;

        size_t line_start = match_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }

        if (line_start != last_emitted_line_start) {
            const void *newline = memchr(found, '\n', haystack_len - match_start);
            const size_t output_end = newline == NULL
                ? haystack_len
                : (size_t)(((const uint8_t *)newline - base) + 1);
            const size_t output_len = output_end - line_start;
            size_t bytes_written = 0;
            while (bytes_written < output_len) {
                ssize_t written = write(STDOUT_FILENO, base + line_start + bytes_written, output_len - bytes_written);
                if (written < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    result.status = -1;
                    return result;
                }
                if (written == 0) {
                    result.status = -1;
                    return result;
                }
                bytes_written += (size_t)written;
            }
            if (newline == NULL) {
                uint8_t terminator = '\n';
                while (write(STDOUT_FILENO, &terminator, 1) < 0) {
                    if (errno != EINTR) {
                        result.status = -1;
                        return result;
                    }
                }
            }
            result.matched_line_count++;
            last_emitted_line_start = line_start;
        }

        search_offset = match_start + needle_len;
    }

    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = haystack_len;
    return result;
}

static rg_darwin_literal_file_result rg_darwin_write_literal_bytes_case_sensitive(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    return rg_darwin_write_literal_bytes(base, haystack_len, needle, needle_len, NULL, 0);
}

static int rg_write_all_stdout(const uint8_t *bytes, size_t length);

static rg_darwin_literal_file_result rg_darwin_read_literal_fd_full(
    int fd,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
    uint8_t *buffer = malloc(haystack_len);
    if (buffer == NULL) {
        result.status = -1;
        return result;
    }

    size_t bytes_read = 0;
    while (bytes_read < haystack_len) {
        ssize_t count = read(fd, buffer + bytes_read, haystack_len - bytes_read);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buffer);
            result.status = -1;
            return result;
        }
        if (count == 0) {
            break;
        }
        bytes_read += (size_t)count;
    }

    result = rg_darwin_write_literal_bytes_case_sensitive(buffer, bytes_read, needle, needle_len);
    free(buffer);
    return result;
}

static int rg_darwin_process_literal_complete_lines(
    const uint8_t *base,
    size_t length,
    const uint8_t *needle,
    size_t needle_len,
    int final_chunk,
    rg_darwin_literal_file_result *result
) {
    size_t search_offset = 0;
    size_t last_emitted_line_start = (size_t)-1;
    while (search_offset < length) {
        const uint8_t *found = rg_memmem_simple(base + search_offset, length - search_offset, needle, needle_len);
        if (found == NULL) {
            break;
        }

        const size_t match_start = (size_t)(found - base);
        result->total_match_count++;

        size_t line_start = match_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }

        if (line_start != last_emitted_line_start) {
            const void *newline = memchr(found, '\n', length - match_start);
            const size_t output_end = newline == NULL
                ? length
                : (size_t)(((const uint8_t *)newline - base) + 1);
            if (rg_write_all_stdout(base + line_start, output_end - line_start) != 0) {
                result->status = -1;
                return -1;
            }
            if (final_chunk && newline == NULL) {
                uint8_t terminator = '\n';
                if (rg_write_all_stdout(&terminator, 1) != 0) {
                    result->status = -1;
                    return -1;
                }
            }
            result->matched_line_count++;
            last_emitted_line_start = line_start;
        }

        search_offset = match_start + needle_len;
    }
    return 0;
}

static const uint8_t *rg_last_newline(const uint8_t *bytes, size_t length) {
    for (size_t index = length; index > 0; --index) {
        if (bytes[index - 1] == '\n') {
            return bytes + index - 1;
        }
    }
    return NULL;
}

static rg_darwin_literal_file_result rg_darwin_stream_literal_fd_lines(
    int fd,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
    const size_t chunk_size = 1024 * 1024;
    const size_t carry_capacity = 64 * 1024;
    const size_t buffer_capacity = chunk_size + carry_capacity + needle_len;
    uint8_t *buffer = malloc(buffer_capacity);
    if (buffer == NULL) {
        result.status = -1;
        return result;
    }

    size_t carry_len = 0;
    size_t bytes_read = 0;
    int checked_binary_prefix = 0;
    for (;;) {
        ssize_t count = read(fd, buffer + carry_len, chunk_size);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buffer);
            result.status = -1;
            return result;
        }

        const size_t bytes_in_buffer = carry_len + (count > 0 ? (size_t)count : 0);
        bytes_read += count > 0 ? (size_t)count : 0;

        if (!checked_binary_prefix) {
            if (bytes_in_buffer >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF) {
                free(buffer);
                return result;
            }
            if (bytes_in_buffer >= 2
                && ((buffer[0] == 0xFF && buffer[1] == 0xFE) || (buffer[0] == 0xFE && buffer[1] == 0xFF))) {
                free(buffer);
                return result;
            }
            const size_t binary_check_len = bytes_in_buffer < (64 * 1024) ? bytes_in_buffer : (64 * 1024);
            if (memchr(buffer, 0, binary_check_len) != NULL) {
                free(buffer);
                return result;
            }
            checked_binary_prefix = bytes_in_buffer >= (64 * 1024) || bytes_read == haystack_len || count == 0;
        }

        if (count == 0) {
            if (rg_darwin_process_literal_complete_lines(buffer, bytes_in_buffer, needle, needle_len, 1, &result) != 0) {
                free(buffer);
                return result;
            }
            break;
        }

        const uint8_t *last_newline = rg_last_newline(buffer, bytes_in_buffer);
        if (last_newline == NULL) {
            if (bytes_in_buffer > carry_capacity) {
                free(buffer);
                if (lseek(fd, 0, SEEK_SET) < 0) {
                    result.status = -1;
                    return result;
                }
                return rg_darwin_read_literal_fd_full(fd, haystack_len, needle, needle_len);
            }
            carry_len = bytes_in_buffer;
            continue;
        }

        const size_t process_len = (size_t)(last_newline - buffer) + 1;
        if (rg_darwin_process_literal_complete_lines(buffer, process_len, needle, needle_len, 0, &result) != 0) {
            free(buffer);
            return result;
        }

        carry_len = bytes_in_buffer - process_len;
        if (carry_len > 0) {
            memmove(buffer, buffer + process_len, carry_len);
        }
        if (carry_len > carry_capacity) {
            free(buffer);
            if (lseek(fd, 0, SEEK_SET) < 0) {
                result.status = -1;
                return result;
            }
            return rg_darwin_read_literal_fd_full(fd, haystack_len, needle, needle_len);
        }
    }

    free(buffer);
    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = bytes_read;
    return result;
}

static rg_darwin_literal_file_result rg_darwin_write_literal_bytes_case_insensitive(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
    uint8_t *folded = malloc(needle_len);
    if (folded == NULL) {
        result.status = -1;
        return result;
    }

    size_t shifts[256];
    for (size_t index = 0; index < 256; ++index) {
        shifts[index] = needle_len;
    }
    for (size_t index = 0; index < needle_len; ++index) {
        folded[index] = rg_ascii_lower(needle[index]);
    }
    if (needle_len > 1) {
        for (size_t index = 0; index + 1 < needle_len; ++index) {
            shifts[folded[index]] = needle_len - 1 - index;
        }
    }

    result = rg_darwin_write_literal_bytes(base, haystack_len, folded, needle_len, shifts, 1);
    free(folded);
    return result;
}

static int rg_ascii_is_word(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z')
        || (byte >= 'a' && byte <= 'z')
        || (byte >= '0' && byte <= '9')
        || byte == '_';
}

static int rg_ascii_is_regex_space(uint8_t byte) {
    return byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r' || byte == '\f' || byte == '\v';
}

static int rg_word_boundary_ascii(
    const uint8_t *base,
    size_t haystack_len,
    size_t match_start,
    size_t match_end
) {
    if (match_start > 0) {
        const uint8_t before = base[match_start - 1];
        if (before >= 0x80) {
            return -1;
        }
        if (rg_ascii_is_word(before)) {
            return 0;
        }
    }
    if (match_end < haystack_len) {
        const uint8_t after = base[match_end];
        if (after >= 0x80) {
            return -1;
        }
        if (rg_ascii_is_word(after)) {
            return 0;
        }
    }
    return 1;
}

static int rg_write_all_stdout(const uint8_t *bytes, size_t length) {
    size_t bytes_written = 0;
    while (bytes_written < length) {
        ssize_t written = write(STDOUT_FILENO, bytes + bytes_written, length - bytes_written);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            return -1;
        }
        bytes_written += (size_t)written;
    }
    return 0;
}

static int rg_write_decimal_colon(size_t value) {
    uint8_t buffer[32];
    size_t cursor = sizeof(buffer);
    buffer[--cursor] = ':';
    do {
        buffer[--cursor] = (uint8_t)('0' + (value % 10));
        value /= 10;
    } while (value > 0);
    return rg_write_all_stdout(buffer + cursor, sizeof(buffer) - cursor);
}

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} rg_output_buffer;

static int rg_output_buffer_flush(rg_output_buffer *buffer) {
    if (buffer->length == 0) {
        return 0;
    }
    if (rg_write_all_stdout(buffer->bytes, buffer->length) != 0) {
        return -1;
    }
    buffer->length = 0;
    return 0;
}

static int rg_output_buffer_write(rg_output_buffer *buffer, const uint8_t *bytes, size_t length) {
    if (length > buffer->capacity) {
        if (rg_output_buffer_flush(buffer) != 0) {
            return -1;
        }
        return rg_write_all_stdout(bytes, length);
    }
    if (buffer->length + length > buffer->capacity && rg_output_buffer_flush(buffer) != 0) {
        return -1;
    }
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return 0;
}

static int rg_has_surrounding_ascii_words(
    const uint8_t *base,
    size_t line_start,
    size_t line_end,
    size_t literal_start,
    size_t literal_end
) {
    if (literal_start <= line_start || literal_end >= line_end) {
        return 0;
    }

    size_t before_space_start = literal_start;
    while (before_space_start > line_start && rg_ascii_is_regex_space(base[before_space_start - 1])) {
        before_space_start--;
    }
    if (before_space_start == literal_start) {
        return 0;
    }

    size_t before_word_start = before_space_start;
    while (before_word_start > line_start && rg_ascii_is_word(base[before_word_start - 1])) {
        before_word_start--;
    }
    if (before_word_start == before_space_start) {
        return 0;
    }

    size_t after_space_end = literal_end;
    while (after_space_end < line_end && rg_ascii_is_regex_space(base[after_space_end])) {
        after_space_end++;
    }
    if (after_space_end == literal_end) {
        return 0;
    }

    size_t after_word_end = after_space_end;
    while (after_word_end < line_end && rg_ascii_is_word(base[after_word_end])) {
        after_word_end++;
    }
    return after_word_end > after_space_end;
}

static rg_darwin_literal_file_result rg_darwin_write_surrounding_words_bytes(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *literal,
    size_t literal_len,
    int include_line_numbers
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };

    if (haystack_len >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) {
        return result;
    }
    if (haystack_len >= 2
        && ((base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF))) {
        return result;
    }
    const size_t binary_check_len = haystack_len < (64 * 1024) ? haystack_len : (64 * 1024);
    if (memchr(base, 0, binary_check_len) != NULL) {
        return result;
    }

    size_t search_offset = 0;
    size_t last_emitted_line_start = (size_t)-1;
    size_t line_count_offset = 0;
    size_t line_number = 1;
    while (search_offset < haystack_len) {
        const uint8_t *found = rg_memmem_simple(base + search_offset, haystack_len - search_offset, literal, literal_len);
        if (found == NULL) {
            break;
        }

        const size_t literal_start = (size_t)(found - base);
        const size_t literal_end = literal_start + literal_len;
        size_t line_start = literal_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }
        const void *newline = memchr(found, '\n', haystack_len - literal_start);
        const size_t line_end = newline == NULL
            ? haystack_len
            : (size_t)((const uint8_t *)newline - base);

        if (rg_has_surrounding_ascii_words(base, line_start, line_end, literal_start, literal_end)) {
            result.total_match_count++;
            if (line_start != last_emitted_line_start) {
                const size_t output_end = newline == NULL ? haystack_len : line_end + 1;
                const size_t output_len = output_end - line_start;
                if (include_line_numbers) {
                    if (line_count_offset < line_start) {
                        line_number += rg_memcount_byte(base + line_count_offset, line_start - line_count_offset, '\n');
                        line_count_offset = line_start;
                    }
                    if (rg_write_decimal_colon(line_number) != 0) {
                        result.status = -1;
                        return result;
                    }
                }
                size_t bytes_written = 0;
                while (bytes_written < output_len) {
                    ssize_t written = write(STDOUT_FILENO, base + line_start + bytes_written, output_len - bytes_written);
                    if (written < 0) {
                        if (errno == EINTR) {
                            continue;
                        }
                        result.status = -1;
                        return result;
                    }
                    if (written == 0) {
                        result.status = -1;
                        return result;
                    }
                    bytes_written += (size_t)written;
                }
                if (newline == NULL) {
                    uint8_t terminator = '\n';
                    while (write(STDOUT_FILENO, &terminator, 1) < 0) {
                        if (errno != EINTR) {
                            result.status = -1;
                            return result;
                        }
                    }
                }
                result.matched_line_count++;
                last_emitted_line_start = line_start;
            }
        }

        search_offset = literal_end;
    }

    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = haystack_len;
    return result;
}

static rg_darwin_literal_file_result rg_darwin_write_word_literal_bytes(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *literal,
    size_t literal_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };

    if (haystack_len >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) {
        return result;
    }
    if (haystack_len >= 2
        && ((base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF))) {
        return result;
    }
    const size_t binary_check_len = haystack_len < (64 * 1024) ? haystack_len : (64 * 1024);
    if (memchr(base, 0, binary_check_len) != NULL) {
        return result;
    }

    size_t search_offset = 0;
    size_t last_emitted_line_start = (size_t)-1;
    size_t line_count_offset = 0;
    size_t line_number = 1;
    while (search_offset < haystack_len) {
        const uint8_t *found = rg_memmem_simple(base + search_offset, haystack_len - search_offset, literal, literal_len);
        if (found == NULL) {
            break;
        }

        const size_t match_start = (size_t)(found - base);
        const size_t match_end = match_start + literal_len;
        const int boundary = rg_word_boundary_ascii(base, haystack_len, match_start, match_end);
        if (boundary < 0) {
            return result;
        }
        if (boundary == 0) {
            search_offset = match_start + 1;
            continue;
        }

        result.total_match_count++;
        size_t line_start = match_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }

        if (line_start != last_emitted_line_start) {
            if (line_count_offset < line_start) {
                line_number += rg_memcount_byte(base + line_count_offset, line_start - line_count_offset, '\n');
                line_count_offset = line_start;
            }
            const void *newline = memchr(found, '\n', haystack_len - match_start);
            const size_t output_end = newline == NULL
                ? haystack_len
                : (size_t)(((const uint8_t *)newline - base) + 1);
            if (rg_write_decimal_colon(line_number) != 0
                || rg_write_all_stdout(base + line_start, output_end - line_start) != 0) {
                result.status = -1;
                return result;
            }
            if (newline == NULL) {
                uint8_t terminator = '\n';
                if (rg_write_all_stdout(&terminator, 1) != 0) {
                    result.status = -1;
                    return result;
                }
            }
            result.matched_line_count++;
            last_emitted_line_start = line_start;
        }

        search_offset = match_end;
    }

    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = haystack_len;
    return result;
}

static rg_darwin_literal_file_result rg_darwin_write_byte_set_bytes(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *needles,
    size_t needle_count
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };

    if (haystack_len >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) {
        return result;
    }
    if (haystack_len >= 2
        && ((base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF))) {
        return result;
    }
    const size_t binary_check_len = haystack_len < (64 * 1024) ? haystack_len : (64 * 1024);
    if (memchr(base, 0, binary_check_len) != NULL) {
        return result;
    }

    rg_output_buffer output = { .bytes = malloc(1024 * 1024), .length = 0, .capacity = 1024 * 1024 };
    if (output.bytes == NULL) {
        result.status = -1;
        return result;
    }

    size_t search_offset = 0;
    while (search_offset < haystack_len) {
        const uint8_t *found = rg_memchr_any_bytes(base + search_offset, haystack_len - search_offset, needles, needle_count);
        if (found == NULL) {
            break;
        }

        const size_t match_start = (size_t)(found - base);
        size_t line_start = match_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }

        const void *newline = memchr(found, '\n', haystack_len - match_start);
        const size_t output_end = newline == NULL
            ? haystack_len
            : (size_t)(((const uint8_t *)newline - base) + 1);
        if (rg_output_buffer_write(&output, base + line_start, output_end - line_start) != 0) {
            free(output.bytes);
            result.status = -1;
            return result;
        }
        if (newline == NULL) {
            uint8_t terminator = '\n';
            if (rg_output_buffer_write(&output, &terminator, 1) != 0) {
                free(output.bytes);
                result.status = -1;
                return result;
            }
        }
        result.matched_line_count++;
        result.total_match_count++;
        search_offset = output_end;
    }

    if (rg_output_buffer_flush(&output) != 0) {
        free(output.bytes);
        result.status = -1;
        return result;
    }
    free(output.bytes);
    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = haystack_len;
    return result;
}

static rg_darwin_literal_file_result rg_darwin_write_multi_literal_bytes(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *literals,
    const size_t *literal_offsets,
    const size_t *literal_lengths,
    size_t literal_count
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };

    if (haystack_len >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) {
        return result;
    }
    if (haystack_len >= 2
        && ((base[0] == 0xFF && base[1] == 0xFE) || (base[0] == 0xFE && base[1] == 0xFF))) {
        return result;
    }
    const size_t binary_check_len = haystack_len < (64 * 1024) ? haystack_len : (64 * 1024);
    if (memchr(base, 0, binary_check_len) != NULL) {
        return result;
    }

    if (literal_count > 64) {
        return result;
    }
    for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
        if (literal_lengths[literal_index] == 0) {
            return result;
        }
    }

    rg_output_buffer output = { .bytes = malloc(1024 * 1024), .length = 0, .capacity = 1024 * 1024 };
    if (output.bytes == NULL) {
        result.status = -1;
        return result;
    }

    size_t max_literal_len = 0;
    for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
        if (literal_lengths[literal_index] > max_literal_len) {
            max_literal_len = literal_lengths[literal_index];
        }
    }

#if defined(__APPLE__) && defined(__aarch64__)
    uint8x16_t first_vectors[literal_count];
    uint8x16_t tail_vectors[literal_count];
    for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
        const uint8_t *literal = literals + literal_offsets[literal_index];
        const size_t literal_len = literal_lengths[literal_index];
        first_vectors[literal_index] = vdupq_n_u8(literal[0]);
        tail_vectors[literal_index] = vdupq_n_u8(literal[literal_len - 1]);
    }
#endif

    size_t cursor = 0;
    size_t last_emitted_line_start = (size_t)-1;
    while (cursor < haystack_len) {
        size_t match_start = (size_t)-1;

#if defined(__APPLE__) && defined(__aarch64__)
        if (max_literal_len > 0 && cursor + max_literal_len + 15 <= haystack_len) {
            uint8x16_t candidate_lanes = vdupq_n_u8(0);
            const uint8x16_t first_bytes = vld1q_u8(base + cursor);
            for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
                const size_t literal_len = literal_lengths[literal_index];
                const uint8x16_t tail_bytes = vld1q_u8(base + cursor + literal_len - 1);
                candidate_lanes = vorrq_u8(
                    candidate_lanes,
                    vandq_u8(
                        vceqq_u8(first_bytes, first_vectors[literal_index]),
                        vceqq_u8(tail_bytes, tail_vectors[literal_index])
                    )
                );
            }
            if (vmaxvq_u8(candidate_lanes) != 0) {
                uint8_t matching_lanes[16];
                vst1q_u8(matching_lanes, candidate_lanes);
                for (int lane = 0; lane < 16; lane++) {
                    if (matching_lanes[lane] == 0) {
                        continue;
                    }
                    const size_t candidate_start = cursor + (size_t)lane;
                    for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
                        const uint8_t *literal = literals + literal_offsets[literal_index];
                        const size_t literal_len = literal_lengths[literal_index];
                        if (candidate_start + literal_len <= haystack_len
                            && base[candidate_start] == literal[0]
                            && base[candidate_start + literal_len - 1] == literal[literal_len - 1]
                            && (literal_len <= 2
                                || memcmp(base + candidate_start + 1, literal + 1, literal_len - 2) == 0)) {
                            match_start = candidate_start;
                            break;
                        }
                    }
                    if (match_start != (size_t)-1) {
                        break;
                    }
                }
            }
            if (match_start == (size_t)-1) {
                cursor += 16;
                continue;
            }
        } else
#endif
        {
            while (cursor < haystack_len && match_start == (size_t)-1) {
                for (size_t literal_index = 0; literal_index < literal_count; literal_index++) {
                    const uint8_t *literal = literals + literal_offsets[literal_index];
                    const size_t literal_len = literal_lengths[literal_index];
                    if (cursor + literal_len <= haystack_len
                        && base[cursor] == literal[0]
                        && base[cursor + literal_len - 1] == literal[literal_len - 1]
                        && (literal_len <= 2
                            || memcmp(base + cursor + 1, literal + 1, literal_len - 2) == 0)) {
                        match_start = cursor;
                        break;
                    }
                }
                if (match_start == (size_t)-1) {
                    cursor++;
                }
            }
            if (match_start == (size_t)-1) {
                break;
            }
        }

        size_t line_start = match_start;
        while (line_start > 0 && base[line_start - 1] != '\n') {
            line_start--;
        }
        const void *newline = memchr(base + match_start, '\n', haystack_len - match_start);
        const size_t output_end = newline == NULL
            ? haystack_len
            : (size_t)(((const uint8_t *)newline - base) + 1);
        if (line_start == last_emitted_line_start) {
            cursor = output_end;
            continue;
        }

        if (rg_output_buffer_write(&output, base + line_start, output_end - line_start) != 0) {
            free(output.bytes);
            result.status = -1;
            return result;
        }
        if (newline == NULL) {
            uint8_t terminator = '\n';
            if (rg_output_buffer_write(&output, &terminator, 1) != 0) {
                free(output.bytes);
                result.status = -1;
                return result;
            }
        }
        result.matched_line_count++;
        last_emitted_line_start = line_start;
        cursor = output_end;
    }

    if (rg_output_buffer_flush(&output) != 0) {
        free(output.bytes);
        result.status = -1;
        return result;
    }
    free(output.bytes);
    result.total_match_count = result.matched_line_count;
    result.status = result.matched_line_count > 0 ? 1 : 0;
    result.bytes_searched = haystack_len;
    return result;
}
#endif

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)needle;
    (void)needle_len;
    return result;
#else
    if (path == NULL || needle == NULL || needle_len == 0) {
        return result;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_literal_bytes_case_sensitive(base, haystack_len, needle, needle_len);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines_no_mmap(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)needle;
    (void)needle_len;
    return result;
#else
    if (path == NULL || needle == NULL || needle_len == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    result = rg_darwin_stream_literal_fd_lines(fd, (size_t)file_stat.st_size, needle, needle_len);
    close(fd);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines_ascii_case_insensitive(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)needle;
    (void)needle_len;
    return result;
#else
    if (path == NULL || needle == NULL || needle_len == 0) {
        return result;
    }
    for (size_t index = 0; index < needle_len; ++index) {
        if (needle[index] >= 0x80) {
            return result;
        }
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_literal_bytes_case_insensitive(base, haystack_len, needle, needle_len);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_surrounding_words_file_lines(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)literal;
    (void)literal_len;
    return result;
#else
    if (path == NULL || literal == NULL || literal_len == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_surrounding_words_bytes(base, haystack_len, literal, literal_len, 0);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_surrounding_words_file_lines_with_line_numbers(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)literal;
    (void)literal_len;
    return result;
#else
    if (path == NULL || literal == NULL || literal_len == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_surrounding_words_bytes(base, haystack_len, literal, literal_len, 1);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_word_literal_file_lines(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)literal;
    (void)literal_len;
    return result;
#else
    if (path == NULL || literal == NULL || literal_len == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_word_literal_bytes(base, haystack_len, literal, literal_len);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_byte_set_file_lines(
    const char *path,
    const uint8_t *needles,
    size_t needle_count
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)needles;
    (void)needle_count;
    return result;
#else
    if (path == NULL || needles == NULL || needle_count == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_byte_set_bytes(base, haystack_len, needles, needle_count);
    munmap(base, haystack_len);
    return result;
#endif
}

rg_darwin_literal_file_result rg_darwin_write_multi_literal_file_lines(
    const char *path,
    const uint8_t *literals,
    const size_t *literal_offsets,
    const size_t *literal_lengths,
    size_t literal_count
) {
    rg_darwin_literal_file_result result = { .status = -2, .matched_line_count = 0, .total_match_count = 0, .bytes_searched = 0 };
#ifndef __APPLE__
    (void)path;
    (void)literals;
    (void)literal_offsets;
    (void)literal_lengths;
    (void)literal_count;
    return result;
#else
    if (path == NULL
        || literals == NULL
        || literal_offsets == NULL
        || literal_lengths == NULL
        || literal_count == 0) {
        return result;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result.status = -1;
        return result;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0) {
        close(fd);
        result.status = -1;
        return result;
    }
    if ((file_stat.st_mode & S_IFMT) != S_IFREG) {
        close(fd);
        return result;
    }
    if (file_stat.st_size <= 0) {
        close(fd);
        result.status = 0;
        return result;
    }

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *base = mmap(NULL, haystack_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        result.status = -1;
        return result;
    }

    result = rg_darwin_write_multi_literal_bytes(
        base,
        haystack_len,
        literals,
        literal_offsets,
        literal_lengths,
        literal_count
    );
    munmap(base, haystack_len);
    return result;
#endif
}
