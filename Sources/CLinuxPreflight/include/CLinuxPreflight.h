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

#endif
