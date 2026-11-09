//go:build e2e

package e2e_test

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestNumbersAfterReceive: the hook reports new issues as needing a
// number; once the push is in, the host gives them numbers, and clients
// see and resolve #N after their next sync.
func TestNumbersAfterReceive(t *testing.T) {
	hub := newHub(t)
	installHook(t, hub, nil)
	ada := newClient(t, hub, "Ada")
	first := create(t, ada, "First")
	second := create(t, ada, "Second")
	cli(t, ada, "sync", "origin")

	// The post-receive side: number what the check reported, in order.
	data, err := os.ReadFile(filepath.Join(hub, "needs-number"))
	if err != nil {
		t.Fatal(err)
	}
	pending := strings.Fields(string(data))
	if len(pending) != 2 {
		t.Fatalf("needs a number: %v", pending)
	}
	r := openHost(t, hub)
	numbers := map[string]uint64{}
	for k, id := range pending {
		n := uint64(k + 1)
		if _, err := r.Update(bg, id, new(issuez.Edit).SetNumber(n), host); err != nil {
			t.Fatal(err)
		}
		numbers[id] = n
	}
	for _, id := range []string{first, second} {
		got, err := r.ResolveOne(bg, issuez.KindIssue, "#"+strconv.FormatUint(numbers[id], 10))
		if err != nil || got != id {
			t.Errorf("host resolves #%d to %q: %v", numbers[id], got, err)
		}
	}

	bob := newClient(t, hub, "Bob")
	for _, c := range []string{ada, bob} {
		cli(t, c, "sync", "origin")
		for _, id := range []string{first, second} {
			s := show(t, c, "#"+strconv.FormatUint(numbers[id], 10))
			if s.ID != id || s.Number == nil || *s.Number != numbers[id] {
				t.Errorf("#%d in %s: %+v", numbers[id], filepath.Base(c), s)
			}
		}
	}

	// A later push: only the new issue needs one.
	third := create(t, bob, "Third")
	cli(t, bob, "comment", first, "-m", "Numbered already.")
	cli(t, bob, "sync", "origin")
	data, err = os.ReadFile(filepath.Join(hub, "needs-number"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Fields(string(data)); len(got) != 3 || got[2] != third {
		t.Errorf("needs a number after the second push: %v", got)
	}
}
