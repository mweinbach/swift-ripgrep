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

/// Returns non-zero when every byte is non-NUL ASCII.
int rg_linux_bytes_are_ascii_text(const uint8_t *bytes, size_t count);

/// Returns the first ASCII byte equal to `folded` ignoring ASCII case.
const uint8_t *rg_linux_find_ascii_case_byte(
    const uint8_t *bytes,
    size_t count,
    uint8_t folded
);

#endif
