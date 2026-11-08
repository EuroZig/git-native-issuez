package issuez

/*
#include "issuez.h"
*/
import "C"

import (
	"context"
	"runtime"
	"time"
	"unsafe"
)

// Issue is a loaded issue, copied out of the library. Safe to keep and
// share; LoadJSON is its documented JSON form.
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
	MilestoneID string // direct only; see Projection for the effective one
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
	}
	if e.comment != nil {
		out.Comment = goOID(e.comment.id)
		p := goPerson(e.comment.author)
		out.CommentAuthor = &p
	}
	for i := C.size_t(0); i < e.change_count; i++ {
		c := C.issuez_entry_change_at(e, i)
		ch := Change{
			Field: Field(c.field), Key: goStr(c.key), Op: Verb(c.op),
			Old: goStr(c.old_value), New: goStr(c.new_value),
			OldDone: bool(c.old_done), NewDone: bool(c.new_done), Reason: goStr(c.reason),
		}
		if c.old_person != nil {
			p := goPerson(c.old_person)
			ch.OldPerson = &p
		}
		if c.new_person != nil {
			p := goPerson(c.new_person)
			ch.NewPerson = &p
		}
		if c.old_date.year != 0 {
			d := goDate(c.old_date)
			ch.OldDate = &d
		}
		if c.new_date.year != 0 {
			d := goDate(c.new_date)
			ch.NewDate = &d
		}
		out.Changes = append(out.Changes, ch)
	}
	return out
}

func goCommentReactions(c *C.issuez_comment) []Reaction {
	n := C.issuez_comment_reaction_count(c)
	if n == 0 {
		return nil
	}
	out := make([]Reaction, n)
	for k := range out {
		r := C.issuez_comment_reaction_at(c, C.size_t(k))
		out[k].Emoji = goStr(r.emoji)
		for u := C.size_t(0); u < r.user_count; u++ {
			out[k].Users = append(out[k].Users, goPerson(C.issuez_reaction_user_at(r, u)))
		}
	}
	return out
}

func goReactions(i *C.issuez_issue, comment *C.issuez_oid) []Reaction {
	n := C.issuez_issue_reaction_count(i, comment)
	if n == 0 {
		return nil
	}
	out := make([]Reaction, n)
	for k := range out {
		r := C.issuez_issue_reaction_at(i, comment, C.size_t(k))
		out[k].Emoji = goStr(r.emoji)
		for u := C.size_t(0); u < r.user_count; u++ {
			out[k].Users = append(out[k].Users, goPerson(C.issuez_reaction_user_at(r, u)))
		}
	}
	return out
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
	out := &Issue{
		ID:             goStr(C.issuez_issue_id(i)),
		Tip:            goOID(C.issuez_issue_tip(i)),
		FormatVersion:  goStr(C.issuez_issue_format_version(i)),
		CommitCount:    int(C.issuez_issue_commit_count(i)),
		Title:          goStr(C.issuez_issue_title(i)),
		Description:    goStr(C.issuez_issue_description(i)),
		Author:         goPerson(C.issuez_issue_author(i)),
		Created:        goTime(C.issuez_issue_created(i)),
		Updated:        goTime(C.issuez_issue_updated(i)),
		State:          State(goStr(C.issuez_issue_state_name(i))),
		Done:           bool(C.issuez_issue_is_done(i)),
		WorkflowState:  goStr(C.issuez_issue_workflow_state(i)),
		Deleted:        bool(C.issuez_issue_is_deleted(i)),
		Locked:         bool(C.issuez_issue_is_locked(i)),
		LockReason:     goStr(C.issuez_issue_lock_reason(i)),
		Priority:       Priority(C.issuez_issue_priority(i)),
		MilestoneID:    goStr(C.issuez_issue_milestone_id(i)),
		ParentID:       goStr(C.issuez_issue_parent_id(i)),
		Ref:            goStr(C.issuez_issue_ref(i)),
		OriginalAuthor: goStr(C.issuez_issue_original_author(i)),
		OriginalID:     goStr(C.issuez_issue_original_id(i)),
		Problems:       goProblems(C.issuez_issue_problems(i)),
		Edits:          goEdits(i, nil),
	}
	var num C.uint64_t
	if C.issuez_issue_number(i, &num) {
		out.Number = uint64(num)
	}
	var at C.issuez_time
	var by *C.issuez_person
	if C.issuez_issue_closed(i, &at, &by) {
		out.Closed = &Closure{
			At: goTime(at), By: goPerson(by),
			FixedBy: goStr(C.issuez_issue_fixed_by(i)),
			Release: goStr(C.issuez_issue_release(i)),
			Reason:  goStr(C.issuez_issue_reason(i)),
		}
	}
	out.Labels = goStrs(C.issuez_issue_label_count(i), func(k C.size_t) C.issuez_str { return C.issuez_issue_label_at(i, k) })
	out.BlockedBy = goStrs(C.issuez_issue_blocker_count(i), func(k C.size_t) C.issuez_str { return C.issuez_issue_blocker_at(i, k) })
	for k, n := C.size_t(0), C.issuez_issue_assignee_count(i); k < n; k++ {
		out.Assignees = append(out.Assignees, goPerson(C.issuez_issue_assignee_at(i, k)))
	}
	var d C.issuez_date
	if C.issuez_issue_start_date(i, &d) {
		v := goDate(d)
		out.StartDate = &v
	}
	if C.issuez_issue_due_date(i, &d) {
		v := goDate(d)
		out.DueDate = &v
	}
	var est C.uint32_t
	if C.issuez_issue_estimate_minutes(i, &est) {
		out.Estimate = time.Duration(est) * time.Minute
	}
	if n := C.issuez_issue_extra_count(i); n > 0 {
		out.Extra = make(map[string]string, int(n))
		for k := C.size_t(0); k < n; k++ {
			var key, value C.issuez_str
			C.issuez_issue_extra_at(i, k, &key, &value)
			out.Extra[goStr(key)] = goStr(value)
		}
	}
	out.Reactions = goReactions(i, nil)
	for k, n := C.size_t(0), C.issuez_issue_comment_count(i); k < n; k++ {
		c := C.issuez_issue_comment_at(i, k)
		cm := Comment{
			ID: goOID(c.id), Author: goPerson(c.author),
			Created: goTime(c.created), Updated: goTime(c.updated),
			Text: goStr(c.text), Edited: bool(c.edited), Deleted: bool(c.deleted),
			OriginalAuthor: goStr(c.original_author), OriginalID: goStr(c.original_id),
			Purged:    bool(c.purged),
			Reactions: goCommentReactions(c),
			Edits:     goEdits(i, &c.id),
		}
		cm.AttachmentIDs = goStrs(c.attachment_count, func(k C.size_t) C.issuez_str { return C.issuez_comment_attachment_at(c, k) })
		if history {
			cm.History = goHistory(i, &c.id)
		}
		out.Comments = append(out.Comments, cm)
	}
	for k, n := C.size_t(0), C.issuez_issue_attachment_count(i); k < n; k++ {
		out.Attachments = append(out.Attachments, goAttachment(C.issuez_issue_attachment_at(i, k)))
	}
	for k, n := C.size_t(0), C.issuez_issue_timeline_count(i); k < n; k++ {
		out.Timeline = append(out.Timeline, goEntry(C.issuez_issue_timeline_at(i, k)))
	}
	if history {
		out.History = goHistory(i, nil)
	}
	return out
}

func goIssues(l *C.issuez_issue_list, history bool) (issues []*Issue, skipped []string) {
	n := C.issuez_issue_list_len(l)
	issues = make([]*Issue, 0, int(n))
	for k := C.size_t(0); k < n; k++ {
		issues = append(issues, goIssue(C.issuez_issue_list_at(l, k), history))
	}
	skipped = goStrs(C.issuez_issue_list_skipped_count(l), func(k C.size_t) C.issuez_str {
		return C.issuez_issue_list_skipped_at(l, k)
	})
	return issues, skipped
}

// ─── Loading ───────────────────────────────────────────────────────────

// LoadOption tunes what Load copies out.
type LoadOption func(*loadOpts)
type loadOpts struct {
	history bool
	strict  bool
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

// Strict makes LoadMany fail on a missing or damaged issue instead of
// skipping it.
func Strict() LoadOption { return func(o *loadOpts) { o.strict = true } }

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
	var issue *Issue
	o := loadOptions(opts)
	err := r.use(func(c *C.issuez_repo) error {
		var i *C.issuez_issue
		var cerr *C.issuez_error
		var pin runtime.Pinner
		defer pin.Unpin()
		since := optOID(&pin, o.since)
		at := optOID(&pin, o.at)
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			if at != nil {
				return C.issuez_issue_load_at(c, cStr(id), at, since, tok, &i, &cerr)
			}
			if since != nil {
				return C.issuez_issue_load_since(c, cStr(id), since, tok, &i, &cerr)
			}
			return C.issuez_issue_load(c, cStr(id), tok, &i, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_issue_free(i)
		issue = goIssue(i, o.history)
		issue.Rewritten = bool(C.issuez_issue_rewritten(i))
		return nil
	})
	return issue, err
}

// LoadMany reads several issues in the order of ids. Missing and damaged
// ones are skipped and listed, unless Strict.
func (r *Repo) LoadMany(ctx context.Context, ids []string, opts ...LoadOption) (issues []*Issue, skipped []string, err error) {
	o := loadOptions(opts)
	err = r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		cids, n := cStrs(&pin, ids)
		var l *C.issuez_issue_list
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_issue_load_many(c, cids, n, flagIf(o.strict, C.ISSUEZ_LOAD_FLAG_STRICT), tok, &l, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_issue_list_free(l)
		issues, skipped = goIssues(l, o.history)
		return nil
	})
	return issues, skipped, err
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
	if q.Order != 0 {
		ops = append(ops, op{verb: VerbSet, target: C.ISSUEZ_OPT_Q_ORDER, num: int64(q.Order), num2: b2i(q.Ascending)})
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
	var page Page
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		ops, n := cOps(&pin, q.ops())
		var l *C.issuez_issue_list
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_query_run(c, ops, n, tok, &l, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_issue_list_free(l)
		page.Issues, page.Skipped = goIssues(l, false)
		page.Next = goStr(C.issuez_issue_list_next_cursor(l))
		return nil
	})
	return page, err
}

// Count is the number of matches, ignoring Limit and After.
func (r *Repo) Count(ctx context.Context, q Query) (int, error) {
	var count int
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		ops, n := cOps(&pin, q.ops())
		var out C.uint64_t
		var cerr *C.issuez_error
		rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_query_count(c, ops, n, tok, &out, &cerr)
		})
		if rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		count = int(out)
		return nil
	})
	return count, err
}

// ─── Across issues ─────────────────────────────────────────────────────

// LabelCounts is every label in use, by name; deleted issues don't count.
func (r *Repo) LabelCounts(ctx context.Context) ([]LabelCount, error) {
	var out []LabelCount
	err := r.use(func(c *C.issuez_repo) error {
		var l *C.issuez_label_counts
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code { return C.issuez_label_counts_take(c, tok, &l, &cerr) }); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_label_counts_free(l)
		for i := C.size_t(0); i < C.issuez_label_counts_len(l); i++ {
			x := C.issuez_label_counts_at(l, i)
			out = append(out, goLabelCount(x))
		}
		return nil
	})
	return out, err
}

// People is everyone who opened or is assigned an issue, by email.
func (r *Repo) People(ctx context.Context) ([]KnownPerson, error) {
	var out []KnownPerson
	err := r.use(func(c *C.issuez_repo) error {
		var p *C.issuez_people
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code { return C.issuez_people_take(c, tok, &p, &cerr) }); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_people_free(p)
		for i := C.size_t(0); i < C.issuez_people_len(p); i++ {
			x := C.issuez_people_at(p, i)
			out = append(out, goKnownPerson(x))
		}
		return nil
	})
	return out, err
}

// ShortIDs maps every issue's UUID to its shortest unique prefix, at
// least minLen long: what a list shows so that Resolve takes it.
func (r *Repo) ShortIDs(ctx context.Context, minLen int) (map[string]string, error) {
	var out map[string]string
	err := r.use(func(c *C.issuez_repo) error {
		var s *C.issuez_short_ids
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_short_ids_take(c, C.size_t(minLen), tok, &s, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_short_ids_free(s)
		n := C.issuez_short_ids_len(s)
		out = make(map[string]string, int(n))
		for i := C.size_t(0); i < n; i++ {
			x := C.issuez_short_ids_at(s, i)
			out[goStr(x.id)] = goStr(x.prefix)
		}
		return nil
	})
	return out, err
}

// ─── JSON ──────────────────────────────────────────────────────────────

// JSONOptions shape LoadJSON and LoadManyJSON.
type JSONOptions struct {
	// Full adds the description, comments and history, as show does.
	Full bool
}

// LoadJSON is the issue as git issue show --json writes it (docs/json.md):
// for a host that passes it on, to a web client say, without its own
// encoding.
func (r *Repo) LoadJSON(ctx context.Context, id string, opts JSONOptions) ([]byte, error) {
	var data []byte
	err := r.use(func(c *C.issuez_repo) error {
		var b *C.issuez_bytes
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_issue_json(c, cStr(id), flagIf(opts.Full, C.ISSUEZ_JSON_FLAG_FULL), tok, &b, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_bytes_free(b)
		d := C.issuez_bytes_data(b)
		data = C.GoBytes(unsafe.Pointer(d.ptr), C.int(d.len))
		return nil
	})
	return data, err
}

// LoadManyJSON is a JSON array of the issues with ids, in their order
// (none: every issue that isn't deleted), each in LoadJSON's form;
// missing and damaged ones are left out.
func (r *Repo) LoadManyJSON(ctx context.Context, ids []string, opts JSONOptions) ([]byte, error) {
	var data []byte
	err := r.use(func(c *C.issuez_repo) error {
		var pin runtime.Pinner
		defer pin.Unpin()
		cids, n := cStrs(&pin, ids)
		var b *C.issuez_bytes
		var cerr *C.issuez_error
		if rc := call(ctx, func(tok *C.issuez_cancel) C.issuez_code {
			return C.issuez_issue_json_many(c, cids, n, flagIf(opts.Full, C.ISSUEZ_JSON_FLAG_FULL), tok, &b, &cerr)
		}); rc != C.ISSUEZ_OK {
			return takeError(ctx, cerr)
		}
		defer C.issuez_bytes_free(b)
		d := C.issuez_bytes_data(b)
		data = C.GoBytes(unsafe.Pointer(d.ptr), C.int(d.len))
		return nil
	})
	return data, err
}
