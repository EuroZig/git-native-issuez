package issuez_test

import (
	"errors"
	"sync"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestNewPool(t *testing.T) {
	p := issuez.NewPool[int](2, issuez.WithEnv(testEnv()))
	defer p.Close()
	if p.Len() != 0 {
		t.Errorf("Len() = %d", p.Len())
	}
}

func TestPool_Do(t *testing.T) {
	p := issuez.NewPool[int](4, issuez.WithEnv(testEnv()))
	defer p.Close()
	dir := initRepo(t)
	var first *issuez.Repo
	if err := p.Do(1, dir, func(r *issuez.Repo) error {
		first = r
		_, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("Pooled"), ada)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	// The same handle comes back, and f's error does too.
	want := errors.New("from f")
	if err := p.Do(1, dir, func(r *issuez.Repo) error {
		if r != first {
			t.Error("a new handle for the same repository")
		}
		return want
	}); err != want {
		t.Errorf("Do() = %v", err)
	}
	// Concurrent calls share it.
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if err := p.Do(1, dir, func(r *issuez.Repo) error {
				_, err := r.Snapshot(t.Context())
				return err
			}); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if p.Len() != 1 {
		t.Errorf("Len() = %d", p.Len())
	}
	if err := p.Do(2, t.TempDir()+"/none", func(*issuez.Repo) error { return nil }); err == nil {
		t.Error("opened a repository that isn't one")
	}
}

// TestPool_Do_moved: another path for a key drops the old handle, which a
// call in flight keeps until it returns.
func TestPool_Do_moved(t *testing.T) {
	p := issuez.NewPool[int](4, issuez.WithEnv(testEnv()))
	defer p.Close()
	a, b := initRepo(t), initRepo(t)
	err := p.Do(1, a, func(old *issuez.Repo) error {
		if err := p.Do(1, b, func(r *issuez.Repo) error {
			if r == old || r.GitDir() == old.GitDir() {
				t.Error("the old handle for the new path")
			}
			return nil
		}); err != nil {
			return err
		}
		// Still open: this call holds it.
		_, err := old.Snapshot(t.Context())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if p.Len() != 1 {
		t.Errorf("Len() = %d", p.Len())
	}
}

func TestPool_maxIdle(t *testing.T) {
	p := issuez.NewPool[int](1, issuez.WithEnv(testEnv()))
	defer p.Close()
	var kept *issuez.Repo
	for k, dir := range []string{initRepo(t), initRepo(t)} {
		if err := p.Do(k, dir, func(r *issuez.Repo) error { kept = r; return nil }); err != nil {
			t.Fatal(err)
		}
	}
	if p.Len() != 1 {
		t.Errorf("Len() = %d, want 1", p.Len())
	}
	if _, err := kept.Snapshot(t.Context()); err != nil {
		t.Errorf("the newest handle was closed: %v", err)
	}
}

func TestPool_Forget(t *testing.T) {
	p := issuez.NewPool[int](4, issuez.WithEnv(testEnv()))
	defer p.Close()
	dir := initRepo(t)
	var old *issuez.Repo
	if err := p.Do(1, dir, func(r *issuez.Repo) error { old = r; return nil }); err != nil {
		t.Fatal(err)
	}
	p.Forget(1)
	p.Forget(2)
	if p.Len() != 0 {
		t.Errorf("Len() = %d", p.Len())
	}
	if _, err := old.Snapshot(t.Context()); err == nil {
		t.Error("the forgotten handle is still open")
	}
}

func TestPool_Close(t *testing.T) {
	p := issuez.NewPool[int](4, issuez.WithEnv(testEnv()))
	dir := initRepo(t)
	err := p.Do(1, dir, func(r *issuez.Repo) error {
		p.Close()
		// Busy: closes when this call returns.
		_, err := r.Snapshot(t.Context())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Do(1, dir, func(*issuez.Repo) error { return nil }); !errors.As(err, new(*issuez.Error)) {
		t.Errorf("after Close: %v", err)
	}
}

func TestPool_Len(t *testing.T) {
	p := issuez.NewPool[string](4, issuez.WithEnv(testEnv()))
	defer p.Close()
	if err := p.Do("a", initRepo(t), func(*issuez.Repo) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if p.Len() != 1 {
		t.Errorf("Len() = %d", p.Len())
	}
}
