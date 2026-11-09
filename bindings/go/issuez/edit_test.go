package issuez_test

import (
	"slices"
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
		{"a delete alone", new(issuez.Edit).SetDeleted(true).AddLabel("x"), false, []issuez.ProblemKind{issuez.ProblemIncompatible}, nil},
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
//
// covers: Edit_SetTitle, Edit_SetDescription, Edit_AddComment, Edit_SetState, Edit_SetFixedBy
// covers: Edit_SetRelease, Edit_SetReason, Edit_SetWorkflowState, Edit_SetLabels, Edit_AddLabel
// covers: Edit_RemoveLabel, Edit_SetAssignees, Edit_AddAssignee, Edit_RemoveAssignee
// covers: Edit_SetPriority, Edit_SetMilestone, Edit_SetParent, Edit_SetBlockers, Edit_AddBlocker
// covers: Edit_RemoveBlocker, Edit_SetStartDate, Edit_SetDueDate, Edit_SetLocked, Edit_SetRef
// covers: Edit_SetDeleted, Edit_SetNumber, Edit_SetExtra, Edit_SetSubject, Edit_SetOriginal
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
		len(i.BlockedBy) != 1 || i.StartDate == nil || *i.StartDate != day || *i.DueDate != day || i.Estimate != 90*time.Minute ||
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
	if i.WorkflowState != "backlog" || !slices.Equal(i.Labels, []string{"b", "c"}) || len(i.Assignees) != 1 ||
		i.Assignees[0].Email != "ada@example.com" ||
		i.Priority != issuez.PriorityNone || i.ParentID != "" || !slices.Equal(i.BlockedBy, []string{parent.ID}) ||
		i.StartDate != nil || i.DueDate != nil || i.Estimate != 0 || !i.Locked ||
		i.LockReason != "heated" || i.Ref != "v2" {
		t.Fatalf("after update: %+v", i)
	}
	if got := git(t, r.GitDir(), "log", "-1", "--format=%s", w.Commit.String()); got != "Rework" {
		t.Errorf("subject: %q", got)
	}
	// The Set forms replace the whole set; false and "" take back.
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).SetLabels("z").SetAssignees(grace).SetBlockers(blocker.ID).
		SetLocked(false, "").SetExtra("X-Forgejo-Project", ""), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	i = w.Issue
	if !slices.Equal(i.Labels, []string{"z"}) || len(i.Assignees) != 1 || i.Assignees[0].UserID != grace.UserID ||
		!slices.Equal(i.BlockedBy, []string{blocker.ID}) || i.Locked || i.LockReason != "" || len(i.Extra) != 0 {
		t.Fatalf("after replacing: %+v", i)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).SetRef("").AddComment("Done.").
		SetState("closed").SetFixedBy("abc").SetRelease("1.2").SetReason("completed"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if i := w.Issue; !i.Done || i.Ref != "" || i.Comments[len(i.Comments)-1].Text != "Done." ||
		i.Closed == nil || i.Closed.FixedBy != "abc" || i.Closed.Release != "1.2" || i.Closed.Reason != "completed" ||
		i.Closed.By.Email != ada.Email {
		t.Fatalf("after closing: %+v", i)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).SetMilestone(""), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if w.Issue.MilestoneID != "" {
		t.Errorf("milestone not cleared: %q", w.Issue.MilestoneID)
	}
	w, err = r.Update(ctx, w.ID, new(issuez.Edit).SetDeleted(true), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if !w.Issue.Deleted {
		t.Error("not deleted")
	}
	// Nothing open is left in v1: it can be completed.
	if _, err = r.UpdateMilestone(ctx, m.ID, new(issuez.MilestoneEdit).SetStatus(issuez.MilestoneCompleted), ada); err != nil {
		t.Fatal(err)
	}
}
