package issuez_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestConcurrentQueries: queries share the repo's cache of loaded issues
// while another goroutine writes; every count is one the repo had.
func TestConcurrentQueries(t *testing.T) {
	ctx := context.Background()
	r := newRepo(t, issuez.WithPoolSize(4))
	for i := 0; i < 5; i++ {
		create(t, r, fmt.Sprintf("Seed %d", i), "seed")
	}
	done := make(chan struct{})
	errs := make(chan error, 8)
	for g := 0; g < 4; g++ {
		go func() {
			for {
				select {
				case <-done:
					errs <- nil
					return
				default:
				}
				page, err := r.Query(ctx, issuez.Query{Labels: []string{"seed"}})
				if err != nil || len(page.Issues) < 5 || len(page.Issues) > 25 {
					errs <- fmt.Errorf("query %d: %v", len(page.Issues), err)
					return
				}
				for _, i := range page.Issues {
					if !strings.HasPrefix(i.Title, "Seed") && !strings.HasPrefix(i.Title, "More") {
						errs <- fmt.Errorf("title %q", i.Title)
						return
					}
				}
			}
		}()
	}
	for i := 0; i < 20; i++ {
		create(t, r, fmt.Sprintf("More %d", i), "seed")
	}
	close(done)
	for g := 0; g < 4; g++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if page, err := r.Query(ctx, issuez.Query{Labels: []string{"seed"}}); err != nil || len(page.Issues) != 25 {
		t.Fatalf("final count %d: %v", len(page.Issues), err)
	}
}

var update = flag.Bool("update", false, "rewrite the golden files in testdata")

// golden compares got with testdata/name, or rewrites it with -update.
func golden(t *testing.T, name string, got []byte) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *update {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update to write it)", err)
	}
	if !bytes.Equal(want, got) {
		t.Errorf("%s differs; got:\n%s", name, got)
	}
}

// TestRepo_Load reads an issue with every field into the Issue struct and
// compares it, IDs and object IDs aside, with testdata/issue.golden.json.
func TestRepo_Load(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	at := func(minute int) issuez.Actor {
		a := ada
		a.At = time.Date(2026, time.January, 2, 3, minute, 0, 0, time.UTC)
		return a
	}
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), at(0))
	if err != nil {
		t.Fatal(err)
	}
	w, err := r.Create(ctx, new(issuez.Edit).
		SetTitle("Golden").SetDescription("Every field.").
		SetLabels("bug", "ui").SetPriority(issuez.PriorityHigh).SetMilestone(m.ID).
		AddAssignee(issuez.Person{Email: "grace@example.invalid", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}).
		SetDueDate(issuez.Date{Year: 2026, Month: time.December, Day: 1}).SetEstimate(90*time.Minute).
		SetNumber(12).SetExtra("X-Forgejo-Project", "3").SetOriginal("octo@github", "gh-12"), at(1))
	if err != nil {
		t.Fatal(err)
	}
	said, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("A comment"), at(2))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).EditComment(said.Commit, "An edited comment"), at(3)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).ReactToComment(said.Commit, "heart"), at(4)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).SetLocked(true, "heated").SetRef("v2"), at(5)); err != nil {
		t.Fatal(err)
	}
	i, err := r.Load(ctx, w.ID, issuez.LoadHistory())
	if err != nil {
		t.Fatal(err)
	}
	if i.ID != w.ID || i.Tip.IsZero() || len(i.Comments) != 1 || i.Comments[0].ID != said.Commit {
		t.Fatalf("ids: %+v", i)
	}
	got, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	got = bytes.ReplaceAll(got, []byte(w.ID), []byte("<issue>"))
	got = bytes.ReplaceAll(got, []byte(m.ID), []byte("<milestone>"))
	// Commit IDs depend on the UUIDs; their form is what's checked.
	got = regexp.MustCompile(`"[0-9a-f]{40}"`).ReplaceAll(got, []byte(`"<oid>"`))
	golden(t, "issue.golden.json", append(got, '\n'))

	var e *issuez.Error
	if _, err := r.Load(ctx, "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
	if _, err := r.Load(ctx, w.ID[:8]); !errors.As(err, &e) || e.Code != issuez.CodeInvalidArgument {
		t.Errorf("prefix: %v", err)
	}
}

func TestLoadHistory(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w := create(t, r, "History")
	said, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("First"), ada)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).EditComment(said.Commit, "Second"), ada); err != nil {
		t.Fatal(err)
	}
	without, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	with, err := r.Load(ctx, w.ID, issuez.LoadHistory())
	if err != nil {
		t.Fatal(err)
	}
	if len(without.History) != 0 || len(without.Comments[0].History) != 0 {
		t.Errorf("history without LoadHistory: %+v", without.Comments[0].History)
	}
	if len(with.History) != 1 || len(with.Comments[0].History) != 2 || with.Comments[0].History[0].Text != "First" {
		t.Errorf("history: %+v / %+v", with.History, with.Comments[0].History)
	}
	if h := with.Comments[0].History; h[0].Previous != "" || h[1].Previous != "First" {
		t.Errorf("previous texts: %q, %q", h[0].Previous, h[1].Previous)
	}
	// Edit counts come either way.
	for _, i := range []*issuez.Issue{without, with} {
		if i.Edits != 0 || i.Comments[0].Edits != 1 {
			t.Errorf("edits: description %d, comment %d", i.Edits, i.Comments[0].Edits)
		}
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).SetDescription("Again"), ada); err != nil {
		t.Fatal(err)
	}
	if again, err := r.Load(ctx, w.ID); err != nil || again.Edits != 1 {
		t.Errorf("description edits: %v %v", again, err)
	}
}

func TestRepo_Query(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	when := func(year int) issuez.Actor {
		a := ada
		a.At = time.Date(year, time.January, 1, 0, 0, 0, 0, time.UTC)
		return a
	}
	mk := func(e *issuez.Edit, year int) string {
		w, err := r.Create(ctx, e, when(year))
		if err != nil {
			t.Fatal(err)
		}
		return w.ID
	}
	bob := issuez.Actor{Name: "Bob", Email: "bob@example.invalid", At: time.Date(2021, time.January, 1, 0, 0, 0, 0, time.UTC)}
	a := mk(new(issuez.Edit).SetTitle("Login crash").SetDescription("Only on Safari.").SetLabels("bug", "ui").
		AddAssignee(issuez.Person{Email: "grace@example.invalid"}).SetPriority(issuez.PriorityHigh), 2020)
	wb, err := r.Create(ctx, new(issuez.Edit).SetTitle("Dark mode").AddLabel("feature").SetPriority(issuez.PriorityLow).SetWorkflowState("review"), bob)
	if err != nil {
		t.Fatal(err)
	}
	mk(new(issuez.Edit).SetTitle("Old bug").AddLabel("bug").SetState("closed"), 2022)
	mk(new(issuez.Edit).SetTitle("Child").SetParent(a).AddBlocker(wb.ID), 2023)
	gone := mk(new(issuez.Edit).SetTitle("Gone"), 2024)
	if _, err := r.Update(ctx, gone, new(issuez.Edit).SetDeleted(true), when(2024)); err != nil {
		t.Fatal(err)
	}
	asc := issuez.Query{Order: issuez.SortCreated, Ascending: true}
	with := func(f func(*issuez.Query)) issuez.Query { q := asc; f(&q); return q }
	tests := []struct {
		name string
		q    issuez.Query
		want string
	}{
		{"default", asc, "Login crash,Dark mode,Child"},
		{"done", with(func(q *issuez.Query) { q.Done = issuez.TriYes }), "Old bug"},
		{"any", with(func(q *issuez.Query) { q.Done = issuez.TriAny }), "Login crash,Dark mode,Old bug,Child"},
		{"deleted", with(func(q *issuez.Query) { q.Deleted = issuez.TriYes; q.Done = issuez.TriAny }), "Gone"},
		{"states", with(func(q *issuez.Query) { q.Done = issuez.TriAny; q.States = []string{"closed"} }), "Old bug"},
		{"workflow", with(func(q *issuez.Query) { q.WorkflowStates = []string{"review"} }), "Dark mode"},
		{"labels", with(func(q *issuez.Query) { q.Labels = []string{"bug", "ui"} }), "Login crash"},
		{"not labels", with(func(q *issuez.Query) { q.NotLabels = []string{"bug"} }), "Dark mode,Child"},
		{"no labels", with(func(q *issuez.Query) { q.NoLabels = true }), "Child"},
		{"assignee", with(func(q *issuez.Query) { q.Assignees = []string{"grace@example.invalid"} }), "Login crash"},
		{"unassigned", with(func(q *issuez.Query) { q.Assignees = []string{""} }), "Dark mode,Child"},
		{"authors", with(func(q *issuez.Query) { q.Authors = []string{"bob@example.invalid"} }), "Dark mode"},
		{"priorities", with(func(q *issuez.Query) { q.Priorities = []issuez.Priority{issuez.PriorityHigh, issuez.PriorityLow} }), "Login crash,Dark mode"},
		{"parent", with(func(q *issuez.Query) { q.Parent = a }), "Child"},
		{"blocked", with(func(q *issuez.Query) { q.Blocked = issuez.TriYes }), "Child"},
		{"updated", with(func(q *issuez.Query) { q.UpdatedAfter = time.Date(2022, 6, 1, 0, 0, 0, 0, time.UTC) }), "Child"},
		{"updated before", with(func(q *issuez.Query) { q.UpdatedBefore = time.Date(2020, 6, 1, 0, 0, 0, 0, time.UTC) }), "Login crash"},
		{"text", with(func(q *issuez.Query) { q.Text = "safari" }), ""},
		{"text ignoring case", with(func(q *issuez.Query) { q.Text = "safari"; q.TextIgnoreCase = true }), "Login crash"},
		{"priority order", issuez.Query{Order: issuez.SortPriority}, "Login crash,Dark mode,Child"},
		{"default order", issuez.Query{}, "Child,Dark mode,Login crash"},
		{"default order ascending", issuez.Query{Ascending: true}, "Login crash,Dark mode,Child"},
		{"milestone none", with(func(q *issuez.Query) { q.Milestones = []string{""} }), "Login crash,Dark mode,Child"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			page, err := r.Query(ctx, tt.q)
			if err != nil {
				t.Fatal(err)
			}
			var titles []string
			for _, i := range page.Issues {
				titles = append(titles, i.Title)
			}
			if got := strings.Join(titles, ","); got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
	// Paging.
	q := asc
	q.Limit = 2
	first, err := r.Query(ctx, q)
	if err != nil || len(first.Issues) != 2 || first.Next == "" {
		t.Fatalf("first page: %v %+v", err, first)
	}
	q.After = first.Next
	second, err := r.Query(ctx, q)
	if err != nil || len(second.Issues) != 1 || second.Next != "" || second.Issues[0].Title != "Child" {
		t.Errorf("second page: %v %+v", err, second)
	}
	q.After = "garbage"
	if _, err := r.Query(ctx, q); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("bad cursor: %v", err)
	}
}

// covers: Issue_NewEntries
func TestSince(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w := create(t, r, "Since")
	other := create(t, r, "Other")
	first, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("First"), ada)
	if err != nil {
		t.Fatal(err)
	}
	second, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Second"), ada)
	if err != nil {
		t.Fatal(err)
	}
	i, err := r.Load(ctx, w.ID, issuez.Since(first.NewTip))
	if err != nil {
		t.Fatal(err)
	}
	if n := i.NewEntries(); i.Rewritten || len(n) != 1 || n[0].Commit != second.Commit {
		t.Errorf("since the first comment: %+v, rewritten %v", n, i.Rewritten)
	}
	all, err := r.Load(ctx, w.ID)
	if err != nil || len(all.NewEntries()) != len(all.Timeline) {
		t.Errorf("without Since: %v", err)
	}
	gone, err := r.Load(ctx, w.ID, issuez.Since(other.NewTip))
	if err != nil || !gone.Rewritten || len(gone.NewEntries()) != 0 {
		t.Errorf("another issue's tip: rewritten %v, %v", gone.Rewritten, err)
	}
}

// TestChange: one change per field, values the commit didn't say filled
// in, typed values parsed.
func TestChange(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w := create(t, r, "First title")
	grace := issuez.Person{Email: "grace@example.com", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	due := issuez.Date{Year: 2026, Month: time.December, Day: 1}
	for _, e := range []*issuez.Edit{
		new(issuez.Edit).SetTitle("Second title"),
		new(issuez.Edit).AddAssignee(grace),
		new(issuez.Edit).SetDueDate(due),
		new(issuez.Edit).SetLocked(true, "heated"),
		new(issuez.Edit).SetState("wontfix"),
	} {
		if _, err := r.Update(ctx, w.ID, e, ada); err != nil {
			t.Fatal(err)
		}
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	of := func(k int, f issuez.Field) []issuez.Change {
		var out []issuez.Change
		for _, ch := range i.Timeline[k].Changes {
			if ch.Field == f {
				out = append(out, ch)
			}
		}
		return out
	}
	if c := of(1, issuez.FieldTitle); len(c) != 1 || c[0].Old != "First title" || c[0].New != "Second title" {
		t.Errorf("title: %+v", c)
	}
	if c := of(2, issuez.FieldAssignees); len(c) != 1 || c[0].OldPerson != nil || c[0].NewPerson == nil || *c[0].NewPerson != grace {
		t.Errorf("assignee: %+v", c)
	}
	if c := of(3, issuez.FieldDueDate); len(c) != 1 || c[0].OldDate != nil || c[0].NewDate == nil || *c[0].NewDate != due {
		t.Errorf("due date: %+v", c)
	}
	if c := of(4, issuez.FieldLocked); len(c) != 1 || c[0].Reason != "heated" || len(of(4, issuez.FieldLockReason)) != 1 {
		t.Errorf("lock: %+v", i.Timeline[4].Changes)
	}
	if c := of(5, issuez.FieldState); len(c) != 1 || c[0].Old != "open" || c[0].OldDone || !c[0].NewDone {
		t.Errorf("state: %+v", c)
	}
}

func TestState_IsOpen(t *testing.T) {
	if !issuez.StateOpen.IsOpen() || issuez.StateClosed.IsOpen() || issuez.State("wontfix").IsOpen() {
		t.Error("IsOpen")
	}
}

func TestIssue_CommentOf(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, c := commented(t, r, "Thread")
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	var found *issuez.Comment
	for _, e := range i.Timeline {
		if e.Kind == issuez.EntryComment {
			found = i.CommentOf(e)
		}
	}
	if found == nil || found.ID != c.Commit || i.CommentOf(i.Timeline[0]) != nil {
		t.Errorf("CommentOf: %+v", found)
	}
}
