package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"sync"
)

// ProjectionView answers what needs several issues (the tree, blockers,
// progress, effective milestones) one question at a time, reading the
// library's projection as asked instead of copying all of it as
// Projection does. Safe for concurrent use; Close it when done.
type ProjectionView struct {
	mu sync.RWMutex
	c  *C.issuez_projection
}

// OpenProjection is the projection as a live view, as opts say (see
// ProjectionOptions); Close it when done.
func (r *Repo) OpenProjection(ctx context.Context, opts ProjectionOptions) (*ProjectionView, error) {
	var p *ProjectionView
	around := opts.Around
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_projection
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			if around == "" {
				return C.issuez_projection_build(c, tok, &h, &cerr)
			}
			return C.issuez_projection_around(c, cStr(around), tok, &h, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		p = &ProjectionView{c: h}
		return nil
	})
	return p, err
}

func (p *ProjectionView) read(f func(h *C.issuez_projection)) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.c != nil {
		f(p.c)
	}
}

// Roots are the issues without a parent, in tree order.
func (p *ProjectionView) Roots() []string {
	var out []string
	p.read(func(h *C.issuez_projection) {
		out = goStrs(C.issuez_projection_root_count(h), func(i C.size_t) C.issuez_str { return C.issuez_projection_root_at(h, i) })
	})
	return out
}

// Children of an issue, in tree order.
func (p *ProjectionView) Children(id string) []string {
	var out []string
	p.read(func(h *C.issuez_projection) {
		k := cStr(id)
		out = goStrs(C.issuez_projection_child_count(h, k), func(i C.size_t) C.issuez_str { return C.issuez_projection_child_at(h, k, i) })
	})
	return out
}

// ActiveBlockers are an issue's blockers that aren't done.
func (p *ProjectionView) ActiveBlockers(id string) []string {
	var out []string
	p.read(func(h *C.issuez_projection) {
		k := cStr(id)
		out = goStrs(C.issuez_projection_active_blocker_count(h, k), func(i C.size_t) C.issuez_str {
			return C.issuez_projection_active_blocker_at(h, k, i)
		})
	})
	return out
}

// Blocking are the issues an issue blocks.
func (p *ProjectionView) Blocking(id string) []string {
	var out []string
	p.read(func(h *C.issuez_projection) {
		k := cStr(id)
		out = goStrs(C.issuez_projection_blocking_count(h, k), func(i C.size_t) C.issuez_str { return C.issuez_projection_blocking_at(h, k, i) })
	})
	return out
}

// Progress of an issue's sub-issues; false for one without any.
func (p *ProjectionView) Progress(id string) (Progress, bool) {
	var pr Progress
	var ok bool
	p.read(func(h *C.issuez_projection) {
		var out C.issuez_progress
		if C.issuez_projection_progress(h, cStr(id), &out) {
			pr, ok = Progress{Done: int(out.done), Total: int(out.total)}, true
		}
	})
	return pr, ok
}

// MilestoneOf is an issue's effective milestone, direct or through its
// parents; "" for none.
func (p *ProjectionView) MilestoneOf(id string) string {
	var m string
	p.read(func(h *C.issuez_projection) { m = goStr(C.issuez_projection_milestone_of(h, cStr(id))) })
	return m
}

// MilestoneProgress counts a milestone's done and total leaves.
func (p *ProjectionView) MilestoneProgress(id string) Progress {
	var pr Progress
	p.read(func(h *C.issuez_projection) {
		out := C.issuez_projection_milestone_progress(h, cStr(id))
		pr = Progress{Done: int(out.done), Total: int(out.total)}
	})
	return pr
}

// Close frees the projection; the methods answer nothing after it. It
// returns nil, so ProjectionView is an io.Closer, and a second Close does
// nothing.
func (p *ProjectionView) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.c != nil {
		C.issuez_projection_free(p.c)
		p.c = nil
	}
	return nil
}
