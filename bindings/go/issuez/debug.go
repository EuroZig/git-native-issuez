//go:build issuez_debug

package issuez

/*
#include <stdint.h>
int64_t issuez__debug_live_allocations(void);
*/
import "C"

// liveAllocations is the library's count of live allocations, for the
// fuzz tests' leak check; false without the counting archive.
func liveAllocations() (int64, bool) { return int64(C.issuez__debug_live_allocations()), true }
