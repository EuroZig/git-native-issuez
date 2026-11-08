package issuez_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

const missingID = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"

// revParse is ref's tip in dir, zero when there's none.
func revParse(t *testing.T, dir, ref string) issuez.OID {
	t.Helper()
	cmd := exec.Command("git", "rev-parse", "--verify", "-q", ref)
	cmd.Dir = dir
	cmd.Env = testEnv()
	out, err := cmd.Output()
	if err != nil {
		return issuez.OID{}
	}
	o, err := issuez.ParseOID(strings.TrimSpace(string(out)))
	if err != nil {
		t.Fatal(err)
	}
	return o
}

// commitOn writes an empty-tree commit with msg, on top of ref when it
// has a tip, and returns it. With move it moves ref there, as a foreign
// tool would.
func commitOn(t *testing.T, dir, ref, msg string, move bool) issuez.OID {
	t.Helper()
	tree := git(t, dir, "hash-object", "-t", "tree", "-w", "/dev/null")
	args := []string{"commit-tree", tree, "-m", msg}
	if !revParse(t, dir, ref).IsZero() {
		args = append(args, "-p", ref)
	}
	hexID := git(t, dir, args...)
	if move {
		git(t, dir, "update-ref", ref, hexID)
	}
	o, err := issuez.ParseOID(hexID)
	if err != nil {
		t.Fatal(err)
	}
	return o
}

// withHub gives r a bare remote "origin" and returns its path.
func withHub(t *testing.T, r *issuez.Repo) string {
	t.Helper()
	hub := initRepo(t, "--bare")
	git(t, r.GitDir(), "remote", "add", "origin", hub)
	return hub
}

// clone is a second repository with hub as origin, opened.
func clone(t *testing.T, hub string) *issuez.Repo {
	t.Helper()
	dir := initRepo(t)
	git(t, dir, "remote", "add", "origin", hub)
	return open(t, dir)
}

func mustSync(t *testing.T, r *issuez.Repo, opts issuez.SyncOptions) *issuez.SyncReport {
	t.Helper()
	rep, err := r.Sync(context.Background(), "origin", opts)
	if err != nil {
		t.Fatal(err)
	}
	return rep
}

func outcomeOf(rep *issuez.SyncReport, id string) (issuez.SyncOutcome, bool) {
	for _, it := range rep.Items {
		if it.ID == id {
			return it.Outcome, true
		}
	}
	return 0, false
}

// tree is E (in M) > C1 > G, E > C2 (closed); X blocked by B1 (open) and
// B2 (closed); O with a parent that isn't there; P and Q each other's
// parent.
type tree struct {
	r                                   *issuez.Repo
	m, e, c1, c2, g, x, b1, b2, o, p, q string
}

func newTree(t *testing.T) *tree {
	t.Helper()
	ctx := context.Background()
	r := newRepo(t)
	mk := func(e *issuez.Edit) string {
		t.Helper()
		w, err := r.Create(ctx, e, ada)
		if err != nil {
			t.Fatal(err)
		}
		return w.ID
	}
	m, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("M"), ada)
	if err != nil {
		t.Fatal(err)
	}
	tr := &tree{r: r, m: m.ID}
	tr.e = mk(new(issuez.Edit).SetTitle("E").SetMilestone(tr.m))
	tr.c1 = mk(new(issuez.Edit).SetTitle("C1").SetParent(tr.e).InheritMilestone())
	tr.g = mk(new(issuez.Edit).SetTitle("G").SetParent(tr.c1).InheritMilestone())
	tr.c2 = mk(new(issuez.Edit).SetTitle("C2").SetParent(tr.e).InheritMilestone().SetState("closed"))
	tr.b1 = mk(new(issuez.Edit).SetTitle("B1"))
	tr.b2 = mk(new(issuez.Edit).SetTitle("B2").SetState("closed"))
	tr.x = mk(new(issuez.Edit).SetTitle("X").AddBlocker(tr.b1).AddBlocker(tr.b2))
	tr.o = mk(new(issuez.Edit).SetTitle("O"))
	tr.p = mk(new(issuez.Edit).SetTitle("P"))
	tr.q = mk(new(issuez.Edit).SetTitle("Q"))
	dir := r.GitDir()
	commitOn(t, dir, "refs/issues/"+tr.o, "Parent\n\nX-Parent: "+missingID, true)
	commitOn(t, dir, "refs/issues/"+tr.p, "Parent\n\nX-Parent: "+tr.q, true)
	commitOn(t, dir, "refs/issues/"+tr.q, "Parent\n\nX-Parent: "+tr.p, true)
	return tr
}

// sorted copies l, sorted: the tests don't depend on sibling order.
func sorted(l []string) []string {
	l = slices.Clone(l)
	slices.Sort(l)
	return l
}

func TestRepo_Projection(t *testing.T) {
	t.Parallel()
	tr := newTree(t)
	p, err := tr.r.Projection(context.Background(), issuez.ProjectionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Issues) != 10 {
		t.Errorf("issues: %d", len(p.Issues))
	}

	t.Run("tree", func(t *testing.T) {
		// A missing parent makes O a root; P and Q, in a cycle, are none.
		for _, id := range []string{tr.e, tr.x, tr.b1, tr.b2, tr.o} {
			if !slices.Contains(p.Roots, id) {
				t.Errorf("root %s missing from %v", id, p.Roots)
			}
		}
		for _, id := range []string{tr.c1, tr.g, tr.c2} {
			if slices.Contains(p.Roots, id) {
				t.Errorf("child %s is a root", id)
			}
		}
		want := map[string][]string{tr.e: sorted([]string{tr.c1, tr.c2}), tr.c1: {tr.g}}
		for id, kids := range want {
			if got := sorted(p.Children[id]); !reflect.DeepEqual(got, kids) {
				t.Errorf("children of %s: %v, want %v", id, got, kids)
			}
		}
		if _, ok := p.Children[tr.g]; ok {
			t.Errorf("leaf G has children: %v", p.Children[tr.g])
		}
	})

	t.Run("blockers", func(t *testing.T) {
		if got := p.ActiveBlockers[tr.x]; !reflect.DeepEqual(got, []string{tr.b1}) {
			t.Errorf("active blockers of X: %v", got)
		}
		for _, b := range []string{tr.b1, tr.b2} {
			if got := p.Blocking[b]; !reflect.DeepEqual(got, []string{tr.x}) {
				t.Errorf("%s blocks %v", b, got)
			}
		}
		if _, ok := p.ActiveBlockers[tr.e]; ok {
			t.Errorf("E has blockers: %v", p.ActiveBlockers[tr.e])
		}
	})

	t.Run("progress", func(t *testing.T) {
		want := map[string]issuez.Progress{tr.e: {Done: 1, Total: 2}, tr.c1: {Done: 0, Total: 1}}
		for id, pr := range want {
			if p.Progress[id] != pr {
				t.Errorf("progress of %s: %+v, want %+v", id, p.Progress[id], pr)
			}
		}
		if pr, ok := p.Progress[tr.g]; ok {
			t.Errorf("leaf G has progress %+v", pr)
		}
		for _, id := range []string{tr.e, tr.c1, tr.g, tr.c2} {
			if p.MilestoneOf[id] != tr.m {
				t.Errorf("milestone of %s: %q", id, p.MilestoneOf[id])
			}
		}
		if m, ok := p.MilestoneOf[tr.x]; ok {
			t.Errorf("X in milestone %q", m)
		}
		if got := p.MilestoneProgress[tr.m]; got != (issuez.Progress{Done: 1, Total: 2}) {
			t.Errorf("milestone progress: %+v", got)
		}
	})

	t.Run("problems", func(t *testing.T) {
		kinds := map[issuez.ProblemKind]bool{}
		for _, pr := range p.Problems {
			kinds[pr.Kind] = true
		}
		if !kinds[issuez.ProblemMissingTarget] || !kinds[issuez.ProblemCycle] {
			t.Errorf("problems: %+v", p.Problems)
		}
	})
}

func TestProjectionOptions_Around(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	tr := newTree(t)
	all, err := tr.r.Projection(ctx, issuez.ProjectionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		name string
		id   string
	}{{"leaf", tr.g}, {"parent", tr.e}, {"blocked", tr.x}, {"blocker", tr.b1}} {
		t.Run(tt.name, func(t *testing.T) {
			p, err := tr.r.Projection(ctx, issuez.ProjectionOptions{Around: tt.id})
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Issues) >= len(all.Issues) {
				t.Errorf("around %s: %d issues, all %d", tt.name, len(p.Issues), len(all.Issues))
			}
			id := tt.id
			if got, want := sorted(p.Children[id]), sorted(all.Children[id]); !reflect.DeepEqual(got, want) {
				t.Errorf("children: %v, want %v", got, want)
			}
			if got, want := p.ActiveBlockers[id], all.ActiveBlockers[id]; !reflect.DeepEqual(got, want) {
				t.Errorf("active blockers: %v, want %v", got, want)
			}
			// Who it blocks needs every issue.
			if got := p.Blocking[id]; len(got) != 0 {
				t.Errorf("blocking: %v", got)
			}
			if p.Progress[id] != all.Progress[id] || p.MilestoneOf[id] != all.MilestoneOf[id] {
				t.Errorf("progress %+v milestone %q, want %+v %q",
					p.Progress[id], p.MilestoneOf[id], all.Progress[id], all.MilestoneOf[id])
			}
		})
	}
	if _, err := tr.r.Projection(ctx, issuez.ProjectionOptions{Around: missingID}); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("around a missing issue: %v", err)
	}
}

func TestRepo_PurgeComment(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	r := newRepo(t)
	w := create(t, r, "Moderated")
	bad, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Abuse"), ada)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Fine"), ada); err != nil {
		t.Fatal(err)
	}
	hub := withHub(t, r)
	mustSync(t, r, issuez.SyncOptions{})
	ref := "refs/issues/" + w.ID
	pushed := revParse(t, hub, ref)

	res, err := r.PurgeComment(ctx, w.ID, bad.Commit, ada, "abuse")
	if err != nil {
		t.Fatal(err)
	}
	if res.NewTip.IsZero() || res.NewTip != revParse(t, r.GitDir(), ref) ||
		!reflect.DeepEqual(res.ExposedRemotes, []string{"origin"}) {
		t.Errorf("comment purge: %+v", res)
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(i.Comments) != 2 || !i.Comments[0].Purged || strings.Contains(i.Comments[0].Text, "Abuse") ||
		i.Comments[1].Text != "Fine" {
		t.Errorf("after the purge: %+v", i.Comments)
	}

	// The next sync replaces the hub's copy and sends the tombstone.
	mustSync(t, r, issuez.SyncOptions{})
	if got := revParse(t, hub, ref); got == pushed || got != res.NewTip {
		t.Errorf("hub's tip %v, purged %v, before %v", got, res.NewTip, pushed)
	}
	if revParse(t, hub, "refs/issuez-purged/"+w.ID).IsZero() {
		t.Error("no tombstone on the hub")
	}

	// A commit that isn't one of the issue's comments.
	other := create(t, r, "Other")
	_, err = r.PurgeComment(ctx, w.ID, other.Commit, ada, "")
	var e *issuez.Error
	if !errors.As(err, &e) {
		t.Errorf("purging another issue's commit: %v", err)
	}
	if _, err := r.PurgeComment(ctx, missingID, bad.Commit, ada, ""); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("missing issue: %v", err)
	}
}

func TestRepo_PurgeIssue(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	t.Run("local only", func(t *testing.T) {
		t.Parallel()
		r := newRepo(t)
		w := create(t, r, "Doxxing")
		res, err := r.PurgeIssue(ctx, w.ID, ada, "")
		if err != nil || !res.NewTip.IsZero() || len(res.ExposedRemotes) != 0 {
			t.Fatalf("purge: %v %+v", err, res)
		}
		if _, err := r.Load(ctx, w.ID); !errors.Is(err, issuez.ErrNotFound) {
			t.Errorf("load after purge: %v", err)
		}
		if _, err := r.PurgeIssue(ctx, missingID, ada, ""); !errors.Is(err, issuez.ErrNotFound) {
			t.Errorf("missing issue: %v", err)
		}
	})
	t.Run("exposed remotes", func(t *testing.T) {
		t.Parallel()
		r := newRepo(t)
		w := create(t, r, "Doxxing")
		hub := withHub(t, r)
		mustSync(t, r, issuez.SyncOptions{})
		other := clone(t, hub)
		mustSync(t, other, issuez.SyncOptions{})

		res, err := r.PurgeIssue(ctx, w.ID, ada, "legal")
		if err != nil || !reflect.DeepEqual(res.ExposedRemotes, []string{"origin"}) {
			t.Fatalf("purge: %v %+v", err, res)
		}
		// The sync deletes the hub's copy; the other clone's goes next.
		rep := mustSync(t, r, issuez.SyncOptions{})
		if o, _ := outcomeOf(rep, w.ID); o != issuez.SyncPurged {
			t.Errorf("outcome %v: %+v", o, rep.Items)
		}
		if !revParse(t, hub, "refs/issues/"+w.ID).IsZero() {
			t.Error("the hub still has the issue")
		}
		rep = mustSync(t, other, issuez.SyncOptions{})
		if o, _ := outcomeOf(rep, w.ID); o != issuez.SyncPurged {
			t.Errorf("other clone's outcome %v: %+v", o, rep.Items)
		}
		if _, err := other.Load(ctx, w.ID); !errors.Is(err, issuez.ErrNotFound) {
			t.Errorf("other clone still loads it: %v", err)
		}
	})
}

func TestRepo_Sync(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	t.Run("push and merge", func(t *testing.T) {
		t.Parallel()
		a := newRepo(t)
		w := create(t, a, "Shared")
		hub := withHub(t, a)
		rep := mustSync(t, a, issuez.SyncOptions{})
		if len(rep.Items) != 1 || rep.Items[0] != (issuez.SyncItem{
			Kind: issuez.KindIssue, ID: w.ID, Outcome: issuez.SyncPushed, LocalTip: w.NewTip,
			RemoteTip: w.NewTip,
		}) || !rep.OK {
			t.Errorf("push: %+v", rep)
		}
		b := clone(t, hub)
		if o, _ := outcomeOf(mustSync(t, b, issuez.SyncOptions{}), w.ID); o != issuez.SyncNew {
			t.Errorf("new: %v", o)
		}
		steps := []struct {
			name   string
			writer *issuez.Repo
			want   issuez.SyncOutcome
		}{
			{"fast-forward", a, issuez.SyncFastForward},
			{"merged", b, issuez.SyncMerged},
		}
		for _, s := range steps {
			if _, err := a.Update(ctx, w.ID, new(issuez.Edit).AddComment("From A"), ada); err != nil {
				t.Fatal(err)
			}
			mustSync(t, a, issuez.SyncOptions{})
			if s.writer == b {
				if _, err := b.Update(ctx, w.ID, new(issuez.Edit).AddComment("From B"), ada); err != nil {
					t.Fatal(err)
				}
			}
			if o, _ := outcomeOf(mustSync(t, b, issuez.SyncOptions{}), w.ID); o != s.want {
				t.Errorf("%s: %v", s.name, o)
			}
		}
		if o, _ := outcomeOf(mustSync(t, b, issuez.SyncOptions{}), w.ID); o != issuez.SyncUpToDate {
			t.Errorf("up to date: %v", o)
		}
		m, err := a.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada)
		if err != nil {
			t.Fatal(err)
		}
		rep = mustSync(t, a, issuez.SyncOptions{})
		found := false
		for _, it := range rep.Items {
			found = found || it.ID == m.ID && it.Kind == issuez.KindMilestone
		}
		if !found {
			t.Errorf("milestone not synced: %+v", rep.Items)
		}
	})

	t.Run("no push", func(t *testing.T) {
		t.Parallel()
		r := newRepo(t)
		w := create(t, r, "Local")
		hub := withHub(t, r)
		if _, ok := outcomeOf(mustSync(t, r, issuez.SyncOptions{NoPush: true}), w.ID); ok {
			t.Error("reported a local-only issue")
		}
		if got := git(t, hub, "for-each-ref", "refs/issues/"); got != "" {
			t.Errorf("hub has %s", got)
		}
	})

	t.Run("quarantine", func(t *testing.T) {
		t.Parallel()
		a := newRepo(t)
		w := create(t, a, "Rewritten")
		hub := withHub(t, a)
		mustSync(t, a, issuez.SyncOptions{})
		git(t, hub, "update-ref", "-d", "refs/issues/"+w.ID)
		commitOn(t, hub, "refs/issues/"+w.ID, "Started over\n\nState: open\nFormat-Version: 1", true)
		rep := mustSync(t, a, issuez.SyncOptions{})
		var item issuez.SyncItem
		for _, it := range rep.Items {
			if it.ID == w.ID {
				item = it
			}
		}
		if rep.OK || item.Outcome != issuez.SyncQuarantined || item.Reason == "" {
			t.Errorf("rewound hub: %+v", rep)
		}
	})

	t.Run("errors", func(t *testing.T) {
		t.Parallel()
		r := newRepo(t)
		create(t, r, "Refused")
		hub := withHub(t, r)
		script(t, filepath.Join(hub, "hooks"), "pre-receive", "echo 'no issues here' >&2\nexit 1\n")
		_, err := r.Sync(ctx, "origin", issuez.SyncOptions{})
		var e *issuez.Error
		if !errors.As(err, &e) || e.Code != issuez.CodeNetwork || !strings.Contains(e.GitStderr, "no issues here") {
			t.Errorf("refusing hub: %v", err)
		}
		if _, err := r.Sync(ctx, "no-such-remote", issuez.SyncOptions{}); !errors.As(err, &e) {
			t.Errorf("unknown remote: %v", err)
		}
		cancelled, cancel := context.WithCancel(ctx)
		cancel()
		if _, err := r.Sync(cancelled, "origin", issuez.SyncOptions{}); !issuez.IsCancelled(err) {
			t.Errorf("cancelled: %v", err)
		}
	})

	// The derived ref of an issue with an attachment goes along; with
	// git-lfs the bytes too, unless NoAttachments.
	for _, upload := range []bool{false, true} {
		t.Run(fmt.Sprintf("attachments upload=%v", upload), func(t *testing.T) {
			t.Parallel()
			if upload {
				if err := exec.Command("git", "lfs", "version").Run(); err != nil {
					t.Skip("no git-lfs")
				}
			}
			r := newRepo(t)
			w := create(t, r, "With a screenshot")
			// An attachment as `git issue attach` writes it: the bytes in
			// the issuez store, the trailer on a commit.
			data := []byte("not really a png")
			sum := sha256.Sum256(data)
			sha := hex.EncodeToString(sum[:])
			store := filepath.Join(r.GitDir(), "issuez", "lfs", "objects", sha[0:2], sha[2:4])
			if err := os.MkdirAll(store, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(store, sha), data, 0o644); err != nil {
				t.Fatal(err)
			}
			msg := fmt.Sprintf("Add attachment\n\nX-Attachment: %s image/png %d sha256:%s shot.png",
				missingID, len(data), sha)
			commitOn(t, r.GitDir(), "refs/issues/"+w.ID, msg, true)
			hub := withHub(t, r)
			mustSync(t, r, issuez.SyncOptions{NoAttachments: !upload})
			if revParse(t, hub, "refs/attachments/"+w.ID).IsZero() {
				t.Error("no derived ref on the hub")
			}
			_, err := os.Stat(filepath.Join(hub, "lfs", "objects", sha[0:2], sha[2:4], sha))
			if upload != (err == nil) {
				t.Errorf("bytes on the hub: %v", err == nil)
			}
		})
	}
}

// pushFix is a host and a client that would push to it, the push read as
// a pre-receive hook sees it: the client's objects as the quarantine, the
// host's as its alternate.
type pushFix struct {
	server, client *issuez.Repo
	serverDir      string
	clientDir      string
}

func newPushFix(t *testing.T) *pushFix {
	t.Helper()
	f := &pushFix{serverDir: initRepo(t, "--bare"), clientDir: initRepo(t)}
	git(t, f.clientDir, "remote", "add", "origin", f.serverDir)
	f.server = open(t, f.serverDir)
	f.client = open(t, f.clientDir)
	return f
}

// land really pushes refs to the server, unchecked.
func (f *pushFix) land(t *testing.T, refs ...string) {
	t.Helper()
	for _, ref := range refs {
		git(t, f.clientDir, "push", "-q", "-f", "origin", ref+":"+ref)
	}
}

// update brings the server's ref to the client's.
func (f *pushFix) update(t *testing.T, ref string) issuez.RefUpdate {
	t.Helper()
	return issuez.RefUpdate{Ref: ref, Old: revParse(t, f.serverDir, ref), New: revParse(t, f.clientDir, ref)}
}

func (f *pushFix) policy() issuez.PushPolicy {
	return issuez.PushPolicy{
		ObjectDir:           filepath.Join(f.client.GitDir(), "objects"),
		AlternateObjectDirs: filepath.Join(f.server.GitDir(), "objects"),
	}
}

// verdict is what a case expects of one update; Problem zero for none.
type verdict struct {
	Action  issuez.PushAction
	Kind    issuez.Kind
	Accept  bool
	Problem issuez.ProblemKind
}

func TestRepo_PushCheck(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	issueRef := func(id string) string { return "refs/issues/" + id }
	write := func(t *testing.T, r *issuez.Repo, id string, e *issuez.Edit, who issuez.Actor) {
		t.Helper()
		if _, err := r.Update(ctx, id, e, who); err != nil {
			t.Fatal(err)
		}
	}
	mallory := issuez.Actor{Name: "M", Email: "mallory@example.com"}
	tests := []struct {
		name string
		// Builds the push and the policy to check it under.
		setup func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy)
		want  []verdict
	}{
		{
			name: "create, ignored",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Pushed")
				p := f.policy()
				p.PusherEmails, p.Authors = []string{"ADA@example.com"}, issuez.AuthorEnforce
				return []issuez.RefUpdate{
					f.update(t, issueRef(w.ID)), {Ref: "refs/heads/main", New: w.NewTip},
				}, p
			},
			want: []verdict{
				{Action: issuez.PushCreate, Kind: issuez.KindIssue, Accept: true},
				{Action: issuez.PushIgnored, Accept: true},
			},
		},
		{
			name: "fast-forward",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Pushed")
				f.land(t, issueRef(w.ID))
				write(t, f.client, w.ID, new(issuez.Edit).AddComment("More"), ada)
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, f.policy()
			},
			want: []verdict{{Action: issuez.PushFastForward, Kind: issuez.KindIssue, Accept: true}},
		},
		{
			name: "rewind, delete, local ref, bad name",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Base")
				ref := issueRef(w.ID)
				write(t, f.client, w.ID, new(issuez.Edit).AddComment("Second"), ada)
				f.land(t, ref)
				tip := revParse(t, f.serverDir, ref)
				return []issuez.RefUpdate{
					{Ref: ref, Old: tip, New: w.NewTip},
					{Ref: ref, Old: tip},
					{Ref: "refs/issuez-guard/x", New: w.NewTip},
					{Ref: "refs/issues/not-a-uuid", New: w.NewTip},
				}, f.policy()
			},
			want: []verdict{
				{Action: issuez.PushRewrite, Kind: issuez.KindIssue, Problem: issuez.ProblemNonFastForward},
				{Action: issuez.PushDelete, Kind: issuez.KindIssue, Problem: issuez.ProblemRefDeleted},
				{Action: issuez.PushCreate, Problem: issuez.ProblemLocalRef},
				{Action: issuez.PushCreate, Problem: issuez.ProblemBadRefName},
			},
		},
		{
			name: "someone else's commit, enforced",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("Spoofed"), mallory)
				if err != nil {
					t.Fatal(err)
				}
				p := f.policy()
				p.PusherEmails, p.Authors = []string{"ada@example.com"}, issuez.AuthorEnforce
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, p
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemAuthorMismatch}},
		},
		{
			name: "someone else's commit, warned",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("Spoofed"), mallory)
				if err != nil {
					t.Fatal(err)
				}
				p := f.policy()
				p.PusherEmails, p.Authors = []string{"ada@example.com"}, issuez.AuthorWarn
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, p
			},
			want: []verdict{{
				Action: issuez.PushCreate, Kind: issuez.KindIssue, Accept: true,
				Problem: issuez.ProblemAuthorMismatch,
			}},
		},
		{
			name: "the pusher's email on someone else's UUID",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				forged := ada
				forged.UserID = "1d9e8b63-4a2f-4c7b-8e3d-6f5a4b3c2d1e"
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("As Ada"), forged)
				if err != nil {
					t.Fatal(err)
				}
				p := f.policy()
				p.PusherEmails, p.Authors = []string{"ada@example.com"}, issuez.AuthorEnforce
				p.PusherUserIDs = []string{"0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, p
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemAuthorMismatch}},
		},
		{
			name: "the pusher's own UUID",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				own := ada
				own.UserID = "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("By Ada"), own)
				if err != nil {
					t.Fatal(err)
				}
				p := f.policy()
				p.PusherEmails, p.Authors = []string{"ada@example.com"}, issuez.AuthorEnforce
				p.PusherUserIDs = []string{own.UserID}
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, p
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Accept: true}},
		},
		{
			name: "client number",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(5), ada)
				if err != nil {
					t.Fatal(err)
				}
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, f.policy()
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemReadOnlyField}},
		},
		{
			name: "taken number",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(5), ada)
				if err != nil {
					t.Fatal(err)
				}
				f.land(t, issueRef(w.ID))
				twin := create(t, f.client, "Twin")
				commitOn(t, f.clientDir, issueRef(twin.ID), "Number\n\nX-Number: 5", true)
				p := f.policy()
				p.AllowNumbers = true
				return []issuez.RefUpdate{f.update(t, issueRef(twin.ID))}, p
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemDuplicateNumber}},
		},
		{
			name: "another format",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				o := commitOn(t, f.clientDir, "refs/none", "Future\n\nState: open\nFormat-Version: 2", false)
				return []issuez.RefUpdate{{Ref: issueRef(missingID), New: o}}, f.policy()
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemUnsupportedFormat}},
		},
		{
			name: "outside the quarantine",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Pushed")
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, issuez.PushPolicy{}
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemInvalidHistory}},
		},
		{
			name: "locked",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Heated")
				write(t, f.client, w.ID, new(issuez.Edit).SetLocked(true, "heated"), ada)
				f.land(t, issueRef(w.ID))
				write(t, f.client, w.ID, new(issuez.Edit).AddComment("Still"), ada)
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, f.policy()
			},
			want: []verdict{{Action: issuez.PushFastForward, Kind: issuez.KindIssue, Accept: true}},
		},
		{
			name: "purges without leave",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				return purges(t, f), f.policy()
			},
			want: []verdict{
				{Action: issuez.PushRewrite, Kind: issuez.KindIssue, Problem: issuez.ProblemNonFastForward},
				{Action: issuez.PushCreate, Kind: issuez.KindTombstone, Problem: issuez.ProblemPurgeNotAllowed},
				{Action: issuez.PushDelete, Kind: issuez.KindIssue, Problem: issuez.ProblemRefDeleted},
				{Action: issuez.PushCreate, Kind: issuez.KindTombstone, Problem: issuez.ProblemPurgeNotAllowed},
			},
		},
		{
			name: "purges with leave",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				p := f.policy()
				p.AllowPurge = true
				return purges(t, f), p
			},
			want: []verdict{
				{Action: issuez.PushRewrite, Kind: issuez.KindIssue, Accept: true},
				{Action: issuez.PushCreate, Kind: issuez.KindTombstone, Accept: true},
				{Action: issuez.PushDelete, Kind: issuez.KindIssue, Accept: true},
				{Action: issuez.PushCreate, Kind: issuez.KindTombstone, Accept: true},
			},
		},
		{
			name: "purged history back, forged tombstone",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				ups := purges(t, f)
				x, xt := ups[0].Ref, ups[1].Ref
				f.land(t, xt)
				old := revParse(t, f.serverDir, x)
				forged := commitOn(t, f.clientDir, xt, "Hello\n\nX-Purge: maybe", false)
				p := f.policy()
				p.AllowPurge = true
				return []issuez.RefUpdate{
					{Ref: x, Old: old, New: old},
					{Ref: xt, Old: revParse(t, f.serverDir, xt), New: forged},
				}, p
			},
			want: []verdict{
				{Action: issuez.PushFastForward, Kind: issuez.KindIssue, Problem: issuez.ProblemPurged},
				{Action: issuez.PushFastForward, Kind: issuez.KindTombstone, Problem: issuez.ProblemNotAPurge},
			},
		},
		{
			name: "attachments not derived",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Screenshot")
				fake := commitOn(t, f.clientDir, "refs/none", "Regenerate attachments", false)
				return []issuez.RefUpdate{
					f.update(t, issueRef(w.ID)), {Ref: "refs/attachments/" + w.ID, New: fake},
				}, f.policy()
			},
			want: []verdict{
				{Action: issuez.PushCreate, Kind: issuez.KindIssue, Accept: true},
				{Action: issuez.PushCreate, Kind: issuez.KindAttachments, Problem: issuez.ProblemNotDerived},
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newPushFix(t)
			ups, policy := tt.setup(t, f)
			vs, err := f.server.PushCheck(ctx, ups, policy)
			accepted := true
			for _, w := range tt.want {
				accepted = accepted && w.Accept
			}
			if accepted && err != nil || !accepted && !errors.Is(err, issuez.ErrRejected) {
				t.Errorf("err %v, want accepted %v", err, accepted)
			}
			if len(vs) != len(tt.want) {
				t.Fatalf("%d verdicts, want %d: %+v", len(vs), len(tt.want), vs)
			}
			for i, w := range tt.want {
				v := vs[i]
				if v.Ref != ups[i].Ref || v.Action != w.Action || v.Kind != w.Kind || v.Accept != w.Accept {
					t.Errorf("verdict %d: %+v, want %+v", i, v, w)
				}
				has := false
				for _, p := range v.Problems {
					has = has || p.Kind == w.Problem
				}
				if w.Problem != 0 && !has || w.Problem == 0 && len(v.Problems) != 0 {
					t.Errorf("verdict %d problems %+v, want %v", i, v.Problems, w.Problem)
				}
			}
		})
	}

	t.Run("facts", func(t *testing.T) {
		t.Parallel()
		f := newPushFix(t)
		w := create(t, f.client, "Heated")
		write(t, f.client, w.ID, new(issuez.Edit).SetLocked(true, "heated"), ada)
		vs, err := f.server.PushCheck(ctx, []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, f.policy())
		if err != nil || !vs[0].NeedsNumber || vs[0].CommitCount != 2 || len(vs[0].Entries) != 2 ||
			vs[0].Entries[0].Kind != issuez.EntryCreated || vs[0].ID != w.ID {
			t.Errorf("new issue: %v %+v", err, vs)
		}
		f.land(t, issueRef(w.ID))
		write(t, f.client, w.ID, new(issuez.Edit).AddComment("Still"), ada)
		vs, err = f.server.PushCheck(ctx, []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, f.policy())
		if err != nil || !vs[0].TouchesLocked || vs[0].CommitCount != 1 {
			t.Errorf("locked issue: %v %+v", err, vs)
		}
		p := f.policy()
		p.AllowNumbers = true
		n, err := f.client.Create(ctx, new(issuez.Edit).SetTitle("Numbered").SetNumber(7), ada)
		if err != nil {
			t.Fatal(err)
		}
		vs, err = f.server.PushCheck(ctx, []issuez.RefUpdate{f.update(t, issueRef(n.ID))}, p)
		if err != nil || vs[0].NeedsNumber {
			t.Errorf("numbered by the client: %v %+v", err, vs)
		}
		if vs, err := f.server.PushCheck(ctx, nil, f.policy()); err != nil || len(vs) != 0 {
			t.Errorf("empty push: %v %+v", err, vs)
		}
		bad := []issuez.RefUpdate{{Ref: issueRef(w.ID)}}
		var e *issuez.Error
		if _, err := f.server.PushCheck(ctx, bad, f.policy()); !errors.As(err, &e) {
			t.Errorf("an update without old or new: %v", err)
		}
	})
}

// purges lands X (with a comment) and Y on the server, purges the comment
// and Y in the client, and returns the updates that would send the
// purges: X, its tombstone, Y, its tombstone.
func purges(t *testing.T, f *pushFix) []issuez.RefUpdate {
	t.Helper()
	ctx := context.Background()
	x := create(t, f.client, "Talk")
	said, err := f.client.Update(ctx, x.ID, new(issuez.Edit).AddComment("Abuse"), ada)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.client.Update(ctx, x.ID, new(issuez.Edit).AddComment("Fine"), ada); err != nil {
		t.Fatal(err)
	}
	y := create(t, f.client, "Doxxing")
	f.land(t, "refs/issues/"+x.ID, "refs/issues/"+y.ID)
	if _, err := f.client.PurgeComment(ctx, x.ID, said.Commit, ada, "abuse"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.client.PurgeIssue(ctx, y.ID, ada, "legal"); err != nil {
		t.Fatal(err)
	}
	var ups []issuez.RefUpdate
	for _, id := range []string{x.ID, y.ID} {
		ups = append(ups, f.update(t, "refs/issues/"+id), f.update(t, "refs/issuez-purged/"+id))
	}
	return ups
}

// TestPushVerdict_authorsAndAttachments: what a host's permission rules
// need from a verdict without loading the issue: who opened it, whose
// comment an entry touches, and the images to find in its LFS store.
func TestPushVerdict_authorsAndAttachments(t *testing.T) {
	ctx := t.Context()
	f := newPushFix(t)
	client := open(t, f.clientDir, issuez.WithAttachmentStore(false))
	w, err := client.Create(ctx, new(issuez.Edit).SetTitle("Pictured"), ada)
	if err != nil {
		t.Fatal(err)
	}
	said, err := client.Update(ctx, w.ID, new(issuez.Edit).AddComment("Ada's"), ada)
	if err != nil {
		t.Fatal(err)
	}
	ref := "refs/issues/" + w.ID
	f.land(t, ref)
	grace := issuez.Actor{Name: "Grace", Email: "grace@example.com"}
	if _, err := client.Update(ctx, w.ID, new(issuez.Edit).EditComment(said.Commit, "Edited by Grace").
		AddAttachment("", "a.png", png), grace); err != nil {
		t.Fatal(err)
	}
	vs, err := f.server.PushCheck(ctx, []issuez.RefUpdate{f.update(t, ref)}, f.policy())
	if err != nil {
		t.Fatal(err)
	}
	v := vs[0]
	if v.IssueAuthor == nil || v.IssueAuthor.Email != ada.Email {
		t.Errorf("issue author: %+v", v.IssueAuthor)
	}
	if len(v.Entries) != 1 || v.Entries[0].CommentAuthor == nil || v.Entries[0].CommentAuthor.Email != ada.Email {
		t.Errorf("the edited comment's author: %+v", v.Entries)
	}
	sum := sha256.Sum256(png)
	if len(v.Attachments) != 1 || v.Attachments[0].SHA256 != hex.EncodeToString(sum[:]) || v.Attachments[0].Size != uint64(len(png)) {
		t.Errorf("attachments: %+v", v.Attachments)
	}
}

func TestRepo_SyncStatus(t *testing.T) {
	r := newRepo(t)
	w := create(t, r, "Unpushed")
	withHub(t, r)
	st, err := r.SyncStatus(t.Context(), "origin")
	if err != nil || len(st.Pending) != 1 || st.Pending[0] != w.ID || len(st.Quarantined) != 0 {
		t.Errorf("SyncStatus() = %+v, %v", st, err)
	}
	mustSync(t, r, issuez.SyncOptions{})
	if st, err := r.SyncStatus(t.Context(), "origin"); err != nil || len(st.Pending) != 0 {
		t.Errorf("after a sync: %+v, %v", st, err)
	}
}

func TestRepo_Search(t *testing.T) {
	r := newRepo(t)
	w := create(t, r, "Login crashes")
	create(t, r, "Other")
	hits, err := r.Search(t.Context(), "login", issuez.SearchOptions{IgnoreCase: true})
	if err != nil || len(hits) != 1 || hits[0] != (issuez.SearchHit{IssueID: w.ID, Line: "Login crashes"}) {
		t.Errorf("Search() = %+v, %v", hits, err)
	}
}

func TestRepo_DefaultRemotes(t *testing.T) {
	r := newRepo(t)
	if names, err := r.DefaultRemotes(t.Context()); err != nil || len(names) != 0 {
		t.Errorf("no remotes: %v %v", names, err)
	}
	withHub(t, r)
	if names, err := r.DefaultRemotes(t.Context()); err != nil || len(names) != 1 || names[0] != "origin" {
		t.Errorf("origin: %v %v", names, err)
	}
}

func TestRepo_ConfigureRemote(t *testing.T) {
	r := newRepo(t)
	withHub(t, r)
	s, err := r.ConfigureRemote(t.Context(), "origin", issuez.RemoteOptions{})
	if err != nil || !s.Configured || s.Unsafe {
		t.Errorf("first: %+v %v", s, err)
	}
	if s, err := r.ConfigureRemote(t.Context(), "origin", issuez.RemoteOptions{}); err != nil || s.Configured {
		t.Errorf("again: %+v %v", s, err)
	}
	if _, err := r.ConfigureRemote(t.Context(), "upstream", issuez.RemoteOptions{}); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("unknown: %v", err)
	}
}

func TestRepo_Fsck(t *testing.T) {
	r := newRepo(t)
	create(t, r, "Fine")
	rep, err := r.Fsck(t.Context(), issuez.FsckOptions{})
	if err != nil || rep.Issues != 1 || rep.Errors != 0 {
		t.Fatalf("clean: %+v %v", rep, err)
	}
	dir := r.GitDir()
	tree := git(t, dir, "hash-object", "-t", "tree", "-w", "/dev/null")
	commit := git(t, dir, "commit-tree", tree, "-m", "Odd")
	git(t, dir, "update-ref", "refs/issues/not-a-uuid", commit)
	rep, err = r.Fsck(t.Context(), issuez.FsckOptions{})
	if err != nil || rep.Errors == 0 || len(rep.Findings) == 0 || rep.Findings[0].Kind != issuez.FsckIntegrity || rep.Findings[0].Subject != "not-a-uuid" {
		t.Errorf("damaged: %+v %v", rep, err)
	}
}
