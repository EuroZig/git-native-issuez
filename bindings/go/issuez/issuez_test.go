package issuez_test

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestCancelRunningGit stops a git that hangs: the call returns soon
// after its context ends, not at the network timeout.
func TestCancelRunningGit(t *testing.T) {
	dir := t.TempDir()
	slow := filepath.Join(dir, "slow-git")
	script := "#!/bin/sh\nfor a; do [ \"$a\" = fetch ] && exec sleep 30; done\nexec git \"$@\"\n"
	if err := os.WriteFile(slow, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r := newRepo(t, issuez.WithGit(slow))
	hub := filepath.Join(dir, "hub.git")
	for _, args := range [][]string{{"init", "-q", "--bare", hub}, {"-C", r.GitDir(), "remote", "add", "origin", hub}} {
		if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := r.Sync(ctx, "origin", issuez.SyncOptions{})
	if !issuez.IsCancelled(err) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("sync: %v", err)
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Errorf("cancelled after %v", took)
	}
	// The handle still works.
	if _, err := r.Snapshot(context.Background()); err != nil {
		t.Errorf("after the cancel: %v", err)
	}
}

// git dying while the library writes to it must end in an error, not a
// signal that takes the Go process down.
func TestBrokenPipeIsAnError(t *testing.T) {
	bin := t.TempDir()
	wrapper := filepath.Join(bin, "git")
	script := "#!/bin/sh\ncase \"$1\" in cat-file|hash-object) exit 0;; esac\nexec git \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r := newRepo(t, issuez.WithGit(wrapper))
	for range 20 {
		_, err := r.Create(context.Background(), new(issuez.Edit).SetTitle("Doomed"), ada)
		if err == nil {
			t.Fatal("a write through a git that exits succeeded")
		}
	}
}

func TestVersion(t *testing.T) {
	v := issuez.Version()
	// A library built from a git checkout has a suffix: 1.2.3-12-ga3e21cfa.
	release, _, _ := strings.Cut(v, "-")
	parts := strings.Split(release, ".")
	if len(parts) != 3 {
		t.Fatalf("Version() = %q, want MAJOR.MINOR.PATCH[-suffix]", v)
	}
	for _, p := range parts {
		if _, err := strconv.Atoi(p); err != nil {
			t.Errorf("Version() = %q: %v", v, err)
		}
	}
}

func TestIsCancelled(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"cancelled", &issuez.Error{Code: issuez.CodeCancelled}, true},
		{"timeout", &issuez.Error{Code: issuez.CodeTimeout}, true},
		{"other", &issuez.Error{Code: issuez.CodeNotFound}, false},
		{"nil", nil, false},
		{"plain", errors.New("x"), false},
		{"wrapped", fmt.Errorf("sync: %w", &issuez.Error{Code: issuez.CodeCancelled}), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := issuez.IsCancelled(tt.err); got != tt.want {
				t.Errorf("IsCancelled(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestDate_String(t *testing.T) {
	tests := []struct {
		d    issuez.Date
		want string
	}{
		{issuez.Date{Year: 2026, Month: time.December, Day: 1}, "2026-12-01"},
		{issuez.Date{Year: 999, Month: time.January, Day: 9}, "0999-01-09"},
	}
	for _, tt := range tests {
		if got := tt.d.String(); got != tt.want {
			t.Errorf("%+v.String() = %q, want %q", tt.d, got, tt.want)
		}
	}
}

const sha1Hex = "5186cff79af42ee5c6a80d822eec95a842832b34"

func TestParseOID(t *testing.T) {
	sha256Hex := strings.Repeat("ab", 32)
	for _, ok := range []string{sha1Hex, sha256Hex} {
		o, err := issuez.ParseOID(ok)
		if err != nil || o.String() != ok {
			t.Errorf("ParseOID(%q) = %v, %v", ok, o, err)
		}
	}
	for _, zero := range []string{strings.Repeat("0", 40), strings.Repeat("0", 64)} {
		if o, err := issuez.ParseOID(zero); err != nil || !o.IsZero() {
			t.Errorf("ParseOID(%q) = %v, %v; want the zero OID", zero, o, err)
		}
	}
	for _, bad := range []string{"", "abc", sha1Hex[:39], sha1Hex + "00", strings.ToUpper(sha1Hex), "zz" + sha1Hex[2:]} {
		var e *issuez.Error
		if _, err := issuez.ParseOID(bad); !errors.As(err, &e) || e.Code != issuez.CodeInvalidArgument {
			t.Errorf("ParseOID(%q) = %v, want CodeInvalidArgument", bad, err)
		}
	}
}

func TestOID_MarshalText(t *testing.T) {
	o, _ := issuez.ParseOID(sha1Hex)
	data, err := json.Marshal(struct{ Tip, None issuez.OID }{Tip: o})
	if want := `{"Tip":"` + sha1Hex + `","None":""}`; err != nil || string(data) != want {
		t.Errorf("json.Marshal = %s, %v; want %s", data, err, want)
	}
}

func TestOID_UnmarshalText(t *testing.T) {
	var v struct{ Tip, None issuez.OID }
	if err := json.Unmarshal([]byte(`{"Tip":"`+sha1Hex+`","None":""}`), &v); err != nil || v.Tip.String() != sha1Hex || !v.None.IsZero() {
		t.Errorf("json.Unmarshal = %+v, %v", v, err)
	}
	var o issuez.OID
	if err := o.UnmarshalText([]byte("abc")); !errors.Is(err, &issuez.Error{Code: issuez.CodeInvalidArgument}) {
		t.Errorf("UnmarshalText(abc) = %v", err)
	}
}

func TestOID_Bytes(t *testing.T) {
	o, _ := issuez.ParseOID(sha1Hex)
	if got := hex.EncodeToString(o.Bytes()); got != sha1Hex || len(o.Bytes()) != 20 {
		t.Errorf("Bytes() = %x", o.Bytes())
	}
	if len((issuez.OID{}).Bytes()) != 0 {
		t.Error("the zero OID has bytes")
	}
}

func TestOID_IsZero(t *testing.T) {
	o, _ := issuez.ParseOID(sha1Hex)
	if o.IsZero() || !(issuez.OID{}).IsZero() {
		t.Errorf("IsZero: parsed %v, zero %v", o.IsZero(), (issuez.OID{}).IsZero())
	}
}

func TestOID_String(t *testing.T) {
	o, _ := issuez.ParseOID(sha1Hex)
	if o.String() != sha1Hex || (issuez.OID{}).String() != "" {
		t.Errorf("String() = %q, zero %q", o.String(), (issuez.OID{}).String())
	}
}

func TestSetDefaultLogger(t *testing.T) {
	r := newRepo(t)
	var mu sync.Mutex
	var events []issuez.LogEvent
	issuez.SetDefaultLogger(issuez.LogDebug, func(e issuez.LogEvent) {
		mu.Lock()
		defer mu.Unlock()
		events = append(events, e)
	})
	t.Cleanup(func() { issuez.SetDefaultLogger(issuez.LogOff, nil) })
	create(t, r, "Logged")
	issuez.SetDefaultLogger(issuez.LogOff, nil)
	mu.Lock()
	n := len(events)
	var git bool
	for _, e := range events {
		if strings.HasPrefix(e.Operation, "git.") && e.Duration >= 0 && e.RepoPath != "" {
			git = true
		}
		if e.Level > issuez.LogDebug {
			t.Errorf("event above the level: %+v", e)
		}
	}
	mu.Unlock()
	if !git {
		t.Errorf("no git request among %d events", n)
	}
	create(t, r, "Quiet")
	mu.Lock()
	defer mu.Unlock()
	if len(events) != n {
		t.Errorf("events after LogOff: %d more", len(events)-n)
	}
}
