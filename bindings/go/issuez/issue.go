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

// Issue is a loaded issue, copied out of the library. Safe to keep and
// share.
type Issue struct {
	ID            string
	Tip           OID    // pass to ExpectTip
	Number        uint64 // 0: not assigned yet
	FormatVersion string
	CommitCount   int

	Title       string
	Description string
	Author      Person
	Created     time.Time
	Updated     time.Time

	State         State  // "open", "closed", "wontfix", ...
	Done          bool   // closed or a done state of the repo
	WorkflowState string // "" when done
	Closed        *Closure
	Deleted       bool
	Locked        bool
	LockReason    string

	Priority    Priority
	Labels      []string
	Assignees   []Person
	MilestoneID string // direct only, not one inherited from a parent
	ParentID    string
	BlockedBy   []string
	StartDate   *Date
	DueDate     *Date
	Estimate    time.Duration // whole minutes; 0: none
	Ref         string
	// An imported issue's author and ID in the other tracker.
	OriginalAuthor string
	OriginalID     string
	Extra          map[string]string

	Reactions []Reaction
	Comments  []Comment
	// Present ones first, oldest first, then the removed ones.
	Attachments []Attachment
	Timeline    []Entry
	// Description versions, oldest first; only with LoadHistory.
	History []Revision
	// How often the description was edited, with or without LoadHistory:
	// a version number for optimistic locking in a host's forms.
	Edits int
	// Invalid values, unresolved events, merge conflicts.
	Problems []Problem
	// Loaded with Since, whose tip isn't in the history (a purge rewrote
	// it): no entry is New, and what is new can't be told.
	Rewritten bool
}

// Closure is how a done issue was closed.
type Closure struct {
	At      time.Time
	By      Person
	FixedBy string
	Release string
	Reason  string
}

// Comment is one comment on an issue, deleted and purged ones too.
type Comment struct {
	ID            OID
	Author        Person
	Created       time.Time
	Updated       time.Time
	Text          string
	Edited        bool
	Deleted       bool
	AttachmentIDs []string
	// An imported comment's author and ID in the other tracker.
	OriginalAuthor string
	OriginalID     string
	// A purge took its text, attachments and origin; its fields stay.
	Purged    bool
	Reactions []Reaction
	History   []Revision // only with LoadHistory
	// How often its text was edited, with or without LoadHistory.
	Edits int
}

// Reaction is one emoji and who reacted with it.
type Reaction struct {
	Emoji string
	Users []Person
}

// Revision is one version of the description or a comment.
type Revision struct {
	Commit OID
	Author Person
	At     time.Time
	Kind   RevisionKind
	// The whole text after it; for a delete or restore, what it hid or
	// showed again.
	Text string
	// The text before it: the last original or edit's; "" for the
	// original.
	Previous string
}

// RevisionKind is what a Revision did to its text.
type RevisionKind uint32

const (
	RevisionOriginal RevisionKind = C.ISSUEZ_REVISION_ORIGINAL
	RevisionEdit     RevisionKind = C.ISSUEZ_REVISION_EDIT
	RevisionDelete   RevisionKind = C.ISSUEZ_REVISION_DELETE
	RevisionRestore  RevisionKind = C.ISSUEZ_REVISION_RESTORE
)

// EntryKind is what a timeline Entry's commit did.
type EntryKind uint32

const (
	EntryCreated         EntryKind = C.ISSUEZ_ENTRY_CREATED
	EntryComment         EntryKind = C.ISSUEZ_ENTRY_COMMENT
	EntryUpdate          EntryKind = C.ISSUEZ_ENTRY_UPDATE
	EntryDescriptionEdit EntryKind = C.ISSUEZ_ENTRY_DESCRIPTION_EDIT
	EntryCommentEdit     EntryKind = C.ISSUEZ_ENTRY_COMMENT_EDIT
	EntryCommentDelete   EntryKind = C.ISSUEZ_ENTRY_COMMENT_DELETE
	EntryCommentRestore  EntryKind = C.ISSUEZ_ENTRY_COMMENT_RESTORE
	EntryReaction        EntryKind = C.ISSUEZ_ENTRY_REACTION
	EntryMerge           EntryKind = C.ISSUEZ_ENTRY_MERGE
)

// Entry is one commit of the timeline.
type Entry struct {
	Kind    EntryKind
	Commit  OID
	Author  Person
	At      time.Time
	Comment OID // the comment it adds or targets; zero otherwise
	// That comment's author: whose comment an edit, delete or restore
	// touches.
	CommentAuthor *Person
	Changes       []Change
	// Not reachable from the tip given to Since; true without Since.
	New bool
}

// Change is one field change: Set (Old -> New), Clear, Add (New), Remove
// (Old). One per field, or per member of a set, whichever trailers said
// it. Old is the value before even when the commit didn't say it (a
// first title change: the root's subject; a first state: "open").
type Change struct {
	Field Field
	Key   string
	Op    Verb
	Old   string
	New   string
	// FieldAssignees: the member, parsed.
	OldPerson, NewPerson *Person
	// FieldStartDate, FieldDueDate: parsed; nil for none.
	OldDate, NewDate *Date
	// FieldState: whether each state is done, by the repo's done states.
	OldDone, NewDone bool
	// FieldLocked: the lock's reason as of this commit.
	Reason string
}

// ─── Copying out ───────────────────────────────────────────────────────

func goEntry(e *C.issuez_entry) Entry {
	out := Entry{
		Kind:   EntryKind(e.kind),
		Commit: goOID(e.commit),
		Author: goPerson(e.author),
		At:     goTime(e.at),
		New:    bool(e.is_new),
		Changes: goList(e.change_count, func(i C.size_t) Change {
			return goChange(C.issuez_entry_change_at(e, i))
		}),
	}
	if e.comment != nil {
		out.Comment = goOID(e.comment.id)
		out.CommentAuthor = new(goPerson(e.comment.author))
	}
	return out
}

func goChange(c *C.issuez_change) Change {
	return Change{
		Field: Field(c.field), Key: goStr(c.key), Op: Verb(c.op),
		Old: goStr(c.old_value), New: goStr(c.new_value),
		OldPerson: goOptPerson(c.old_person), NewPerson: goOptPerson(c.new_person),
		OldDate: goOptDate(c.old_date), NewDate: goOptDate(c.new_date),
		OldDone: bool(c.old_done), NewDone: bool(c.new_done), Reason: goStr(c.reason),
	}
}

func goReaction(r *C.issuez_reaction) Reaction {
	return Reaction{Emoji: goStr(r.emoji), Users: goList(r.user_count, func(u C.size_t) Person {
		return goPerson(C.issuez_reaction_user_at(r, u))
	})}
}

func goReactions(i *C.issuez_issue, comment *C.issuez_oid) []Reaction {
	return goList(C.issuez_issue_reaction_count(i, comment), func(k C.size_t) Reaction {
		return goReaction(C.issuez_issue_reaction_at(i, comment, k))
	})
}

// goEdits counts the edit revisions without copying their texts.
func goEdits(i *C.issuez_issue, comment *C.issuez_oid) int {
	n := C.issuez_issue_history_count(i, comment)
	edits := 0
	for k := C.size_t(0); k < n; k++ {
		if RevisionKind(C.issuez_issue_history_at(i, comment, k).kind) == RevisionEdit {
			edits++
		}
	}
	return edits
}

func goHistory(i *C.issuez_issue, comment *C.issuez_oid) []Revision {
	n := C.issuez_issue_history_count(i, comment)
	out := make([]Revision, 0, int(n))
	prev := ""
	for k := C.size_t(0); k < n; k++ {
		v := C.issuez_issue_history_at(i, comment, k)
		rev := Revision{
			Commit: goOID(v.commit), Author: goPerson(v.author), At: goTime(v.at),
			Kind: RevisionKind(v.kind), Text: goStr(v.text), Previous: prev,
		}
		if rev.Kind == RevisionOriginal || rev.Kind == RevisionEdit {
			prev = rev.Text
		}
		out = append(out, rev)
	}
	return out
}

func goIssue(i *C.issuez_issue, history bool) *Issue {
	r := C.issuez_issue_info_of(i)
	out := &Issue{
		ID:             goStr(r.id),
		Tip:            goOID(r.tip),
		Number:         uint64(r.number),
		FormatVersion:  goStr(r.format_version),
		CommitCount:    int(r.commit_count),
		Title:          goStr(r.title),
		Description:    goStr(r.description),
		Author:         goPerson(r.author),
		Created:        goTime(r.created),
		Updated:        goTime(r.updated),
		State:          State(goStr(r.state_name)),
		Done:           bool(r.is_done),
		WorkflowState:  goStr(r.workflow_state),
		Deleted:        bool(r.is_deleted),
		Locked:         bool(r.is_locked),
		LockReason:     goStr(r.lock_reason),
		Priority:       Priority(r.priority),
		MilestoneID:    goStr(r.milestone_id),
		ParentID:       goStr(r.parent_id),
		StartDate:      goOptDate(r.start_date),
		DueDate:        goOptDate(r.due_date),
		Estimate:       time.Duration(r.estimate_minutes) * time.Minute,
		Ref:            goStr(r.ref),
		OriginalAuthor: goStr(r.original_author),
		OriginalID:     goStr(r.original_id),
		Problems:       goProblems(C.issuez_issue_problems(i)),
		Edits:          goEdits(i, nil),
		Rewritten:      bool(r.rewritten),
	}
	if r.closed_by != nil {
		out.Closed = &Closure{
			At: goTime(r.closed_at), By: goPerson(r.closed_by),
			FixedBy: goStr(r.fixed_by),
			Release: goStr(r.release),
			Reason:  goStr(r.reason),
		}
	}
	out.Labels = goStrs(C.issuez_issue_label_count(i), func(k C.size_t) C.issuez_str { return C.issuez_issue_label_at(i, k) })
	out.BlockedBy = goStrs(C.issuez_issue_blocker_count(i), func(k C.size_t) C.issuez_str { return C.issuez_issue_blocker_at(i, k) })
	out.Assignees = goList(C.issuez_issue_assignee_count(i), func(k C.size_t) Person {
		return goPerson(C.issuez_issue_assignee_at(i, k))
	})
	if n := C.issuez_issue_extra_count(i); n > 0 {
		out.Extra = make(map[string]string, int(n))
		for k := C.size_t(0); k < n; k++ {
			var key, value C.issuez_str
			C.issuez_issue_extra_at(i, k, &key, &value)
			out.Extra[goStr(key)] = goStr(value)
		}
	}
	out.Reactions = goReactions(i, nil)
	out.Comments = goList(C.issuez_issue_comment_count(i), func(k C.size_t) Comment {
		c := C.issuez_issue_comment_at(i, k)
		cm := Comment{
			ID: goOID(c.id), Author: goPerson(c.author),
			Created: goTime(c.created), Updated: goTime(c.updated),
			Text: goStr(c.text), Edited: bool(c.edited), Deleted: bool(c.deleted),
			OriginalAuthor: goStr(c.original_author), OriginalID: goStr(c.original_id),
			Purged:    bool(c.purged),
			Reactions: goReactions(i, &c.id),
			Edits:     goEdits(i, &c.id),
		}
		cm.AttachmentIDs = goStrs(c.attachment_count, func(k C.size_t) C.issuez_str { return C.issuez_comment_attachment_at(c, k) })
		if history {
			cm.History = goHistory(i, &c.id)
		}
		return cm
	})
	out.Attachments = goList(C.issuez_issue_attachment_count(i), func(k C.size_t) Attachment {
		return goAttachment(C.issuez_issue_attachment_at(i, k))
	})
	out.Timeline = goList(C.issuez_issue_timeline_count(i), func(k C.size_t) Entry {
		return goEntry(C.issuez_issue_timeline_at(i, k))
	})
	if history {
		out.History = goHistory(i, nil)
	}
	return out
}

func goIssues(l *C.issuez_issue_list) (issues []*Issue, skipped []string) {
	n := C.issuez_issue_list_len(l)
	issues = make([]*Issue, 0, int(n))
	for k := C.size_t(0); k < n; k++ {
		issues = append(issues, goIssue(C.issuez_issue_list_at(l, k), false))
	}
	skipped = goStrs(C.issuez_issue_list_skipped_count(l), func(k C.size_t) C.issuez_str {
		return C.issuez_issue_list_skipped_at(l, k)
	})
	return issues, skipped
}

// takePage copies and frees an owned list.
func takePage(l *C.issuez_issue_list) (p Page) {
	defer C.issuez_issue_list_free(l)
	p.Issues, p.Skipped = goIssues(l)
	p.Next = goStr(C.issuez_issue_list_next_cursor(l))
	return p
}

// ─── Loading ───────────────────────────────────────────────────────────

// LoadOption tunes what Load copies out.
type LoadOption func(*loadOpts)
type loadOpts struct {
	history bool
	since   OID
	at      OID
}

// LoadHistory also copies every version of the description and comments.
func LoadHistory() LoadOption { return func(o *loadOpts) { o.history = true } }

// Since marks the timeline entries a host that saw the issue at tip
// hasn't seen (Entry.New): commits tip doesn't reach, merged-in ones
// included. A tip outside the history sets Issue.Rewritten instead. Load
// only; the zero OID marks every entry new.
func Since(tip OID) LoadOption { return func(o *loadOpts) { o.since = tip } }

// CommentOf is the comment a timeline entry adds or targets; nil for
// entries without one.
func (i *Issue) CommentOf(e Entry) *Comment {
	if e.Comment.IsZero() {
		return nil
	}
	for k := range i.Comments {
		if i.Comments[k].ID == e.Comment {
			return &i.Comments[k]
		}
	}
	return nil
}

// NewEntries are the timeline entries marked New.
func (i *Issue) NewEntries() []Entry {
	var out []Entry
	for _, e := range i.Timeline {
		if e.New {
			out = append(out, e)
		}
	}
	return out
}

func loadOptions(opts []LoadOption) loadOpts {
	var o loadOpts
	for _, f := range opts {
		f(&o)
	}
	return o
}

// LoadAt reads an exact historical tip. The objects must still exist.
// Since and LoadHistory apply to this captured state, even if its ref moved.
func (r *Repo) LoadAt(ctx context.Context, id string, tip OID, opts ...LoadOption) (*Issue, error) {
	if tip.IsZero() {
		return nil, &Error{Code: CodeInvalidArgument, Message: "tip is zero"}
	}
	opts = append(append([]LoadOption(nil), opts...), func(o *loadOpts) { o.at = tip })
	return r.Load(ctx, id, opts...)
}

// Load reads one issue by full UUID (see ResolveOne for user input).
func (r *Repo) Load(ctx context.Context, id string, opts ...LoadOption) (*Issue, error) {
	o := loadOptions(opts)
	var pin runtime.Pinner
	defer pin.Unpin()
	since := optOID(&pin, o.since)
	at := optOID(&pin, o.at)
	return fetch(ctx, r, func(a cArgs, i **C.issuez_issue) C.issuez_code {
		if at != nil {
			return C.issuez_issue_load_at(a.repo, cStr(id), at, since, a.tok, i, a.cerr)
		}
		if since != nil {
			return C.issuez_issue_load_since(a.repo, cStr(id), since, a.tok, i, a.cerr)
		}
		return C.issuez_issue_load(a.repo, cStr(id), a.tok, i, a.cerr)
	}, func(i *C.issuez_issue) *Issue {
		defer C.issuez_issue_free(i)
		return goIssue(i, o.history)
	})
}

// ─── Query ─────────────────────────────────────────────────────────────

// Tri is a three-way filter; the zero value keeps the library's default.
type Tri int8

const (
	TriDefault Tri = iota
	TriYes
	TriNo
	TriAny
)

// Sort is a Query's order.
type Sort uint32

const (
	SortCreated  Sort = C.ISSUEZ_SORT_CREATED
	SortUpdated  Sort = C.ISSUEZ_SORT_UPDATED
	SortNumber   Sort = C.ISSUEZ_SORT_NUMBER
	SortPriority Sort = C.ISSUEZ_SORT_PRIORITY
	SortDueDate  Sort = C.ISSUEZ_SORT_DUE_DATE
	SortComments Sort = C.ISSUEZ_SORT_COMMENTS
	SortState    Sort = C.ISSUEZ_SORT_STATE
)

// Query is a filter as a plain struct. The zero value: open work, not
// deleted, newest first, 100 per page. Lists match any member (OR);
// different fields must all match.
type Query struct {
	Done, Deleted  Tri
	States         []string
	WorkflowStates []string
	Labels         []string // must have all
	NotLabels      []string
	NoLabels       bool
	Assignees      []string // email or user id; "" unassigned
	Authors        []string
	Priorities     []Priority
	Milestones     []string // effective; "" none
	Parent         string
	Blocked        Tri
	UpdatedAfter   time.Time
	UpdatedBefore  time.Time
	// Fixed-string match; hosts with a search index use that instead.
	Text           string
	TextIgnoreCase bool
	Order          Sort
	Ascending      bool
	Limit          int
	After          string // Page.Next of the previous page
}

func (q *Query) ops() []op {
	var ops []op
	tri := func(t Tri, target uint32) {
		if t != TriDefault {
			n := map[Tri]int64{TriYes: 1, TriNo: 0, TriAny: -1}[t]
			ops = append(ops, op{verb: VerbSet, target: target, num: n})
		}
	}
	adds := func(target uint32, vs []string, verb Verb) {
		for _, v := range vs {
			ops = append(ops, op{verb: verb, target: target, str: v})
		}
	}
	tri(q.Done, C.ISSUEZ_OPT_Q_DONE)
	tri(q.Deleted, C.ISSUEZ_OPT_Q_DELETED)
	tri(q.Blocked, C.ISSUEZ_OPT_Q_BLOCKED)
	adds(C.ISSUEZ_OPT_Q_STATE, q.States, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_WORKFLOW_STATE, q.WorkflowStates, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_LABEL, q.Labels, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_NOT_LABEL, q.NotLabels, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_ASSIGNEE, q.Assignees, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_AUTHOR, q.Authors, VerbAdd)
	adds(C.ISSUEZ_OPT_Q_MILESTONE, q.Milestones, VerbAdd)
	if q.NoLabels {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_NO_LABELS})
	}
	for _, p := range q.Priorities {
		ops = append(ops, op{verb: VerbAdd, target: C.ISSUEZ_OPT_Q_PRIORITY, num: int64(p)})
	}
	if q.Parent != "" {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_PARENT, str: q.Parent})
	}
	if !q.UpdatedAfter.IsZero() || !q.UpdatedBefore.IsZero() {
		o := op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_UPDATED}
		if !q.UpdatedAfter.IsZero() {
			o.num = q.UpdatedAfter.Unix()
		}
		if !q.UpdatedBefore.IsZero() {
			o.num2 = q.UpdatedBefore.Unix()
		}
		ops = append(ops, o)
	}
	if q.Text != "" {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_TEXT, str: q.Text, num: b2i(q.TextIgnoreCase)})
	}
	if q.Order != 0 || q.Ascending {
		// The library's default order is SortCreated.
		order := q.Order
		if order == 0 {
			order = SortCreated
		}
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_ORDER, num: int64(order), num2: b2i(q.Ascending)})
	}
	if q.Limit > 0 {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_LIMIT, num: int64(q.Limit)})
	}
	if q.After != "" {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_AFTER, str: q.After})
	}
	return ops
}

// Page is one page of a Query's matches.
type Page struct {
	Issues  []*Issue
	Skipped []string // matched but damaged
	Next    string   // "" on the last page
}

// Query runs q. Problem.Op indexes are internal to the binding here; use
// Problem.Field.
func (r *Repo) Query(ctx context.Context, q Query) (Page, error) {
	var pin runtime.Pinner
	defer pin.Unpin()
	ops, n := cOps(&pin, q.ops())
	return fetch(ctx, r, func(a cArgs, l **C.issuez_issue_list) C.issuez_code {
		return C.issuez_query_run(a.repo, ops, n, a.tok, l, a.cerr)
	}, takePage)
}
