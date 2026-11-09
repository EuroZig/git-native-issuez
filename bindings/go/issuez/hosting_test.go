package issuez_test

import (
	"context"
	"errors"
	"maps"
	"os"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func TestRepo_LoadAt(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w := create(t, r, "Before")
	next, err := r.Update(ctx, w.ID, new(issuez.Edit).SetTitle("After").AddComment("Later"), ada)
	if err != nil {
		t.Fatal(err)
	}
	old, err := r.LoadAt(ctx, w.ID, w.NewTip, issuez.LoadHistory())
	if err != nil {
		t.Fatal(err)
	}
	if old.Title != "Before" || old.Tip != w.NewTip || len(old.Comments) != 0 {
		t.Fatalf("historical: %+v", old)
	}
	delta, err := r.LoadAt(ctx, w.ID, next.NewTip, issuez.Since(w.NewTip))
	if err != nil {
		t.Fatal(err)
	}
	if len(delta.NewEntries()) != 1 {
		t.Fatalf("new entries: %+v", delta.NewEntries())
	}
	git(t, r.GitDir(), "update-ref", "-d", "refs/issues/"+w.ID)
	if _, err = r.LoadAt(ctx, w.ID, w.NewTip); err != nil {
		t.Fatal(err)
	}
	if _, err = r.LoadAt(ctx, w.ID, issuez.OID{}); err == nil {
		t.Fatal("accepted zero tip")
	}
}

func TestRepo_LoadMilestoneAt(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	w, err := r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("Before"), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if w.Milestone.Tip != w.NewTip {
		t.Fatal("reload tip differs")
	}
	if _, err = r.UpdateMilestone(ctx, w.ID, new(issuez.MilestoneEdit).SetName("After"), ada); err != nil {
		t.Fatal(err)
	}
	m, err := r.LoadMilestoneAt(ctx, w.ID, w.NewTip)
	if err != nil {
		t.Fatal(err)
	}
	if m.Name != "Before" || m.Tip != w.NewTip {
		t.Fatalf("historical: %+v", m)
	}
	if _, err = r.LoadMilestoneAt(ctx, w.ID, issuez.OID{}); err == nil {
		t.Fatal("accepted zero tip")
	}
}

func TestSnapshot_MarshalBinaryMutations(t *testing.T) {
	r := newRepo(t)
	create(t, r, "A")
	snap, err := r.Snapshot(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	first, err := snap.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	clear(snap.Tips)
	b, err := snap.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	var back issuez.Snapshot
	if err := back.UnmarshalBinary(b); err != nil {
		t.Fatal(err)
	}
	if !maps.Equal(snap.Tips, back.Tips) {
		t.Fatal("serialized stale tips")
	}
	first[0] = 'x'
	if _, err := snap.MarshalBinary(); err != nil {
		t.Fatal("returned bytes alias snapshot", err)
	}
	manual := &issuez.Snapshot{Tips: map[issuez.RefKey]issuez.OID{}}
	if _, err := manual.MarshalBinary(); err != nil {
		t.Fatal(err)
	}

	tip, err := issuez.ParseOID(strings.Repeat("1", 40))
	if err != nil {
		t.Fatal(err)
	}
	manual.Tips[issuez.RefKey{Kind: issuez.KindIssue, ID: "invalid"}] = tip
	if _, err := manual.MarshalBinary(); err == nil {
		t.Fatal("accepted invalid UUID")
	}
	clear(manual.Tips)
	manual.Tips[issuez.RefKey{Kind: issuez.KindAttachments, ID: "invalid"}] = tip
	if _, err := manual.MarshalBinary(); err == nil {
		t.Fatal("accepted invalid kind")
	}
}

func TestReload_CommittedCancellation(t *testing.T) {
	for _, kind := range []string{"issue", "milestone"} {
		t.Run(kind, func(t *testing.T) {
			r := newRepo(t)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			r.SetLogger(issuez.LogDebug, func(e issuez.LogEvent) {
				if e.Operation == "git.update-ref" {
					cancel()
				}
			})
			var w *issuez.Write
			var err error
			if kind == "issue" {
				w, err = r.Create(ctx, new(issuez.Edit).SetTitle("Committed"), ada, issuez.Reload())
			} else {
				w, err = r.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("Committed"), ada, issuez.Reload())
			}
			var e *issuez.Error
			if !errors.As(err, &e) || !errors.Is(err, context.Canceled) || e.Write == nil || w == nil || !w.Wrote || e.Write != w {
				t.Fatalf("receipt=%+v error=%+v", w, err)
			}
			r.SetLogger(issuez.LogOff, nil)
			snap, err := r.Snapshot(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			if len(snap.Tips) != 1 {
				t.Fatal("committed write missing")
			}
		})
	}
}

func TestRepo_PrepareAttachment(t *testing.T) {
	r := newRepo(t, issuez.WithAttachmentStore(false))
	a, err := r.PrepareAttachment(t.Context(), "", "/tmp/shot.png", png)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID == "" || a.Name != "shot.png" || a.MediaType != "image/png" || a.Size != uint64(len(png)) || len(a.SHA256) != 64 {
		t.Fatalf("prepared: %+v", a)
	}
	if _, err := r.PrepareAttachment(t.Context(), "", "bad.png", []byte("no image")); err == nil {
		t.Fatal("accepted invalid image")
	}
	// Refused the way a write refuses them.
	var e *issuez.Error
	if _, err := r.PrepareAttachment(t.Context(), "", "a.gif", []byte("GIF89a")); !errors.As(err, &e) || e.Code != issuez.CodeInvalidValue {
		t.Errorf("gif: %v", err)
	}
	small := open(t, r.GitDir(), issuez.WithLimit("max_attachment_bytes", 8))
	if _, err := small.PrepareAttachment(t.Context(), "", "a.png", png); !errors.As(err, &e) || e.Code != issuez.CodeLimit {
		t.Errorf("too large: %v", err)
	}
	// The pointer is the one a write stores.
	stored, err := newRepo(t).Create(t.Context(), new(issuez.Edit).SetTitle("Pointer").AddAttachment("", "a.png", png), ada, issuez.Reload())
	if err != nil || stored.Issue.Attachments[0].SHA256 != a.SHA256 || stored.Issue.Attachments[0].Size != a.Size {
		t.Errorf("stored %+v, prepared %+v: %v", stored, a, err)
	}
	r.Close()
	if _, err := r.PrepareAttachment(t.Context(), "", "a.png", png); err == nil {
		t.Error("closed repo")
	}
}

func TestEdit_AddPreparedAttachment(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t, issuez.WithAttachmentStore(false))
	a, err := r.PrepareAttachment(ctx, "", "shot.png", png)
	if err != nil {
		t.Fatal(err)
	}
	w, err := r.Create(ctx, new(issuez.Edit).SetTitle("Image").AddPreparedAttachment(a), ada, issuez.Reload())
	if err != nil {
		t.Fatal(err)
	}
	if len(w.Issue.Attachments) != 1 || w.Issue.Attachments[0].ID != a.ID {
		t.Fatal("prepared metadata missing")
	}
	if _, err := os.Stat(r.GitDir() + "/issuez/lfs/objects"); !os.IsNotExist(err) {
		t.Fatal("host bytes unexpectedly stored", err)
	}
	bad := a
	bad.ID = "not-a-uuid"
	if _, err := r.Update(ctx, w.ID, new(issuez.Edit).AddPreparedAttachment(bad), ada); err == nil {
		t.Fatal("accepted malformed metadata")
	}
	local := newRepo(t)
	if _, err := local.Create(ctx, new(issuez.Edit).SetTitle("No bytes").AddPreparedAttachment(a), ada); err == nil {
		t.Fatal("accepted prepared data without external storage")
	}
	small := newRepo(t, issuez.WithAttachmentStore(false), issuez.WithLimit("max_attachment_bytes", 1))
	if _, err := small.Create(ctx, new(issuez.Edit).SetTitle("Too big").AddPreparedAttachment(a), ada); err == nil {
		t.Fatal("ignored size limit")
	}
}

func TestRepo_BeginImport(t *testing.T) {
	for _, format := range []string{"sha1", "sha256"} {
		t.Run(format, func(t *testing.T) {
			ctx := t.Context()
			dir := initRepo(t, "--bare", "--object-format="+format)
			r := open(t, dir, issuez.WithAttachmentStore(false), issuez.WithCommitter("Host", "host@example.com"), issuez.WithLimit("max_title_bytes", 4))
			stage, err := r.BeginImport(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer stage.Close()
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			if _, err := r.BeginImport(cancelled); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled import: %v", err)
			}
			path := stage.GitDir()
			if _, err := stage.Create(ctx, new(issuez.Edit).SetTitle("too long"), ada); err == nil {
				t.Fatal("lost limit")
			}
			w := create(t, stage.Repo, "Fine")
			snap, err := r.Snapshot(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if len(snap.Tips) != 0 {
				t.Fatal("import visible before commit")
			}
			if err := stage.Close(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("scratch repo remains", err)
			}
			if _, err := r.Load(ctx, w.ID); !errors.Is(err, issuez.ErrNotFound) {
				t.Fatal("aborted ref visible", err)
			}
		})
	}
}

func TestImport_Commit(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	stage, err := r.BeginImport(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer stage.Close()
	path := stage.GitDir()
	w := create(t, stage.Repo, "Imported")
	if _, err := stage.CreateMilestone(ctx, new(issuez.MilestoneEdit).SetName("v1"), ada); err != nil {
		t.Fatal(err)
	}
	targetPath := r.GitDir()
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	n, err := stage.Commit(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("adopted %d refs", n)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("staging remains", err)
	}
	reopened := open(t, targetPath)
	got, err := reopened.Load(ctx, w.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != "Imported" {
		t.Fatal("published wrong state")
	}
}

func TestImport_CommitConflict(t *testing.T) {
	ctx := t.Context()
	r := newRepo(t)
	stage, err := r.BeginImport(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer stage.Close()
	first := create(t, stage.Repo, "First")
	// The target has that issue by now, as if another writer got there first.
	git(t, r.GitDir(), "update-ref", "refs/issues/"+first.ID, first.NewTip.String())
	second := create(t, stage.Repo, "Second")
	if _, err := stage.Commit(ctx); err == nil {
		t.Fatal("overwrote existing refs")
	}
	if _, err := r.Load(ctx, second.ID); !errors.Is(err, issuez.ErrNotFound) {
		t.Fatal("partial publication", err)
	}
	snap, err := r.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Tips) != 1 {
		t.Fatal("target changed")
	}
	if !strings.Contains(stage.GitDir(), "import-") {
		t.Fatal("failed import closed before caller could retry")
	}
}
