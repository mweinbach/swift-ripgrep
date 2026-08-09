#ifndef SWIFT_RIPGREP_CLINUXPREFLIGHT_H
#define SWIFT_RIPGREP_CLINUXPREFLIGHT_H

#include <stddef.h>
#include <stdint.h>

/// Returns the first byte equal to `first` or `second`. `matched_second` is
/// non-zero when the returned byte equals `second` (including when both
/// needles are equal).
const uint8_t *rg_linux_find_either_byte(
    const uint8_t *bytes,
    size_t count,
    uint8_t first,
    uint8_t second,
    int *matched_second
);

/// Counts lines containing a folded ASCII literal while validating ASCII text.
/// Returns non-zero for valid non-NUL ASCII and writes the line count.
int rg_linux_count_ascii_case_lines(
    const uint8_t *bytes,
    size_t count,
    const uint8_t *folded_needle,
    size_t needle_count,
    size_t *matched_lines
);

#endif
