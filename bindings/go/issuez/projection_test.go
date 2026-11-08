package issuez_test

import (
	"slices"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// epicTree is an epic with two tasks, one of them done and blocking the other.
func epicTree(t *testing.T) (r *issuez.Repo, epic, done, open string) {
	t.Helper()
	ctx := t.Context()
	r = newRepo(t)
	epic = create(t, r, "Epic").ID
	d, err := r.Create(ctx, new(issuez.Edit).SetTitle("Done").SetParent(epic), ada)
	if err != nil {
		t.Fatal(err)
	}
	o, err := r.Create(ctx, new(issuez.Edit).SetTitle("Open").SetParent(epic).AddBlocker(d.ID), ada)
	if err != nil {
		t.Fatal(err)
	}
	return r, epic, d.ID, o.ID
}

func TestRepo_OpenProjection(t *testing.T) {
	r, epic, done, open := epicTree(t)
	p, err := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if roots := p.Roots(); len(roots) != 1 || roots[0] != epic {
		t.Errorf("Roots() = %v", roots)
	}
	if kids := p.Children(epic); len(kids) != 2 || !slices.Contains(kids, done) || !slices.Contains(kids, open) {
		t.Errorf("Children() = %v", kids)
	}
	around, err := r.OpenProjection(t.Context(), issuez.ProjectionOptions{Around: open})
	if err != nil {
		t.Fatal(err)
	}
	defer around.Close()
	if b := around.ActiveBlockers(open); len(b) != 1 || b[0] != done {
		t.Errorf("around: ActiveBlockers() = %v", b)
	}
}

func TestProjectionView_Roots(t *testing.T) {
	r, epic, _, _ := epicTree(t)
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	defer p.Close()
	if roots := p.Roots(); len(roots) != 1 || roots[0] != epic {
		t.Errorf("Roots() = %v", roots)
	}
}

func TestProjectionView_Children(t *testing.T) {
	r, epic, _, open := epicTree(t)
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	defer p.Close()
	if len(p.Children(epic)) != 2 || len(p.Children(open)) != 0 {
		t.Error("Children")
	}
}

func TestProjectionView_ActiveBlockers(t *testing.T) {
	r, _, done, open := epicTree(t)
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	defer p.Close()
	if b := p.ActiveBlockers(open); len(b) != 1 || b[0] != done {
		t.Errorf("ActiveBlockers() = %v", b)
	}
}

func TestProjectionView_Blocking(t *testing.T) {
	r, _, done, open := epicTree(t)
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	defer p.Close()
	if b := p.Blocking(done); len(b) != 1 || b[0] != open {
		t.Errorf("Blocking() = %v", b)
	}
}

func TestProjectionView_Progress(t *testing.T) {
	r, epic, done, _ := epicTree(t)
	if _, err := r.Update(t.Context(), done, new(issuez.Edit).SetState(issuez.StateClosed), ada); err != nil {
		t.Fatal(err)
	}
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	defer p.Close()
	if pr, ok := p.Progress(epic); !ok || pr != (issuez.Progress{Done: 1, Total: 2}) {
		t.Errorf("Progress() = %+v %v", pr, ok)
	}
}

func TestProjectionView_MilestoneOf(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	m, _ := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
	epic, _ := r.Create(ctx, new(issuez.Edit).SetTitle("Epic").SetMilestone(m.ID), ada)
	task, _ := r.Create(ctx, new(issuez.Edit).SetTitle("Task").SetParent(epic.ID), ada)
	p, _ := r.OpenProjection(ctx, issuez.ProjectionOptions{})
	defer p.Close()
	if got := p.MilestoneOf(task.ID); got != m.ID {
		t.Errorf("MilestoneOf() = %q", got)
	}
	if pr := p.MilestoneProgress(m.ID); pr.Total != 1 {
		t.Errorf("MilestoneProgress() = %+v", pr)
	}
}

func TestProjectionView_MilestoneProgress(t *testing.T) {
	TestProjectionView_MilestoneOf(t)
}

func TestProjectionView_Close(t *testing.T) {
	r, epic, _, _ := epicTree(t)
	p, _ := r.OpenProjection(t.Context(), issuez.ProjectionOptions{})
	p.Close()
	p.Close()
	if p.Children(epic) != nil {
		t.Error("answers after Close")
	}
}
