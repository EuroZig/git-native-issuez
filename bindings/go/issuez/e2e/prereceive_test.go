//go:build e2e

package e2e_test

import (
	"strings"
	"testing"
)

// syncFails runs `git issue sync` in a client, which the hub's hook must
// refuse with a remote error saying why.
func syncFails(t *testing.T, dir string, why string) {
	t.Helper()
	out, err := gitTry(dir, env(), "issue", "sync", "origin")
	if err == nil {
		t.Fatalf("%s: the push went through\n%s", why, out)
	}
	if !strings.Contains(out, "remote: error: ") || !strings.Contains(out, why) {
		t.Errorf("%s: no remote error saying so\n%s", why, out)
	}
}

// TestPreReceive: a hub whose pre-receive hook is a Go program calling
// PushCheck, with the quarantine git gives it. Honest syncs pass; what
// the check refuses comes back to the client as git's remote errors.
func TestPreReceive(t *testing.T) {
	hub := newHub(t)
	installHook(t, hub, map[string]string{"pusher": "ada@example.com", "authors": "enforce"})
	ada := newClient(t, hub, "Ada")
	id := create(t, ada, "Checked on the way in")
	cli(t, ada, "comment", id, "-m", "Looks fine.")
	cli(t, ada, "sync", "origin")
	ref := "refs/issues/" + id
	if got := git(t, hub, "rev-parse", ref); got != git(t, ada, "rev-parse", ref) {
		t.Fatalf("hub has %s", got)
	}

	t.Run("honest syncs", func(t *testing.T) {
		cli(t, ada, "comment", id, "-m", "A fast-forward.")
		cli(t, ada, "sync", "origin")
	})

	t.Run("forced rewind", func(t *testing.T) {
		c := newClient(t, hub, "Ada")
		cli(t, c, "sync", "origin")
		git(t, c, "update-ref", ref, ref+"~1")
		out, err := gitTry(c, env(), "push", "-f", "origin", ref+":"+ref)
		if err == nil || !strings.Contains(out, "remote: error: "+ref) {
			t.Errorf("rewind went through: %v\n%s", err, out)
		}
	})

	t.Run("spoofed author", func(t *testing.T) {
		// Bob's commits, pushed as Ada.
		bob := newClient(t, hub, "Bob")
		create(t, bob, "Not by the pusher")
		syncFails(t, bob, "isn't the pusher")
	})

	t.Run("client number", func(t *testing.T) {
		c := newClient(t, hub, "Ada")
		create(t, c, "Numbered by the client", "--number", "5")
		syncFails(t, c, "numbers are the host's to give")
	})

	t.Run("purge", func(t *testing.T) {
		c := newClient(t, hub, "Ada")
		cli(t, c, "sync", "origin")
		victim := create(t, c, "Doxxing")
		cli(t, c, "sync", "origin")
		cli(t, c, "purge", victim, "--reason", "legal", "--yes")
		syncFails(t, c, "refs/issuez-purged/"+victim+": the pusher may not purge")
		if got := refsUnder(t, hub, "refs/issues/"+victim); len(got) != 1 {
			t.Fatalf("refused purge took the issue: %v", got)
		}

		// With leave, the same sync goes through.
		git(t, hub, "config", "e2ehook.allowPurge", "true")
		cli(t, c, "sync", "origin")
		if got := refsUnder(t, hub, "refs/issues/"+victim); len(got) != 0 {
			t.Errorf("hub still has the purged issue: %v", got)
		}
		if got := refsUnder(t, hub, "refs/issuez-purged/"+victim); len(got) != 1 {
			t.Errorf("no tombstone on the hub: %v", got)
		}
	})
}
