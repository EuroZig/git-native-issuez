package issuez_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestCode_String(t *testing.T) {
	seen := map[string]bool{}
	for c := issuez.CodeABI; c <= issuez.CodeInternal; c++ {
		s := c.String()
		if s == "" || s == "UNKNOWN" || seen[s] {
			t.Errorf("Code(%d).String() = %q", int(c), s)
		}
		seen[s] = true
	}
	if got := issuez.CodeVersionMismatch.String(); got != "VERSION_MISMATCH" {
		t.Errorf("CodeVersionMismatch.String() = %q", got)
	}
	if got := issuez.Code(999).String(); got != "UNKNOWN" {
		t.Errorf("Code(999).String() = %q", got)
	}
}

func TestError_Error(t *testing.T) {
	tests := []struct {
		err  *issuez.Error
		want string
	}{
		{&issuez.Error{Code: issuez.CodeNotFound, Message: "no such issue", Subject: "abc"}, "issuez: abc: no such issue"},
		{&issuez.Error{Code: issuez.CodeInternal, Message: "oops"}, "issuez: oops"},
	}
	for _, tt := range tests {
		if got := tt.err.Error(); got != tt.want {
			t.Errorf("Error() = %q, want %q", got, tt.want)
		}
	}
}

func TestError_Is(t *testing.T) {
	r := newRepo(t)
	_, err := r.Load(t.Context(), "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")
	if !errors.Is(err, issuez.ErrNotFound) || errors.Is(err, issuez.ErrGuard) {
		t.Errorf("errors.Is on %v", err)
	}
	sentinels := []*issuez.Error{issuez.ErrNotFound, issuez.ErrAmbiguous, issuez.ErrInvalidValue,
		issuez.ErrVersionMismatch, issuez.ErrGuard, issuez.ErrPurged, issuez.ErrRejected}
	for _, s := range sentinels {
		e := &issuez.Error{Code: s.Code, Message: "x"}
		if !errors.Is(fmt.Errorf("wrapped: %w", e), s) {
			t.Errorf("errors.Is(%v, %v) is false", e, s.Code)
		}
	}
	if (&issuez.Error{Code: issuez.CodeGuard}).Is(errors.New("guard")) {
		t.Error("an Error matched a non-Error")
	}
}

func TestError_Unwrap(t *testing.T) {
	r := newRepo(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err := r.Create(ctx, new(issuez.Edit).SetTitle("Never"), ada)
	if !errors.Is(err, context.Canceled) || !issuez.IsCancelled(err) {
		t.Errorf("cancelled create: %v", err)
	}
	if (&issuez.Error{Code: issuez.CodeNotFound}).Unwrap() != nil {
		t.Error("an error without a cause unwraps to something")
	}
}

func TestField_String(t *testing.T) {
	tests := map[issuez.Field]string{
		issuez.FieldTitle:   "Title",
		issuez.FieldLabels:  "Labels",
		issuez.FieldDueDate: "X-Due-Date",
		issuez.Field(9999):  "",
	}
	for f, want := range tests {
		if got := f.String(); got != want {
			t.Errorf("Field(%d).String() = %q, want %q", f, got, want)
		}
	}
}

// TestEnumsHaveGoConstants: every value of the C API's enums
// (docs/issuez-api.json) has a Go constant, except the enums the binding
// keeps internal.
func TestEnumsHaveGoConstants(t *testing.T) {
	internal := map[string]bool{
		"issuez_op_list": true, // Edit.Validate picks the list
		"issuez_state":   true, // Issue.State is the state's name
		// The binding doesn't wrap issuez_quarantine_resolve.
		"issuez_quarantine_choice": true,
	}
	exempt := map[string]bool{
		"ISSUEZ_OPT_PUSHER": true, // PushPolicy.PusherEmails covers it
	}
	data, err := os.ReadFile(apiJSON)
	if err != nil {
		t.Skip("docs/issuez-api.json isn't here:", err)
	}
	var api struct {
		Types []struct {
			Name   string `json:"name"`
			Kind   string `json:"kind"`
			Values []struct {
				Name string `json:"name"`
			} `json:"values"`
		} `json:"types"`
	}
	if err := json.Unmarshal(data, &api); err != nil {
		t.Fatal(err)
	}
	sources, _ := filepath.Glob("*.go")
	used := map[string]bool{}
	ref := regexp.MustCompile(`C\.(ISSUEZ_[A-Z0-9_]+)`)
	for _, f := range sources {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range ref.FindAllSubmatch(b, -1) {
			used[string(m[1])] = true
		}
	}
	for _, ty := range api.Types {
		if ty.Kind != "enum" || internal[ty.Name] {
			continue
		}
		for _, v := range ty.Values {
			// A flags enum's zero is no flag: the binding passes 0.
			none := strings.HasSuffix(v.Name, "_FLAG_NONE")
			if strings.HasSuffix(v.Name, "_UNKNOWN") || none || exempt[v.Name] || used[v.Name] {
				continue
			}
			t.Errorf("%s (%s) has no Go constant", v.Name, ty.Name)
		}
	}
}

func TestUserMessage(t *testing.T) {
	r := newRepo(t)
	_, err := r.Create(t.Context(), new(issuez.Edit).SetTitle(""), ada)
	if msg, ok := issuez.UserMessage(fmt.Errorf("wrapped: %w", err)); !ok || msg == "" {
		t.Errorf("UserMessage(%v) = %q, %v", err, msg, ok)
	}
	_, err = r.Load(t.Context(), "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c")
	if msg, ok := issuez.UserMessage(err); ok {
		t.Errorf("UserMessage(not found) = %q", msg)
	}
	if _, ok := issuez.UserMessage(errors.New("other")); ok {
		t.Error("UserMessage of a plain error")
	}
}
