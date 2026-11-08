package issuez_test

import (
	"bytes"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestRepo_Snapshot(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	empty, err := r.Snapshot(ctx)
	if err != nil || len(empty.Tips) != 0 {
		t.Fatalf("empty: %v %v", err, empty)
	}
	w := create(t, r, "Watched")
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
	if err != nil {
		t.Fatal(err)
	}
	snap, err := r.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Tips) != 2 || snap.Tips[issuez.RefKey{Kind: issuez.KindIssue, ID: w.ID}] != w.NewTip ||
		snap.Tips[issuez.RefKey{Kind: issuez.KindMilestone, ID: m.ID}] != m.NewTip {
		t.Errorf("tips: %+v", snap.Tips)
	}
}

func TestSnapshot_MarshalBinary(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	create(t, r, "A")
	create(t, r, "B")
	snap, err := r.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	data, err := snap.MarshalBinary()
	if err != nil || len(data) == 0 {
		t.Fatalf("marshal: %v %d", err, len(data))
	}
	var back issuez.Snapshot
	if err := back.UnmarshalBinary(data); err != nil {
		t.Fatal(err)
	}
	if !maps.Equal(back.Tips, snap.Tips) {
		t.Errorf("round trip: %v != %v", back.Tips, snap.Tips)
	}
	again, _ := back.MarshalBinary()
	if !bytes.Equal(again, data) {
		t.Error("encoding isn't stable")
	}
}

func TestSnapshot_UnmarshalBinary(t *testing.T) {
	var s issuez.Snapshot
	if err := s.UnmarshalBinary(nil); err != nil || len(s.Tips) != 0 {
		t.Errorf("empty: %v", err)
	}
	for _, bad := range [][]byte{[]byte("garbage"), {0xff, 0, 1}, bytes.Repeat([]byte{7}, 100)} {
		var e *issuez.Error
		if err := s.UnmarshalBinary(bad); !errors.As(err, &e) {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

func TestDiff(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	create(t, r, "Kept")
	changed, gone := create(t, r, "Changed"), create(t, r, "Gone")
	before, err := r.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if d := issuez.Diff(nil, before); len(d) != 3 || d[0].Change != issuez.ChangeCreated || !d[0].OldTip.IsZero() {
		t.Errorf("from nothing: %+v", d)
	}
	if d := issuez.Diff(before, before); len(d) != 0 {
		t.Errorf("unchanged: %+v", d)
	}
	upd, err := r.Update(ctx, changed.ID, new(issuez.Edit).AddLabel("x"), ada)
	if err != nil {
		t.Fatal(err)
	}
	added := create(t, r, "Added")
	after, _ := r.Snapshot(ctx)
	delete(after.Tips, issuez.RefKey{Kind: issuez.KindIssue, ID: gone.ID})
	want := map[string]issuez.DiffEntry{
		changed.ID: {RefKey: issuez.RefKey{Kind: issuez.KindIssue, ID: changed.ID}, Change: issuez.ChangeUpdated, OldTip: changed.NewTip, NewTip: upd.NewTip},
		added.ID:   {RefKey: issuez.RefKey{Kind: issuez.KindIssue, ID: added.ID}, Change: issuez.ChangeCreated, NewTip: added.NewTip},
		gone.ID:    {RefKey: issuez.RefKey{Kind: issuez.KindIssue, ID: gone.ID}, Change: issuez.ChangeRemoved, OldTip: gone.NewTip},
	}
	d := issuez.Diff(before, after)
	if len(d) != len(want) {
		t.Fatalf("diff: %+v", d)
	}
	for i, e := range d {
		if e != want[e.ID] {
			t.Errorf("%s: got %+v, want %+v", e.ID, e, want[e.ID])
		}
		if i > 0 && d[i-1].ID > e.ID {
			t.Error("not sorted")
		}
	}
}

func TestOpen(t *testing.T) {
	work := initRepo(t)
	bare := initRepo(t, "--bare")
	for _, dir := range []string{work, filepath.Join(work, "."), bare} {
		r, err := issuez.Open(dir, issuez.WithEnv(testEnv()))
		if err != nil {
			t.Fatalf("Open(%q): %v", dir, err)
		}
		r.Close()
	}
	var e *issuez.Error
	ceiling := "GIT_CEILING_DIRECTORIES=" + filepath.Dir(t.TempDir())
	if _, err := issuez.Open(t.TempDir(), issuez.WithEnv(append(testEnv(), ceiling))); !errors.As(err, &e) || e.Code != issuez.CodeNotARepository {
		t.Errorf("not a repository: %v", err)
	}
	if _, err := issuez.Open(work, issuez.WithEnv(testEnv()), issuez.WithPoolSize(0)); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("bad option: %v", err)
	}
}

func TestRepo_Close(t *testing.T) {
	r := newRepo(t)
	w := create(t, r, "Before")
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	if err := r.Close(); err != nil {
		t.Errorf("second Close: %v", err)
	}
	var e *issuez.Error
	if _, err := r.Load(t.Context(), w.ID); !errors.As(err, &e) || e.Code != issuez.CodeInvalidArgument {
		t.Errorf("Load after Close: %v", err)
	}
	if w.ID == "" {
		t.Error("the write receipt didn't survive")
	}
}

func TestRepo_GitDir(t *testing.T) {
	dir := initRepo(t)
	r := open(t, dir)
	want, _ := filepath.EvalSymlinks(filepath.Join(dir, ".git"))
	got, _ := filepath.EvalSymlinks(r.GitDir())
	if got != want {
		t.Errorf("GitDir() = %q, want %q", got, want)
	}
}

func TestWithGit(t *testing.T) {
	dir := initRepo(t)
	if _, err := issuez.Open(dir, issuez.WithEnv(testEnv()), issuez.WithGit("/nonexistent/git")); err == nil {
		t.Fatal("opened with a git that isn't there")
	}
	marker := filepath.Join(t.TempDir(), "used")
	wrapper := script(t, t.TempDir(), "git", "touch "+marker+"\nexec git \"$@\"\n")
	create(t, open(t, dir, issuez.WithGit(wrapper)), "Through the wrapper")
	if _, err := os.Stat(marker); err != nil {
		t.Errorf("the wrapper wasn't run: %v", err)
	}
}

func TestWithEnv(t *testing.T) {
	dir := initRepo(t)
	out := filepath.Join(t.TempDir(), "seen")
	wrapper := script(t, t.TempDir(), "git", "printf %s \"$ISSUEZ_MARK\" > "+out+"\nexec git \"$@\"\n")
	r, err := issuez.Open(dir, issuez.WithEnv(append(testEnv(), "ISSUEZ_MARK=hello")), issuez.WithGit(wrapper))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	create(t, r, "Env")
	if b, _ := os.ReadFile(out); string(b) != "hello" {
		t.Errorf("git saw ISSUEZ_MARK=%q", b)
	}
}

func TestWithCommitter(t *testing.T) {
	dir := initRepo(t)
	w := create(t, open(t, dir, issuez.WithCommitter("Server", "server@example.invalid")), "Committed")
	if got := git(t, dir, "log", "-1", "--format=%cn <%ce> / %an", "refs/issues/"+w.ID); got != "Server <server@example.invalid> / Ada" {
		t.Errorf("committer: %q", got)
	}
}

func TestWithDoneStates(t *testing.T) {
	r := newRepo(t, issuez.WithDoneStates("shipped"))
	w, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("Done").SetState("shipped"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if !w.Issue.Done {
		t.Error("shipped isn't done")
	}
}

func TestWithWorkflowStates(t *testing.T) {
	r := newRepo(t, issuez.WithWorkflowStates("todo", "doing"))
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").SetWorkflowState("doing"), ada); err != nil {
		t.Errorf("doing: %v", err)
	}
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").SetWorkflowState("ready"), ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("ready: %v", err)
	}
	w, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("Default"), ada, issuez.Reload())
	if err != nil || w.Issue.WorkflowState != "todo" {
		t.Errorf("default: %v %q", err, w.Issue.WorkflowState)
	}
}

func TestWithExclusiveScopes(t *testing.T) {
	r := newRepo(t, issuez.WithExclusiveScopes("kind"))
	w := create(t, r, "Scoped", "kind/bug", "ui")
	u, err := r.Update(t.Context(), w.ID, new(issuez.Edit).AddLabel("kind/idea"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(u.Issue.Labels, ","); got != "ui,kind/idea" {
		t.Errorf("labels %q", got)
	}
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").AddLabel("kind/a").AddLabel("kind/b"), ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("two of one scope: %v", err)
	}
}

func TestWithExtraPrefixes(t *testing.T) {
	r := newRepo(t, issuez.WithExtraPrefixes("X-Acme-"))
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").SetExtra("X-Acme-Ticket", "7"), ada); err != nil {
		t.Errorf("allowed prefix: %v", err)
	}
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").SetExtra("X-Forgejo-Project", "1"), ada); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("default prefix replaced: %v", err)
	}
}

func TestWithLimit(t *testing.T) {
	r := newRepo(t, issuez.WithLimit("max_labels", 1))
	var e *issuez.Error
	if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("T").SetLabels("a", "b"), ada); !errors.As(err, &e) || e.Code != issuez.CodeLimit {
		t.Errorf("over the limit: %v", err)
	}
	if _, err := issuez.Open(initRepo(t), issuez.WithEnv(testEnv()), issuez.WithLimit("no_such_limit", 1)); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("unknown limit: %v", err)
	}
}

func TestWithPoolSize(t *testing.T) {
	dir := initRepo(t)
	for _, n := range []int{0, 65} {
		if _, err := issuez.Open(dir, issuez.WithEnv(testEnv()), issuez.WithPoolSize(n)); !errors.Is(err, issuez.ErrInvalidValue) {
			t.Errorf("pool size %d: %v", n, err)
		}
	}
	r := open(t, dir, issuez.WithPoolSize(1))
	// One session serves calls from many goroutines, one at a time.
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			if _, err := r.Create(t.Context(), new(issuez.Edit).SetTitle("Queued"), ada); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if n, err := r.Count(t.Context(), issuez.Query{}); err != nil || n != 4 {
		t.Errorf("count %d: %v", n, err)
	}
}

func TestWithNetworkTimeout(t *testing.T) {
	dir := initRepo(t)
	git(t, dir, "remote", "add", "origin", filepath.Join(t.TempDir(), "hub.git"))
	slow := script(t, t.TempDir(), "slow-git", "for a; do [ \"$a\" = fetch ] && exec sleep 30; done\nexec git \"$@\"\n")
	r := open(t, dir, issuez.WithGit(slow), issuez.WithNetworkTimeout(200*time.Millisecond))
	start := time.Now()
	_, err := r.Sync(t.Context(), "origin", issuez.SyncOptions{})
	var e *issuez.Error
	if !errors.As(err, &e) || e.Code != issuez.CodeTimeout {
		t.Fatalf("sync: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Errorf("timed out after %v", time.Since(start))
	}
}

func TestWithLocalTimeout(t *testing.T) {
	dir := initRepo(t)
	slow := script(t, t.TempDir(), "slow-git", "for a; do [ \"$a\" = for-each-ref ] && exec sleep 30; done\nexec git \"$@\"\n")
	r := open(t, dir, issuez.WithGit(slow), issuez.WithLocalTimeout(2*time.Second))
	start := time.Now()
	_, err := r.Snapshot(t.Context())
	var e *issuez.Error
	if !errors.As(err, &e) || e.Code != issuez.CodeTimeout {
		t.Fatalf("snapshot: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Errorf("timed out after %v", time.Since(start))
	}
	// 0 keeps the default.
	if _, err := open(t, dir, issuez.WithLocalTimeout(0)).Snapshot(t.Context()); err != nil {
		t.Errorf("default: %v", err)
	}
}

func TestWithCacheIssues(t *testing.T) {
	dir := initRepo(t)
	if _, err := issuez.Open(dir, issuez.WithEnv(testEnv()), issuez.WithCacheIssues(-1)); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("negative: %v", err)
	}
	reads := func(r *issuez.Repo) int {
		var mu sync.Mutex
		n := 0
		issuez.SetDefaultLogger(issuez.LogDebug, func(e issuez.LogEvent) {
			if e.Operation == "git.read-object" {
				mu.Lock()
				n++
				mu.Unlock()
			}
		})
		defer issuez.SetDefaultLogger(issuez.LogOff, nil)
		if _, err := r.Count(t.Context(), issuez.Query{}); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		defer mu.Unlock()
		return n
	}
	cached := open(t, dir)
	create(t, cached, "Cached")
	reads(cached)
	if n := reads(cached); n != 0 {
		t.Errorf("cached: %d reads the second time", n)
	}
	uncached := open(t, dir, issuez.WithCacheIssues(0))
	reads(uncached)
	if n := reads(uncached); n == 0 {
		t.Error("uncached: no reads the second time")
	}
}

func TestRepo_Resolve(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(12), ada)
	if err != nil {
		t.Fatal(err)
	}
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1.0"), ada)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name  string
		kind  issuez.Kind
		input string
		want  []string
	}{
		{"uuid", issuez.KindIssue, w.ID, []string{w.ID}},
		{"prefix", issuez.KindIssue, w.ID[:8], []string{w.ID}},
		{"number", issuez.KindIssue, "#12", []string{w.ID}},
		{"no number", issuez.KindIssue, "#13", nil},
		{"milestone name", issuez.KindMilestone, "v1.0", []string{m.ID}},
		{"milestone prefix", issuez.KindMilestone, m.ID[:8], []string{m.ID}},
		{"wrong kind", issuez.KindMilestone, w.ID, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := r.Resolve(ctx, tt.kind, tt.input)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got, tt.want) {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
	// Several: a prefix two IDs share.
	var ids []string
	for len(ids) < 2 {
		x := create(t, r, "Another")
		if ids, err = r.Resolve(ctx, issuez.KindIssue, x.ID[:1]); err != nil {
			t.Fatal(err)
		}
	}
	if !slices.IsSorted(ids) {
		t.Errorf("not sorted: %v", ids)
	}
}

func TestRepo_ResolveOne(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(7), ada)
	if err != nil {
		t.Fatal(err)
	}
	if id, err := r.ResolveOne(ctx, issuez.KindIssue, "#7"); err != nil || id != w.ID {
		t.Errorf("#7: %q %v", id, err)
	}
	if _, err := r.ResolveOne(ctx, issuez.KindIssue, "#8"); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("#8: %v", err)
	}
	// Create until two IDs share their first character.
	seen := map[byte]bool{w.ID[0]: true}
	for {
		x := create(t, r, "Another")
		if seen[x.ID[0]] {
			_, err := r.ResolveOne(ctx, issuez.KindIssue, x.ID[:1])
			var e *issuez.Error
			if !errors.Is(err, issuez.ErrAmbiguous) || !errors.As(err, &e) {
				t.Errorf("ambiguous: %v", err)
			}
			break
		}
		seen[x.ID[0]] = true
	}
}

func TestIsRef(t *testing.T) {
	for _, ref := range []string{"refs/issues/x", "refs/milestones/x", "refs/attachments/x", "refs/issuez-purged/x"} {
		if !issuez.IsRef(ref) {
			t.Errorf("IsRef(%q) = false", ref)
		}
	}
	for _, ref := range []string{"refs/heads/main", "refs/issues", "refs/tags/refs/issues/x"} {
		if issuez.IsRef(ref) {
			t.Errorf("IsRef(%q) = true", ref)
		}
	}
}

func TestRefPrefixes(t *testing.T) {
	got := issuez.RefPrefixes()
	want := []string{"refs/issues/", "refs/milestones/", "refs/attachments/", "refs/issuez-purged/"}
	if !slices.Equal(got, want) {
		t.Fatalf("RefPrefixes() = %q", got)
	}
	// The caller's copy: changing it changes nothing.
	got[0] = "refs/heads/"
	if issuez.IsRef("refs/heads/main") || issuez.RefPrefixes()[0] != "refs/issues/" {
		t.Error("RefPrefixes() shares its slice")
	}
}

func TestRefSpecs(t *testing.T) {
	specs := issuez.RefSpecs()
	if len(specs) != len(issuez.RefPrefixes()) || specs[0] != "+refs/issues/*:refs/issues/*" {
		t.Errorf("RefSpecs() = %q", specs)
	}
}

func TestWithEnvOverrides(t *testing.T) {
	ceiling := "GIT_CEILING_DIRECTORIES=" + filepath.Dir(t.TempDir())
	var e *issuez.Error
	// On top of the process's environment, which still finds git.
	if _, err := issuez.Open(t.TempDir(), issuez.WithEnvOverrides(ceiling)); !errors.As(err, &e) || e.Code != issuez.CodeNotARepository {
		t.Errorf("not a repository: %v", err)
	}
	// On top of WithEnv.
	if _, err := issuez.Open(t.TempDir(), issuez.WithEnv(testEnv()), issuez.WithEnvOverrides(ceiling)); !errors.As(err, &e) || e.Code != issuez.CodeNotARepository {
		t.Errorf("not a repository, with WithEnv: %v", err)
	}
}

func TestRepo_ResolveNumber(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(12), ada)
	if err != nil {
		t.Fatal(err)
	}
	if id, err := r.ResolveNumber(ctx, 12); err != nil || id != w.ID {
		t.Errorf("12: %q %v", id, err)
	}
	if _, err := r.ResolveNumber(ctx, 1); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("1: %v", err)
	}
}

func TestWithRetries(t *testing.T) {
	r := newRepo(t, issuez.WithRetries(3))
	if v, ok := r.Limit("cas_retries"); !ok || v != 3 {
		t.Errorf("cas_retries = %d, %v", v, ok)
	}
	if _, err := issuez.Open(initRepo(t), issuez.WithEnv(testEnv()), issuez.WithRetries(65)); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("over the maximum: %v", err)
	}
}

func TestRepo_Limit(t *testing.T) {
	r := newRepo(t, issuez.WithLimit("max_labels", 5))
	if v, ok := r.Limit("max_labels"); !ok || v != 5 {
		t.Errorf("max_labels = %d, %v", v, ok)
	}
	if v, ok := r.Limit("max_attachment_bytes"); !ok || v == 0 {
		t.Errorf("max_attachment_bytes = %d, %v", v, ok)
	}
	if _, ok := r.Limit("no_such_limit"); ok {
		t.Error("an unknown limit")
	}
	r.Close()
	if _, ok := r.Limit("max_labels"); ok {
		t.Error("a closed repo")
	}
}

func TestRepo_DropAll(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	create(t, r, "One")
	if _, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada); err != nil {
		t.Fatal(err)
	}
	n, err := r.DropAll(ctx)
	if err != nil || n < 2 {
		t.Fatalf("DropAll() = %d, %v", n, err)
	}
	if s, err := r.Snapshot(ctx); err != nil || len(s.Tips) != 0 {
		t.Errorf("left: %v %v", s, err)
	}
	if n, err := r.DropAll(ctx); err != nil || n != 0 {
		t.Errorf("again: %d %v", n, err)
	}
}

func TestRepo_AdoptRefs(t *testing.T) {
	ctx := t.Context()
	dir := initRepo(t)
	main := open(t, dir)
	scratchDir := initRepo(t, "--bare")
	scratch := open(t, scratchDir, issuez.WithEnvOverrides("GIT_OBJECT_DIRECTORY="+filepath.Join(main.GitDir(), "objects")))
	w := create(t, scratch, "Imported")
	if n, err := main.AdoptRefs(ctx, scratch); err != nil || n != 1 {
		t.Fatalf("AdoptRefs() = %d, %v", n, err)
	}
	if i, err := main.Load(ctx, w.ID); err != nil || i.Title != "Imported" {
		t.Errorf("adopted: %v %v", i, err)
	}
	var e *issuez.Error
	if _, err := main.AdoptRefs(ctx, scratch); !errors.As(err, &e) || e.Code != issuez.CodeContended {
		t.Errorf("again: %v", err)
	}
	own := newRepo(t)
	create(t, own, "Elsewhere")
	if _, err := main.AdoptRefs(ctx, own); !errors.As(err, &e) || e.Code != issuez.CodeCorrupt {
		t.Errorf("objects of its own: %v", err)
	}
}

func TestRepo_WriteSettings(t *testing.T) {
	ctx := t.Context()
	dir := initRepo(t)
	r := open(t, dir)
	if err := r.WriteSettings(ctx, issuez.Settings{DoneStates: []string{"wontfix", "cancelled"}, WorkflowStates: []string{"todo", "doing"}}); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "config", "issue.workflowStates"); got != "todo, doing" {
		t.Errorf("workflow states: %q", got)
	}
	if err := r.WriteSettings(ctx, issuez.Settings{WorkflowStates: []string{}}); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "config", "--get", "--default", "unset", "issue.workflowStates"); got != "unset" {
		t.Errorf("unset: %q", got)
	}
	if got := git(t, dir, "config", "issue.doneStates"); got != "wontfix, cancelled" {
		t.Errorf("done states kept: %q", got)
	}
	if err := r.WriteSettings(ctx, issuez.Settings{DoneStates: []string{"open"}}); !errors.Is(err, issuez.ErrInvalidValue) {
		t.Errorf("open as done: %v", err)
	}
}

func TestRepo_SetLogger(t *testing.T) {
	r := newRepo(t)
	var mine atomic.Int32
	r.SetLogger(issuez.LogDebug, func(e issuez.LogEvent) {
		if e.Operation == "git.update-ref" {
			mine.Add(1)
		}
	})
	create(t, r, "Logged")
	if mine.Load() == 0 {
		t.Error("no events for this repo")
	}
	r.SetLogger(issuez.LogOff, nil)
	n := mine.Load()
	create(t, r, "Quiet")
	if mine.Load() != n {
		t.Error("events after LogOff")
	}
}

// Replacing a logger while calls run: a call already under way logs through
// the logger it started with.
func TestRepo_SetLoggerWhileCallsRun(t *testing.T) {
	r := newRepo(t)
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				create(t, r, "Busy")
			}
		}()
	}
	for end := time.Now().Add(time.Second); time.Now().Before(end); {
		r.SetLogger(issuez.LogDebug, func(issuez.LogEvent) {})
		r.SetLogger(issuez.LogOff, nil)
	}
	close(stop)
	wg.Wait()
}
