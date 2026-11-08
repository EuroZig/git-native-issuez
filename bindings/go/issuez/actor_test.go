package issuez_test

import (
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestActor_zero: the zero Actor writes as git's identity.
func TestActor_zero(t *testing.T) {
	r := newRepo(t)
	w, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("As git"), issuez.Actor{}, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if a := w.Issue.Author; a.Email != "t@example.com" || a.Name != "Tester" {
		t.Errorf("author %+v, want git's identity", a)
	}
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("No email"), issuez.Actor{Name: "Ada"}); err == nil {
		t.Error("a name without an email")
	}
}
