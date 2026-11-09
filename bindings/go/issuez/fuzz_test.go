package issuez

// Fuzz tests. White-box: FuzzEditValidate feeds
// raw ops no builder makes, and the leak check reads the library's count
// of live allocations, built with -tags issuez_debug (`zig build
// fuzz-go`). The seeds run as normal tests.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// noLeak runs f and fails when the library holds more memory after it.
func noLeak(t *testing.T, f func()) {
	t.Helper()
	if err := initOnce(); err != nil {
		t.Fatal(err)
	}
	before, counted := liveAllocations()
	f()
	if !counted {
		return
	}
	if after, _ := liveAllocations(); after != before {
		t.Errorf("%d allocations leaked", after-before)
	}
}

// wantError fails unless err is nil or the library's *Error.
func wantError(t *testing.T, err error) {
	t.Helper()
	var e *Error
	if err != nil && !errors.As(err, &e) {
		t.Errorf("not an *Error: %T %v", err, err)
	}
}

func FuzzParseOID(f *testing.F) {
	for _, s := range []string{
		"5186cff79af42ee5c6a80d822eec95a842832b34",
		strings.Repeat("ab", 32),
		strings.Repeat("0", 40),
		"5186CFF79AF42EE5C6A80D822EEC95A842832B34",
		"5186cff",
		"",
		"zz86cff79af42ee5c6a80d822eec95a842832b34",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		o, err := ParseOID(s)
		valid := (len(s) == 40 || len(s) == 64) && strings.Trim(s, "0123456789abcdef") == ""
		if (err == nil) != valid {
			t.Fatalf("ParseOID(%q): %v, valid %v", s, err, valid)
		}
		if err != nil {
			if !o.IsZero() {
				t.Errorf("ParseOID(%q) failed with %v", s, o)
			}
			return
		}
		if strings.Trim(s, "0") == "" {
			if !o.IsZero() {
				t.Errorf("ParseOID(%q) = %v, want the zero OID", s, o)
			}
			return
		}
		if o.IsZero() || o.String() != s || len(o.Bytes()) != len(s)/2 {
			t.Errorf("ParseOID(%q) = %v, %d bytes", s, o, len(o.Bytes()))
		}
	})
}

// seedSnapshot is a real snapshot's encoding: a repo with one issue and
// one milestone.
func seedSnapshot(f *testing.F) []byte {
	f.Helper()
	dir := filepath.Join(f.TempDir(), "repo")
	env := append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null")
	cmd := exec.Command("git", "init", "-q", dir)
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil {
		f.Fatalf("git init: %v\n%s", err, out)
	}
	r, err := Open(dir, WithEnv(env))
	if err != nil {
		f.Fatal(err)
	}
	defer r.Close()
	ctx := context.Background()
	who := Actor{Name: "Ada", Email: "ada@example.com"}
	if _, err := r.Create(ctx, new(Edit).SetTitle("Seed"), who); err != nil {
		f.Fatal(err)
	}
	if _, err := r.CreateMilestone(ctx, new(MilestoneEdit).SetName("v1"), who); err != nil {
		f.Fatal(err)
	}
	s, err := r.Snapshot(ctx)
	if err != nil {
		f.Fatal(err)
	}
	b, _ := s.MarshalBinary()
	return b
}

func FuzzSnapshotUnmarshal(f *testing.F) {
	seed := seedSnapshot(f)
	f.Add(seed)
	f.Add(seed[:len(seed)/2])
	f.Add([]byte{})
	f.Add([]byte("garbage"))
	f.Fuzz(func(t *testing.T, b []byte) {
		var s Snapshot
		var err error
		noLeak(t, func() { err = s.UnmarshalBinary(b) })
		wantError(t, err)
		if err != nil {
			return
		}
		// What it decoded encodes to the same snapshot again.
		out, _ := s.MarshalBinary()
		var again Snapshot
		if err := again.UnmarshalBinary(out); err != nil {
			t.Fatalf("re-decoding: %v", err)
		}
		if !reflect.DeepEqual(s.Tips, again.Tips) {
			t.Errorf("round trip: %v, then %v", s.Tips, again.Tips)
		}
	})
}

// opsFrom reads ops out of fuzz bytes: per op a verb, a target (a field,
// or an option past 1024), which slots to fill, and a string. Verbs and
// targets go past the known ones, and slots the target doesn't use get
// values too.
func opsFrom(b []byte) []op {
	var ops []op
	for len(b) >= 4 && len(ops) < 64 {
		o := op{verb: Verb(b[0] % 8), target: uint32(b[1] % 40)}
		if b[2]&0x80 != 0 {
			o.target = 1024 + uint32(b[1])
		}
		slots, n := b[2], int(b[3])%64
		b = b[4:]
		n = min(n, len(b))
		s := string(b[:n])
		b = b[n:]
		if slots&0x01 != 0 {
			o.str = s
		}
		if slots&0x02 != 0 {
			o.num = int64(len(s)) - 8
		}
		if slots&0x04 != 0 {
			o.name = s
		}
		if slots&0x08 != 0 {
			o.date = Date{Year: 1900 + len(s)*7, Month: time.Month(n % 14), Day: n % 33}
		}
		if slots&0x10 != 0 {
			o.person = Person{Name: s, Email: s + "@example.com"}
		}
		if slots&0x20 != 0 && len(s) >= 20 {
			o.oid.n = 20
			copy(o.oid.b[:], s)
		}
		if slots&0x40 != 0 {
			o.num2 = -int64(n)
		}
		ops = append(ops, o)
	}
	return ops
}

func FuzzEditValidate(f *testing.F) {
	// Builder-made edits, encoded the way opsFrom reads them back, and
	// some that no builder makes.
	f.Add(true, []byte("\x01\x01\x01\x05Title"))
	f.Add(false, []byte("\x01\x02\x01\x00\x03\x05\x01\x03bug"))
	f.Add(true, []byte("\x07\x27\xff\x02xx\x01\x01\x7f\x00"))
	f.Add(false, []byte("\x01\x01\x09\x0aline\nbreak"))
	f.Fuzz(func(t *testing.T, create bool, b []byte) {
		e := &Edit{ops: opsFrom(b)}
		var problems []Problem
		var err error
		validate := e.ValidateUpdate
		if create {
			validate = e.ValidateCreate
		}
		noLeak(t, func() { problems, err = validate() })
		wantError(t, err)
		for _, p := range problems {
			if p.Op < -1 || p.Op >= e.Len() {
				t.Errorf("problem at op %d of %d: %+v", p.Op, e.Len(), p)
			}
		}
		again, err2 := validate()
		if !reflect.DeepEqual(problems, again) || (err == nil) != (err2 == nil) {
			t.Errorf("not deterministic: %+v %v, then %+v %v", problems, err, again, err2)
		}
	})
}
