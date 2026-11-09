//go:build !cgo

package issuez

// The binding links the C library: build with CGO_ENABLED=1 and a C
// toolchain. This names the problem when cgo is off.
var _ = issuezNeedsCGOEnabled1
