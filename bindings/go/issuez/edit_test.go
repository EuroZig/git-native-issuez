package issuez_test

import (
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestEdit_ValidateCreate(t *testing.T) { validateTable(t, true) }
func TestEdit_ValidateUpdate(t *testing.T) { validateTable(t, false) }

// validateTable runs the create or the update cases.
func validateTable(t *testing.T, create bool) {
	bad := issuez.Date{Year: 2026, Month: time.February, Day: 30}
	tests := []struct {
		name   string
		edit   *issuez.Edit
		create bool
		want   []issuez.ProblemKind // in order
		ops    []int
	}{
		{"fine", new(issuez.Edit).SetTitle("T").AddLabel("bug"), true, nil, nil},
		{"two problems at their ops", new(issuez.Edit).SetTitle("a\nb").AddLabel("ok").SetDueDate(bad), true,
			[]issuez.ProblemKind{issuez.ProblemNewline, issuez.ProblemBadFormat}, []int{0, 2}},
		{"a create needs a title", new(issuez.Edit).AddLabel("x"), true, []issuez.ProblemKind{issuez.ProblemMissingValue}, []int{-1}},
		{"an update doesn't", new(issuez.Edit).AddLabel("x"), false, nil, nil},
		{"no comment on a create", new(issuez.Edit).SetTitle("T").AddComment("hi"), true, []issuez.ProblemKind{issuez.ProblemIncompatible}, []int{1}},
		{"a delete alone", new(issuez.Edit).SetDeleted(true).AddLabel("x"), false, []issuez.ProblemKind{issuez.ProblemIncompatible}, nil},
		{"a bad state", new(issuez.Edit).SetState("not a state"), false, []issuez.ProblemKind{issuez.ProblemBadFormat}, []int{0}},
	}
	for _, tt := range tests {
		if tt.create != create {
			continue
		}
		t.Run(tt.name, func(t *testing.T) {
			validate := tt.edit.ValidateUpdate
			if create {
				validate = tt.edit.ValidateCreate
			}
			got, err := validate()
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("problems = %+v, want kinds %v", got, tt.want)
			}
			for i, k := range tt.want {
				if got[i].Kind != k {
					t.Errorf("problem %d: kind %d, want %d (%s)", i, got[i].Kind, k, got[i].Message)
				}
				if tt.ops != nil && got[i].Op != tt.ops[i] {
					t.Errorf("problem %d: op %d, want %d", i, got[i].Op, tt.ops[i])
				}
			}
		})
	}
}

// TestEditAppliesEveryBuilder writes with every builder and reads the
// fields back: the ops reach the library as the builders mean them.
func TestEditAppliesEveryBuilder(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
	if err != nil {
		t.Fatal(err)
	}
	parent := create(t, r, "Parent")
	blocker := create(t, r, "Blocker")
	grace := issuez.Person{Email: "grace@example.invalid", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	day := issuez.Date{Year: 2026, Month: time.December, Day: 1}
	w, err := r.Create(ctx, new(issuez.Edit).
		SetTitle("Everything").
		SetDescription("All of it.").
		SetWorkflowState("ready").
		SetLabels("a", "b").
		SetAssignees(grace).
		SetPriority(issuez.PriorityHigh).
		SetMilestone(m.ID).
		SetParent(parent.ID).
		SetBlockers(blocker.ID).
		SetStartDate(day).
		SetDueDate(day).
		SetEstimate(90*time.Minute).
		SetNumber(7).
		SetExtra("X-Forgejo-Project", "3").
		SetOriginal("octo@github", "gh-1"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	i := w.Issue
	if i.Title != "Everything" || i.Description != "All of it." || i.WorkflowState != "ready" ||
		len(i.Labels) != 2 || len(i.Assignees) != 1 || i.Assignees[0].UserID != grace.UserID ||
		i.Priority != issuez.PriorityHigh || i.MilestoneID != m.ID || i.ParentID != parent.ID ||
		len(i.BlockedBy) != 1 || i.StartDate == nil || *i.DueDate != day || i.Estimate != 90*time.Minute ||
		i.Number != 7 || i.Extra["X-Forgejo-Project"] != "3" || i.OriginalAuthor != "octo@github" || i.OriginalID != "gh-1" {
		t.Fatalf("after create: %+v", i)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).
		SetWorkflowState("").
		RemoveLabel("a").AddLabel("c").
		RemoveAssignee(grace).AddAssignee(issuez.Person{Email: "ada@example.com"}).
		SetPriority(issuez.PriorityNone).
		SetParent("").
		RemoveBlocker(blocker.ID).AddBlocker(parent.ID).
		SetStartDate(issuez.Date{}).SetDueDate(issuez.Date{}).SetEstimate(0).
		SetLocked(true, "heated").SetRef("v2").
		SetSubject("Rework"), ada, issuez.Reload(), issuez.ExpectTip(w.NewTip))
	if err != nil {
		t.Fatal(err)
	}
	i = w.Issue
	if i.WorkflowState != "backlog" || len(i.Labels) != 2 || i.Assignees[0].Email != "ada@example.com" ||
		i.Priority != issuez.PriorityNone || i.ParentID != "" || i.BlockedBy[0] != parent.ID ||
		i.StartDate != nil || i.DueDate != nil || i.Estimate != 0 || !i.Locked ||
		i.LockReason != "heated" || i.Ref != "v2" {
		t.Fatalf("after update: %+v", i)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).InheritMilestone().SetRef("").AddComment("Done.").
		SetState("closed").SetFixedBy("abc").SetRelease("1.2").SetReason("completed"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if i := w.Issue; !i.Done || i.Ref != "" || i.Comments[len(i.Comments)-1].Text != "Done." {
		t.Fatalf("after closing: %+v", i)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).SetMilestone(""), ada)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = r.Update(ctx, w.ID, new(issuez.Edit).SetDeleted(true), ada); err != nil {
		t.Fatal(err)
	}
	// Nothing open is left in v1: it can be completed.
	if _, err = r.UpdateMilestone(ctx, m.ID, new(issuez.MilestoneEdit).SetStatus(issuez.MilestoneCompleted), ada); err != nil {
		t.Fatal(err)
	}
}

// TestEdit_zeroValuesClear: the zero value of an optional setter clears
// the field through the library too.
func TestEdit_zeroValuesClear(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	day := issuez.Date{Year: 2026, Month: time.December, Day: 1}
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Zero").SetRef("main").SetDueDate(day).
		SetStartDate(day).SetPriority(issuez.PriorityHigh), ada)
	if err != nil {
		t.Fatal(err)
	}
	u, err := r.Update(ctx, w.ID, new(issuez.Edit).SetRef("").SetDueDate(issuez.Date{}).
		SetStartDate(issuez.Date{}).SetPriority(issuez.PriorityNone), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if i := u.Issue; i.Ref != "" || i.DueDate != nil || i.StartDate != nil || i.Priority != issuez.PriorityNone {
		t.Errorf("not cleared: ref %q, due %v, start %v, priority %v", i.Ref, i.DueDate, i.StartDate, i.Priority)
	}
}
