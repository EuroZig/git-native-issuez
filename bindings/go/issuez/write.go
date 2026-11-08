package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"runtime"
	"unsafe"
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
	f func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_write, cerr **C.issuez_error) C.issuez_code,
) (res *Write, err error) {
	err = r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		var w *C.issuez_write
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code { return f(c, &pin, tok, &w, &cerr) })
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_write_free(w)
		res = goWrite(w)
		if o.reload && res.Kind == KindIssue {
			var i *C.issuez_issue
			rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
				return C.issuez_write_load_issue(w, tok, &i, &cerr)
			})
			if rc != C.ISSUEZ_OK {
				// The write landed; report that with the error.
				e := takeError(ctx, cerr).(*Error)
				e.Write = res
				return e
			}
			defer C.issuez_issue_free(i)
			res.Issue = goIssue(i, false)
		}
		if o.reload && res.Kind == KindMilestone {
			var m *C.issuez_milestone
			rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
				return C.issuez_write_load_milestone(w, tok, &m, &cerr)
			})
			if rc != C.ISSUEZ_OK {
				e := takeError(ctx, cerr).(*Error)
				e.Write = res
				return e
			}
			defer C.issuez_milestone_free(m)
			res.Milestone = goMilestone(m)
		}
		return nil
	})
	return res, err
}

// Create writes a new issue; e needs a title.
func (r *Repo) Create(ctx context.Context, e *Edit, actor Actor, opts ...WriteOption) (*Write, error) {
	return r.write(ctx, writeOptions(opts), func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_write, cerr **C.issuez_error) C.issuez_code {
		ops, n := cOps(pin, e.opsOrNil())
		return C.issuez_issue_create(c, ops, n, pinActor(pin, actor), tok, out, cerr)
	})
}

// Update writes e as one commit. An edit that changes nothing is fine and
// writes nothing (Write.Wrote is false): values the issue has, and sets
// with the members it has in any order, are no change. So a host can
// state the whole state it wants and let the library write the
// difference.
func (r *Repo) Update(ctx context.Context, id string, e *Edit, actor Actor, opts ...WriteOption) (*Write, error) {
	o := writeOptions(opts)
	return r.write(ctx, o, func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_write, cerr **C.issuez_error) C.issuez_code {
		ops, n := cOps(pin, o.withExpect(e))
		return C.issuez_issue_update(c, cStr(id), ops, n, pinActor(pin, actor), tok, out, cerr)
	})
}

// CheckCreate is a dry run of Create: every problem it would hit now,
// nil if none. Unlike Edit.ValidateCreate it reads the repository (the
// targets of milestones, parents and blockers, the done states).
func (r *Repo) CheckCreate(ctx context.Context, e *Edit) ([]Problem, error) {
	return r.check(ctx, "", e.opsOrNil())
}

// CheckUpdate is a dry run of Update: every problem it would hit now, nil
// if none. ExpectTip applies; Reload has nothing to reload.
func (r *Repo) CheckUpdate(ctx context.Context, id string, e *Edit, opts ...WriteOption) ([]Problem, error) {
	if id == "" {
		return nil, &Error{Code: CodeInvalidArgument, Message: "id is empty"}
	}
	return r.check(ctx, id, writeOptions(opts).withExpect(e))
}

// check runs issuez_issue_check; id "" checks a create.
func (r *Repo) check(ctx context.Context, id string, o []op) ([]Problem, error) {
	var problems []Problem
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		ops, n := cOps(&pin, o)
		var out *C.issuez_problems
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_issue_check(c, cStr(id), ops, n, tok, &out, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		problems = takeProblems(out)
		return nil
	})
	return problems, err
}

func optOID(pin *runtime.Pinner, o OID) *C.issuez_oid {
	if o.IsZero() {
		return nil
	}
	c := cOID(o)
	pin.Pin(&c)
	return &c
}

// ReadAttachment is an attachment's bytes from the repository's store,
// checked against its trailer. CodeNotFound for no such issue or
// attachment, CodeLFS when the bytes aren't in this clone (git lfs
// fetch), CodeCorrupt when they don't match.
func (r *Repo) ReadAttachment(ctx context.Context, issueID, attachmentID string) ([]byte, error) {
	var data []byte
	err := r.use(func(c *C.issuez_repo) error {
		var b *C.issuez_bytes
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_attachment_read(c, cStr(issueID), cStr(attachmentID), tok, &b, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_bytes_free(b)
		d := C.issuez_bytes_data(b)
		data = C.GoBytes(unsafe.Pointer(d.ptr), C.int(d.len))
		return nil
	})
	return data, err
}

// AttachmentInfo is what a write would store of an attachment: its media
// type and its LFS pointer (SHA256, Size), the object a host that keeps
// the bytes (WithAttachmentStore(false)) stores before the write.
type AttachmentInfo struct {
	MediaType string
	SHA256    string // lowercase hex
	Size      uint64
}

// ValidateAttachment says whether a write would take data as an
// attachment, without writing: what it would store, or an *Error
// (CodeInvalidValue for the type or animation, CodeLimit for the size).
func (r *Repo) ValidateAttachment(name string, data []byte) (AttachmentInfo, error) {
	var info AttachmentInfo
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		var media C.issuez_str
		var cerr *C.issuez_error
		if C.issuez_attachment_validate(c, pinStr(&pin, name), pinStr(&pin, string(data)), &media, &cerr) != C.ISSUEZ_OK {
			return takeError(context.Background(), cerr)
		}
		sum := sha256.Sum256(data)
		info = AttachmentInfo{MediaType: goStr(media), SHA256: hex.EncodeToString(sum[:]), Size: uint64(len(data))}
		return nil
	})
	return info, err
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
	return r.write(ctx, writeOptions(opts), func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_write, cerr **C.issuez_error) C.issuez_code {
		ops, n := cOps(pin, e.edit().opsOrNil())
		return C.issuez_milestone_create(c, ops, n, pinActor(pin, actor), tok, out, cerr)
	})
}

// UpdateMilestone writes e as one commit of milestone id; like Update, an
// edit that changes nothing writes nothing.
func (r *Repo) UpdateMilestone(ctx context.Context, id string, e *MilestoneEdit, actor Actor, opts ...WriteOption) (*Write, error) {
	o := writeOptions(opts)
	return r.write(ctx, o, func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_write, cerr **C.issuez_error) C.issuez_code {
		ops, n := cOps(pin, o.withExpect(e.edit()))
		return C.issuez_milestone_update(c, cStr(id), ops, n, pinActor(pin, actor), tok, out, cerr)
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
	var spec AttachmentSpec
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		var p *C.issuez_prepared_attachment
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_attachment_prepare(c, cStr(id), cStr(name), cStr(string(data)), tok, &p, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_prepared_attachment_free(p)
		info := C.issuez_prepared_attachment_info(p)
		spec = AttachmentSpec{ID: goStr(info.id), Name: goStr(info.name),
			MediaType: goStr(info.media_type), SHA256: goStr(info.sha256), Size: uint64(info.size)}
		return nil
	})
	return spec, err
}

// AddPreparedAttachment adds metadata whose bytes the host already stored.
// The writer validates metadata and limits but does not read or hash the bytes.
func (e *Edit) AddPreparedAttachment(a AttachmentSpec) *Edit {
	return e.add(op{verb: VerbAdd, target: C.ISSUEZ_OPT_PREPARED_ATTACHMENT,
		str: fmt.Sprintf("%s %s %d sha256:%s %s", a.ID, a.MediaType, a.Size, a.SHA256, a.Name)})
}
