package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"fmt"
	"runtime"
)

// Write is the receipt of a write.
type Write struct {
	Kind    Kind
	ID      string
	Wrote   bool // false: nothing changed, no commit
	Commit  OID
	OldTip  OID // zero on create
	NewTip  OID // the next ExpectTip
	Retries int
	// The commit as a timeline entry, with typed changes.
	Entry Entry
	// The issue as of NewTip; only with Reload.
	Issue *Issue
	// A milestone write's milestone, loaded after it; only with Reload.
	Milestone *Milestone
}

func goWrite(w *C.issuez_write) *Write {
	out := &Write{
		Kind:    Kind(C.issuez_write_kind(w)),
		ID:      goStr(C.issuez_write_id(w)),
		Wrote:   bool(C.issuez_write_wrote(w)),
		Commit:  goOID(C.issuez_write_commit(w)),
		OldTip:  goOID(C.issuez_write_old_tip(w)),
		NewTip:  goOID(C.issuez_write_new_tip(w)),
		Retries: int(C.issuez_write_retries(w)),
	}
	if e := C.issuez_write_entry(w); e != nil {
		out.Entry = goEntry(e)
	}
	return out
}

// WriteOption tunes a write. Every write takes them.
type WriteOption func(*writeOpts)
type writeOpts struct {
	reload bool
	expect OID
}

func writeOptions(opts []WriteOption) writeOpts {
	var o writeOpts
	for _, fn := range opts {
		fn(&o)
	}
	return o
}

// Reload also returns the issue as of the new tip (Write.Issue), for
// caches and notifications without a second call; for a milestone write
// the milestone (Write.Milestone).
func Reload() WriteOption { return func(o *writeOpts) { o.reload = true } }

// ExpectTip makes the write fail with ErrVersionMismatch when the issue's
// or milestone's tip isn't tip (an ETag); Error.CurrentTip is the one it
// has. The zero OID expects nothing; creates have no tip and ignore it.
func ExpectTip(tip OID) WriteOption { return func(o *writeOpts) { o.expect = tip } }

// withExpect is e's ops, with o's expectation last.
func (o writeOpts) withExpect(e *Edit) []op {
	ops := e.opsOrNil()
	if o.expect.IsZero() {
		return ops
	}
	return append(append([]op(nil), ops...), op{verb: VerbSet, target: targetExpect, oid: o.expect})
}

// write runs one write call and copies the receipt out.
func (r *Repo) write(ctx context.Context, o writeOpts,
	f func(a cArgs, pin *runtime.Pinner, w **C.issuez_write) C.issuez_code,
) (*Write, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	var failed error
	res, err := fetch(ctx, r, func(a cArgs, w **C.issuez_write) C.issuez_code {
		return f(a, &pin, w)
	}, func(w *C.issuez_write) *Write {
		defer C.issuez_write_free(w)
		res := goWrite(w)
		if o.reload && res.Kind == KindIssue {
			res.Issue, failed = reload(ctx, res, func(a cArgs, i **C.issuez_issue) C.issuez_code {
				return C.issuez_write_load_issue(w, a.tok, i, a.cerr)
			}, func(i *C.issuez_issue) *Issue {
				defer C.issuez_issue_free(i)
				return goIssue(i, false)
			})
		}
		if o.reload && res.Kind == KindMilestone {
			res.Milestone, failed = reload(ctx, res, func(a cArgs, m **C.issuez_milestone) C.issuez_code {
				return C.issuez_write_load_milestone(w, a.tok, m, a.cerr)
			}, takeMilestone)
		}
		return res
	})
	if err == nil {
		err = failed
	}
	return res, err
}

// reload is what a write that landed wrote; an error says the write landed.
func reload[H, T any](ctx context.Context, w *Write, f func(cArgs, *H) C.issuez_code, take func(H) T) (T, error) {
	h, err := invoke(ctx, nil, f)
	if err != nil {
		var none T
		err.(*Error).Write = w
		return none, err
	}
	return take(h), nil
}

// Create writes a new issue; e needs a title.
func (r *Repo) Create(ctx context.Context, e *Edit, actor Actor, opts ...WriteOption) (*Write, error) {
	return r.write(ctx, writeOptions(opts), func(a cArgs, pin *runtime.Pinner, out **C.issuez_write) C.issuez_code {
		ops, n := cOps(pin, e.opsOrNil())
		return C.issuez_issue_create(a.repo, ops, n, pinActor(pin, actor), a.tok, out, a.cerr)
	})
}

// Update writes e as one commit. An edit that changes nothing is fine and
// writes nothing (Write.Wrote is false): values the issue has, and sets
// with the members it has in any order, are no change. So a host can
// state the whole state it wants and let the library write the
// difference.
func (r *Repo) Update(ctx context.Context, id string, e *Edit, actor Actor, opts ...WriteOption) (*Write, error) {
	o := writeOptions(opts)
	return r.write(ctx, o, func(a cArgs, pin *runtime.Pinner, out **C.issuez_write) C.issuez_code {
		ops, n := cOps(pin, o.withExpect(e))
		return C.issuez_issue_update(a.repo, cStr(id), ops, n, pinActor(pin, actor), a.tok, out, a.cerr)
	})
}

func optOID(pin *runtime.Pinner, o OID) *C.issuez_oid {
	if o.IsZero() {
		return nil
	}
	c := cOID(o)
	pin.Pin(&c)
	return &c
}

// ─── Milestones ────────────────────────────────────────────────────────

// MilestoneStatus is where a milestone is in its life.
type MilestoneStatus uint32

const (
	MilestoneOpen      MilestoneStatus = C.ISSUEZ_MILESTONE_OPEN
	MilestoneCompleted MilestoneStatus = C.ISSUEZ_MILESTONE_COMPLETED
	MilestoneRetired   MilestoneStatus = C.ISSUEZ_MILESTONE_RETIRED
)

// CreateMilestone writes a new milestone; e needs SetName.
func (r *Repo) CreateMilestone(ctx context.Context, e *MilestoneEdit, actor Actor, opts ...WriteOption) (*Write, error) {
	return r.write(ctx, writeOptions(opts), func(a cArgs, pin *runtime.Pinner, out **C.issuez_write) C.issuez_code {
		ops, n := cOps(pin, e.edit().opsOrNil())
		return C.issuez_milestone_create(a.repo, ops, n, pinActor(pin, actor), a.tok, out, a.cerr)
	})
}

// UpdateMilestone writes e as one commit of milestone id; like Update, an
// edit that changes nothing writes nothing.
func (r *Repo) UpdateMilestone(ctx context.Context, id string, e *MilestoneEdit, actor Actor, opts ...WriteOption) (*Write, error) {
	o := writeOptions(opts)
	return r.write(ctx, o, func(a cArgs, pin *runtime.Pinner, out **C.issuez_write) C.issuez_code {
		ops, n := cOps(pin, o.withExpect(e.edit()))
		return C.issuez_milestone_update(a.repo, cStr(id), ops, n, pinActor(pin, actor), a.tok, out, a.cerr)
	})
}

// AttachmentSpec is validated image metadata. Store its bytes by SHA256 before
// adding it to an edit on a repo opened with WithAttachmentStore(false).
// It owns no C resources and may be kept or marshaled like any Go value.
type AttachmentSpec struct {
	ID, MediaType, SHA256, Name string
	Size                        uint64
}

// PrepareAttachment validates and hashes data once and sanitizes name.
// An empty id picks a UUID before the host stores bytes or builds text links.
func (r *Repo) PrepareAttachment(ctx context.Context, id, name string, data []byte) (AttachmentSpec, error) {
	return fetch(ctx, r, func(a cArgs, p **C.issuez_prepared_attachment) C.issuez_code {
		return C.issuez_attachment_prepare(a.repo, cStr(id), cStr(name), cBytes(data), a.tok, p, a.cerr)
	}, func(p *C.issuez_prepared_attachment) AttachmentSpec {
		defer C.issuez_prepared_attachment_free(p)
		info := C.issuez_prepared_attachment_info(p)
		return AttachmentSpec{ID: goStr(info.id), Name: goStr(info.name),
			MediaType: goStr(info.media_type), SHA256: goStr(info.sha256), Size: uint64(info.size)}
	})
}

// AddPreparedAttachment adds metadata whose bytes the host already stored.
// The writer validates metadata and limits but does not read or hash the bytes.
func (e *Edit) AddPreparedAttachment(a AttachmentSpec) *Edit {
	return e.add(op{verb: VerbAdd, target: C.ISSUEZ_OPT_PREPARED_ATTACHMENT,
		str: fmt.Sprintf("%s %s %d sha256:%s %s", a.ID, a.MediaType, a.Size, a.SHA256, a.Name)})
}
