//go:build e2e

package e2e_test

import (
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestPurge: the host purges a comment and an issue on the hub. A mirror
// the hub synced to is reported exposed, and the next Sync replaces its
// copy; clients drop the text on their next sync.
func TestPurge(t *testing.T) {
	hub := newHub(t)
	ada := newClient(t, hub, "Ada")
	talk := create(t, ada, "Talk")
	cli(t, ada, "comment", talk, "-m", "Abuse")
	cli(t, ada, "comment", talk, "-m", "Fine")
	doxx := create(t, ada, "Doxxing")
	cli(t, ada, "sync", "origin")
	bob := newClient(t, hub, "Bob")
	cli(t, bob, "sync", "origin")

	mirror := newHub(t)
	git(t, hub, "remote", "add", "mirror", "file://"+mirror)
	r := openHost(t, hub)
	if _, err := r.Sync(bg, "mirror", issuez.SyncOptions{}); err != nil {
		t.Fatal(err)
	}

	i, err := r.Load(bg, talk)
	if err != nil {
		t.Fatal(err)
	}
	var abuse issuez.OID
	for _, c := range i.Comments {
		if c.Text == "Abuse" {
			abuse = c.ID
		}
	}
	res, err := r.PurgeComment(bg, talk, abuse, host, "abuse")
	if err != nil || !reflect.DeepEqual(res.ExposedRemotes, []string{"mirror"}) {
		t.Fatalf("comment purge: %v %+v", err, res)
	}
	res, err = r.PurgeIssue(bg, doxx, host, "legal")
	if err != nil || !reflect.DeepEqual(res.ExposedRemotes, []string{"mirror"}) {
		t.Fatalf("issue purge: %v %+v", err, res)
	}

	if _, err := r.Sync(bg, "mirror", issuez.SyncOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := refsUnder(t, mirror, "refs/issues/"+doxx); len(got) != 0 {
		t.Errorf("mirror still has the purged issue")
	}
	ref := "refs/issues/" + talk
	if git(t, mirror, "rev-parse", ref) != git(t, hub, "rev-parse", ref) {
		t.Errorf("mirror's copy of the talk wasn't replaced")
	}

	for _, c := range []string{ada, bob} {
		cli(t, c, "sync", "origin")
		s := show(t, c, talk)
		if slices.Contains(s.texts(), "Abuse") || !slices.Contains(s.texts(), "Fine") {
			t.Errorf("comments after the purge: %q", s.texts())
		}
		if log := git(t, c, "log", "--format=%B", ref); strings.Contains(log, "Abuse") {
			t.Errorf("history still has the text:\n%s", log)
		}
		if out, err := gitTry(c, env(), "issue", "show", doxx); err == nil {
			t.Errorf("purged issue still shows:\n%s", out)
		}
	}
}
