//go:build e2e

package e2e_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestCancelAndTimeouts: a remote that hangs. A context deadline ends
// Sync promptly, and so does the network timeout without one; the next
// call works.
func TestCancelAndTimeouts(t *testing.T) {
	hub := newHub(t)
	ada := newClient(t, hub, "Ada")
	create(t, ada, "Waiting")
	cli(t, ada, "sync", "origin")

	// git, but every fetch hangs.
	slow := filepath.Join(t.TempDir(), "slow-git")
	script := "#!/bin/sh\nfor a; do [ \"$a\" = fetch ] && exec sleep 30; done\nexec git \"$@\"\n"
	if err := os.WriteFile(slow, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	mirror := newHub(t)
	git(t, hub, "remote", "add", "mirror", "file://"+mirror)

	t.Run("deadline", func(t *testing.T) {
		r := openHost(t, hub, issuez.WithGit(slow))
		ctx, cancel := context.WithTimeout(bg, 300*time.Millisecond)
		defer cancel()
		start := time.Now()
		_, err := r.Sync(ctx, "mirror", issuez.SyncOptions{})
		if !issuez.IsCancelled(err) || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("sync: %v", err)
		}
		if took := time.Since(start); took > 5*time.Second {
			t.Errorf("returned after %v", took)
		}
		// The handle still works.
		if _, err := r.Snapshot(bg); err != nil {
			t.Errorf("after the cancel: %v", err)
		}
	})

	t.Run("network timeout", func(t *testing.T) {
		r := openHost(t, hub, issuez.WithGit(slow), issuez.WithLocalTimeout(10*time.Second), issuez.WithNetworkTimeout(300*time.Millisecond))
		start := time.Now()
		_, err := r.Sync(bg, "mirror", issuez.SyncOptions{})
		// The library's deadline: cancelled, but not by a context.
		var e *issuez.Error
		if !errors.As(err, &e) || e.Code != issuez.CodeTimeout || !issuez.IsCancelled(err) ||
			errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("sync: %v", err)
		}
		if took := time.Since(start); took > 5*time.Second {
			t.Errorf("returned after %v", took)
		}
	})

	t.Run("then a working sync", func(t *testing.T) {
		r := openHost(t, hub)
		if _, err := r.Sync(bg, "mirror", issuez.SyncOptions{}); err != nil {
			t.Fatal(err)
		}
	})
}
