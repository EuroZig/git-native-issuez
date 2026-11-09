package issuez

/*
#include <stdint.h>
*/
import "C"

import (
	"unsafe"
)

// The C logger's callback; see issuez.go. Only declarations may sit in
// this file's preamble, so the event comes as a plain pointer.
//
//export issuezGoLog
func issuezGoLog(userdata unsafe.Pointer, event unsafe.Pointer) {
	if userdata != nil {
		deliverRepoLog(uintptr(userdata), event)
		return
	}
	deliverLog(event)
}
