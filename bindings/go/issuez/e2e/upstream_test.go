//go:build e2e

package e2e_test

import (
	"os"
	"path/filepath"
	"testing"
)

// TestUpstreamInterop: issues written by upstream's git-issue pass the Go
// push check and read back through the binding.
func TestUpstreamInterop(t *testing.T) {
	upstream := os.Getenv("ISSUEZ_UPSTREAM")
	if upstream == "" {
		t.Skip("ISSUEZ_UPSTREAM not set")
	}
	abs, err := filepath.Abs(upstream)
	if err != nil {
		t.Fatal(err)
	}
	upEnv := envWith(abs)
	hub := newHub(t)
	installHook(t, hub, map[string]string{"pusher": "ada@example.com", "authors": "enforce"})
	ada := newClient(t, hub, "Ada")
	up := func(args ...string) string {
		t.Helper()
		out, err := gitTry(ada, upEnv, append([]string{"issue"}, args...)...)
		if err != nil {
			t.Fatalf("upstream git issue %v: %v\n%s", args, err, out)
		}
		return out
	}
	if out := up("version"); out == "" {
		t.Fatal("no upstream version")
	}
	before := refsUnder(t, ada, "refs/issues/")
	up("create", "Written by upstream", "-m", "Its description.", "-l", "bug")
	after := refsUnder(t, ada, "refs/issues/")
	if len(after) != len(before)+1 {
		t.Fatalf("upstream made %d issues", len(after)-len(before))
	}
	id := filepath.Base(after[len(after)-1])
	up("comment", id, "-m", "An upstream comment.")
	up("state", id, "--close")

	out, err := gitTry(ada, upEnv, "push", "origin", "refs/issues/*:refs/issues/*")
	if err != nil {
		t.Fatalf("the push check refused upstream's issue: %v\n%s", err, out)
	}

	r := openHost(t, hub)
	i, err := r.Load(bg, id)
	if err != nil {
		t.Fatal(err)
	}
	if i.Title != "Written by upstream" || i.Description != "Its description." || i.State != "closed" ||
		len(i.Labels) != 1 || i.Labels[0] != "bug" || len(i.Problems) != 0 {
		t.Errorf("read back: %+v", i)
	}
	found := false
	for _, c := range i.Comments {
		found = found || c.Text == "An upstream comment."
	}
	if !found {
		t.Errorf("comments: %+v", i.Comments)
	}
}
