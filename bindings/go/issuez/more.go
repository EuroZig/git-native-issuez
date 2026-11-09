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

// ProjectionOptions shape Projection.
type ProjectionOptions struct {
	// Around is an issue's UUID: project only what its answers need (the
	// issue, its ancestors, descendants and blockers). Cheaper, with the
	// same answers for that issue but Blocking, which needs every issue.
	// "" projects every issue.
	Around string
}

// Projection is a copy of the projection, its handle freed at once.
func (r *Repo) Projection(ctx context.Context, opts ProjectionOptions) (*Projection, error) {
	return fetch(ctx, r, func(a cArgs, h **C.issuez_projection) C.issuez_code {
		if opts.Around == "" {
			return C.issuez_projection_build(a.repo, a.tok, h, a.cerr)
		}
		return C.issuez_projection_around(a.repo, cStr(opts.Around), a.tok, h, a.cerr)
	}, func(h *C.issuez_projection) *Projection {
		defer C.issuez_projection_free(h)
		return goProjection(h)
	})
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
	var ops []op
	if opts.NoPush {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_SYNC_PUSH, num: 0})
	}
	if opts.NoAttachments {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_SYNC_ATTACHMENTS, num: 0})
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	cops, n := cOps(&pin, ops)
	return fetch(ctx, r, func(a cArgs, h **C.issuez_sync_report) C.issuez_code {
		return C.issuez_sync(a.repo, cStr(remote), cops, n, a.tok, h, a.cerr)
	}, func(h *C.issuez_sync_report) *SyncReport {
		defer C.issuez_sync_report_free(h)
		return &SyncReport{
			OK: bool(C.issuez_sync_report_ok(h)),
			Items: goList(C.issuez_sync_report_len(h), func(i C.size_t) SyncItem {
				return goSyncItem(C.issuez_sync_report_at(h, i))
			}),
		}
	})
}

// ─── Purge ─────────────────────────────────────────────────────────────

// PurgeResult says what a purge left.
type PurgeResult struct {
	// The issue's new tip after a comment purge; zero when the issue is gone.
	NewTip OID
	// Remotes that had the purged commits, one synced by URL or path as the
	// url-<hash> its refs are kept under. The next Sync with each replaces
	// their copy.
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
	return fetch(ctx, r, func(a cArgs, h **C.issuez_sync_status) C.issuez_code {
		return C.issuez_sync_status_take(a.repo, cStr(remote), a.tok, h, a.cerr)
	}, func(h *C.issuez_sync_status) *SyncStatus {
		defer C.issuez_sync_status_free(h)
		return &SyncStatus{
			Quarantined: goList(C.issuez_sync_status_quarantined_count(h), func(i C.size_t) Quarantined {
				return goQuarantined(C.issuez_sync_status_quarantined_at(h, i))
			}),
			Pending: goStrs(C.issuez_sync_status_pending_count(h), func(i C.size_t) C.issuez_str {
				return C.issuez_sync_status_pending_at(h, i)
			}),
		}
	})
}

// SearchOptions shape Search.
type SearchOptions struct {
	IgnoreCase bool // ASCII only
}

// Search finds the lines of what each live issue says now (title, fields,
// description, comments) that contain needle, as git issue search does.
func (r *Repo) Search(ctx context.Context, needle string, opts SearchOptions) ([]SearchHit, error) {
	return fetch(ctx, r, func(a cArgs, h **C.issuez_search_hits) C.issuez_code {
		return C.issuez_search(a.repo, cStr(needle), flagIf(opts.IgnoreCase, C.ISSUEZ_SEARCH_FLAG_IGNORE_CASE), a.tok, h, a.cerr)
	}, func(h *C.issuez_search_hits) []SearchHit {
		defer C.issuez_search_hits_free(h)
		return goList(C.issuez_search_hits_len(h), func(i C.size_t) SearchHit {
			return goSearchHit(C.issuez_search_hits_at(h, i))
		})
	})
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
	return fetch(ctx, r, func(a cArgs, m **C.issuez_matches) C.issuez_code {
		return C.issuez_remote_default(a.repo, a.tok, m, a.cerr)
	}, takeMatches)
}

// ConfigureRemote adds the fetch refspecs that bring remote's issues,
// milestones and attachment refs into refs/remotes/<remote>/, as git issue
// init does; idempotent. Sync works without it.
func (r *Repo) ConfigureRemote(ctx context.Context, remote string, opts RemoteOptions) (RemoteSetup, error) {
	return fetch(ctx, r, func(a cArgs, out *C.issuez_remote_setup) C.issuez_code {
		return C.issuez_remote_configure(a.repo, cStr(remote), flagIf(opts.FixUnsafe, C.ISSUEZ_REMOTE_FLAG_FIX_UNSAFE), a.tok, out, a.cerr)
	}, func(out C.issuez_remote_setup) RemoteSetup {
		return RemoteSetup{Configured: bool(out.configured), RemovedUnsafe: bool(out.removed_unsafe), Unsafe: bool(out.unsafe)}
	})
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
	return fetch(ctx, r, func(a cArgs, h **C.issuez_fsck_report) C.issuez_code {
		return C.issuez_fsck(a.repo, flagIf(opts.Repair, C.ISSUEZ_FSCK_FLAG_REPAIR), a.tok, h, a.cerr)
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
