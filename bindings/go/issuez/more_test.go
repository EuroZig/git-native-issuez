package issuez_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os/exec"
	"path/filepath"
	"reflect"
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
	// What syncing with origin leaves: a tracking ref for the issue it has.
	git(t, r.GitDir(), "remote", "add", "origin", initRepo(t, "--bare"))
	git(t, r.GitDir(), "update-ref", "refs/remotes/origin/issues/"+w.ID, w.NewTip.String())
	ref := "refs/issues/" + w.ID

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
			name: "outside the quarantine",
			setup: func(t *testing.T, f *pushFix) ([]issuez.RefUpdate, issuez.PushPolicy) {
				w := create(t, f.client, "Pushed")
				return []issuez.RefUpdate{f.update(t, issueRef(w.ID))}, issuez.PushPolicy{}
			},
			want: []verdict{{Action: issuez.PushCreate, Kind: issuez.KindIssue, Problem: issuez.ProblemInvalidHistory}},
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

// refState is every ref and how many objects there are, loose or packed.
func refState(t *testing.T, dir string) string {
	t.Helper()
	return git(t, dir, "for-each-ref") + git(t, dir, "count-objects", "-v")
}

func TestRepo_Fsck(t *testing.T) {
	r := newRepo(t)
	w := create(t, r, "Fine")
	rep, err := r.Fsck(t.Context())
	if err != nil || rep.Issues != 1 || rep.Errors != 0 {
		t.Fatalf("clean: %+v %v", rep, err)
	}
	dir := r.GitDir()
	tree := git(t, dir, "hash-object", "-t", "tree", "-w", "/dev/null")
	commit := git(t, dir, "commit-tree", tree, "-m", "Odd")
	git(t, dir, "update-ref", "refs/issues/not-a-uuid", commit)
	// A problem across issues is a note.
	commitOn(t, dir, "refs/issues/"+w.ID, "Parent\n\nX-Parent: "+missingID, true)
	before := refState(t, dir)
	rep, err = r.Fsck(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if rep.Errors == 0 || len(rep.Findings) < 2 {
		t.Fatalf("damaged: %+v", rep)
	}
	var integrity, across bool
	for _, f := range rep.Findings {
		integrity = integrity || f.Kind == issuez.FsckIntegrity && f.IsError && f.Subject == "not-a-uuid" && f.SubjectKind == issuez.KindIssue
		across = across || f.Kind == issuez.FsckProjection && !f.IsError && f.Subject == w.ID
	}
	if !integrity || !across {
		t.Errorf("findings: %+v", rep.Findings)
	}
	if after := refState(t, dir); after != before {
		t.Errorf("fsck wrote:\n%s\nwas:\n%s", after, before)
	}
}

// TestRepo_Fsck_cancelled: the call fails, with no report of what it got to.
func TestRepo_Fsck_cancelled(t *testing.T) {
	r := newRepo(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if rep, err := r.Fsck(ctx); !issuez.IsCancelled(err) || rep != nil {
		t.Errorf("%+v %v", rep, err)
	}
}
