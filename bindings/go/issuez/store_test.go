package issuez_test

import (
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// covers: Repo_NewStore, Store_Issues, Store_Find, Store_Generation
func TestStore_Refresh(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	one := create(t, r, "One")
	// More issues than a small map holds (8): up to that Go iterates one in
	// insertion order from a random start, which often passes as sorted.
	const issues = 12
	for i := 1; i < issues; i++ {
		create(t, r, "Other "+strconv.Itoa(i))
	}
	s, err := r.NewStore()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if len(s.Issues()) != 0 || s.Generation() != 0 {
		t.Error("not empty before the first refresh")
	}
	if changed, err := s.Refresh(ctx); err != nil || len(changed) != issues || len(s.Issues()) != issues || s.Generation() != 1 {
		t.Fatalf("first: %v %v, generation %d", changed, err, s.Generation())
	}
	if !slices.IsSortedFunc(s.Issues(), func(a, b *issuez.Issue) int { return strings.Compare(a.ID, b.ID) }) {
		t.Error("Issues() not in UUID order")
	}
	if s.Find("nope") != nil {
		t.Error("Find of no such issue")
	}
	if changed, err := s.Refresh(ctx); err != nil || changed != nil {
		t.Errorf("nothing moved: %v %v", changed, err)
	}
	kept := s.Find(one.ID)
	if _, err := r.Update(ctx, one.ID, new(issuez.Edit).SetTitle("One, renamed"), ada); err != nil {
		t.Fatal(err)
	}
	changed, err := s.Refresh(ctx)
	if err != nil || len(changed) != 1 || changed[0] != one.ID || s.Find(one.ID).Title != "One, renamed" || kept.Title != "One" {
		t.Errorf("after an edit: %v %v", changed, err)
	}
	if s.Generation() != 2 {
		t.Errorf("Generation() = %d", s.Generation())
	}
}

func TestStore_Close(t *testing.T) {
	r := newRepo(t)
	s, _ := r.NewStore()
	s.Close()
	s.Close()
	if _, err := s.Refresh(t.Context()); err == nil {
		t.Error("refresh after Close")
	}
}
