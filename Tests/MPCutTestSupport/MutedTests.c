#include <stdlib.h>
#include "MPCutTestSupport.h"

// MPCutAppTests runs MPCut muted, as an app launched with MPCUT_MUTED=1 does. The variable is set
// as the test bundle loads, before any test or player exists, whichever tests are selected.
// An explicit MPCUT_MUTED=0 in the environment keeps the tests audible.
__attribute__((constructor)) static void mpcut_tests_run_muted(void) {
    setenv("MPCUT_MUTED", "1", 0);
}
