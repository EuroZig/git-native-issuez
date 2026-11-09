package issuez_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestEdit_React: idempotent, on the issue and a comment, taken back.
//
// covers: Edit_Unreact, Edit_ReactToComment
func TestEdit_React(t *testing.T) {
	ctx := context.Background()
	r := newRepo(t)
	w := create(t, r, "Liked")
	cw, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Nice"), ada)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).React(":+1:"), ada); err != nil {
		t.Fatal(err)
	}
	again, err := r.Update(ctx, w.ID, new(issuez.Edit).React(":+1:"), ada)
	if err != nil || again.Wrote {
		t.Errorf("again: %v %+v", err, again)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).ReactToComment(cw.Commit, ":heart:"), ada); err != nil {
		t.Fatal(err)
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(i.Reactions) != 1 || i.Reactions[0].Emoji != ":+1:" || len(i.Reactions[0].Users) != 1 ||
		i.Reactions[0].Users[0].Email != "ada@example.com" {
		t.Errorf("issue reactions: %+v", i.Reactions)
	}
	if len(i.Comments[0].Reactions) != 1 || i.Comments[0].Reactions[0].Emoji != ":heart:" {
		t.Errorf("comment reactions: %+v", i.Comments[0].Reactions)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).Unreact(":+1:"), ada); err != nil {
		t.Fatal(err)
	}
	if i, _ = r.Load(ctx, w.ID); len(i.Reactions) != 0 {
		t.Errorf("after taking back: %+v", i.Reactions)
	}
	if again, err := r.Update(ctx, w.ID, new(issuez.Edit).Unreact(":+1:"), ada); err != nil || again.Wrote {
		t.Errorf("taken back again: %v %+v", err, again)
	}
}

func TestProblemsPointAtOps(t *testing.T) {
	r := newRepo(t)
	e := new(issuez.Edit).
		SetTitle("two\nlines").
		SetDueDate(issuez.Date{Year: 2026, Month: time.February, Day: 30}).
		AddLabel("fine")
	problems, err := e.ValidateCreate()
	if err != nil || len(problems) != 2 {
		t.Fatalf("validate: %v %+v", err, problems)
	}
	_, err = r.Create(context.Background(), e, ada)
	var ie *issuez.Error
	if !errors.Is(err, issuez.ErrInvalidValue) || !errors.As(err, &ie) || len(ie.Problems) != 2 {
		t.Fatalf("create: %v", err)
	}
	if ie.Problems[0].Op != 0 || ie.Problems[0].Kind != issuez.ProblemNewline ||
		ie.Problems[1].Op != 1 || ie.Problems[1].Field != issuez.FieldDueDate {
		t.Errorf("problems: %+v", ie.Problems)
	}
}

func TestRepo_Create(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("New").AddLabel("x"), ada)
	if err != nil {
		t.Fatal(err)
	}
	if w.Kind != issuez.KindIssue || len(w.ID) != 36 || !w.Wrote || w.Commit != w.NewTip || !w.OldTip.IsZero() ||
		w.Entry.Kind != issuez.EntryCreated || w.Issue != nil {
		t.Errorf("receipt: %+v", w)
	}
	_, err = r.Create(ctx, new(issuez.Edit).AddLabel("no title"), ada)
	var refused *issuez.Error
	if !errors.Is(err, issuez.ErrInvalidValue) || !errors.As(err, &refused) || refused.Problems[0].Field != issuez.FieldTitle {
		t.Errorf("no title: %v", err)
	}
	// Reads the repository: a parent that doesn't exist.
	_, err = r.Create(ctx, new(issuez.Edit).SetTitle("Child").SetParent("0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"), ada)
	if !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing parent: %v", err)
	}
	if _, err := r.Create(ctx, nil, ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("nil edit: %v", err)
	}
	if _, err := r.Create(ctx, new(issuez.Edit).SetTitle("Nobody"), issuez.Actor{Name: "Nobody"}); err == nil {
		t.Error("an actor without an email")
	}
	// A host's user: the UUID comes back on the author and the receipt.
	grace := issuez.Actor{Name: "Grace", Email: "grace@example.com", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	g, err := r.Create(ctx, new(issuez.Edit).SetTitle("Hosted"), grace, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if g.Entry.Author.UserID != grace.UserID || g.Issue.Author.UserID != grace.UserID {
		t.Errorf("author UUID: receipt %q, issue %q", g.Entry.Author.UserID, g.Issue.Author.UserID)
	}
	grace.UserID = "42"
	if _, err := r.Create(ctx, new(issuez.Edit).SetTitle("Bad UUID"), grace); err == nil {
		t.Error("a UserID that isn't a UUID")
	}
	// Taken numbers are refused.
	if _, err := r.Create(ctx, new(issuez.Edit).SetTitle("One").SetNumber(1), ada); err != nil {
		t.Fatal(err)
	}
	_, err = r.Create(ctx, new(issuez.Edit).SetTitle("Also one").SetNumber(1), ada)
	var ie *issuez.Error
	if !errors.Is(err, issuez.ErrGuard) || !errors.As(err, &ie) || ie.Problems[0].Kind != issuez.ProblemDuplicateNumber {
		t.Errorf("duplicate number: %v", err)
	}
}

func TestRepo_Update(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w := create(t, r, "Before")
	const missing = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"
	// Refused for what the repository says: nothing is written.
	_, err := r.Update(ctx, w.ID, new(issuez.Edit).SetParent(missing), ada)
	if !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing parent: %v", err)
	}
	if i, _ := r.Load(ctx, w.ID); i.Tip != w.NewTip {
		t.Error("a refused update wrote")
	}
	if _, err := r.Update(ctx, missing, new(issuez.Edit).AddLabel("x"), ada); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing issue: %v", err)
	}
	var refused *issuez.Error
	if _, err := r.Update(ctx, "", new(issuez.Edit).AddLabel("x"), ada); !errors.As(err, &refused) || refused.Code != issuez.CodeInvalidArgument {
		t.Errorf("no id: %v", err)
	}
	u, err := r.Update(ctx, w.ID, new(issuez.Edit).SetTitle("After"), ada, issuez.ExpectTip(w.NewTip))
	if err != nil {
		t.Fatal(err)
	}
	if !u.Wrote || u.OldTip != w.NewTip || u.NewTip == w.NewTip || u.Entry.Kind != issuez.EntryUpdate ||
		len(u.Entry.Changes) != 1 || u.Entry.Changes[0].Old != "Before" || u.Entry.Changes[0].New != "After" {
		t.Errorf("receipt: %+v", u)
	}
	// Nothing to change: no commit.
	same, err := r.Update(ctx, w.ID, new(issuez.Edit).SetTitle("After"), ada)
	if err != nil || same.Wrote || same.NewTip != u.NewTip {
		t.Errorf("no-op: %v %+v", err, same)
	}
	if same, err := r.Update(ctx, w.ID, new(issuez.Edit).SetState("open").SetLabels(), ada); err != nil || same.Wrote {
		t.Errorf("same state: %v %+v", err, same)
	}
	// A stale Expect is refused, and says so.
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).SetTitle("Lost"), ada, issuez.ExpectTip(w.NewTip)); !errors.Is(err, issuez.ErrVersionMismatch) {
		t.Errorf("stale expect: %v", err)
	}
	if _, err := r.Update(ctx, "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c", new(issuez.Edit).SetTitle("x"), ada); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
}

func TestReload(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Fresh"), ada, issuez.Reload())
	if err != nil || w.Issue == nil || w.Issue.Title != "Fresh" || w.Issue.Tip != w.NewTip {
		t.Fatalf("create: %v %+v", err, w)
	}
	u, err := r.Update(ctx, w.ID, new(issuez.Edit).AddLabel("x"), ada, issuez.Reload())
	if err != nil || u.Issue == nil || len(u.Issue.Labels) != 1 {
		t.Errorf("update: %v %+v", err, u)
	}
	// A milestone write reloads its milestone.
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada, issuez.Reload())
	if err != nil || m.Issue != nil || m.Milestone == nil || m.Milestone.Name != "v1" {
		t.Errorf("milestone: %v %+v", err, m)
	}
	if m, err := r.UpdateMilestone(ctx, m.ID, new(issuez.MilestoneEdit).SetName("v2"), ada); err != nil || m.Milestone != nil {
		t.Errorf("without Reload: %v %+v", err, m)
	}
}

// TestExpectTip: every write that has a tip to compare takes the option.
func TestExpectTip(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Expected")
	stale := w.NewTip
	writes := map[string]func(...issuez.WriteOption) (*issuez.Write, error){
		"Update": func(o ...issuez.WriteOption) (*issuez.Write, error) {
			return r.Update(ctx, w.ID, new(issuez.Edit).AddLabel("x"), ada, o...)
		},
		"DeleteComment": func(o ...issuez.WriteOption) (*issuez.Write, error) {
			return r.Update(ctx, w.ID, new(issuez.Edit).DeleteComment(c.Commit), ada, o...)
		},
		"RestoreComment": func(o ...issuez.WriteOption) (*issuez.Write, error) {
			return r.Update(ctx, w.ID, new(issuez.Edit).RestoreComment(c.Commit), ada, o...)
		},
		"React": func(o ...issuez.WriteOption) (*issuez.Write, error) {
			return r.Update(ctx, w.ID, new(issuez.Edit).React("eyes"), ada, o...)
		},
	}
	for _, name := range []string{"Update", "DeleteComment", "RestoreComment", "React"} {
		_, err := writes[name](issuez.ExpectTip(stale))
		var e *issuez.Error
		if !errors.As(err, &e) || e.Code != issuez.CodeVersionMismatch || e.CurrentTip.IsZero() {
			t.Fatalf("%s, stale: %v", name, err)
		}
		if _, err := writes[name](issuez.ExpectTip(e.CurrentTip)); err != nil {
			t.Fatalf("%s, current: %v", name, err)
		}
	}
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada, issuez.ExpectTip(stale))
	if err != nil {
		t.Fatalf("create ignores it: %v", err)
	}
	if _, err := r.UpdateMilestone(ctx, m.ID, new(issuez.MilestoneEdit).SetName("v2"), ada, issuez.ExpectTip(stale)); !errors.Is(err, issuez.ErrVersionMismatch) {
		t.Errorf("milestone, stale: %v", err)
	}
	if _, err := r.UpdateMilestone(ctx, m.ID, new(issuez.MilestoneEdit).SetName("v2"), ada, issuez.ExpectTip(m.NewTip)); err != nil {
		t.Errorf("milestone, current: %v", err)
	}
}

// commented creates an issue with one comment and returns both.
func commented(t *testing.T, r *issuez.Repo, text string) (*issuez.Write, *issuez.Write) {
	t.Helper()
	w := create(t, r, "Discussed")
	c, err := r.Update(t.Context(), w.ID, new(issuez.Edit).AddComment(text), ada)
	if err != nil {
		t.Fatal(err)
	}
	return w, c
}

func TestEdit_DeleteComment(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Oops")
	d, err := r.Update(ctx, w.ID, new(issuez.Edit).DeleteComment(c.Commit), ada)
	if err != nil || d.Entry.Kind != issuez.EntryCommentDelete {
		t.Fatalf("delete: %v %+v", err, d)
	}
	if i, _ := r.Load(ctx, w.ID); !i.Comments[0].Deleted {
		t.Errorf("not deleted: %+v", i.Comments[0])
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).DeleteComment(c.Commit), ada, issuez.ExpectTip(c.NewTip)); !errors.Is(err, issuez.ErrVersionMismatch) {
		t.Errorf("stale: %v", err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).DeleteComment(issuez.OID{}), ada); err == nil {
		t.Error("no comment")
	}
}

func TestEdit_RestoreComment(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Back")
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).DeleteComment(c.Commit), ada); err != nil {
		t.Fatal(err)
	}
	back, err := r.Update(ctx, w.ID, new(issuez.Edit).RestoreComment(c.Commit), ada)
	if err != nil || back.Entry.Kind != issuez.EntryCommentRestore {
		t.Fatalf("restore: %v %+v", err, back)
	}
	if i, _ := r.Load(ctx, w.ID); i.Comments[0].Deleted || i.Comments[0].Text != "Back" {
		t.Errorf("not restored: %+v", i.Comments[0])
	}
}

// covers: MilestoneEdit_SetName, MilestoneEdit_SetDescription, MilestoneEdit_SetDueDate
// covers: MilestoneEdit_SetStatus
func TestRepo_CreateMilestone(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	due := issuez.Date{Year: 2026, Month: time.June, Day: 30}
	w, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1").SetDescription("First.").
		SetDueDate(due).SetStatus(issuez.MilestoneCompleted), ada)
	if err != nil {
		t.Fatal(err)
	}
	if w.Kind != issuez.KindMilestone || !w.Wrote || len(w.ID) != 36 {
		t.Errorf("receipt: %+v", w)
	}
	m, err := r.LoadMilestone(ctx, w.ID)
	if err != nil || m.Name != "v1" || m.Description != "First." || m.DueDate == nil || *m.DueDate != due ||
		m.Status != issuez.MilestoneCompleted || m.Tip != w.NewTip {
		t.Errorf("milestone: %v %+v", err, m)
	}
	if _, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetDescription("No name"), ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("no name: %v", err)
	}
}

func TestRepo_UpdateMilestone(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
	if err != nil {
		t.Fatal(err)
	}
	u, err := r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetName("v1.0").SetStatus(issuez.MilestoneRetired), ada)
	if err != nil || !u.Wrote || u.OldTip != w.NewTip {
		t.Fatalf("update: %v %+v", err, u)
	}
	m, _ := r.LoadMilestone(ctx, w.ID)
	if m.Name != "v1.0" || m.Status != issuez.MilestoneRetired {
		t.Errorf("milestone: %+v", m)
	}
	// As it is: nothing written.
	if same, err := r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetName("v1.0"), ada); err != nil || same.Wrote || same.NewTip != u.NewTip {
		t.Errorf("no-op: %v %+v", err, same)
	}
	if _, err := r.UpdateMilestone(ctx, "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c", new(issuez.MilestoneEdit).SetName("x"), ada); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
}

func TestRepo_LoadMilestone(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	if _, err := r.LoadMilestone(ctx, "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
	// An issue's ID isn't a milestone's.
	w := create(t, r, "Issue")
	if _, err := r.LoadMilestone(ctx, w.ID); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("issue id: %v", err)
	}
	at := time.Date(2025, time.March, 4, 5, 6, 7, 0, time.UTC)
	actor := ada
	actor.At = at
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("Plain"), actor)
	if err != nil {
		t.Fatal(err)
	}
	got, err := r.LoadMilestone(ctx, m.ID)
	if err != nil || got.ID != m.ID || !got.Created.Equal(at) || got.DueDate != nil ||
		got.Status != issuez.MilestoneOpen || len(got.Problems) != 0 {
		t.Errorf("plain: %v %+v", err, got)
	}
}

func TestRepo_Milestones(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	if ms, err := r.Milestones(ctx); err != nil || len(ms) != 0 {
		t.Errorf("none: %v %+v", err, ms)
	}
	mk := func(name string, due *issuez.Date) {
		e := new(issuez.MilestoneEdit).SetName(name)
		if due != nil {
			e.SetDueDate(*due)
		}
		if _, err := r.CreateMilestone(ctx, e, ada); err != nil {
			t.Fatal(err)
		}
	}
	mk("b, undated", nil)
	mk("late", &issuez.Date{Year: 2027, Month: time.January, Day: 1})
	mk("a, undated", nil)
	mk("early", &issuez.Date{Year: 2026, Month: time.January, Day: 1})
	ms, err := r.Milestones(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, m := range ms {
		names = append(names, m.Name)
	}
	if got := strings.Join(names, ","); got != "early,late,a, undated,b, undated" {
		t.Errorf("order: %s", got)
	}
}

func TestEdit_ExpectEdits(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Versioned")
	steps := []struct {
		name string
		e    *issuez.Edit
		ok   bool
	}{
		{"first edit", new(issuez.Edit).SetDescription("v1").ExpectEdits(0), true},
		{"stale", new(issuez.Edit).SetDescription("stale").ExpectEdits(0), false},
		{"another change", new(issuez.Edit).AddLabel("bug"), true},
		{"second edit", new(issuez.Edit).SetDescription("v2").ExpectEdits(1), true},
		{"a comment", new(issuez.Edit).EditComment(c.Commit, "edited").ExpectEdits(0), true},
		{"a stale comment", new(issuez.Edit).EditComment(c.Commit, "stale").ExpectEdits(0), false},
	}
	for _, s := range steps {
		_, err := r.Update(ctx, w.ID, s.e, ada)
		if s.ok && err != nil || !s.ok && !errors.Is(err, issuez.ErrVersionMismatch) {
			t.Errorf("%s: %v", s.name, err)
		}
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).AddLabel("x").ExpectEdits(0), ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("without a text: %v", err)
	}
	i, _ := r.Load(ctx, w.ID)
	if i.Description != "v2" || i.Edits != 2 || i.Comments[0].Text != "edited" {
		t.Errorf("issue: %q (%d edits), comment %q", i.Description, i.Edits, i.Comments[0].Text)
	}
}

// TestMilestone_times: when a milestone was updated and its status set,
// and who made it.
func TestMilestone_times(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	m := w.Milestone
	if m.StatusChanged != nil || !m.Updated.Equal(m.Created) || m.Author.Email != ada.Email {
		t.Errorf("new: %+v", m)
	}
	done := ada
	done.At = m.Created.Add(time.Hour)
	u, err := r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetStatus(issuez.MilestoneCompleted), done, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if m := u.Milestone; m.StatusChanged == nil || !m.StatusChanged.Equal(done.At) || !m.Updated.Equal(done.At) {
		t.Errorf("completed: %+v", m)
	}
}

// TestRepo_Update_unchanged: an edit that states values the issue has
// writes nothing, so a host can state the whole state it wants.
func TestRepo_Update_unchanged(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
	if err != nil {
		t.Fatal(err)
	}
	grace := issuez.Person{Email: "grace@example.com", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	due := issuez.Date{Year: 2026, Month: time.December, Day: 1}
	state := func() *issuez.Edit {
		return new(issuez.Edit).SetTitle("Whole").SetDescription("Body").SetLabels("b", "a").
			SetAssignees(grace).SetMilestone(m.ID).SetDueDate(due).SetRef("main").
			SetLocked(true, "heated").SetState(issuez.StateClosed)
	}
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Whole"), ada)
	if err != nil {
		t.Fatal(err)
	}
	blocker := create(t, r, "Blocker")
	other := create(t, r, "Other")
	whole := state
	state = func() *issuez.Edit { return whole().SetBlockers(blocker.ID, other.ID) }
	if u, err := r.Update(ctx, w.ID, state(), ada); err != nil || !u.Wrote {
		t.Fatalf("first: %v %+v", err, u)
	}
	// The same sets in another order too.
	again, err := r.Update(ctx, w.ID, state().SetLabels("a", "b").SetBlockers(other.ID, blocker.ID), ada)
	if err != nil || again.Wrote {
		t.Errorf("unchanged: %v, wrote %v, changes %+v", err, again != nil && again.Wrote, again.Entry.Changes)
	}
}

func TestEdit_UnreactToComment(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Liked")
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).ReactToComment(c.Commit, "heart"), ada); err != nil {
		t.Fatal(err)
	}
	u, err := r.Update(ctx, w.ID, new(issuez.Edit).UnreactToComment(c.Commit, "heart"), ada, issuez.Reload())
	if err != nil || len(u.Issue.Comments[0].Reactions) != 0 {
		t.Fatalf("unreact: %v %+v", err, u)
	}
}

// The binding copies the C records field by field: times a minute apart
// can't pass for one another.
func TestCopiedTimes(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	at := func(minute int) issuez.Actor {
		a := ada
		a.At = time.Date(2026, time.March, 1, 9, minute, 0, 0, time.UTC)
		return a
	}
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Times"), at(1))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).SetState(issuez.StateClosed), at(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Late"), at(3)); err != nil {
		t.Fatal(err)
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !i.Created.Equal(at(1).At) || !i.Closed.At.Equal(at(2).At) || !i.Updated.Equal(at(3).At) {
		t.Errorf("issue: created %v, closed %v, updated %v", i.Created, i.Closed.At, i.Updated)
	}

	w, err = r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("Times"), at(1))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetStatus(issuez.MilestoneCompleted), at(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetName("Later"), at(3)); err != nil {
		t.Fatal(err)
	}
	m, err := r.LoadMilestone(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !m.Created.Equal(at(1).At) || !m.StatusChanged.Equal(at(2).At) || !m.Updated.Equal(at(3).At) {
		t.Errorf("milestone: created %v, status %v, updated %v", m.Created, m.StatusChanged, m.Updated)
	}
}
