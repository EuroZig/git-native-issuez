//go:build e2e

package e2e_test

import (
	"maps"
	"slices"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// index is the host's search index: what it learns from Snapshot and
// Diff after each push, loaded with LoadMany (a host's post-receive
// flow).
type index struct {
	r      *issuez.Repo
	last   *issuez.Snapshot
	issues map[string]*issuez.Issue
}

// refresh indexes what changed since the last refresh and returns it.
func (x *index) refresh(t *testing.T) []issuez.DiffEntry {
	t.Helper()
	now, err := x.r.Snapshot(bg)
	if err != nil {
		t.Fatal(err)
	}
	// What a host keeps between pushes: the snapshot's bytes.
	b, err := now.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	kept := new(issuez.Snapshot)
	if err := kept.UnmarshalBinary(b); err != nil {
		t.Fatal(err)
	}
	diff := issuez.Diff(x.last, kept)
	x.last = kept
	var ids []string
	for _, d := range diff {
		switch {
		case d.Kind != issuez.KindIssue:
		case d.Change == issuez.ChangeRemoved:
			delete(x.issues, d.ID)
		default:
			ids = append(ids, d.ID)
		}
	}
	if len(ids) > 0 {
		loaded, skipped, err := x.r.LoadMany(bg, ids, issuez.Strict())
		if err != nil || len(skipped) != 0 {
			t.Fatalf("LoadMany: %v, skipped %v", err, skipped)
		}
		for _, i := range loaded {
			x.issues[i.ID] = i
		}
	}
	return diff
}

// changes is diff as (kind, id, change) for comparing.
func changes(diff []issuez.DiffEntry) map[issuez.RefKey]issuez.ChangeKind {
	out := map[issuez.RefKey]issuez.ChangeKind{}
	for _, d := range diff {
		out[d.RefKey] = d.Change
	}
	return out
}

// TestHostAndClients: CLI clients push to a hub; the host indexes each
// push with Snapshot, Diff and LoadMany, and its own writes reach the
// clients on their next sync.
func TestHostAndClients(t *testing.T) {
	hub := newHub(t)
	ada := newClient(t, hub, "Ada")
	bob := newClient(t, hub, "Bob")
	x := &index{r: openHost(t, hub), issues: map[string]*issuez.Issue{}}
	if d := x.refresh(t); len(d) != 0 {
		t.Fatalf("empty hub: %+v", d)
	}

	var id string
	t.Run("a client's new issue", func(t *testing.T) {
		id = create(t, ada, "Login broken", "-m", "Since the update.", "-l", "bug")
		cli(t, ada, "comment", id, "-m", "Steps: open the page.")
		cli(t, ada, "sync", "origin")
		got := changes(x.refresh(t))
		want := map[issuez.RefKey]issuez.ChangeKind{{Kind: issuez.KindIssue, ID: id}: issuez.ChangeCreated}
		if !maps.Equal(got, want) {
			t.Fatalf("diff %v, want %v", got, want)
		}
		i := x.issues[id]
		if i.Title != "Login broken" || i.Description != "Since the update." ||
			!slices.Equal(i.Labels, []string{"bug"}) || len(i.Comments) != 1 ||
			i.Author.Email != "ada@example.com" {
			t.Errorf("indexed: %+v", i)
		}
	})

	t.Run("another client's update", func(t *testing.T) {
		cli(t, bob, "sync", "origin")
		cli(t, bob, "comment", id, "-m", "Same here.")
		cli(t, bob, "state", id, "--close", "-m", "Fixed upstream")
		cli(t, bob, "milestone", "create", "v1")
		cli(t, bob, "sync", "origin")
		got := changes(x.refresh(t))
		if got[issuez.RefKey{Kind: issuez.KindIssue, ID: id}] != issuez.ChangeUpdated || len(got) != 2 {
			t.Fatalf("diff %v", got)
		}
		if i := x.issues[id]; i.State != "closed" || len(i.Comments) < 2 {
			t.Errorf("indexed: state %q, %d comments", i.State, len(i.Comments))
		}
		ms, err := x.r.Milestones(bg)
		if err != nil || len(ms) != 1 || ms[0].Name != "v1" {
			t.Errorf("milestones: %v %+v", err, ms)
		}
	})

	t.Run("the host's write reaches the clients", func(t *testing.T) {
		w, err := x.r.Update(bg, id, new(issuez.Edit).AddComment("Reopened from the web.").SetState("open"), host)
		if err != nil {
			t.Fatal(err)
		}
		if got := changes(x.refresh(t)); got[issuez.RefKey{Kind: issuez.KindIssue, ID: id}] != issuez.ChangeUpdated {
			t.Errorf("the host's own write: %v", got)
		}
		if x.issues[id].Tip != w.NewTip {
			t.Errorf("indexed tip %v, wrote %v", x.issues[id].Tip, w.NewTip)
		}
		for _, c := range []string{ada, bob} {
			cli(t, c, "sync", "origin")
			s := show(t, c, id)
			if s.State != "open" || !slices.Contains(s.texts(), "Reopened from the web.") {
				t.Errorf("client sees %+v", s)
			}
		}
		// Nothing new after the clients' syncs: they had nothing to push.
		if d := x.refresh(t); len(d) != 0 {
			t.Errorf("after the clients' syncs: %+v", d)
		}
	})

	t.Run("a new issue from the host", func(t *testing.T) {
		w, err := x.r.Create(bg, new(issuez.Edit).SetTitle("Filed on the web"), host)
		if err != nil {
			t.Fatal(err)
		}
		cli(t, ada, "sync", "origin")
		if s := show(t, ada, w.ID); s.Title != "Filed on the web" {
			t.Errorf("client sees %+v", s)
		}
	})
}
