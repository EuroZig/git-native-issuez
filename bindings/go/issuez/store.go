package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"sort"
	"sync"
)

// Store is a live view of a repository's issues for a front end: every
// issue, kept up to date by Refresh, which loads only the issues whose
// tip moved and copies only those again. Safe for concurrent use. Close
// it when done.
type Store struct {
	r      *Repo
	mu     sync.Mutex
	c      *C.issuez_store
	issues map[string]*Issue
	order  []string
}

// NewStore is an empty store over r; the first Refresh fills it.
func (r *Repo) NewStore() (*Store, error) {
	var s *Store
	err := r.use(func(c *C.issuez_repo) error {
		var out *C.issuez_store
		var cerr *C.issuez_error
		if C.issuez_store_new(c, &out, &cerr) != C.ISSUEZ_OK {
			return takeError(context.Background(), cerr)
		}
		s = &Store{r: r, c: out, issues: map[string]*Issue{}}
		return nil
	})
	return s, err
}

// Refresh reads the refs and loads what moved: the UUIDs of the issues
// created, changed or deleted since the last refresh, nil when nothing
// moved.
func (s *Store) Refresh(ctx context.Context) ([]string, error) {
	var changed []string
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.c == nil {
		return nil, &Error{Code: CodeInvalidArgument, Message: "store is closed"}
	}
	err := s.r.use(func(*C.issuez_repo) error {
		var moved C.bool
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_store_refresh(s.c, tok, &moved, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		if !moved {
			return nil
		}
		changed = goStrs(C.issuez_store_changed_count(s.c), func(i C.size_t) C.issuez_str {
			return C.issuez_store_changed_at(s.c, i)
		})
		for _, id := range changed {
			if i := C.issuez_store_find(s.c, cStr(id)); i != nil {
				s.issues[id] = goIssue(i, false)
			} else {
				delete(s.issues, id)
			}
		}
		// The first refresh, or one after issues failed to load before.
		if n := int(C.issuez_store_issue_count(s.c)); n != len(s.issues) {
			for k := C.size_t(0); k < C.size_t(n); k++ {
				i := C.issuez_store_issue_at(s.c, k)
				id := goStr(C.issuez_issue_id(i))
				if _, ok := s.issues[id]; !ok {
					s.issues[id] = goIssue(i, false)
				}
			}
		}
		s.order = s.order[:0]
		for id := range s.issues {
			s.order = append(s.order, id)
		}
		sort.Strings(s.order)
		return nil
	})
	return changed, err
}

// Issues is every issue as of the last Refresh, deleted ones too, in UUID
// order. The values are shared: don't change them.
func (s *Store) Issues() []*Issue {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Issue, 0, len(s.order))
	for _, id := range s.order {
		out = append(out, s.issues[id])
	}
	return out
}

// Find is the issue with this UUID as of the last Refresh; nil for none.
func (s *Store) Find(id string) *Issue {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.issues[id]
}

// Generation is bumped by every Refresh that changed something.
func (s *Store) Generation() uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.c == nil {
		return 0
	}
	return uint32(C.issuez_store_generation(s.c))
}

// Close frees the store; Refresh fails after it. It returns nil, so
// Store is an io.Closer, and a second Close does nothing.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.c != nil {
		C.issuez_store_free(s.c)
		s.c = nil
	}
	return nil
}
