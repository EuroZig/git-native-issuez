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
	out := &Milestone{
		ID:          goStr(C.issuez_milestone_id(m)),
		Tip:         goOID(C.issuez_milestone_tip(m)),
		Name:        goStr(C.issuez_milestone_name(m)),
		Description: goStr(C.issuez_milestone_description(m)),
		Status:      MilestoneStatus(C.issuez_milestone_status_of(m)),
		Created:     goTime(C.issuez_milestone_created(m)),
		Updated:     goTime(C.issuez_milestone_updated(m)),
		Author:      goPerson(C.issuez_milestone_author(m)),
		Problems:    goProblems(C.issuez_milestone_problems(m)),
	}
	var at C.issuez_time
	if C.issuez_milestone_status_changed(m, &at) {
		t := goTime(at)
		out.StatusChanged = &t
	}
	var d C.issuez_date
	if C.issuez_milestone_due_date(m, &d) {
		v := goDate(d)
		out.DueDate = &v
	}
	return out
}

// LoadMilestone reads one milestone by full UUID.
func (r *Repo) LoadMilestone(ctx context.Context, id string) (*Milestone, error) {
	var m *Milestone
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_milestone
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_milestone_load(c, cStr(id), tok, &h, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_milestone_free(h)
		m = goMilestone(h)
		return nil
	})
	return m, err
}

// Milestones lists every milestone: by due date, then name.
func (r *Repo) Milestones(ctx context.Context) ([]*Milestone, error) {
	var list []*Milestone
	err := r.use(func(c *C.issuez_repo) error {
		var l *C.issuez_milestone_list
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_milestone_list_all(c, tok, &l, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_milestone_list_free(l)
		n := C.issuez_milestone_list_len(l)
		list = make([]*Milestone, 0, int(n))
		for i := C.size_t(0); i < n; i++ {
			list = append(list, goMilestone(C.issuez_milestone_list_at(l, i)))
		}
		return nil
	})
	return list, err
}

// ─── Projection ────────────────────────────────────────────────────────

// Progress counts done and total leaves.
type Progress struct{ Done, Total int }

// Projection answers what needs several issues: the tree, blockers,
// progress, effective milestones and problems across issues.
type Projection struct {
	Issues []*Issue
	// Roots in tree order; a broken parent makes an issue a root.
	Roots    []string
	Children map[string][]string
	// Blockers that aren't done.
	ActiveBlockers map[string][]string
	// Issues each one blocks.
	Blocking map[string][]string
	Progress map[string]Progress
	// The effective milestone, direct or through parents.
	MilestoneOf       map[string]string
	MilestoneProgress map[string]Progress
	Problems          []Problem
}

// ProjectionOptions shape Projection and OpenProjection.
type ProjectionOptions struct {
	// Around is an issue's UUID: project only what its answers need (the
	// issue, its ancestors, descendants and blockers). Cheaper, with the
	// same answers for that issue but Blocking, which needs every issue.
	// "" projects every issue.
	Around string
}

// Projection is a copy of the projection, its handle freed at once.
func (r *Repo) Projection(ctx context.Context, opts ProjectionOptions) (*Projection, error) {
	var p *Projection
	id := opts.Around
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_projection
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			if id == "" {
				return C.issuez_projection_build(c, tok, &h, &cerr)
			}
			return C.issuez_projection_around(c, cStr(id), tok, &h, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_projection_free(h)
		p = goProjection(h)
		return nil
	})
	return p, err
}

func goProjection(h *C.issuez_projection) *Projection {
	issues, _ := goIssues(C.issuez_projection_issues(h), false)
	p := &Projection{
		Issues:            issues,
		Children:          map[string][]string{},
		ActiveBlockers:    map[string][]string{},
		Blocking:          map[string][]string{},
		Progress:          map[string]Progress{},
		MilestoneOf:       map[string]string{},
		MilestoneProgress: map[string]Progress{},
		Problems:          goProblems(C.issuez_projection_problems(h, C.issuez_str{})),
	}
	p.Roots = goStrs(C.issuez_projection_root_count(h), func(i C.size_t) C.issuez_str {
		return C.issuez_projection_root_at(h, i)
	})
	for _, issue := range issues {
		id := cStr(issue.ID)
		if l := goStrs(C.issuez_projection_child_count(h, id), func(i C.size_t) C.issuez_str {
			return C.issuez_projection_child_at(h, id, i)
		}); l != nil {
			p.Children[issue.ID] = l
		}
		if l := goStrs(C.issuez_projection_active_blocker_count(h, id), func(i C.size_t) C.issuez_str {
			return C.issuez_projection_active_blocker_at(h, id, i)
		}); l != nil {
			p.ActiveBlockers[issue.ID] = l
		}
		if l := goStrs(C.issuez_projection_blocking_count(h, id), func(i C.size_t) C.issuez_str {
			return C.issuez_projection_blocking_at(h, id, i)
		}); l != nil {
			p.Blocking[issue.ID] = l
		}
		var pr C.issuez_progress
		if C.issuez_projection_progress(h, id, &pr) {
			p.Progress[issue.ID] = Progress{Done: int(pr.done), Total: int(pr.total)}
		}
		if m := goStr(C.issuez_projection_milestone_of(h, id)); m != "" {
			p.MilestoneOf[issue.ID] = m
			if _, ok := p.MilestoneProgress[m]; !ok {
				mp := C.issuez_projection_milestone_progress(h, cStr(m))
				p.MilestoneProgress[m] = Progress{Done: int(mp.done), Total: int(mp.total)}
			}
		}
	}
	return p
}

// ─── Sync ──────────────────────────────────────────────────────────────

// SyncOutcome is what a sync did to one issue or milestone.
type SyncOutcome uint32

const (
	SyncUpToDate    SyncOutcome = C.ISSUEZ_SYNC_UP_TO_DATE
	SyncNew         SyncOutcome = C.ISSUEZ_SYNC_NEW
	SyncFastForward SyncOutcome = C.ISSUEZ_SYNC_FAST_FORWARD
	SyncMerged      SyncOutcome = C.ISSUEZ_SYNC_MERGED
	SyncPushed      SyncOutcome = C.ISSUEZ_SYNC_PUSHED
	SyncQuarantined SyncOutcome = C.ISSUEZ_SYNC_QUARANTINED
	SyncFailed      SyncOutcome = C.ISSUEZ_SYNC_FAILED
	// A tombstone purged the issue; the push deletes the remote's copy.
	SyncPurged SyncOutcome = C.ISSUEZ_SYNC_PURGED
)

// SyncReport is what a sync did, item by item. OK is false when an item
// was quarantined or failed.
type SyncReport struct {
	Items []SyncItem
	OK    bool
}

// SyncOptions shape Sync; the zero value fetches, merges and pushes.
type SyncOptions struct {
	NoPush bool
	// Push the derived refs/attachments refs but upload no bytes: for
	// hosts whose LFS server already has them, or that keep attachments
	// elsewhere.
	NoAttachments bool
}

// Sync fetches, merges and pushes issues and milestones with a remote.
func (r *Repo) Sync(ctx context.Context, remote string, opts SyncOptions) (*SyncReport, error) {
	var rep *SyncReport
	var ops []op
	if opts.NoPush {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_SYNC_PUSH, num: 0})
	}
	if opts.NoAttachments {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_SYNC_ATTACHMENTS, num: 0})
	}
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		cops, n := cOps(&pin, ops)
		var h *C.issuez_sync_report
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_sync(c, cStr(remote), cops, n, tok, &h, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_sync_report_free(h)
		rep = &SyncReport{OK: bool(C.issuez_sync_report_ok(h))}
		for i := C.size_t(0); i < C.issuez_sync_report_len(h); i++ {
			it := C.issuez_sync_report_at(h, i)
			rep.Items = append(rep.Items, goSyncItem(it))
		}
		return nil
	})
	return rep, err
}

// ─── Purge ─────────────────────────────────────────────────────────────

// PurgeResult says what a purge left.
type PurgeResult struct {
	// The issue's new tip after a comment purge; zero when the issue is gone.
	NewTip OID
	// Remotes that had the purged commits. The next Sync with each
	// replaces their copy.
	ExposedRemotes []string
	// The attachments it took out of history: a host that keeps their
	// bytes drops its copies.
	RemovedAttachments []string
}

// PurgeIssue removes the issue from history for good, leaving a tombstone
// that syncs to the remotes and every clone.
func (r *Repo) PurgeIssue(ctx context.Context, id string, actor Actor, reason string) (*PurgeResult, error) {
	return r.purge(ctx, func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_purge_result, cerr **C.issuez_error) C.issuez_code {
		return C.issuez_purge_issue(c, cStr(id), pinActor(pin, actor), cStr(reason), tok, out, cerr)
	})
}

// PurgeComment takes one comment's text, attachments and origin, and
// rewrites the issue from there on: later commits get new IDs.
func (r *Repo) PurgeComment(ctx context.Context, id string, comment OID, actor Actor, reason string) (*PurgeResult, error) {
	return r.purge(ctx, func(c *C.issuez_repo, pin *runtime.Pinner, tok *C.issuez_cancel, out **C.issuez_purge_result, cerr **C.issuez_error) C.issuez_code {
		return C.issuez_purge_comment(c, cStr(id), optOID(pin, comment), pinActor(pin, actor), cStr(reason), tok, out, cerr)
	})
}

func (r *Repo) purge(ctx context.Context, f func(*C.issuez_repo, *runtime.Pinner, *C.issuez_cancel, **C.issuez_purge_result, **C.issuez_error) C.issuez_code) (*PurgeResult, error) {
	var res *PurgeResult
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		var h *C.issuez_purge_result
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code { return f(c, &pin, tok, &h, &cerr) })
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_purge_result_free(h)
		res = &PurgeResult{
			NewTip: goOID(C.issuez_purge_result_new_tip(h)),
			ExposedRemotes: goStrs(C.issuez_purge_result_exposed_remote_count(h), func(i C.size_t) C.issuez_str {
				return C.issuez_purge_result_exposed_remote_at(h, i)
			}),
			RemovedAttachments: goStrs(C.issuez_purge_result_attachment_count(h), func(i C.size_t) C.issuez_str {
				return C.issuez_purge_result_attachment_at(h, i)
			}),
		}
		return nil
	})
	return res, err
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
		var h *C.issuez_push_verdicts
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_push_check(c, cups, C.size_t(len(updates)), cops, n, tok, &h, &cerr)
		})
		if h != nil {
			defer C.issuez_push_verdicts_free(h)
			for i := C.size_t(0); i < C.issuez_push_verdicts_len(h); i++ {
				v := C.issuez_push_verdicts_at(h, i)
				out := PushVerdict{
					Ref:           goStr(v.ref),
					Kind:          Kind(v.kind),
					ID:            goStr(v.id),
					Action:        PushAction(v.action),
					Accept:        bool(v.accept),
					Problems:      goProblems(v.problems),
					NeedsNumber:   bool(v.needs_number),
					TouchesLocked: bool(v.touches_locked),
					CommitCount:   int(v.commit_count),
				}
				for k := C.size_t(0); k < v.entry_count; k++ {
					out.Entries = append(out.Entries, goEntry(C.issuez_push_verdict_entry_at(v, k)))
				}
				if v.issue_author != nil {
					p := goPerson(v.issue_author)
					out.IssueAuthor = &p
				}
				for k := C.size_t(0); k < v.attachment_count; k++ {
					out.Attachments = append(out.Attachments, goAttachment(C.issuez_push_verdict_attachment_at(v, k)))
				}
				verdicts = append(verdicts, out)
			}
		}
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		return nil
	})
	return verdicts, err
}

// ─── Sync status and search ────────────────────────────────────────────

// QuarantineReason is why a remote version was refused.
type QuarantineReason uint32

const (
	// No longer applies; the next merge clears it.
	QuarantineCleared          QuarantineReason = C.ISSUEZ_QUARANTINE_UNKNOWN
	QuarantineUnrelatedHistory QuarantineReason = C.ISSUEZ_QUARANTINE_UNRELATED_HISTORY
	QuarantineRewound          QuarantineReason = C.ISSUEZ_QUARANTINE_REWOUND
	QuarantineInvalidIssue     QuarantineReason = C.ISSUEZ_QUARANTINE_INVALID_ISSUE
)

// SyncStatus is a remote's sync state without the network.
type SyncStatus struct {
	Quarantined []Quarantined
	// Issues not pushed yet, quarantined ones left out.
	Pending []string
}

// SyncStatus says what is quarantined from remote and not pushed to it.
func (r *Repo) SyncStatus(ctx context.Context, remote string) (*SyncStatus, error) {
	var st *SyncStatus
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_sync_status
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_sync_status_take(c, cStr(remote), tok, &h, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_sync_status_free(h)
		st = &SyncStatus{}
		for i := C.size_t(0); i < C.issuez_sync_status_quarantined_count(h); i++ {
			q := C.issuez_sync_status_quarantined_at(h, i)
			st.Quarantined = append(st.Quarantined, goQuarantined(q))
		}
		st.Pending = goStrs(C.issuez_sync_status_pending_count(h), func(i C.size_t) C.issuez_str {
			return C.issuez_sync_status_pending_at(h, i)
		})
		return nil
	})
	return st, err
}

// SearchOptions shape Search.
type SearchOptions struct {
	IgnoreCase bool // ASCII only
}

// Search finds the lines of what each live issue says now (title, fields,
// description, comments) that contain needle, as git issue search does.
func (r *Repo) Search(ctx context.Context, needle string, opts SearchOptions) ([]SearchHit, error) {
	var hits []SearchHit
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_search_hits
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_search(c, cStr(needle), flagIf(opts.IgnoreCase, C.ISSUEZ_SEARCH_FLAG_IGNORE_CASE), tok, &h, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_search_hits_free(h)
		for i := C.size_t(0); i < C.issuez_search_hits_len(h); i++ {
			x := C.issuez_search_hits_at(h, i)
			hits = append(hits, goSearchHit(x))
		}
		return nil
	})
	return hits, err
}

// ─── Remote setup ──────────────────────────────────────────────────────

// RemoteOptions shape ConfigureRemote.
type RemoteOptions struct {
	// FixUnsafe takes out upstream's forced refspec, which lets a plain
	// git fetch overwrite local issue refs.
	FixUnsafe bool
}

// RemoteSetup is what ConfigureRemote found and did.
type RemoteSetup struct {
	// The refspecs were added now; false when they were there.
	Configured bool
	// Upstream's forced refspec was taken out (FixUnsafe).
	RemovedUnsafe bool
	// The remote still has upstream's forced refspec: a plain git fetch
	// can overwrite local issue refs.
	Unsafe bool
}

// DefaultRemotes are the remotes to set up when none is named, as git
// issue init picks them: the only remote, else origin, else every remote;
// none when the repository has none.
func (r *Repo) DefaultRemotes(ctx context.Context) ([]string, error) {
	var names []string
	err := r.use(func(c *C.issuez_repo) error {
		var m *C.issuez_matches
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code { return C.issuez_remote_default(c, tok, &m, &cerr) }); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_matches_free(m)
		names = goStrs(C.issuez_matches_len(m), func(i C.size_t) C.issuez_str { return C.issuez_matches_at(m, i) })
		return nil
	})
	return names, err
}

// ConfigureRemote adds the fetch refspecs that bring remote's issues,
// milestones and attachment refs into refs/remotes/<remote>/, as git issue
// init does; idempotent. Sync works without it.
func (r *Repo) ConfigureRemote(ctx context.Context, remote string, opts RemoteOptions) (RemoteSetup, error) {
	var setup RemoteSetup
	err := r.use(func(c *C.issuez_repo) error {
		var out C.issuez_remote_setup
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_remote_configure(c, cStr(remote), flagIf(opts.FixUnsafe, C.ISSUEZ_REMOTE_FLAG_FIX_UNSAFE), tok, &out, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		setup = RemoteSetup{Configured: bool(out.configured), RemovedUnsafe: bool(out.removed_unsafe), Unsafe: bool(out.unsafe)}
		return nil
	})
	return setup, err
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
	FsckRepaired          FsckKind = C.ISSUEZ_FSCK_REPAIRED
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

// FsckOptions shape Fsck.
type FsckOptions struct {
	// Repair rewrites missing or stale derived attachment refs, nothing
	// else.
	Repair bool
}

// Fsck checks the issue data as git issue fsck does.
func (r *Repo) Fsck(ctx context.Context, opts FsckOptions) (*FsckReport, error) {
	var rep *FsckReport
	err := r.use(func(c *C.issuez_repo) error {
		var h *C.issuez_fsck_report
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_fsck(c, flagIf(opts.Repair, C.ISSUEZ_FSCK_FLAG_REPAIR), tok, &h, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_fsck_report_free(h)
		rep = &FsckReport{
			Issues:     int(C.issuez_fsck_report_issue_count(h)),
			Milestones: int(C.issuez_fsck_report_milestone_count(h)),
			Errors:     int(C.issuez_fsck_report_error_count(h)),
		}
		for i := C.size_t(0); i < C.issuez_fsck_report_len(h); i++ {
			f := C.issuez_fsck_report_at(h, i)
			rep.Findings = append(rep.Findings, goFsckFinding(f))
		}
		return nil
	})
	return rep, err
}

// LoadMilestoneAt reads the milestone at an exact, nonzero historical tip.
func (r *Repo) LoadMilestoneAt(ctx context.Context, id string, tip OID) (*Milestone, error) {
	var m *Milestone
	if tip.IsZero() {
		return nil, &Error{Code: CodeInvalidArgument, Message: "tip is zero"}
	}
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		var out *C.issuez_milestone
		var cerr *C.issuez_error
		ct := optOID(&pin, tip)
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_milestone_load_at(c, cStr(id), ct, tok, &out, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_milestone_free(out)
		m = goMilestone(out)
		return nil
	})
	return m, err
}
