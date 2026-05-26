#ifndef SWIFT_RIPGREP_CRIPGREPLATFORM_H
#define SWIFT_RIPGREP_CRIPGREPLATFORM_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int status;
    size_t matched_line_count;
    size_t total_match_count;
    size_t bytes_searched;
} rg_darwin_literal_file_result;

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

const uint8_t *rg_memcasemem_ascii_prepared(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *folded_needle,
    size_t needle_len,
    const size_t shifts[256]
);

const uint8_t *rg_memchr_any_bytes(
    const uint8_t *haystack,
    size_t haystack_len,
    const uint8_t *needles,
    size_t needle_count
);

size_t rg_memcount_byte(
    const uint8_t *haystack,
    size_t haystack_len,
    uint8_t byte
);

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
);

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines_no_mmap(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
);

rg_darwin_literal_file_result rg_darwin_write_literal_file_lines_ascii_case_insensitive(
    const char *path,
    const uint8_t *needle,
    size_t needle_len
);

rg_darwin_literal_file_result rg_darwin_write_surrounding_words_file_lines(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
);

rg_darwin_literal_file_result rg_darwin_write_surrounding_words_file_lines_with_line_numbers(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
);

rg_darwin_literal_file_result rg_darwin_write_fixed_conditional_pcre_o(
    const uint8_t *base,
    size_t haystack_len,
    int condition_kind,
    const uint8_t *condition,
    size_t condition_len,
    const uint8_t *true_literal,
    size_t true_literal_len,
    const uint8_t *false_literal,
    size_t false_literal_len
);

rg_darwin_literal_file_result rg_darwin_write_fixed_literal_pcre_o(
    const uint8_t *base,
    size_t haystack_len,
    const uint8_t *literal,
    size_t literal_len,
    const uint8_t *prefix,
    size_t prefix_len,
    int has_prefix,
    int prefix_should_match,
    const uint8_t *suffix,
    size_t suffix_len,
    int has_suffix,
    int suffix_should_match,
    int ascii_case_insensitive
);

rg_darwin_literal_file_result rg_darwin_write_byte_unit_pcre_o(
    const uint8_t *base,
    size_t haystack_len,
    int mode,
    size_t fixed_count,
    int unicode_start_only
);

rg_darwin_literal_file_result rg_darwin_write_word_literal_file_lines(
    const char *path,
    const uint8_t *literal,
    size_t literal_len
);

rg_darwin_literal_file_result rg_darwin_write_byte_set_file_lines(
    const char *path,
    const uint8_t *needles,
    size_t needle_count
);

rg_darwin_literal_file_result rg_darwin_write_multi_literal_file_lines(
    const char *path,
    const uint8_t *literals,
    const size_t *literal_offsets,
    const size_t *literal_lengths,
    size_t literal_count
);

#endif
