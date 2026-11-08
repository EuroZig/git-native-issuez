package issuez_test

import (
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestRepo_Watch(t *testing.T) {
	dir := initRepo(t)
	r := open(t, dir)
	got := make(chan issuez.WatchChange, 16)
	w, err := r.Watch(func(c issuez.WatchChange) { got <- c })
	if err != nil {
		t.Fatal(err)
	}
	defer w.Stop()
	other := open(t, dir)
	create(t, other, "Watched")
	select {
	case c := <-got:
		if c&issuez.WatchRefs == 0 {
			t.Errorf("change %v", c)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no change reported")
	}
}

func TestWatcher_Stop(t *testing.T) {
	r := newRepo(t)
	w, err := r.Watch(func(issuez.WatchChange) {})
	if err != nil {
		t.Fatal(err)
	}
	w.Stop()
	w.Stop()
}
