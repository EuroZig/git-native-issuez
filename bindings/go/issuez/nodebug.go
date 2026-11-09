//go:build !issuez_debug

package issuez

// liveAllocations: the release archives don't count (see debug.go).
func liveAllocations() (int64, bool) { return 0, false }
