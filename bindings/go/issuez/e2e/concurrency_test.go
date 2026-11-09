//go:build e2e

package e2e_test

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestConcurrency: the host writes to one issue from many goroutines
// while clients comment on it and push. Every write lands exactly once.
func TestConcurrency(t *testing.T) {
	const writers, rounds = 16, 3
	hub := newHub(t)
	ada := newClient(t, hub, "Ada")
	id := create(t, ada, "Busy")
	cli(t, ada, "sync", "origin")
	bob := newClient(t, hub, "Bob")
	cli(t, bob, "sync", "origin")
	r := openHost(t, hub, issuez.WithPoolSize(4))

	var wg sync.WaitGroup
	errs := make(chan error, writers+2)
	retries := make(chan int, writers)
	for k := range writers {
		wg.Go(func() {
			// A write that keeps losing its race gives up, writes nothing
			// and says so; the host tries again.
			for try := 0; ; try++ {
				w, err := r.Update(bg, id, new(issuez.Edit).AddComment(fmt.Sprintf("host %d", k)), host)
				var e *issuez.Error
				if errors.As(err, &e) && e.Code == issuez.CodeContended && try < 20 {
					continue
				}
				if err != nil {
					errs <- fmt.Errorf("host write %d: %w", k, err)
					return
				}
				retries <- w.Retries
				return
			}
		})
	}
	// A sync can lose every round to the host's writes and say so; it
	// changes nothing then, and the client tries again.
	syncRetrying := func(dir string) error {
		for try := 0; ; try++ {
			out, err := gitTry(dir, env(), "issue", "sync", "origin")
			if err == nil {
				return nil
			}
			if try == 20 || !strings.Contains(out, "kept changing while pushing") {
				return fmt.Errorf("sync: %v\n%s", err, out)
			}
		}
	}
	for _, c := range []string{ada, bob} {
		wg.Go(func() {
			for k := range rounds {
				text := fmt.Sprintf("%s %d", filepath.Base(c), k)
				if out, err := gitTry(c, env(), "issue", "comment", id, "-m", text); err != nil {
					errs <- fmt.Errorf("comment: %v\n%s", err, out)
					return
				}
				if err := syncRetrying(c); err != nil {
					errs <- err
					return
				}
			}
		})
	}
	wg.Wait()
	close(errs)
	close(retries)
	for err := range errs {
		t.Error(err)
	}
	total := 0
	for n := range retries {
		total += n
	}
	// Writes to one issue from 16 goroutines contend: some must retry.
	if total == 0 {
		t.Error("no host write reported a retry")
	}
	t.Logf("host writes retried %d times in all", total)

	for _, c := range []string{ada, bob} {
		if err := syncRetrying(c); err != nil {
			t.Fatal(err)
		}
	}
	want := map[string]int{}
	for k := range writers {
		want[fmt.Sprintf("host %d", k)] = 1
	}
	for _, c := range []string{ada, bob} {
		for k := range rounds {
			want[fmt.Sprintf("%s %d", filepath.Base(c), k)] = 1
		}
	}
	check := func(where string, texts []string) {
		t.Helper()
		got := map[string]int{}
		for _, s := range texts {
			got[s]++
		}
		for text, n := range want {
			if got[text] != n {
				t.Errorf("%s: %q %d times", where, text, got[text])
			}
		}
	}
	i, err := r.Load(bg, id)
	if err != nil {
		t.Fatal(err)
	}
	var texts []string
	for _, c := range i.Comments {
		texts = append(texts, c.Text)
	}
	check("host", texts)
	for _, c := range []string{ada, bob} {
		check(filepath.Base(c), show(t, c, id).texts())
	}
}
