// Only loaded into the standalone PDF equivalence process. Never linked into the app.
// Fix Foundation wall-clock dates, including the existing Date() calls in PDF headers.
// Monotonic scheduling, the system clock and other processes remain untouched.
#include <CoreFoundation/CoreFoundation.h>

static CFAbsoluteTime fixture_now(void) { return 790000000.0; }

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} fixture_clock_interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&fixture_now, (const void *)&CFAbsoluteTimeGetCurrent
};
