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

//go:generate go run ./internal/enumgen/cmd enums_gen.go enums_gen_test.go

// Field is an issue or milestone field (ISSUEZ_FIELD_*), as used in
// writes, timeline changes and problems.
type Field uint32

const (
	FieldTitle           Field = C.ISSUEZ_FIELD_TITLE
	FieldDescription     Field = C.ISSUEZ_FIELD_DESCRIPTION
	FieldComment         Field = C.ISSUEZ_FIELD_COMMENT
	FieldState           Field = C.ISSUEZ_FIELD_STATE
	FieldWorkflowState   Field = C.ISSUEZ_FIELD_WORKFLOW_STATE
	FieldLabels          Field = C.ISSUEZ_FIELD_LABELS
	FieldAssignees       Field = C.ISSUEZ_FIELD_ASSIGNEES
	FieldPriority        Field = C.ISSUEZ_FIELD_PRIORITY
	FieldMilestone       Field = C.ISSUEZ_FIELD_MILESTONE
	FieldParent          Field = C.ISSUEZ_FIELD_PARENT
	FieldBlockedBy       Field = C.ISSUEZ_FIELD_BLOCKED_BY
	FieldStartDate       Field = C.ISSUEZ_FIELD_START_DATE
	FieldDueDate         Field = C.ISSUEZ_FIELD_DUE_DATE
	FieldEstimate        Field = C.ISSUEZ_FIELD_ESTIMATE
	FieldNumber          Field = C.ISSUEZ_FIELD_NUMBER
	FieldLocked          Field = C.ISSUEZ_FIELD_LOCKED
	FieldRef             Field = C.ISSUEZ_FIELD_REF
	FieldDeleted         Field = C.ISSUEZ_FIELD_DELETED
	FieldFixedBy         Field = C.ISSUEZ_FIELD_FIXED_BY
	FieldRelease         Field = C.ISSUEZ_FIELD_RELEASE
	FieldReason          Field = C.ISSUEZ_FIELD_REASON
	FieldAttachments     Field = C.ISSUEZ_FIELD_ATTACHMENTS
	FieldReactions       Field = C.ISSUEZ_FIELD_REACTIONS
	FieldName            Field = C.ISSUEZ_FIELD_NAME
	FieldMilestoneStatus Field = C.ISSUEZ_FIELD_MILESTONE_STATUS
	FieldExtra           Field = C.ISSUEZ_FIELD_EXTRA
	// Timeline only: the lock's reason changed (FieldLocked has it too).
	FieldLockReason Field = C.ISSUEZ_FIELD_LOCK_REASON
)

// String is the field's trailer key, e.g. "Labels", "X-Due-Date".
func (f Field) String() string { return C.GoString(C.issuez_field_key(C.issuez_field(f))) }

// Verb of an op, and of a timeline change.
type Verb uint32

const (
	VerbSet     Verb = C.ISSUEZ_OP_SET
	VerbClear   Verb = C.ISSUEZ_OP_CLEAR
	VerbAdd     Verb = C.ISSUEZ_OP_ADD
	VerbRemove  Verb = C.ISSUEZ_OP_REMOVE
	VerbInherit Verb = C.ISSUEZ_OP_INHERIT
)

// Priority is an issue's priority; PriorityNone is none.
type Priority int

const (
	PriorityNone     Priority = C.ISSUEZ_PRIORITY_UNKNOWN
	PriorityLow      Priority = C.ISSUEZ_PRIORITY_LOW
	PriorityMedium   Priority = C.ISSUEZ_PRIORITY_MEDIUM
	PriorityHigh     Priority = C.ISSUEZ_PRIORITY_HIGH
	PriorityCritical Priority = C.ISSUEZ_PRIORITY_CRITICAL
)

// op mirrors issuez_op with Go values. Every Go-side builder (Edit,
// Query, the open options) is just a []op; nothing lives in C until a
// call.
type op struct {
	verb   Verb
	target uint32
	name   string
	str    string
	num    int64
	num2   int64
	date   Date
	oid    OID
	person Person
	id     string
}

// cOps converts ops for one call. Strings stay in Go memory, pinned
// until p.Unpin, so nothing is copied.
func cOps(p *runtime.Pinner, ops []op) (*C.issuez_op, C.size_t) {
	if len(ops) == 0 {
		return nil, 0
	}
	out := make([]C.issuez_op, len(ops))
	for i, o := range ops {
		c := &out[i]
		c.verb = C.uint32_t(o.verb)
		c.target = C.uint32_t(o.target)
		c.name = pinStr(p, o.name)
		c.str = pinStr(p, o.str)
		c.num = C.int64_t(o.num)
		c.num2 = C.int64_t(o.num2)
		c.date = cDate(o.date)
		c.oid = cOID(o.oid)
		c.person = C.issuez_person{
			name:    pinStr(p, o.person.Name),
			email:   pinStr(p, o.person.Email),
			user_id: pinStr(p, o.person.UserID),
		}
		c.id = pinStr(p, o.id)
	}
	p.Pin(&out[0])
	return &out[0], C.size_t(len(out))
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// ─── Edit ──────────────────────────────────────────────────────────────

// Edit is one commit's worth of changes to an issue, for Create and
// Update (MilestoneEdit is a milestone's). The zero
// value is an empty edit; methods chain. Nothing is checked until the
// call, which then reports every problem (Problem.Op is the method call's
// position, counting from 0).
//
// Setters of optional fields clear them when given the zero value, so a
// host can pass what it has: "" for SetWorkflowState, SetMilestone,
// SetParent, SetRef and SetExtra, a zero Date for SetStartDate and
// SetDueDate, PriorityNone for SetPriority, 0 for SetEstimate.
// SetLabels, SetAssignees and SetBlockers with none clear the set.
//
//	e := new(issuez.Edit).AddComment("Fixed.").SetState("closed")
//	w, err := repo.Update(ctx, id, e, actor, issuez.ExpectTip(tip))
type Edit struct{ ops []op }

func (e *Edit) add(o op) *Edit { e.ops = append(e.ops, o); return e }
func (e *Edit) str(v Verb, f Field, s string) *Edit {
	return e.add(op{verb: v, target: uint32(f), str: s})
}
func (e *Edit) num(v Verb, f Field, n int64) *Edit {
	return e.add(op{verb: v, target: uint32(f), num: n})
}
func (e *Edit) clear(f Field) *Edit { return e.add(op{verb: VerbClear, target: uint32(f)}) }

// optional sets s, or clears f when s is "".
func (e *Edit) optional(f Field, s string) *Edit {
	if s == "" {
		return e.clear(f)
	}
	return e.str(VerbSet, f, s)
}

// optionalDate sets d, or clears f when d is the zero Date.
func (e *Edit) optionalDate(f Field, d Date) *Edit {
	if d == (Date{}) {
		return e.clear(f)
	}
	return e.add(op{verb: VerbSet, target: uint32(f), date: d})
}

// Len is the number of ops so far; Problem.Op indexes them.
func (e *Edit) Len() int { return len(e.ops) }

// SetTitle sets the title; a create needs one.
func (e *Edit) SetTitle(s string) *Edit { return e.str(VerbSet, FieldTitle, s) }

// SetDescription is the body on create; on update a description edit
// (not together with AddComment).
func (e *Edit) SetDescription(s string) *Edit { return e.str(VerbSet, FieldDescription, s) }

// AddComment makes the write's commit a comment with text s.
func (e *Edit) AddComment(s string) *Edit { return e.str(VerbSet, FieldComment, s) }

// State is an issue's state: open, closed or one of the repository's
// own ("wontfix", ...). Issue.Done says whether it counts as done.
type State string

// The two states every repository has; others are the repository's done
// and workflow states.
const (
	StateOpen   State = "open"
	StateClosed State = "closed"
)

// IsOpen is the state open, the one every issue starts in.
func (s State) IsOpen() bool { return s == StateOpen || s == "" }

// SetState sets the state: open, closed or one of the repository's.
func (e *Edit) SetState(s State) *Edit { return e.str(VerbSet, FieldState, string(s)) }

// SetFixedBy records what fixed the issue, a commit say (Fixed-By).
func (e *Edit) SetFixedBy(s string) *Edit { return e.str(VerbSet, FieldFixedBy, s) }

// SetRelease records the release with the fix (Release).
func (e *Edit) SetRelease(s string) *Edit { return e.str(VerbSet, FieldRelease, s) }

// SetReason records why the state changed (Reason).
func (e *Edit) SetReason(s string) *Edit { return e.str(VerbSet, FieldReason, s) }

// SetWorkflowState sets the workflow state of an open issue; "" clears it.
func (e *Edit) SetWorkflowState(s string) *Edit { return e.optional(FieldWorkflowState, s) }

// SetLabels replaces the labels.
func (e *Edit) SetLabels(labels ...string) *Edit {
	e.clear(FieldLabels)
	for _, l := range labels {
		e.AddLabel(l)
	}
	return e
}

// AddLabel adds a label; one the issue has is no change.
func (e *Edit) AddLabel(l string) *Edit { return e.str(VerbAdd, FieldLabels, l) }

// RemoveLabel takes a label off; one the issue lacks is no change.
func (e *Edit) RemoveLabel(l string) *Edit { return e.str(VerbRemove, FieldLabels, l) }

// SetAssignees replaces the assignees.
func (e *Edit) SetAssignees(who ...Person) *Edit {
	e.clear(FieldAssignees)
	for _, p := range who {
		e.AddAssignee(p)
	}
	return e
}

// AddAssignee assigns p (its Email, and its UserID if set).
func (e *Edit) AddAssignee(p Person) *Edit {
	return e.add(op{verb: VerbAdd, target: uint32(FieldAssignees), person: p})
}

// RemoveAssignee unassigns p.
func (e *Edit) RemoveAssignee(p Person) *Edit {
	return e.add(op{verb: VerbRemove, target: uint32(FieldAssignees), person: p})
}

// SetPriority sets the priority; PriorityNone clears it.
func (e *Edit) SetPriority(p Priority) *Edit {
	if p == PriorityNone {
		return e.clear(FieldPriority)
	}
	return e.num(VerbSet, FieldPriority, int64(p))
}

// SetMilestone sets the direct milestone by UUID; "" clears it.
func (e *Edit) SetMilestone(id string) *Edit { return e.optional(FieldMilestone, id) }

// InheritMilestone drops the direct milestone so the issue takes its
// parent's.
func (e *Edit) InheritMilestone() *Edit {
	return e.add(op{verb: VerbInherit, target: uint32(FieldMilestone)})
}

// SetParent sets the parent issue by UUID; "" makes it a root.
func (e *Edit) SetParent(id string) *Edit { return e.optional(FieldParent, id) }

// SetBlockers replaces the issues blocking this one.
func (e *Edit) SetBlockers(ids ...string) *Edit {
	e.clear(FieldBlockedBy)
	for _, id := range ids {
		e.AddBlocker(id)
	}
	return e
}

// AddBlocker adds an issue, by UUID, that blocks this one.
func (e *Edit) AddBlocker(id string) *Edit { return e.str(VerbAdd, FieldBlockedBy, id) }

// RemoveBlocker takes a blocker off.
func (e *Edit) RemoveBlocker(id string) *Edit { return e.str(VerbRemove, FieldBlockedBy, id) }

// SetStartDate sets the start date; the zero Date clears it.
func (e *Edit) SetStartDate(d Date) *Edit { return e.optionalDate(FieldStartDate, d) }

// SetDueDate sets the due date; the zero Date clears it.
func (e *Edit) SetDueDate(d Date) *Edit { return e.optionalDate(FieldDueDate, d) }

// SetEstimate is stored in whole minutes, rounded; under half a minute
// clears it.
func (e *Edit) SetEstimate(d time.Duration) *Edit {
	m := d.Round(time.Minute) / time.Minute
	if m <= 0 {
		return e.clear(FieldEstimate)
	}
	return e.num(VerbSet, FieldEstimate, int64(m))
}

// SetLocked locks the conversation, with a reason, or unlocks it.
func (e *Edit) SetLocked(locked bool, reason string) *Edit {
	return e.add(op{verb: VerbSet, target: uint32(FieldLocked), num: b2i(locked), str: reason})
}

// SetRef sets the branch or tag the issue is about (X-Ref); "" clears it.
func (e *Edit) SetRef(ref string) *Edit { return e.optional(FieldRef, ref) }

// SetDeleted soft-deletes the issue, or restores it.
func (e *Edit) SetDeleted(deleted bool) *Edit { return e.num(VerbSet, FieldDeleted, b2i(deleted)) }

// SetNumber gives the issue its number: write-once, normally the
// server's job.
func (e *Edit) SetNumber(n uint64) *Edit { return e.num(VerbSet, FieldNumber, int64(n)) }

// SetExtra writes a host field (key with an allowed prefix, "X-Forgejo-"
// by default). "" clears it.
func (e *Edit) SetExtra(key, value string) *Edit {
	return e.add(op{verb: VerbSet, target: uint32(FieldExtra), name: key, str: value})
}

// AddAttachment adds an image (PNG, JPEG or WebP, not animated) in the
// write's own commit: a new issue's root, the comment of Comment, the
// edit of SetDescription or EditComment, or a commit of its own. id is a
// v4 UUID of the caller's ("" picks one); text links to it as
// "attachment:<id>". The bytes go to the repository's store, unless it
// was opened WithAttachmentStore(false).
func (e *Edit) AddAttachment(id, name string, data []byte) *Edit {
	return e.add(op{verb: VerbAdd, target: uint32(FieldAttachments), id: id, name: name, str: string(data)})
}

// RemoveAttachment hides a present attachment; its bytes stay referenced.
// Alone it is a commit of its own that leaves every text as it is; the
// attachment keeps its Comment.
func (e *Edit) RemoveAttachment(id string) *Edit { return e.str(VerbRemove, FieldAttachments, id) }

// EditComment makes an update the edit of comment, with text its new
// text; the attachments it adds or removes go with it. Nothing else does
// but ExpectTip and SetSubject. AddComment, by contrast, adds a comment.
func (e *Edit) EditComment(comment OID, text string) *Edit {
	e.add(op{verb: VerbSet, target: targetEditComment, oid: comment})
	return e.str(VerbSet, FieldComment, text)
}

// DeleteComment makes an update hide comment: a commit of its own, with
// only SetSubject beside it.
func (e *Edit) DeleteComment(comment OID) *Edit {
	return e.add(op{verb: VerbSet, target: uint32(C.ISSUEZ_OPT_DELETE_COMMENT), oid: comment})
}

// RestoreComment makes an update show a hidden comment again.
func (e *Edit) RestoreComment(comment OID) *Edit {
	return e.add(op{verb: VerbSet, target: uint32(C.ISSUEZ_OPT_RESTORE_COMMENT), oid: comment})
}

// React makes an update add actor's reaction to the issue: a commit of
// its own, none when it is there already.
func (e *Edit) React(emoji string) *Edit { return e.str(VerbAdd, FieldReactions, emoji) }

// Unreact takes actor's reaction to the issue back.
func (e *Edit) Unreact(emoji string) *Edit { return e.str(VerbRemove, FieldReactions, emoji) }

// ReactToComment is React on a comment.
func (e *Edit) ReactToComment(comment OID, emoji string) *Edit {
	return e.reactionTarget(comment).React(emoji)
}

// UnreactToComment is Unreact on a comment.
func (e *Edit) UnreactToComment(comment OID, emoji string) *Edit {
	return e.reactionTarget(comment).Unreact(emoji)
}

func (e *Edit) reactionTarget(comment OID) *Edit {
	return e.add(op{verb: VerbSet, target: uint32(C.ISSUEZ_OPT_REACTION_TARGET), oid: comment})
}

// Write options that aren't fields.
const (
	targetExpect         = uint32(C.ISSUEZ_OPT_EXPECT)
	targetSubject        = uint32(C.ISSUEZ_OPT_SUBJECT)
	targetOriginalAuthor = uint32(C.ISSUEZ_OPT_ORIGINAL_AUTHOR)
	targetOriginalID     = uint32(C.ISSUEZ_OPT_ORIGINAL_ID)
	targetEditComment    = uint32(C.ISSUEZ_OPT_EDIT_COMMENT)
	targetExpectEdits    = uint32(C.ISSUEZ_OPT_EXPECT_EDITS)
)

// ExpectEdits makes an update that edits a text (SetDescription, or
// EditComment) fail with ErrVersionMismatch unless that text was edited
// exactly n times (Issue.Edits, Comment.Edits): a form's version of the
// text, which other changes to the issue don't touch, unlike ExpectTip.
func (e *Edit) ExpectEdits(n int) *Edit {
	return e.add(op{verb: VerbSet, target: targetExpectEdits, num: int64(n)})
}

// SetSubject is the commit's subject where the library would pick one.
func (e *Edit) SetSubject(s string) *Edit {
	return e.add(op{verb: VerbSet, target: targetSubject, str: s})
}

// SetOriginal records an imported issue's or comment's author and ID in
// the other tracker.
func (e *Edit) SetOriginal(author, id string) *Edit {
	e.add(op{verb: VerbSet, target: targetOriginalAuthor, str: author})
	return e.add(op{verb: VerbSet, target: targetOriginalID, str: id})
}

// ValidateCreate checks the format alone, without a repository, by the
// rules of Create: what a form can show as the user types.
func (e *Edit) ValidateCreate() ([]Problem, error) {
	return validate(C.ISSUEZ_LIST_ISSUE_CREATE, e.opsOrNil())
}

// ValidateUpdate is ValidateCreate by the rules of Update.
func (e *Edit) ValidateUpdate() ([]Problem, error) {
	return validate(C.ISSUEZ_LIST_ISSUE_UPDATE, e.opsOrNil())
}

func validate(list C.issuez_op_list, o []op) ([]Problem, error) {
	if err := initOnce(); err != nil {
		return nil, err
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	ops, n := cOps(&pin, o)
	var out *C.issuez_problems
	var cerr *C.issuez_error
	if C.issuez_ops_validate(list, ops, n, &out, &cerr) != C.ISSUEZ_OK {
		return nil, takeError(context.Background(), cerr)
	}
	return takeProblems(out), nil
}

func (e *Edit) opsOrNil() []op {
	if e == nil {
		return nil
	}
	return e.ops
}

// ─── MilestoneEdit ─────────────────────────────────────────────────────

// MilestoneEdit is one commit's worth of changes to a milestone, for
// CreateMilestone (SetName required) and UpdateMilestone. Like Edit, the
// zero value is empty, methods chain, and the call reports every problem.
//
//	e := new(issuez.MilestoneEdit).SetName("v1.0").SetDueDate(due)
type MilestoneEdit struct{ e Edit }

// Len is the number of ops so far; Problem.Op indexes them.
func (m *MilestoneEdit) Len() int { return m.e.Len() }

// SetName sets the name; a create needs one.
func (m *MilestoneEdit) SetName(s string) *MilestoneEdit { m.e.str(VerbSet, FieldName, s); return m }

// SetDescription sets the description.
func (m *MilestoneEdit) SetDescription(s string) *MilestoneEdit {
	m.e.str(VerbSet, FieldDescription, s)
	return m
}

// SetDueDate sets the due date; the zero Date clears it.
func (m *MilestoneEdit) SetDueDate(d Date) *MilestoneEdit { m.e.SetDueDate(d); return m }

// SetStatus completes (a GUARD problem while issues are open), retires or
// reopens the milestone.
func (m *MilestoneEdit) SetStatus(s MilestoneStatus) *MilestoneEdit {
	m.e.num(VerbSet, FieldMilestoneStatus, int64(s))
	return m
}

// SetSubject is Edit.SetSubject.
func (m *MilestoneEdit) SetSubject(s string) *MilestoneEdit { m.e.SetSubject(s); return m }

// SetOriginal records an imported milestone's author and ID in the other
// tracker.
func (m *MilestoneEdit) SetOriginal(author, id string) *MilestoneEdit {
	m.e.SetOriginal(author, id)
	return m
}

// ValidateCreate checks the format alone, without a repository, by the
// rules of CreateMilestone.
func (m *MilestoneEdit) ValidateCreate() ([]Problem, error) {
	return validate(C.ISSUEZ_LIST_MILESTONE_CREATE, m.edit().opsOrNil())
}

// ValidateUpdate is ValidateCreate by the rules of UpdateMilestone.
func (m *MilestoneEdit) ValidateUpdate() ([]Problem, error) {
	return validate(C.ISSUEZ_LIST_MILESTONE_UPDATE, m.edit().opsOrNil())
}

func (m *MilestoneEdit) edit() *Edit {
	if m == nil {
		return nil
	}
	return &m.e
}
