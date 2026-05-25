#include "CRipgrepPlatform.h"

#ifdef __APPLE__
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

    const size_t haystack_len = (size_t)file_stat.st_size;
    uint8_t *buffer = malloc(haystack_len);
    if (buffer == NULL) {
        close(fd);
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
            close(fd);
            result.status = -1;
            return result;
        }
        if (count == 0) {
            break;
        }
        bytes_read += (size_t)count;
    }
    close(fd);

    result = rg_darwin_write_literal_bytes_case_sensitive(buffer, bytes_read, needle, needle_len);
    free(buffer);
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
