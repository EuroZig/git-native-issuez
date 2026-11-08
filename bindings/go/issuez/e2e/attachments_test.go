//go:build e2e

package e2e_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

// TestAttachments: a CLI client attaches an image and syncs to a file://
// hub with git-lfs. The host sees the derived ref and the attachment ID,
// and its own Sync to mirrors uploads the bytes unless NoAttachments.
func TestAttachments(t *testing.T) {
	if err := exec.Command("git", "lfs", "version").Run(); err != nil {
		t.Skip("no git-lfs")
	}
	hub := newHub(t)
	ada := newClient(t, hub, "Ada")
	id := create(t, ada, "Rendering glitch")
	var img bytes.Buffer
	if err := png.Encode(&img, image.NewGray(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	shot := filepath.Join(t.TempDir(), "shot.png")
	if err := os.WriteFile(shot, img.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	cli(t, ada, "attach", "add", id, shot, "-m", "Screenshot")
	cli(t, ada, "sync", "origin")
	sum := sha256.Sum256(img.Bytes())
	sha := hex.EncodeToString(sum[:])
	lfsObject := func(repo string) bool {
		_, err := os.Stat(filepath.Join(repo, "lfs", "objects", sha[0:2], sha[2:4], sha))
		return err == nil
	}
	if !lfsObject(hub) {
		t.Fatal("the client's sync didn't upload the bytes")
	}
	if len(refsUnder(t, hub, "refs/attachments/"+id)) != 1 {
		t.Fatal("no derived ref on the hub")
	}

	r := openHost(t, hub)
	i, err := r.Load(bg, id)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, c := range i.Comments {
		ids = append(ids, c.AttachmentIDs...)
	}
	if len(ids) != 1 {
		t.Errorf("attachment IDs: %v in %+v", ids, i.Comments)
	}

	for _, upload := range []bool{false, true} {
		mirror := newHub(t)
		name := "refs-only"
		if upload {
			name = "with-bytes"
		}
		git(t, hub, "remote", "add", name, "file://"+mirror)
		if _, err := r.Sync(bg, name, issuez.SyncOptions{NoAttachments: !upload}); err != nil {
			t.Fatalf("sync to %s: %v", name, err)
		}
		if len(refsUnder(t, mirror, "refs/attachments/"+id)) != 1 {
			t.Errorf("%s: no derived ref", name)
		}
		if lfsObject(mirror) != upload {
			t.Errorf("%s: bytes there %v", name, lfsObject(mirror))
		}
	}
}
