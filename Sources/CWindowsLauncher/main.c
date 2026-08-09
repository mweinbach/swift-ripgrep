#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS

#include <windows.h>
#include <emmintrin.h>
#include <fcntl.h>
#include <io.h>
#include <intrin.h>
#include <process.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/*
 * A small native front end for the conservative Windows hot paths. The full
 * Swift executable remains beside this program as ripgrep-swift.exe and owns
 * every unsupported invocation. Keeping Foundation out of this process avoids
 * a fixed 7-9 ms loader penalty on short Windows searches.
 */

#define FAST_UNSUPPORTED (-1000)
#define MAX_BUFFERED_BYTES ((uint64_t)512 * 1024 * 1024)

#ifndef PF_AVX2_INSTRUCTIONS_AVAILABLE
#define PF_AVX2_INSTRUCTIONS_AVAILABLE 40
#endif

typedef int (*swift_rg_literal_candidate_callback)(size_t offset, void *context);
int swift_rg_scan_literal_avx2(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    swift_rg_literal_candidate_callback callback,
    void *context
);
int swift_rg_scan_ascii_case_insensitive_avx2(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    swift_rg_literal_candidate_callback callback,
    void *context
);

typedef struct {
    HANDLE handle;
    unsigned char *bytes;
    size_t count;
    int mapped;
} FileBytes;

typedef struct {
    unsigned char *bytes;
    size_t capacity;
} ReusableBuffer;

typedef struct {
    unsigned char *bytes;
    size_t count;
    size_t capacity;
    HANDLE handle;
    int failed;
} OutputBuffer;

typedef struct {
    unsigned char *bytes;
    size_t count;
    size_t capacity;
} MemoryBuffer;

typedef struct {
    wchar_t *wide_path;
    char *path;
    uint64_t size;
    uint64_t matches;
} DirectoryFile;

typedef struct {
    DirectoryFile *files;
    size_t count;
    size_t capacity;
} DirectoryFiles;

enum DirectoryMode {
    DIRECTORY_FILES,
    DIRECTORY_LINES,
    DIRECTORY_COUNT,
    DIRECTORY_WITH_MATCHES
};

enum SingleKind {
    SINGLE_LITERAL,
    SINGLE_CASE_INSENSITIVE,
    SINGLE_WORD,
    SINGLE_ALTERNATION,
    SINGLE_CAPITALIZED_SUFFIX
};

static int environment_exists(const wchar_t *name) {
    SetLastError(ERROR_SUCCESS);
    DWORD length = GetEnvironmentVariableW(name, NULL, 0);
    return length > 0 || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
}

static int stdout_is_console(void) {
    HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    return handle != NULL && handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode);
}

static int output_init(OutputBuffer *output, size_t capacity) {
    memset(output, 0, sizeof(*output));
    output->handle = GetStdHandle(STD_OUTPUT_HANDLE);
    output->capacity = capacity;
    output->bytes = (unsigned char *)malloc(capacity);
    return output->bytes != NULL && output->handle != NULL && output->handle != INVALID_HANDLE_VALUE;
}

static int output_flush(OutputBuffer *output) {
    if (output->failed) return 0;
    size_t offset = 0;
    while (offset < output->count) {
        DWORD written = 0;
        DWORD requested = (DWORD)((output->count - offset) > MAXDWORD
            ? MAXDWORD : (output->count - offset));
        if (!WriteFile(output->handle, output->bytes + offset, requested, &written, NULL)
            || written == 0) {
            output->failed = 1;
            return 0;
        }
        offset += written;
    }
    output->count = 0;
    return 1;
}

static int output_write(OutputBuffer *output, const void *bytes, size_t count) {
    const unsigned char *source = (const unsigned char *)bytes;
    while (count > 0) {
        if (output->count == output->capacity && !output_flush(output)) return 0;
        size_t available = output->capacity - output->count;
        size_t chunk = count < available ? count : available;
        memcpy(output->bytes + output->count, source, chunk);
        output->count += chunk;
        source += chunk;
        count -= chunk;
    }
    return 1;
}

static int output_byte(OutputBuffer *output, unsigned char byte) {
    return output_write(output, &byte, 1);
}

static int output_decimal(OutputBuffer *output, uint64_t value) {
    char buffer[32];
    int count = _snprintf(buffer, sizeof(buffer), "%llu", (unsigned long long)value);
    return count > 0 && output_write(output, buffer, (size_t)count);
}

static void output_destroy(OutputBuffer *output) {
    free(output->bytes);
    memset(output, 0, sizeof(*output));
}

static int is_ascii_wide(const wchar_t *string) {
    for (; *string; ++string) {
        if (*string > 0x7f) return 0;
    }
    return 1;
}

static char *ascii_from_wide(const wchar_t *string) {
    if (!is_ascii_wide(string)) return NULL;
    size_t count = wcslen(string);
    char *result = (char *)malloc(count + 1);
    if (!result) return NULL;
    for (size_t index = 0; index < count; ++index) {
        result[index] = string[index] == L'/' ? '\\' : (char)string[index];
    }
    result[count] = 0;
    return result;
}

static wchar_t *duplicate_normalized_path(const wchar_t *path) {
    size_t count = wcslen(path);
    wchar_t *result = (wchar_t *)malloc((count + 1) * sizeof(wchar_t));
    if (!result) return NULL;
    for (size_t index = 0; index <= count; ++index) {
        result[index] = path[index] == L'/' ? L'\\' : path[index];
    }
    while (count > 3 && result[count - 1] == L'\\') result[--count] = 0;
    return result;
}

static int is_plain_literal(const char *pattern) {
    static const char *metacharacters = "\\.^$*+?()[]{}|";
    if (!pattern[0]) return 0;
    for (const unsigned char *cursor = (const unsigned char *)pattern; *cursor; ++cursor) {
        if (*cursor >= 0x80 || *cursor == '\n' || *cursor == '\r'
            || strchr(metacharacters, *cursor)) return 0;
    }
    return 1;
}

static const unsigned char *find_literal(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count
) {
    if (literal_count == 0 || count < literal_count) return NULL;
    const unsigned char *cursor = bytes;
    const unsigned char *last = bytes + count - literal_count;
    while (cursor <= last) {
        const unsigned char *candidate = (const unsigned char *)memchr(
            cursor, literal[0], (size_t)(last - cursor + 1));
        if (!candidate) return NULL;
        if (literal_count == 1 || memcmp(candidate + 1, literal + 1, literal_count - 1) == 0) {
            return candidate;
        }
        cursor = candidate + 1;
    }
    return NULL;
}

static unsigned char ascii_lower(unsigned char byte) {
    return byte >= 'A' && byte <= 'Z' ? (unsigned char)(byte + ('a' - 'A')) : byte;
}

static const unsigned char *find_ascii_case_insensitive(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count
) {
    if (literal_count == 0 || count < literal_count) return NULL;
    size_t anchor = literal_count / 2;
    unsigned char lower = ascii_lower(literal[anchor]);
    unsigned char upper = lower >= 'a' && lower <= 'z'
        ? (unsigned char)(lower - ('a' - 'A')) : lower;
    const unsigned char *anchor_cursor = bytes + anchor;
    const unsigned char *anchor_end = bytes + count - (literal_count - anchor) + 1;
    __m128i lower_vector = _mm_set1_epi8((char)lower);
    __m128i upper_vector = _mm_set1_epi8((char)upper);
    while (anchor_cursor + 16 <= anchor_end) {
        __m128i block = _mm_loadu_si128((const __m128i *)anchor_cursor);
        __m128i matches = _mm_or_si128(
            _mm_cmpeq_epi8(block, lower_vector),
            _mm_cmpeq_epi8(block, upper_vector));
        unsigned long mask = (unsigned long)_mm_movemask_epi8(matches);
        while (mask) {
            unsigned long bit = 0;
            _BitScanForward(&bit, mask);
            const unsigned char *candidate = anchor_cursor + bit - anchor;
            size_t index = 0;
            while (index < literal_count
                && ascii_lower(candidate[index]) == ascii_lower(literal[index])) ++index;
            if (index == literal_count) return candidate;
            mask &= mask - 1;
        }
        anchor_cursor += 16;
    }
    while (anchor_cursor < anchor_end) {
        if ((*anchor_cursor == lower || *anchor_cursor == upper)) {
            const unsigned char *candidate = anchor_cursor - anchor;
            size_t index = 0;
            while (index < literal_count
                && ascii_lower(candidate[index]) == ascii_lower(literal[index])) ++index;
            if (index == literal_count) return candidate;
        }
        ++anchor_cursor;
    }
    return NULL;
}

static int usable_ascii_bytes(const unsigned char *bytes, size_t count) {
    if (count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) return 0;
    if (count >= 2
        && ((bytes[0] == 0xff && bytes[1] == 0xfe)
            || (bytes[0] == 0xfe && bytes[1] == 0xff))) return 0;
    __m128i zero = _mm_setzero_si128();
    size_t index = 0;
    while (index + 16 <= count) {
        __m128i block = _mm_loadu_si128((const __m128i *)(bytes + index));
        if (_mm_movemask_epi8(block)
            || _mm_movemask_epi8(_mm_cmpeq_epi8(block, zero))) return 0;
        index += 16;
    }
    for (; index < count; ++index) {
        if (bytes[index] == 0 || bytes[index] >= 0x80) return 0;
    }
    return 1;
}

static const unsigned char *line_end_after(
    const unsigned char *bytes,
    const unsigned char *end,
    const unsigned char *position
);
static int memory_append(MemoryBuffer *buffer, const unsigned char *bytes, size_t count);

static int memory_append(MemoryBuffer *buffer, const unsigned char *bytes, size_t count) {
    if (count > MAX_BUFFERED_BYTES - buffer->count) return 0;
    size_t required = buffer->count + count;
    if (required > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 64 * 1024;
        while (capacity < required) capacity *= 2;
        unsigned char *replacement = (unsigned char *)realloc(buffer->bytes, capacity);
        if (!replacement) return 0;
        buffer->bytes = replacement;
        buffer->capacity = capacity;
    }
    memcpy(buffer->bytes + buffer->count, bytes, count);
    buffer->count += count;
    return 1;
}

typedef struct {
    const unsigned char *bytes;
    const unsigned char *end;
    size_t literal_count;
    const unsigned char *last_matched_line_end;
    uint64_t matched_lines;
    int collect_lines;
    MemoryBuffer *line_output;
} PlainLiteralContext;

static int collect_plain_literal_candidate(size_t offset, void *opaque_context) {
    PlainLiteralContext *context = (PlainLiteralContext *)opaque_context;
    const unsigned char *candidate = context->bytes + offset;
    if (context->last_matched_line_end && candidate < context->last_matched_line_end) return 1;
    const unsigned char *line_start = candidate;
    while (line_start > context->bytes && line_start[-1] != '\n') --line_start;
    const unsigned char *after = line_end_after(
        context->bytes, context->end, candidate + context->literal_count);
    ++context->matched_lines;
    context->last_matched_line_end = after;
    if (!context->collect_lines) return 1;
    if (!memory_append(context->line_output, line_start, (size_t)(after - line_start))) return 0;
    if (after == context->end && context->end > line_start && context->end[-1] != '\n') {
        static const unsigned char newline = '\n';
        if (!memory_append(context->line_output, &newline, 1)) return 0;
    }
    return 1;
}

typedef struct {
    const unsigned char *bytes;
    const unsigned char *end;
    size_t suffix_count;
    uint64_t matched_lines;
    int supported;
    const unsigned char *last_matched_line_end;
} CapitalizedSuffixContext;

static int collect_capitalized_suffix_candidate(size_t offset, void *opaque_context) {
    CapitalizedSuffixContext *context = (CapitalizedSuffixContext *)opaque_context;
    const unsigned char *match = context->bytes + offset;
    if (context->last_matched_line_end && match < context->last_matched_line_end) return 1;
    const unsigned char *prefix = match;
    int saw_space = 0;
    while (prefix > context->bytes) {
        unsigned char byte = prefix[-1];
        if (byte >= 0x80) {
            context->supported = 0;
            return 0;
        }
        if (byte != ' ' && !(byte >= 0x09 && byte <= 0x0d)) break;
        saw_space = 1;
        --prefix;
    }
    const unsigned char *lower_end = prefix;
    while (prefix > context->bytes && prefix[-1] >= 'a' && prefix[-1] <= 'z') --prefix;
    if (saw_space && prefix < lower_end && prefix > context->bytes
        && prefix[-1] >= 'A' && prefix[-1] <= 'Z') {
        ++context->matched_lines;
        context->last_matched_line_end = line_end_after(
            context->bytes, context->end, match + context->suffix_count);
    }
    return 1;
}

static int append_literal_lines_to_memory(
    MemoryBuffer *output,
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    int final_chunk
) {
    const unsigned char *end = bytes + count;
    const unsigned char *cursor = bytes;
    while (cursor < end) {
        const unsigned char *match = find_literal(cursor, (size_t)(end - cursor), literal, literal_count);
        if (!match) break;
        const unsigned char *start = match;
        while (start > bytes && start[-1] != '\n') --start;
        const unsigned char *after = line_end_after(bytes, end, match + literal_count);
        if (!memory_append(output, start, (size_t)(after - start))) return 0;
        if (final_chunk && after == end && end > start && end[-1] != '\n') {
            static const unsigned char newline = '\n';
            if (!memory_append(output, &newline, 1)) return 0;
        }
        cursor = after;
    }
    return 1;
}

static int stream_buffered_literal_lines(
    const wchar_t *path,
    const unsigned char *literal,
    size_t literal_count
) {
    HANDLE file = CreateFileW(
        path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return FAST_UNSUPPORTED;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0
        || (uint64_t)size.QuadPart > MAX_BUFFERED_BYTES) {
        CloseHandle(file);
        return FAST_UNSUPPORTED;
    }
    size_t capacity = 1024 * 1024;
    unsigned char *buffer = (unsigned char *)malloc(capacity);
    MemoryBuffer matches = {0};
    if (!buffer) { CloseHandle(file); return 2; }
    size_t carried = 0;
    int first_read = 1;
    int result = 1;
    for (;;) {
        if (carried == capacity) {
            if (capacity >= MAX_BUFFERED_BYTES) { result = FAST_UNSUPPORTED; break; }
            size_t replacement_capacity = capacity * 2;
            unsigned char *replacement = (unsigned char *)realloc(buffer, replacement_capacity);
            if (!replacement) { result = 2; break; }
            buffer = replacement;
            capacity = replacement_capacity;
        }
        size_t requested_size = capacity - carried;
        if (requested_size > 1024 * 1024) requested_size = 1024 * 1024;
        DWORD read = 0;
        if (!ReadFile(file, buffer + carried, (DWORD)requested_size, &read, NULL)) {
            result = FAST_UNSUPPORTED;
            break;
        }
        if (read == 0) {
            if (carried && !append_literal_lines_to_memory(
                &matches, buffer, carried, literal, literal_count, 1)) result = 2;
            break;
        }
        size_t total = carried + read;
        if (first_read) {
            if ((total >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf)
                || (total >= 2 && ((buffer[0] == 0xff && buffer[1] == 0xfe)
                    || (buffer[0] == 0xfe && buffer[1] == 0xff)))) {
                result = FAST_UNSUPPORTED;
                break;
            }
            first_read = 0;
        }
        if (memchr(buffer + carried, 0, read)) { result = FAST_UNSUPPORTED; break; }
        size_t complete = total;
        while (complete > 0 && buffer[complete - 1] != '\n') --complete;
        if (complete) {
            if (!append_literal_lines_to_memory(
                &matches, buffer, complete, literal, literal_count, 0)) {
                result = 2;
                break;
            }
            carried = total - complete;
            if (carried) memmove(buffer, buffer + complete, carried);
        } else {
            carried = total;
        }
    }
    CloseHandle(file);
    free(buffer);
    if (result != FAST_UNSUPPORTED && result != 2 && matches.count) {
        OutputBuffer output;
        if (!output_init(&output, 256 * 1024)) result = 2;
        else {
            result = output_write(&output, matches.bytes, matches.count) && output_flush(&output) ? 0 : 2;
            output_destroy(&output);
        }
    }
    free(matches.bytes);
    return result;
}

static int usable_bytes(const unsigned char *bytes, size_t count) {
    if (count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) return 0;
    if (count >= 2
        && ((bytes[0] == 0xff && bytes[1] == 0xfe)
            || (bytes[0] == 0xfe && bytes[1] == 0xff))) return 0;
    return count == 0 || memchr(bytes, 0, count) == NULL;
}

static int load_file(const wchar_t *path, int buffered, FileBytes *result) {
    memset(result, 0, sizeof(*result));
    result->handle = CreateFileW(
        path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
        NULL
    );
    if (result->handle == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(result->handle, &size) || size.QuadPart < 0
        || (uint64_t)size.QuadPart > MAX_BUFFERED_BYTES) {
        CloseHandle(result->handle);
        return 0;
    }
    result->count = (size_t)size.QuadPart;
    if (result->count == 0) {
        result->bytes = (unsigned char *)malloc(1);
        if (!result->bytes) {
            CloseHandle(result->handle);
            return 0;
        }
        return 1;
    }
    if (buffered) {
        result->bytes = (unsigned char *)malloc(result->count);
        if (!result->bytes) {
            CloseHandle(result->handle);
            return 0;
        }
        size_t offset = 0;
        while (offset < result->count) {
            DWORD read = 0;
            DWORD requested = (DWORD)((result->count - offset) > MAXDWORD
                ? MAXDWORD : result->count - offset);
            if (!ReadFile(result->handle, result->bytes + offset, requested, &read, NULL) || read == 0) {
                free(result->bytes);
                CloseHandle(result->handle);
                return 0;
            }
            offset += read;
        }
        return 1;
    }
    HANDLE mapping = CreateFileMappingW(result->handle, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!mapping) {
        CloseHandle(result->handle);
        return 0;
    }
    result->bytes = (unsigned char *)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(mapping);
    if (!result->bytes) {
        CloseHandle(result->handle);
        return 0;
    }
    result->mapped = 1;
    return 1;
}

static void unload_file(FileBytes *file) {
    if (file->bytes) {
        if (file->mapped) UnmapViewOfFile(file->bytes);
        else free(file->bytes);
    }
    if (file->handle && file->handle != INVALID_HANDLE_VALUE) CloseHandle(file->handle);
    memset(file, 0, sizeof(*file));
}

static const unsigned char *line_end_after(
    const unsigned char *bytes,
    const unsigned char *end,
    const unsigned char *position
) {
    (void)bytes;
    const unsigned char *newline = (const unsigned char *)memchr(
        position, '\n', (size_t)(end - position));
    return newline ? newline + 1 : end;
}

static uint64_t count_literal_lines(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count,
    int case_insensitive,
    int word
) {
    const unsigned char *end = bytes + count;
    const unsigned char *cursor = bytes;
    uint64_t matches = 0;
    while (cursor < end) {
        const unsigned char *match = case_insensitive
            ? find_ascii_case_insensitive(cursor, (size_t)(end - cursor), literal, literal_count)
            : find_literal(cursor, (size_t)(end - cursor), literal, literal_count);
        if (!match) break;
        if (word) {
            unsigned char before = match == bytes ? 0 : match[-1];
            unsigned char after = match + literal_count == end ? 0 : match[literal_count];
            int before_word = (before >= 'a' && before <= 'z') || (before >= 'A' && before <= 'Z')
                || (before >= '0' && before <= '9') || before == '_';
            int after_word = (after >= 'a' && after <= 'z') || (after >= 'A' && after <= 'Z')
                || (after >= '0' && after <= '9') || after == '_';
            if (before_word || after_word) {
                cursor = match + 1;
                continue;
            }
        }
        ++matches;
        cursor = line_end_after(bytes, end, match + literal_count);
    }
    return matches;
}

static uint64_t count_alternation_lines(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *left,
    size_t left_count,
    const unsigned char *right,
    size_t right_count
) {
    const unsigned char *end = bytes + count;
    const unsigned char *cursor = bytes;
    uint64_t matches = 0;
    while (cursor < end) {
        const unsigned char *left_match = find_literal(cursor, (size_t)(end - cursor), left, left_count);
        const unsigned char *right_match = find_literal(cursor, (size_t)(end - cursor), right, right_count);
        const unsigned char *match = !left_match ? right_match
            : (!right_match || left_match < right_match ? left_match : right_match);
        if (!match) break;
        ++matches;
        cursor = line_end_after(bytes, end, match + 1);
    }
    return matches;
}

static uint64_t count_capitalized_suffix_lines(
    const unsigned char *bytes,
    size_t count,
    const unsigned char *suffix,
    size_t suffix_count,
    int *supported
) {
    *supported = 1;
    const unsigned char *end = bytes + count;
    const unsigned char *cursor = bytes;
    uint64_t matches = 0;
    while (cursor < end) {
        const unsigned char *match = find_literal(cursor, (size_t)(end - cursor), suffix, suffix_count);
        if (!match) break;
        const unsigned char *prefix = match;
        int saw_space = 0;
        while (prefix > bytes) {
            unsigned char byte = prefix[-1];
            if (byte >= 0x80) {
                *supported = 0;
                return 0;
            }
            if (byte != ' ' && !(byte >= 0x09 && byte <= 0x0d)) break;
            saw_space = 1;
            --prefix;
        }
        const unsigned char *lower_end = prefix;
        while (prefix > bytes && prefix[-1] >= 'a' && prefix[-1] <= 'z') --prefix;
        int matched = saw_space && prefix < lower_end && prefix > bytes
            && prefix[-1] >= 'A' && prefix[-1] <= 'Z';
        if (matched) {
            ++matches;
            cursor = line_end_after(bytes, end, match + suffix_count);
        } else {
            cursor = match + 1;
        }
    }
    return matches;
}

static int write_matching_literal_lines(
    OutputBuffer *output,
    const unsigned char *bytes,
    size_t count,
    const unsigned char *literal,
    size_t literal_count
) {
    const unsigned char *end = bytes + count;
    const unsigned char *cursor = bytes;
    uint64_t matched = 0;
    while (cursor < end) {
        const unsigned char *match = find_literal(cursor, (size_t)(end - cursor), literal, literal_count);
        if (!match) break;
        const unsigned char *start = match;
        while (start > bytes && start[-1] != '\n') --start;
        const unsigned char *after = line_end_after(bytes, end, match + literal_count);
        if (!output_write(output, start, (size_t)(after - start))) return 2;
        if (after == end && end > start && end[-1] != '\n' && !output_byte(output, '\n')) return 2;
        ++matched;
        cursor = after;
    }
    if (!output_flush(output)) return 2;
    return matched ? 0 : 1;
}

static int parse_common_prefix(int argc, wchar_t **argv, int *index) {
    int cursor = 1;
    while (cursor < argc) {
        if (wcscmp(argv[cursor], L"--no-config") == 0 || wcscmp(argv[cursor], L"--color=never") == 0) {
            ++cursor;
        } else if (wcscmp(argv[cursor], L"--color") == 0 && cursor + 1 < argc
            && wcscmp(argv[cursor + 1], L"never") == 0) {
            cursor += 2;
        } else {
            break;
        }
    }
    *index = cursor;
    return 1;
}

static int run_single_file(int argc, wchar_t **argv) {
    int index = 0;
    parse_common_prefix(argc, argv, &index);
    int buffered = 0, count_mode = 0, case_insensitive = 0, word = 0;
    while (index < argc - 2) {
        if (wcscmp(argv[index], L"--no-mmap") == 0) buffered = 1;
        else if (wcscmp(argv[index], L"-c") == 0 || wcscmp(argv[index], L"--count") == 0) count_mode = 1;
        else if (wcscmp(argv[index], L"-i") == 0 || wcscmp(argv[index], L"--ignore-case") == 0) case_insensitive = 1;
        else if (wcscmp(argv[index], L"-w") == 0 || wcscmp(argv[index], L"--word-regexp") == 0) word = 1;
        else return FAST_UNSUPPORTED;
        ++index;
    }
    if (argc - index != 2) return FAST_UNSUPPORTED;
    char *pattern = ascii_from_wide(argv[index]);
    if (!pattern) return FAST_UNSUPPORTED;
    const wchar_t *path = argv[index + 1];
    enum SingleKind kind = SINGLE_LITERAL;
    char *left = NULL, *right = NULL;
    static const char regex_prefix[] = "[A-Z][a-z]+\\s+";
    if (count_mode && !case_insensitive && !word) {
        char *bar = strchr(pattern, '|');
        if (bar && strchr(bar + 1, '|') == NULL) {
            *bar = 0;
            left = pattern;
            right = bar + 1;
            if (!is_plain_literal(left) || !is_plain_literal(right)) {
                free(pattern);
                return FAST_UNSUPPORTED;
            }
            kind = SINGLE_ALTERNATION;
        } else if (strncmp(pattern, regex_prefix, sizeof(regex_prefix) - 1) == 0
            && is_plain_literal(pattern + sizeof(regex_prefix) - 1)) {
            kind = SINGLE_CAPITALIZED_SUFFIX;
        }
    }
    if (kind == SINGLE_LITERAL) {
        if (!is_plain_literal(pattern) || (case_insensitive && word)) {
            free(pattern);
            return FAST_UNSUPPORTED;
        }
        if (case_insensitive) kind = SINGLE_CASE_INSENSITIVE;
        else if (word) kind = SINGLE_WORD;
    }
    if (!count_mode && kind != SINGLE_LITERAL) {
        free(pattern);
        return FAST_UNSUPPORTED;
    }

    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        free(pattern);
        return FAST_UNSUPPORTED;
    }
    if (buffered && !count_mode && kind == SINGLE_LITERAL) {
        int result = stream_buffered_literal_lines(
            path, (const unsigned char *)pattern, strlen(pattern));
        free(pattern);
        return result;
    }
    FileBytes file;
    if (!load_file(path, buffered, &file)) {
        free(pattern);
        return FAST_UNSUPPORTED;
    }
    int used_fused_plain_scan = 0;
    int used_fused_regex_scan = 0;
    int used_fused_case_insensitive_scan = 0;
    MemoryBuffer fused_plain_lines = {0};
    uint64_t fused_plain_matches = 0;
    uint64_t fused_regex_matches = 0;
    uint64_t fused_case_insensitive_matches = 0;
    if (kind == SINGLE_LITERAL
        && IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE)) {
        if ((file.count >= 3 && file.bytes[0] == 0xef && file.bytes[1] == 0xbb && file.bytes[2] == 0xbf)
            || (file.count >= 2 && ((file.bytes[0] == 0xff && file.bytes[1] == 0xfe)
                || (file.bytes[0] == 0xfe && file.bytes[1] == 0xff)))) {
            unload_file(&file);
            free(pattern);
            return FAST_UNSUPPORTED;
        }
        PlainLiteralContext context = {
            file.bytes,
            file.bytes + file.count,
            strlen(pattern),
            NULL,
            0,
            !count_mode,
            &fused_plain_lines
        };
        int scan_result = swift_rg_scan_literal_avx2(
            file.bytes,
            file.count,
            (const unsigned char *)pattern,
            strlen(pattern),
            collect_plain_literal_candidate,
            &context);
        if (scan_result != 0) {
            free(fused_plain_lines.bytes);
            unload_file(&file);
            free(pattern);
            return scan_result == -2 ? 2 : FAST_UNSUPPORTED;
        }
        used_fused_plain_scan = 1;
        fused_plain_matches = context.matched_lines;
    } else if (kind == SINGLE_CAPITALIZED_SUFFIX
        && IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE)) {
        if ((file.count >= 3 && file.bytes[0] == 0xef && file.bytes[1] == 0xbb && file.bytes[2] == 0xbf)
            || (file.count >= 2 && ((file.bytes[0] == 0xff && file.bytes[1] == 0xfe)
                || (file.bytes[0] == 0xfe && file.bytes[1] == 0xff)))) {
            unload_file(&file);
            free(pattern);
            return FAST_UNSUPPORTED;
        }
        const char *suffix = pattern + sizeof(regex_prefix) - 1;
        CapitalizedSuffixContext context = {
            file.bytes,
            file.bytes + file.count,
            strlen(suffix),
            0,
            1,
            NULL
        };
        int scan_result = swift_rg_scan_literal_avx2(
            file.bytes,
            file.count,
            (const unsigned char *)suffix,
            strlen(suffix),
            collect_capitalized_suffix_candidate,
            &context);
        if (scan_result != 0) {
            unload_file(&file);
            free(pattern);
            return !context.supported || scan_result == -1 ? FAST_UNSUPPORTED : 2;
        }
        used_fused_regex_scan = 1;
        fused_regex_matches = context.matched_lines;
    } else if (kind == SINGLE_CASE_INSENSITIVE
        && IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE)) {
        if ((file.count >= 3 && file.bytes[0] == 0xef && file.bytes[1] == 0xbb && file.bytes[2] == 0xbf)
            || (file.count >= 2 && ((file.bytes[0] == 0xff && file.bytes[1] == 0xfe)
                || (file.bytes[0] == 0xfe && file.bytes[1] == 0xff)))) {
            unload_file(&file);
            free(pattern);
            return FAST_UNSUPPORTED;
        }
        PlainLiteralContext context = {
            file.bytes,
            file.bytes + file.count,
            strlen(pattern),
            NULL,
            0,
            0,
            &fused_plain_lines
        };
        int scan_result = swift_rg_scan_ascii_case_insensitive_avx2(
            file.bytes,
            file.count,
            (const unsigned char *)pattern,
            strlen(pattern),
            collect_plain_literal_candidate,
            &context);
        if (scan_result != 0) {
            unload_file(&file);
            free(pattern);
            return scan_result == -1 ? FAST_UNSUPPORTED : 2;
        }
        used_fused_case_insensitive_scan = 1;
        fused_case_insensitive_matches = context.matched_lines;
    } else if (kind == SINGLE_CASE_INSENSITIVE || kind == SINGLE_WORD) {
        if (!usable_ascii_bytes(file.bytes, file.count)) {
            unload_file(&file);
            free(pattern);
            return FAST_UNSUPPORTED;
        }
    } else if (!usable_bytes(file.bytes, file.count)) {
        unload_file(&file);
        free(pattern);
        return FAST_UNSUPPORTED;
    }

    OutputBuffer output;
    if (!output_init(&output, 256 * 1024)) {
        unload_file(&file);
        free(pattern);
        return 2;
    }
    int result = 1;
    if (!count_mode) {
        if (used_fused_plain_scan) {
            if (fused_plain_lines.count) {
                result = output_write(&output, fused_plain_lines.bytes, fused_plain_lines.count)
                    && output_flush(&output) ? 0 : 2;
            }
        } else {
            result = write_matching_literal_lines(
                &output, file.bytes, file.count, (const unsigned char *)pattern, strlen(pattern));
        }
    } else {
        uint64_t matches = 0;
        int supported = 1;
        if (kind == SINGLE_ALTERNATION) {
            matches = count_alternation_lines(
                file.bytes, file.count,
                (const unsigned char *)left, strlen(left),
                (const unsigned char *)right, strlen(right));
        } else if (kind == SINGLE_CAPITALIZED_SUFFIX && used_fused_regex_scan) {
            matches = fused_regex_matches;
        } else if (kind == SINGLE_CAPITALIZED_SUFFIX) {
            const char *suffix = pattern + sizeof(regex_prefix) - 1;
            matches = count_capitalized_suffix_lines(
                file.bytes, file.count, (const unsigned char *)suffix, strlen(suffix), &supported);
        } else if (kind == SINGLE_LITERAL && used_fused_plain_scan) {
            matches = fused_plain_matches;
        } else if (kind == SINGLE_CASE_INSENSITIVE && used_fused_case_insensitive_scan) {
            matches = fused_case_insensitive_matches;
        } else {
            matches = count_literal_lines(
                file.bytes, file.count, (const unsigned char *)pattern, strlen(pattern),
                kind == SINGLE_CASE_INSENSITIVE, kind == SINGLE_WORD);
        }
        if (!supported) {
            result = FAST_UNSUPPORTED;
        } else if (matches > 0) {
            result = output_decimal(&output, matches) && output_byte(&output, '\n')
                && output_flush(&output) ? 0 : 2;
        }
    }
    free(fused_plain_lines.bytes);
    output_destroy(&output);
    unload_file(&file);
    free(pattern);
    return result;
}

static wchar_t *join_wide_path(const wchar_t *directory, const wchar_t *name) {
    size_t directory_count = wcslen(directory);
    size_t name_count = wcslen(name);
    int separator = directory_count > 0 && directory[directory_count - 1] != L'\\';
    wchar_t *result = (wchar_t *)malloc(
        (directory_count + (size_t)separator + name_count + 1) * sizeof(wchar_t));
    if (!result) return NULL;
    memcpy(result, directory, directory_count * sizeof(wchar_t));
    if (separator) result[directory_count++] = L'\\';
    memcpy(result + directory_count, name, (name_count + 1) * sizeof(wchar_t));
    return result;
}

static int marker_exists(const wchar_t *directory, const wchar_t *marker) {
    wchar_t *path = join_wide_path(directory, marker);
    if (!path) return -1;
    SetLastError(ERROR_SUCCESS);
    DWORD attributes = GetFileAttributesW(path);
    DWORD error = GetLastError();
    free(path);
    if (attributes != INVALID_FILE_ATTRIBUTES) return 1;
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return 0;
    return -1;
}

static int ancestor_contains_ignore_metadata(const wchar_t *root) {
    static const wchar_t *markers[] = {L".git", L".gitignore", L".ignore", L".rgignore"};
    wchar_t *directory = _wcsdup(root);
    if (!directory) return 1;
    wchar_t *slash = wcsrchr(directory, L'\\');
    if (slash) *slash = 0;
    while (directory[0]) {
        for (size_t index = 0; index < sizeof(markers) / sizeof(markers[0]); ++index) {
            int present = marker_exists(directory, markers[index]);
            if (present != 0) {
                free(directory);
                return 1;
            }
        }
        if (wcslen(directory) == 3 && directory[1] == L':' && directory[2] == L'\\') break;
        slash = wcsrchr(directory, L'\\');
        if (!slash || slash == directory) break;
        if (slash == directory + 2 && directory[1] == L':') slash[1] = 0;
        else *slash = 0;
    }
    free(directory);
    return 0;
}

static void directory_files_destroy(DirectoryFiles *list) {
    for (size_t index = 0; index < list->count; ++index) {
        free(list->files[index].wide_path);
        free(list->files[index].path);
    }
    free(list->files);
    memset(list, 0, sizeof(*list));
}

static int directory_files_append(
    DirectoryFiles *list,
    wchar_t *wide_path,
    char *path,
    uint64_t size
) {
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 256;
        DirectoryFile *replacement = (DirectoryFile *)realloc(
            list->files, capacity * sizeof(DirectoryFile));
        if (!replacement) return 0;
        list->files = replacement;
        list->capacity = capacity;
    }
    DirectoryFile *file = &list->files[list->count++];
    file->wide_path = wide_path;
    file->path = path;
    file->size = size;
    file->matches = 0;
    return 1;
}

static int collect_directory_files(const wchar_t *directory, DirectoryFiles *files) {
    wchar_t *wildcard = join_wide_path(directory, L"*");
    if (!wildcard) return 0;
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileW(wildcard, &data);
    free(wildcard);
    if (find == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    int success = 1;
    do {
        const wchar_t *name = data.cFileName;
        if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;
        if (!is_ascii_wide(name)) { success = 0; break; }
        if (wcscmp(name, L".git") == 0 || wcscmp(name, L".gitignore") == 0
            || wcscmp(name, L".ignore") == 0 || wcscmp(name, L".rgignore") == 0) {
            success = 0;
            break;
        }
        if (name[0] == L'.') continue;
        DWORD attributes = data.dwFileAttributes;
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;
        if (attributes & FILE_ATTRIBUTE_HIDDEN) { success = 0; break; }
        wchar_t *path = join_wide_path(directory, name);
        if (!path) { success = 0; break; }
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            success = collect_directory_files(path, files);
            free(path);
            if (!success) break;
        } else if (!(attributes & FILE_ATTRIBUTE_DEVICE)) {
            uint64_t size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
            char *ascii_path = ascii_from_wide(path);
            if (size > MAX_BUFFERED_BYTES || !ascii_path
                || !directory_files_append(files, path, ascii_path, size)) {
                free(path);
                free(ascii_path);
                success = 0;
                break;
            }
        } else {
            free(path);
        }
    } while (FindNextFileW(find, &data));
    if (success && GetLastError() != ERROR_NO_MORE_FILES) success = 0;
    FindClose(find);
    return success;
}

static int compare_directory_files(const void *left, const void *right) {
    const DirectoryFile *lhs = (const DirectoryFile *)left;
    const DirectoryFile *rhs = (const DirectoryFile *)right;
    const char *left_component = lhs->path;
    const char *right_component = rhs->path;
    for (;;) {
        const char *left_end = strchr(left_component, '\\');
        const char *right_end = strchr(right_component, '\\');
        size_t left_count = left_end ? (size_t)(left_end - left_component) : strlen(left_component);
        size_t right_count = right_end ? (size_t)(right_end - right_component) : strlen(right_component);
        size_t common = left_count < right_count ? left_count : right_count;
        int ordering = memcmp(left_component, right_component, common);
        if (ordering != 0) return ordering;
        if (left_count != right_count) return left_count < right_count ? -1 : 1;
        if (!left_end || !right_end) return left_end ? 1 : (right_end ? -1 : 0);
        left_component = left_end + 1;
        right_component = right_end + 1;
    }
}

static int reusable_read_file(const DirectoryFile *file, ReusableBuffer *buffer, size_t *count) {
    HANDLE handle = CreateFileW(
        file->wide_path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
        NULL);
    if (handle == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER actual_size;
    if (!GetFileSizeEx(handle, &actual_size) || actual_size.QuadPart < 0
        || (uint64_t)actual_size.QuadPart > MAX_BUFFERED_BYTES) {
        CloseHandle(handle);
        return 0;
    }
    size_t size = (size_t)actual_size.QuadPart;
    if (!buffer->bytes) {
        buffer->capacity = 256 * 1024;
        buffer->bytes = (unsigned char *)malloc(buffer->capacity);
        if (!buffer->bytes) { CloseHandle(handle); return 0; }
    }
    if (size > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 256 * 1024;
        while (capacity < size) capacity *= 2;
        unsigned char *replacement = (unsigned char *)realloc(buffer->bytes, capacity);
        if (!replacement) { CloseHandle(handle); return 0; }
        buffer->bytes = replacement;
        buffer->capacity = capacity;
    }
    size_t offset = 0;
    while (offset < size) {
        DWORD read = 0;
        DWORD requested = (DWORD)((size - offset) > MAXDWORD ? MAXDWORD : size - offset);
        if (!ReadFile(handle, buffer->bytes + offset, requested, &read, NULL) || read == 0) {
            CloseHandle(handle);
            return 0;
        }
        offset += read;
    }
    CloseHandle(handle);
    *count = size;
    return 1;
}

static int run_sorted_directory(int argc, wchar_t **argv) {
    int index = 0;
    parse_common_prefix(argc, argv, &index);
    if (index >= argc) return FAST_UNSUPPORTED;
    if (wcscmp(argv[index], L"--sort=path") == 0) {
        ++index;
    } else if (wcscmp(argv[index], L"--sort") == 0 && index + 1 < argc
        && wcscmp(argv[index + 1], L"path") == 0) {
        index += 2;
    } else {
        return FAST_UNSUPPORTED;
    }

    enum DirectoryMode mode;
    wchar_t *pattern_wide = NULL;
    wchar_t *root_argument = NULL;
    if (argc - index == 2 && wcscmp(argv[index], L"--files") == 0) {
        mode = DIRECTORY_FILES;
        root_argument = argv[index + 1];
    } else if (argc - index == 2) {
        mode = DIRECTORY_LINES;
        pattern_wide = argv[index];
        root_argument = argv[index + 1];
    } else if (argc - index == 3
        && (wcscmp(argv[index], L"-c") == 0 || wcscmp(argv[index], L"--count") == 0)) {
        mode = DIRECTORY_COUNT;
        pattern_wide = argv[index + 1];
        root_argument = argv[index + 2];
    } else if (argc - index == 3
        && (wcscmp(argv[index], L"-l") == 0
            || wcscmp(argv[index], L"--files-with-matches") == 0)) {
        mode = DIRECTORY_WITH_MATCHES;
        pattern_wide = argv[index + 1];
        root_argument = argv[index + 2];
    } else {
        return FAST_UNSUPPORTED;
    }

    char *pattern = pattern_wide ? ascii_from_wide(pattern_wide) : NULL;
    if (pattern_wide && (!pattern || !is_plain_literal(pattern))) {
        free(pattern);
        return FAST_UNSUPPORTED;
    }
    if (!is_ascii_wide(root_argument) || !(root_argument[0] && root_argument[1] == L':')) {
        free(pattern);
        return FAST_UNSUPPORTED;
    }
    wchar_t *root = duplicate_normalized_path(root_argument);
    if (!root) { free(pattern); return FAST_UNSUPPORTED; }
    DWORD attributes = GetFileAttributesW(root);
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) || ancestor_contains_ignore_metadata(root)) {
        free(root);
        free(pattern);
        return FAST_UNSUPPORTED;
    }

    DirectoryFiles files = {0};
    if (!collect_directory_files(root, &files)) {
        directory_files_destroy(&files);
        free(root);
        free(pattern);
        return FAST_UNSUPPORTED;
    }
    qsort(files.files, files.count, sizeof(DirectoryFile), compare_directory_files);
    OutputBuffer output;
    if (!output_init(&output, 64 * 1024)) {
        directory_files_destroy(&files);
        free(root);
        free(pattern);
        return 2;
    }

    int result = files.count ? 0 : 1;
    if (mode == DIRECTORY_FILES) {
        for (size_t file_index = 0; file_index < files.count; ++file_index) {
            DirectoryFile *file = &files.files[file_index];
            if (!output_write(&output, file->path, strlen(file->path)) || !output_byte(&output, '\n')) {
                result = 2;
                break;
            }
        }
    } else {
        ReusableBuffer buffer = {0};
        uint64_t matched_files = 0;
        for (size_t file_index = 0; file_index < files.count; ++file_index) {
            DirectoryFile *file = &files.files[file_index];
            size_t count = 0;
            if (!reusable_read_file(file, &buffer, &count)
                || !usable_bytes(buffer.bytes, count)) {
                result = FAST_UNSUPPORTED;
                break;
            }
            uint64_t matches = count_literal_lines(
                buffer.bytes, count, (const unsigned char *)pattern, strlen(pattern), 0, 0);
            file->matches = matches;
            if (matches) ++matched_files;
            if (mode == DIRECTORY_LINES && matches) {
                result = FAST_UNSUPPORTED;
                break;
            }
        }
        free(buffer.bytes);
        if (result != FAST_UNSUPPORTED) {
            result = matched_files ? 0 : 1;
            if (mode == DIRECTORY_COUNT || mode == DIRECTORY_WITH_MATCHES) {
                for (size_t file_index = 0; file_index < files.count; ++file_index) {
                    DirectoryFile *file = &files.files[file_index];
                    if (!file->matches) continue;
                    if (!output_write(&output, file->path, strlen(file->path))
                        || (mode == DIRECTORY_COUNT
                            && (!output_byte(&output, ':')
                                || !output_decimal(&output, file->matches)))
                        || !output_byte(&output, '\n')) {
                        result = 2;
                        break;
                    }
                }
            }
        }
    }
    if (result != FAST_UNSUPPORTED && result != 2 && !output_flush(&output)) result = 2;
    output_destroy(&output);
    directory_files_destroy(&files);
    free(root);
    free(pattern);
    return result;
}

static int run_native_fast_path(int argc, wchar_t **argv) {
    if (environment_exists(L"SWIFT_RIPGREP_NO_WINDOWS_X86_PREFLIGHT")
        || environment_exists(L"RIPGREP_CONFIG_PATH") || stdout_is_console()) {
        return FAST_UNSUPPORTED;
    }
    int sorted = run_sorted_directory(argc, argv);
    if (sorted != FAST_UNSUPPORTED) return sorted;
    return run_single_file(argc, argv);
}

static wchar_t *quoted_backend_command_line(
    const wchar_t *backend,
    int argc,
    wchar_t **argv
) {
    size_t capacity = wcslen(backend) * 2 + 4;
    for (int index = 1; index < argc; ++index) capacity += wcslen(argv[index]) * 2 + 4;
    wchar_t *command = (wchar_t *)malloc(capacity * sizeof(wchar_t));
    if (!command) return NULL;
    size_t output = 0;
    for (int argument_index = 0; argument_index < argc; ++argument_index) {
        const wchar_t *argument = argument_index == 0 ? backend : argv[argument_index];
        if (argument_index) command[output++] = L' ';
        command[output++] = L'"';
        size_t backslashes = 0;
        for (const wchar_t *cursor = argument; *cursor; ++cursor) {
            if (*cursor == L'\\') {
                ++backslashes;
                continue;
            }
            if (*cursor == L'"') {
                for (size_t index = 0; index < backslashes; ++index) command[output++] = L'\\';
                command[output++] = L'\\';
                command[output++] = L'"';
                backslashes = 0;
                continue;
            }
            for (size_t index = 0; index < backslashes; ++index) command[output++] = L'\\';
            backslashes = 0;
            command[output++] = *cursor;
        }
        for (size_t index = 0; index < backslashes; ++index) {
            command[output++] = L'\\';
            command[output++] = L'\\';
        }
        command[output++] = L'"';
    }
    command[output] = 0;
    return command;
}

static int run_swift_backend(int argc, wchar_t **argv) {
    wchar_t executable[32768];
    DWORD count = GetModuleFileNameW(NULL, executable, 32768);
    if (count == 0 || count >= 32768) return 2;
    wchar_t *slash = wcsrchr(executable, L'\\');
    if (!slash) return 2;
    wcscpy(slash + 1, L"ripgrep-swift.exe");
    wchar_t *command = quoted_backend_command_line(executable, argc, argv);
    if (!command) return 2;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    memset(&startup, 0, sizeof(startup));
    memset(&process, 0, sizeof(process));
    startup.cb = sizeof(startup);
    BOOL started = CreateProcessW(
        executable,
        command,
        NULL,
        NULL,
        TRUE,
        0,
        NULL,
        NULL,
        &startup,
        &process);
    free(command);
    if (!started) {
        fwprintf(stderr, L"ripgrep: unable to start Swift backend at %ls\n", executable);
        return 2;
    }
    CloseHandle(process.hThread);
    DWORD status = 2;
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) {
        GetExitCodeProcess(process.hProcess, &status);
    }
    CloseHandle(process.hProcess);
    return (int)status;
}

int wmain(int argc, wchar_t **argv) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
    int result = run_native_fast_path(argc, argv);
    if (result != FAST_UNSUPPORTED) return result;
    int utility = argc == 2 && (wcscmp(argv[1], L"--version") == 0
        || wcscmp(argv[1], L"-V") == 0
        || wcscmp(argv[1], L"--help") == 0
        || wcscmp(argv[1], L"-h") == 0);
    if (!utility && environment_exists(L"SWIFT_RIPGREP_WINDOWS_NATIVE_ONLY")) {
        fputs("ripgrep: invocation was not handled by the Windows native preflight\n", stderr);
        return 2;
    }
    return run_swift_backend(argc, argv);
}
