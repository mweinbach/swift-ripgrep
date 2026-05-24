#ifndef SWIFT_RIPGREP_CPCRE2_H
#define SWIFT_RIPGREP_CPCRE2_H

#ifndef PCRE2_CODE_UNIT_WIDTH
#define PCRE2_CODE_UNIT_WIDTH 8
#endif

#include <stdint.h>
#include <pcre2.h>

static inline uint32_t rg_pcre2_option_utf(void) { return PCRE2_UTF; }
static inline uint32_t rg_pcre2_option_ucp(void) { return PCRE2_UCP; }
static inline uint32_t rg_pcre2_option_caseless(void) { return PCRE2_CASELESS; }
static inline uint32_t rg_pcre2_option_dotall(void) { return PCRE2_DOTALL; }
static inline uint32_t rg_pcre2_option_multiline(void) { return PCRE2_MULTILINE; }
static inline uint32_t rg_pcre2_option_newline_crlf(void) { return PCRE2_NEWLINE_CRLF; }
static inline uint32_t rg_pcre2_option_match_invalid_utf(void) {
#ifdef PCRE2_MATCH_INVALID_UTF
    return PCRE2_MATCH_INVALID_UTF;
#else
    return 0;
#endif
}
static inline int rg_pcre2_error_nomatch(void) { return PCRE2_ERROR_NOMATCH; }
static inline uint32_t rg_pcre2_config_version_key(void) { return PCRE2_CONFIG_VERSION; }
static inline uint32_t rg_pcre2_config_jit_key(void) { return PCRE2_CONFIG_JIT; }

static inline pcre2_code *rg_pcre2_compile(
    const char *pattern,
    size_t length,
    uint32_t options,
    int *error_code,
    size_t *error_offset
) {
    return pcre2_compile((PCRE2_SPTR)pattern, (PCRE2_SIZE)length, options, error_code, (PCRE2_SIZE *)error_offset, NULL);
}

static inline void rg_pcre2_code_free(pcre2_code *code) {
    pcre2_code_free(code);
}

static inline int rg_pcre2_jit_compile(pcre2_code *code) {
    return pcre2_jit_compile(code, PCRE2_JIT_COMPLETE);
}

static inline pcre2_match_data *rg_pcre2_match_data_create_from_pattern(const pcre2_code *code) {
    return pcre2_match_data_create_from_pattern(code, NULL);
}

static inline void rg_pcre2_match_data_free(pcre2_match_data *match_data) {
    pcre2_match_data_free(match_data);
}

static inline int rg_pcre2_match(
    const pcre2_code *code,
    const char *subject,
    size_t length,
    size_t start_offset,
    uint32_t options,
    pcre2_match_data *match_data
) {
    return pcre2_match(
        code,
        (PCRE2_SPTR)subject,
        (PCRE2_SIZE)length,
        (PCRE2_SIZE)start_offset,
        options,
        match_data,
        NULL
    );
}

static inline size_t *rg_pcre2_get_ovector_pointer(pcre2_match_data *match_data) {
    return (size_t *)pcre2_get_ovector_pointer(match_data);
}

static inline uint32_t rg_pcre2_get_ovector_count(pcre2_match_data *match_data) {
    return pcre2_get_ovector_count(match_data);
}

static inline int rg_pcre2_get_error_message(int error_code, char *buffer, size_t length) {
    return pcre2_get_error_message(error_code, (PCRE2_UCHAR *)buffer, (PCRE2_SIZE)length);
}

static inline int rg_pcre2_config(uint32_t what, void *where) {
    return pcre2_config(what, where);
}

#endif
