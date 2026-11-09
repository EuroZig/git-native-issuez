package issuez_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

var (
	png = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01" +
		"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x00IEND\xaeB`\x82")
	jpeg = []byte("\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9")
)

func TestEdit_AddAttachment(t *testing.T) {
	ctx := context.Background()
	dir := initRepo(t)
	r := open(t, dir, issuez.WithAttachmentStore(false))
	const shot = "5b0c4e0e-2b8a-4f5e-9d39-6c1c1f0f2a77"

	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Login broken").
		SetDescription("![shot](attachment:"+shot+")").AddAttachment(shot, "shot.png", png), ada)
	if err != nil {
		t.Fatal(err)
	}
	cw, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("A photo.").AddAttachment("", "photo.jpg", jpeg), ada)
	if err != nil {
		t.Fatal(err)
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(i.Comments) != 1 || len(i.Comments[0].AttachmentIDs) != 1 {
		t.Fatalf("comment: %+v", i.Comments)
	}
	photo := i.Comments[0].AttachmentIDs[0]
	ew, err := r.Update(ctx, w.ID, new(issuez.Edit).EditComment(cw.Commit, "A better one.").
		AddAttachment("", "better.png", png).RemoveAttachment(photo), ada)
	if err != nil {
		t.Fatal(err)
	}

	if i, err = r.Load(ctx, w.ID); err != nil {
		t.Fatal(err)
	}
	byName := map[string]issuez.Attachment{}
	for _, a := range i.Attachments {
		byName[a.Name] = a
	}
	if len(i.Attachments) != 3 {
		t.Fatalf("attachments: %+v", i.Attachments)
	}
	if a := byName["shot.png"]; a.ID != shot || a.MediaType != "image/png" || a.Size != uint64(len(png)) ||
		len(a.SHA256) != 64 || a.AddedIn != w.Commit || a.AddedBy.Email != ada.Email || a.Removed ||
		!a.Comment.IsZero() || a.At.IsZero() {
		t.Errorf("shot: %+v", a)
	}
	if a := byName["better.png"]; a.AddedIn != ew.Commit || a.Removed || a.Comment != cw.Commit {
		t.Errorf("better: %+v", a)
	}
	if a := byName["photo.jpg"]; a.ID != photo || a.MediaType != "image/jpeg" || !a.Removed || a.Comment != cw.Commit {
		t.Errorf("photo: %+v", a)
	}
	if i.Attachments[2].Name != "photo.jpg" {
		t.Errorf("removed ones go last: %+v", i.Attachments)
	}
	if i.Comments[0].Text != "A better one." {
		t.Errorf("comment text: %q", i.Comments[0].Text)
	}
	git(t, dir, "rev-parse", "--verify", "refs/attachments/"+w.ID)

	_, err = r.Update(ctx, w.ID, new(issuez.Edit).AddAttachment(shot, "again.png", png), ada)
	var e *issuez.Error
	if !errors.As(err, &e) || e.Code != issuez.CodeInvalidValue || len(e.Problems) == 0 ||
		e.Problems[0].Field != issuez.FieldAttachments {
		t.Errorf("same ID again: %v", err)
	}
	if _, err = r.Update(ctx, w.ID, new(issuez.Edit).RemoveAttachment(photo), ada); !errors.Is(err, issuez.ErrNotFound) {
		t.Errorf("removed twice: %v", err)
	}
}

func TestEdit_EditComment(t *testing.T) {
	ctx := context.Background()
	r := newRepo(t)
	w := create(t, r, "Typos")
	cw, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Teh fix."), ada)
	if err != nil {
		t.Fatal(err)
	}
	ew, err := r.Update(ctx, w.ID, new(issuez.Edit).EditComment(cw.Commit, "The fix."), ada, issuez.ExpectTip(cw.NewTip))
	if err != nil {
		t.Fatal(err)
	}
	if ew.Entry.Kind != issuez.EntryCommentEdit {
		t.Errorf("kind: %v", ew.Entry.Kind)
	}
	i, err := r.Load(ctx, w.ID)
	if err != nil || i.Comments[0].Text != "The fix." || !i.Comments[0].Edited || i.Comments[0].ID != cw.Commit {
		t.Fatalf("after: %v %+v", err, i.Comments)
	}
	var e *issuez.Error
	_, err = r.Update(ctx, w.ID, new(issuez.Edit).EditComment(cw.Commit, "x").SetTitle("y"), ada)
	if !errors.As(err, &e) || e.Code != issuez.CodeInvalidValue || len(e.Problems) == 0 || e.Problems[0].Op != 2 {
		t.Errorf("with a title: %v", err)
	}
	if _, err = r.Update(ctx, w.ID, new(issuez.Edit).EditComment(cw.Commit, ""), ada); !errors.As(err, &e) ||
		e.Code != issuez.CodeInvalidValue {
		t.Errorf("without text: %v", err)
	}
}

func TestWithAttachmentStore(t *testing.T) {
	ctx := context.Background()
	for _, store := range []bool{true, false} {
		dir := initRepo(t)
		r := open(t, dir, issuez.WithAttachmentStore(store))
		w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Shot").AddAttachment("", "a.png", png), ada)
		var e *issuez.Error
		if store && errors.As(err, &e) && e.Code == issuez.CodeLFS {
			continue // the repository's store needs git-lfs
		}
		if err != nil {
			t.Fatal(err)
		}
		i, err := r.Load(ctx, w.ID)
		if err != nil {
			t.Fatal(err)
		}
		sha := i.Attachments[0].SHA256
		path := filepath.Join(dir, ".git", "issuez", "lfs", "objects", sha[:2], sha[2:4], sha)
		data, err := os.ReadFile(path)
		if store && string(data) != string(png) {
			t.Errorf("stored: %v", err)
		}
		if !store && !os.IsNotExist(err) {
			t.Errorf("stored though the caller keeps the bytes: %v", err)
		}
	}
}

// TestRepo_Fsck_attachmentStore: a repo that stores the bytes checks them;
// one whose caller keeps them doesn't look, and says nothing of them.
func TestRepo_Fsck_attachmentStore(t *testing.T) {
	ctx := context.Background()
	kinds := func(rep *issuez.FsckReport) (l []issuez.FsckKind) {
		for _, f := range rep.Findings {
			l = append(l, f.Kind)
		}
		return l
	}
	t.Run("the caller's", func(t *testing.T) {
		dir := initRepo(t)
		r := open(t, dir, issuez.WithAttachmentStore(false))
		if _, err := r.Create(ctx, new(issuez.Edit).SetTitle("Shot").AddAttachment("", "a.png", png), ada); err != nil {
			t.Fatal(err)
		}
		rep, err := r.Fsck(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if rep.Errors != 0 || len(rep.Findings) != 0 {
			t.Errorf("%v: %+v", kinds(rep), rep.Findings)
		}
	})
	t.Run("the repository's", func(t *testing.T) {
		dir := initRepo(t)
		r := open(t, dir)
		w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Shot").AddAttachment("", "a.png", png), ada)
		var e *issuez.Error
		if errors.As(err, &e) && e.Code == issuez.CodeLFS {
			t.Skip("the repository's store needs git-lfs")
		}
		if err != nil {
			t.Fatal(err)
		}
		i, err := r.Load(ctx, w.ID)
		if err != nil {
			t.Fatal(err)
		}
		sha := i.Attachments[0].SHA256
		if err := os.Remove(filepath.Join(dir, ".git", "issuez", "lfs", "objects", sha[:2], sha[2:4], sha)); err != nil {
			t.Fatal(err)
		}
		rep, err := r.Fsck(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Contains(kinds(rep), issuez.FsckAttachmentMissing) {
			t.Errorf("missing bytes not noted: %+v", rep.Findings)
		}
	})
}

// TestEdit_RemoveAttachment: a commit of its own that keeps the text, with
// the attachment still under its comment; not on a create.
func TestEdit_RemoveAttachment(t *testing.T) {
	ctx := t.Context()
	r := open(t, initRepo(t), issuez.WithAttachmentStore(false))
	w := create(t, r, "Images")
	cw, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("A photo.").AddAttachment("", "a.png", png), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	id := cw.Issue.Attachments[0].ID
	u, err := r.Update(ctx, w.ID, new(issuez.Edit).RemoveAttachment(id), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	a := u.Issue.Attachments[0]
	if !u.Wrote || !a.Removed || a.Comment != cw.Commit || u.Issue.Comments[0].Text != "A photo." {
		t.Errorf("removed: %+v, comment %q", a, u.Issue.Comments[0].Text)
	}
	var e *issuez.Error
	if _, err := r.Create(ctx, new(issuez.Edit).SetTitle("New").RemoveAttachment(id), ada); !errors.As(err, &e) ||
		e.Code != issuez.CodeInvalidValue {
		t.Errorf("on create: %v", err)
	}
}

// TestPurgeResult_RemovedAttachments: a purge names the attachments it
// took out of history.
func TestPurgeResult_RemovedAttachments(t *testing.T) {
	ctx := t.Context()
	r := open(t, initRepo(t), issuez.WithAttachmentStore(false))
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Pictured").AddAttachment("", "shot.png", png), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	shot := w.Issue.Attachments[0].ID
	cw, err := r.Update(ctx, w.ID, new(issuez.Edit).AddComment("Look").AddAttachment("", "photo.jpg", jpeg), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	photo := cw.Issue.Comments[0].AttachmentIDs[0]
	res, err := r.PurgeComment(ctx, w.ID, cw.Commit, ada, "abuse")
	if err != nil || len(res.RemovedAttachments) != 1 || res.RemovedAttachments[0] != photo {
		t.Errorf("comment purge: %+v %v", res, err)
	}
	res, err = r.PurgeIssue(ctx, w.ID, ada, "gone")
	if err != nil || len(res.RemovedAttachments) != 1 || res.RemovedAttachments[0] != shot {
		t.Errorf("issue purge: %+v %v", res, err)
	}
}
