package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"runtime"
	"time"
)

// ─── Milestones ────────────────────────────────────────────────────────

// Milestone is a loaded milestone, copied out of the library.
type Milestone struct {
	ID          string
	Tip         OID
	Name        string
	Description string
	Status      MilestoneStatus
	DueDate     *Date
	Created     time.Time
	Updated     time.Time // of its latest commit
	// When the status it has was set (a completed milestone's closing
	// time); nil when no commit after the root set it.
	StatusChanged *time.Time
	Author        Person
	Problems      []Problem
}

func goMilestone(m *C.issuez_milestone) *Milestone {
	r := C.issuez_milestone_info_of(m)
	out := &Milestone{
		ID:          goStr(r.id),
		Tip:         goOID(r.tip),
		Name:        goStr(r.name),
		Description: goStr(r.description),
		Status:      MilestoneStatus(r.status),
		DueDate:     goOptDate(r.due_date),
		Created:     goTime(r.created),
		Updated:     goTime(r.updated),
		Author:      goPerson(r.author),
		Problems:    goProblems(C.issuez_milestone_problems(m)),
	}
	if r.has_status_changed {
		out.StatusChanged = new(goTime(r.status_changed))
	}
	return out
}

// takeMilestone copies and frees an owned milestone.
func takeMilestone(m *C.issuez_milestone) *Milestone {
	defer C.issuez_milestone_free(m)
	return goMilestone(m)
}

// LoadMilestone reads one milestone by full UUID.
func (r *Repo) LoadMilestone(ctx context.Context, id string) (*Milestone, error) {
	return fetch(ctx, r, func(a cArgs, m **C.issuez_milestone) C.issuez_code {
		return C.issuez_milestone_load(a.repo, cStr(id), a.tok, m, a.cerr)
	}, takeMilestone)
}

// Milestones lists every milestone: by due date, then name.
func (r *Repo) Milestones(ctx context.Context) ([]*Milestone, error) {
	return fetch(ctx, r, func(a cArgs, l **C.issuez_milestone_list) C.issuez_code {
		return C.issuez_milestone_list_all(a.repo, a.tok, l, a.cerr)
	}, func(l *C.issuez_milestone_list) []*Milestone {
		defer C.issuez_milestone_list_free(l)
		n := C.issuez_milestone_list_len(l)
		list := make([]*Milestone, 0, int(n))
		for i := C.size_t(0); i < n; i++ {
			list = append(list, goMilestone(C.issuez_milestone_list_at(l, i)))
		}
		return list
	})
}

// ─── Purge ─────────────────────────────────────────────────────────────

// PurgeResult says what a purge left.
type PurgeResult struct {
	// The issue's new tip after a comment purge; zero when the issue is gone.
	NewTip OID
	// Remotes that had the purged commits, one synced by URL or path as the
	// url-<hash> its refs are kept under. The next `git issue sync` with each
	// replaces their copy.
	ExposedRemotes []string
	// The attachments it took out of history: a host that keeps their
	// bytes drops its copies.
	RemovedAttachments []string
}

// PurgeIssue removes the issue from history for good, leaving a tombstone
// that syncs to the remotes and every clone.
func (r *Repo) PurgeIssue(ctx context.Context, id string, actor Actor, reason string) (*PurgeResult, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	return fetch(ctx, r, func(a cArgs, h **C.issuez_purge_result) C.issuez_code {
		return C.issuez_purge_issue(a.repo, cStr(id), pinActor(&pin, actor), cStr(reason), a.tok, h, a.cerr)
	}, takePurgeResult)
}

// PurgeComment takes one comment's text, attachments and origin, and
// rewrites the issue from there on: later commits get new IDs.
func (r *Repo) PurgeComment(ctx context.Context, id string, comment OID, actor Actor, reason string) (*PurgeResult, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	return fetch(ctx, r, func(a cArgs, h **C.issuez_purge_result) C.issuez_code {
		return C.issuez_purge_comment(a.repo, cStr(id), optOID(&pin, comment), pinActor(&pin, actor), cStr(reason), a.tok, h, a.cerr)
	}, takePurgeResult)
}

func takePurgeResult(h *C.issuez_purge_result) *PurgeResult {
	defer C.issuez_purge_result_free(h)
	return &PurgeResult{
		NewTip: goOID(C.issuez_purge_result_new_tip(h)),
		ExposedRemotes: goStrs(C.issuez_purge_result_exposed_remote_count(h), func(i C.size_t) C.issuez_str {
			return C.issuez_purge_result_exposed_remote_at(h, i)
		}),
		RemovedAttachments: goStrs(C.issuez_purge_result_attachment_count(h), func(i C.size_t) C.issuez_str {
			return C.issuez_purge_result_attachment_at(h, i)
		}),
	}
}

// ─── Push check ────────────────────────────────────────────────────────

// RefUpdate is one line of a pre-receive hook's input. A zero Old is a
// create, a zero New a delete.
type RefUpdate struct {
	Ref      string
	Old, New OID
}

// AuthorPolicy says what to do with new commits not by the pusher.
type AuthorPolicy uint32

const (
	AuthorAny     AuthorPolicy = C.ISSUEZ_AUTHOR_ANY
	AuthorWarn    AuthorPolicy = C.ISSUEZ_AUTHOR_WARN
	AuthorEnforce AuthorPolicy = C.ISSUEZ_AUTHOR_ENFORCE
)

// PushAction is what an update does to its ref.
type PushAction uint32

const (
	PushIgnored     PushAction = C.ISSUEZ_PUSH_IGNORED
	PushCreate      PushAction = C.ISSUEZ_PUSH_CREATE
	PushFastForward PushAction = C.ISSUEZ_PUSH_FAST_FORWARD
	PushRewrite     PushAction = C.ISSUEZ_PUSH_REWRITE
	PushDelete      PushAction = C.ISSUEZ_PUSH_DELETE
)

// PushPolicy is the host's side of the check.
type PushPolicy struct {
	// The pusher's verified emails, compared ignoring case.
	PusherEmails []string
	// The pusher's UUIDs. Under Authors, a new commit's X-Author-Id (the
	// UserID of the Actor that wrote it) must be one of them.
	PusherUserIDs []string
	Authors       AuthorPolicy
	// Clients may give numbers; off, a new commit with X-Number is refused.
	AllowNumbers bool
	// The pusher may push tombstones, and the rewrites and deletes they
	// allow. Give it to admins only: a tombstone purges every clone.
	AllowPurge bool
	// The push's quarantine, from the hook's environment
	// (GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES).
	ObjectDir, AlternateObjectDirs string
}

// PushVerdict is the check's judgement of one update.
type PushVerdict struct {
	Ref    string
	Kind   Kind // zero for refs that aren't issuez refs
	ID     string
	Action PushAction
	Accept bool
	// Why not, or what to flag (an author under AuthorWarn).
	Problems []Problem
	// A new issue without a number: give it one once the push is in.
	NeedsNumber bool
	// Adds commits to a locked issue: the host decides if the pusher may.
	TouchesLocked bool
	// How many commits are new, and for issues those commits as timeline
	// entries.
	CommitCount int
	Entries     []Entry
	// Issues: who opened it, for rules on the pusher's own issue.
	IssueAuthor *Person
	// Issues: the attachments the new commits add. Their SHA256 and Size
	// are the LFS objects the host's store must have before it accepts.
	Attachments []Attachment
}

// PushCheck judges a push's ref updates for a pre-receive hook (format.md
// §11). It returns every verdict; err is a *Error with CodeRejected when
// any update is refused.
func (r *Repo) PushCheck(ctx context.Context, updates []RefUpdate, policy PushPolicy) ([]PushVerdict, error) {
	var verdicts []PushVerdict
	var ops []op
	for _, e := range policy.PusherEmails {
		ops = append(ops, op{verb: VerbAdd, target: C.ISSUEZ_OPT_PUSHER_EMAIL, str: e})
	}
	for _, id := range policy.PusherUserIDs {
		ops = append(ops, op{verb: VerbAdd, target: C.ISSUEZ_OPT_PUSHER_USER_ID, str: id})
	}
	if policy.Authors != 0 {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_AUTHOR_POLICY, num: int64(policy.Authors)})
	}
	ops = append(ops,
		op{verb: VerbSet, target: C.ISSUEZ_OPT_ALLOW_NUMBERS, num: b2i(policy.AllowNumbers)},
		op{verb: VerbSet, target: C.ISSUEZ_OPT_ALLOW_PURGE, num: b2i(policy.AllowPurge)})
	if policy.ObjectDir != "" {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_OBJECT_DIR, str: policy.ObjectDir})
	}
	if policy.AlternateObjectDirs != "" {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_ALTERNATE_OBJECT_DIRS, str: policy.AlternateObjectDirs})
	}
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		cops, n := cOps(&pin, ops)
		var cups *C.issuez_ref_update
		if len(updates) > 0 {
			list := make([]C.issuez_ref_update, len(updates))
			for i, u := range updates {
				list[i].ref = pinStr(&pin, u.Ref)
				list[i].old_oid = cOID(u.Old)
				list[i].new_oid = cOID(u.New)
			}
			pin.Pin(&list[0])
			cups = &list[0]
		}
		// A rejected push has verdicts too.
		h, err := invoke(ctx, c, func(a cArgs, h **C.issuez_push_verdicts) C.issuez_code {
			return C.issuez_push_check(a.repo, cups, C.size_t(len(updates)), cops, n, a.tok, h, a.cerr)
		})
		if h != nil {
			defer C.issuez_push_verdicts_free(h)
			verdicts = goList(C.issuez_push_verdicts_len(h), func(i C.size_t) PushVerdict {
				return goPushVerdict(C.issuez_push_verdicts_at(h, i))
			})
		}
		return err
	})
	return verdicts, err
}

func goPushVerdict(v *C.issuez_push_verdict) PushVerdict {
	return PushVerdict{
		Ref:           goStr(v.ref),
		Kind:          Kind(v.kind),
		ID:            goStr(v.id),
		Action:        PushAction(v.action),
		Accept:        bool(v.accept),
		Problems:      goProblems(v.problems),
		NeedsNumber:   bool(v.needs_number),
		TouchesLocked: bool(v.touches_locked),
		CommitCount:   int(v.commit_count),
		Entries: goList(v.entry_count, func(k C.size_t) Entry {
			return goEntry(C.issuez_push_verdict_entry_at(v, k))
		}),
		IssueAuthor: goOptPerson(v.issue_author),
		Attachments: goList(v.attachment_count, func(k C.size_t) Attachment {
			return goAttachment(C.issuez_push_verdict_attachment_at(v, k))
		}),
	}
}

// ─── Fsck ──────────────────────────────────────────────────────────────

// FsckKind is what a finding is about.
type FsckKind uint32

const (
	FsckIntegrity         FsckKind = C.ISSUEZ_FSCK_INTEGRITY
	FsckMilestoneStatus   FsckKind = C.ISSUEZ_FSCK_MILESTONE_STATUS
	FsckAttachmentTrailer FsckKind = C.ISSUEZ_FSCK_ATTACHMENT_TRAILER
	FsckAttachmentMissing FsckKind = C.ISSUEZ_FSCK_ATTACHMENT_MISSING
	FsckAttachmentCorrupt FsckKind = C.ISSUEZ_FSCK_ATTACHMENT_CORRUPT
	FsckDerivedRef        FsckKind = C.ISSUEZ_FSCK_DERIVED_REF
	FsckAttachmentsFailed FsckKind = C.ISSUEZ_FSCK_ATTACHMENTS_FAILED
	FsckBytesUnchecked    FsckKind = C.ISSUEZ_FSCK_BYTES_UNCHECKED
	FsckOrphans           FsckKind = C.ISSUEZ_FSCK_ORPHANS
	FsckQuarantined       FsckKind = C.ISSUEZ_FSCK_QUARANTINED
	FsckProjection        FsckKind = C.ISSUEZ_FSCK_PROJECTION
)

// FsckReport is what Fsck checked and found, in order.
type FsckReport struct {
	Issues, Milestones, Errors int
	Findings                   []FsckFinding
}

// Fsck checks the issue data as git issue fsck does, and writes nothing.
// A repo opened with WithAttachmentStore(false) leaves the bytes to the
// caller: they aren't checked.
func (r *Repo) Fsck(ctx context.Context) (*FsckReport, error) {
	return fetch(ctx, r, func(a cArgs, h **C.issuez_fsck_report) C.issuez_code {
		return C.issuez_fsck(a.repo, a.tok, h, a.cerr)
	}, func(h *C.issuez_fsck_report) *FsckReport {
		defer C.issuez_fsck_report_free(h)
		return &FsckReport{
			Issues:     int(C.issuez_fsck_report_issue_count(h)),
			Milestones: int(C.issuez_fsck_report_milestone_count(h)),
			Errors:     int(C.issuez_fsck_report_error_count(h)),
			Findings: goList(C.issuez_fsck_report_len(h), func(i C.size_t) FsckFinding {
				return goFsckFinding(C.issuez_fsck_report_at(h, i))
			}),
		}
	})
}

// LoadMilestoneAt reads the milestone at an exact, nonzero historical tip.
func (r *Repo) LoadMilestoneAt(ctx context.Context, id string, tip OID) (*Milestone, error) {
	if tip.IsZero() {
		return nil, &Error{Code: CodeInvalidArgument, Message: "tip is zero"}
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	ct := optOID(&pin, tip)
	return fetch(ctx, r, func(a cArgs, m **C.issuez_milestone) C.issuez_code {
		return C.issuez_milestone_load_at(a.repo, cStr(id), ct, a.tok, m, a.cerr)
	}, takeMilestone)
}
