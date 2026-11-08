package issuez_test

import (
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestRepo_NewStore(t *testing.T) {
	r := newRepo(t)
	s, err := r.NewStore()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if len(s.Issues()) != 0 || s.Generation() != 0 {
		t.Error("not empty before the first refresh")
	}
}

func TestStore_Refresh(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	one := create(t, r, "One")
	create(t, r, "Two")
	s, _ := r.NewStore()
	defer s.Close()
	if changed, err := s.Refresh(ctx); err != nil || len(changed) != 2 || len(s.Issues()) != 2 {
		t.Fatalf("first: %v %v", changed, err)
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

func TestStore_Issues(t *testing.T) {
	r := newRepo(t)
	a, b := create(t, r, "A"), create(t, r, "B")
	s, _ := r.NewStore()
	defer s.Close()
	s.Refresh(t.Context())
	got := s.Issues()
	if len(got) != 2 || got[0].ID > got[1].ID || (got[0].ID != a.ID && got[0].ID != b.ID) {
		t.Errorf("Issues() = %v", got)
	}
}

func TestStore_Find(t *testing.T) {
	r := newRepo(t)
	w := create(t, r, "Found")
	s, _ := r.NewStore()
	defer s.Close()
	s.Refresh(t.Context())
	if s.Find(w.ID) == nil || s.Find("nope") != nil {
		t.Error("Find")
	}
}

func TestStore_Generation(t *testing.T) {
	r := newRepo(t)
	s, _ := r.NewStore()
	defer s.Close()
	create(t, r, "X")
	s.Refresh(t.Context())
	if s.Generation() != 1 {
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
