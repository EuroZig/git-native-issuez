package issuez

/*
#include <stdint.h>
#include "issuez.h"
extern void issuezGoWatch(uintptr_t h, uint32_t changes);
static void issuez_go_watch(void *userdata, uint32_t changes) {
    issuezGoWatch((uintptr_t)userdata, changes);
}
static int issuez_go_watch_start(issuez_repo *repo, uintptr_t h, issuez_watch **out, issuez_error **err) {
    return issuez_watch_start(repo, issuez_go_watch, (void *)h, out, err);
}
*/
import "C"

import (
	"context"
	"runtime/cgo"
	"strconv"
	"strings"
	"sync"
)

// WatchChange says what may have changed on disk.
type WatchChange uint32

const (
	WatchNone WatchChange = C.ISSUEZ_WATCH_NONE
	// Issue, milestone or attachment refs moved: read them again
	// (Snapshot and Diff say what).
	WatchRefs WatchChange = C.ISSUEZ_WATCH_REFS
	// The repository's config, which has the issue settings.
	WatchConfig WatchChange = C.ISSUEZ_WATCH_CONFIG
)

// String is the changes' names joined by "|", "none" for none.
func (c WatchChange) String() string {
	var parts []string
	if c&WatchRefs != 0 {
		parts = append(parts, "refs")
	}
	if c&WatchConfig != 0 {
		parts = append(parts, "config")
	}
	if rest := c &^ (WatchRefs | WatchConfig); rest != 0 {
		parts = append(parts, "0x"+strconv.FormatUint(uint64(rest), 16))
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, "|")
}

// Watcher tells a function when other processes change a repository's
// issues. Stop it when done.
type Watcher struct {
	once sync.Once
	c    *C.issuez_watch
	h    cgo.Handle
}

// Watch calls fn once a burst of changes on disk is quiet (and at least
// every 400 ms while it isn't), on a thread of its own: another git issue,
// another front end, a sync, and this repo's own writes. fn must not call
// Stop.
func (r *Repo) Watch(fn func(WatchChange)) (*Watcher, error) {
	var w *Watcher
	err := r.use(func(c *C.issuez_repo) error {
		h := cgo.NewHandle(fn)
		var out *C.issuez_watch
		var cerr *C.issuez_error
		if C.issuez_go_watch_start(c, C.uintptr_t(h), &out, &cerr) != C.ISSUEZ_OK {
			h.Delete()
			return takeError(context.Background(), cerr)
		}
		w = &Watcher{c: out, h: h}
		return nil
	})
	return w, err
}

// Stop ends the watch: fn isn't called after it returns.
func (w *Watcher) Stop() {
	w.once.Do(func() {
		C.issuez_watch_stop(w.c)
		w.h.Delete()
	})
}
