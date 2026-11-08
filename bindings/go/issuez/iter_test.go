package issuez_test

import (
	"context"
	"errors"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestRepo_All(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	want := map[string]bool{}
	for _, title := range []string{"One", "Two", "Three", "Four", "Five"} {
		w, err := r.Create(ctx, new(issuez.Edit).SetTitle(title), ada)
		if err != nil {
			t.Fatal(err)
		}
		want[w.ID] = true
	}
	// Two per page: three pages.
	got := map[string]bool{}
	for issue, err := range r.All(ctx, issuez.Query{Limit: 2}) {
		if err != nil {
			t.Fatal(err)
		}
		if got[issue.ID] {
			t.Fatalf("%s twice", issue.ID)
		}
		got[issue.ID] = true
	}
	if len(got) != len(want) {
		t.Fatalf("got %d issues, want %d", len(got), len(want))
	}
	// Stopping early stops it.
	n := 0
	for range r.All(ctx, issuez.Query{Limit: 2}) {
		n++
		if n == 3 {
			break
		}
	}
	if n != 3 {
		t.Fatalf("stopped after %d", n)
	}
	// An error is yielded once.
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	errs := 0
	for issue, err := range r.All(cancelled, issuez.Query{}) {
		if issue != nil || !errors.Is(err, context.Canceled) {
			t.Fatalf("got %v, %v", issue, err)
		}
		errs++
	}
	if errs != 1 {
		t.Fatalf("%d errors", errs)
	}
}
