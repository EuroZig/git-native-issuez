// Package issuez binds the git-native-issuez C API (include/issuez.h).
//
// It links libissuez.a, found in lib/ for this platform (Linux builds for musl,
// or Alpine, need the build tag musl) or through CGO_LDFLAGS=-L<its directory>.
// The module github.com/EuroZig/git-native-issuez-go has lib/; in a checkout,
// `zig build go-libs` fills it; otherwise take the release's libissuez archive
// (see the README).
// The tag issuez_debug links lib/debug/libissuez.a instead, which counts its
// allocations for the fuzz tests' leak check (`zig build fuzz-go`).
//
// Everything the library returns is copied into plain Go values and the C
// handles are freed straight away, so values are safe to keep and share.
// encoding/json writes their Go field names; LoadJSON and LoadManyJSON give
// the documented schema (docs/json.md). Only *Repo holds C resources;
// close it when done.
//
// Every call that touches git takes a context: cancelling it stops the
// call (and its git child) promptly. A mutation cancelled before it commits
// did not happen. With Reload, a later read can fail after a successful
// commit: the returned Write and Error.Write then identify what committed.
package issuez

//go:generate go run ./internal/recordgen/cmd ../../../docs/issuez-api.json records_gen.go

/*
#cgo CFLAGS: -I${SRCDIR}/include
#cgo darwin,arm64,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/darwin_arm64
#cgo darwin,amd64,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/darwin_amd64
#cgo linux,amd64,!musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_amd64
#cgo linux,amd64,musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_amd64_musl
#cgo linux,arm64,!musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_arm64
#cgo linux,arm64,musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_arm64_musl
#cgo linux,arm,!musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_arm
#cgo linux,arm,musl,!issuez_debug LDFLAGS: -L${SRCDIR}/lib/linux_arm_musl
#cgo issuez_debug LDFLAGS: -L${SRCDIR}/lib/debug
#cgo LDFLAGS: -lissuez
#cgo linux LDFLAGS: -lpthread
#include <stdlib.h>
#include <stdint.h>
#include "issuez.h"

// The logger: the C callback hands each event to Go (log_export.go).
extern void issuezGoLog(void *userdata, void *event);
static void issuez_go_log(void *userdata, const issuez_log_event *event) {
    issuezGoLog(userdata, (void *)event);
}
void issuez_go_set_logger(issuez_log_level level, int on) {
    issuez_set_logger(level, on ? issuez_go_log : NULL, NULL);
}
// A repo's logger: userdata carries the cgo.Handle of its Go function.
void issuez_go_set_repo_logger(issuez_repo *repo, issuez_log_level level, uintptr_t h) {
    issuez_repo_set_logger(repo, level, h ? issuez_go_log : NULL, (void *)h);
}
*/
import "C"

import (
	"context"
	"encoding/hex"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"
)

var initOnce = sync.OnceValue(func() error {
	var cerr *C.issuez_error
	if C.issuez_init(C.ISSUEZ_ABI_VERSION, &cerr) != C.ISSUEZ_OK {
		return takeError(context.Background(), cerr)
	}
	return nil
})

// Version of the linked library: "1.2.3", or "1.2.3-12-ga3e21cfa" for one built
// from a git checkout past the tag.
func Version() string { return C.GoString(C.issuez_version()) }

// ─── Strings ───────────────────────────────────────────────────────────

// goStr copies a library string. {NULL,0} becomes "".
func goStr(s C.issuez_str) string {
	if s.ptr == nil || s.len == 0 {
		return ""
	}
	return C.GoStringN(s.ptr, C.int(s.len))
}

// cStr points at Go memory for the duration of a call. Passing it by value
// is fine (the bytes hold no pointers); storing it in Go memory handed to
// C needs a pin, see cStrs and the pinner in each call.
func cStr(s string) C.issuez_str {
	if s == "" {
		return C.issuez_str{}
	}
	return C.issuez_str{ptr: (*C.char)(unsafe.Pointer(unsafe.StringData(s))), len: C.size_t(len(s))}
}

// flagIf is flag when on, else 0: one bit of a call's flags.
func flagIf(on bool, flag C.uint32_t) C.uint32_t {
	if on {
		return flag
	}
	return 0
}

func pinStr(p *runtime.Pinner, s string) C.issuez_str {
	if s != "" {
		p.Pin(unsafe.StringData(s))
	}
	return cStr(s)
}

// cStrs builds a pinned array of strings; nil for an empty list.
func cStrs(p *runtime.Pinner, ss []string) (*C.issuez_str, C.size_t) {
	if len(ss) == 0 {
		return nil, 0
	}
	arr := make([]C.issuez_str, len(ss))
	for i, s := range ss {
		arr[i] = pinStr(p, s)
	}
	p.Pin(&arr[0])
	return &arr[0], C.size_t(len(ss))
}

func goStrs(n C.size_t, at func(C.size_t) C.issuez_str) []string {
	if n == 0 {
		return nil
	}
	out := make([]string, n)
	for i := range out {
		out[i] = goStr(at(C.size_t(i)))
	}
	return out
}

// ─── Value types ───────────────────────────────────────────────────────

// OID is a git object ID (SHA-1 or SHA-256). The zero value means none.
// Comparable: usable as a map key. Its text form, in encoding/json too,
// is String's; the zero OID's is "".
type OID struct {
	n uint8
	b [32]byte
}

// IsZero reports the zero OID, no object.
func (o OID) IsZero() bool { return o.n == 0 }

// Bytes is the raw ID, 20 or 32 bytes (none for the zero OID): a copy.
func (o OID) Bytes() []byte { return o.b[:o.n] }

// String is the lowercase hex form, "" for the zero OID.
func (o OID) String() string { return hex.EncodeToString(o.b[:o.n]) }

// MarshalText is String's form.
func (o OID) MarshalText() ([]byte, error) { return []byte(o.String()), nil }

// UnmarshalText takes ParseOID's forms, and "" for the zero OID.
func (o *OID) UnmarshalText(text []byte) error {
	if len(text) == 0 {
		*o = OID{}
		return nil
	}
	v, err := ParseOID(string(text))
	if err != nil {
		return err
	}
	*o = v
	return nil
}

// ParseOID takes the full hex form (40 or 64 digits). All zeros, git's
// "no object" in hook input and reflogs, is the zero OID. Anything else
// is an *Error with CodeInvalidArgument.
func ParseOID(s string) (OID, error) {
	b, err := hex.DecodeString(s)
	// Lowercase only, as git writes them and the library compares them.
	if err != nil || (len(b) != 20 && len(b) != 32) || s != strings.ToLower(s) {
		return OID{}, &Error{Code: CodeInvalidArgument, Message: fmt.Sprintf("not a full object ID: %q", s)}
	}
	if strings.Trim(s, "0") == "" {
		return OID{}, nil
	}
	var o OID
	o.n = uint8(len(b))
	copy(o.b[:], b)
	return o, nil
}

func goOID(c C.issuez_oid) OID {
	var o OID
	o.n = uint8(c.len)
	for i := 0; i < int(c.len); i++ {
		o.b[i] = byte(c.bytes[i])
	}
	return o
}

func cOID(o OID) C.issuez_oid {
	var c C.issuez_oid
	c.len = C.uint8_t(o.n)
	for i := 0; i < int(o.n); i++ {
		c.bytes[i] = C.uint8_t(o.b[i])
	}
	return c
}

func goTime(t C.issuez_time) time.Time {
	off := int(t.tz_offset_minutes) * 60
	return time.Unix(int64(t.unix_seconds), 0).In(time.FixedZone("", off))
}

func cTime(t time.Time) C.issuez_time {
	_, off := t.Zone()
	return C.issuez_time{unix_seconds: C.int64_t(t.Unix()), tz_offset_minutes: C.int16_t(off / 60)}
}

// Date is a calendar day, as start and due dates are stored.
type Date struct {
	Year  int
	Month time.Month
	Day   int
}

// String is the ISO 8601 form, "2026-03-01".
func (d Date) String() string { return fmt.Sprintf("%04d-%02d-%02d", d.Year, d.Month, d.Day) }

func goDate(d C.issuez_date) Date {
	return Date{Year: int(d.year), Month: time.Month(d.month), Day: int(d.day)}
}

func cDate(d Date) C.issuez_date {
	return C.issuez_date{year: C.int16_t(d.Year), month: C.uint8_t(d.Month), day: C.uint8_t(d.Day)}
}

// Person as stored in git. UserID is the host's stable identity, a UUID
// (the format's `<uuid> <email>` assignee form), if the value carried
// one. Assignees have no Name.
type Person struct {
	Name   string
	Email  string
	UserID string
}

func goPerson(p *C.issuez_person) Person {
	if p == nil {
		return Person{}
	}
	return Person{Name: goStr(p.name), Email: goStr(p.email), UserID: goStr(p.user_id)}
}

// Actor is who performs a write: the commit's author. The committer is
// the identity the repo was opened with. UserID, if set, is a UUID: the
// host's identity of the author, written on every commit as X-Author-Id
// and read back as the author's Person.UserID. The zero Actor (no Name,
// Email or UserID) is git's identity, now: what a script or tool writing
// as its user passes.
type Actor struct {
	Name   string
	Email  string
	UserID string
	// Zero: now.
	At time.Time
}

func pinActor(pin *runtime.Pinner, a Actor) *C.issuez_actor {
	if a.Name == "" && a.Email == "" && a.UserID == "" {
		return nil // git's identity
	}
	c := &C.issuez_actor{name: pinStr(pin, a.Name), email: pinStr(pin, a.Email), user_id: pinStr(pin, a.UserID)}
	if !a.At.IsZero() {
		t := cTime(a.At)
		pin.Pin(&t)
		c.at = &t
	}
	pin.Pin(c)
	return c
}

// ─── Cancellation ──────────────────────────────────────────────────────

// call runs f with a cancel token tied to ctx. The token is freed only
// after a running trigger has finished, so it never outlives its use.
func call(ctx context.Context, f func(*C.issuez_cancel) C.issuez_code) C.issuez_code {
	if ctx.Done() == nil {
		return f(nil)
	}
	tok := C.issuez_cancel_new()
	defer C.issuez_cancel_free(tok)
	triggered := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		C.issuez_cancel_trigger(tok)
		close(triggered)
	})
	defer func() {
		if !stop() {
			<-triggered
		}
	}()
	if ctx.Err() != nil {
		C.issuez_cancel_trigger(tok)
	}
	return f(tok)
}
