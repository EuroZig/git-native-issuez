// Shared by the tests: repositories isolated from the user's config.

package issuez_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

var ada = issuez.Actor{Name: "Ada", Email: "ada@example.com"}

// testEnv is the environment of every git the tests run, the user's
// config left out.
func testEnv() []string {
	return append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null")
}

// git runs git with testEnv in dir and returns its trimmed output.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = testEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// initRepo makes an empty repository with an identity and returns its
// path; extra are `git init` flags such as --bare.
func initRepo(t *testing.T, extra ...string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repo")
	git(t, filepath.Dir(dir), append(append([]string{"init", "-q"}, extra...), dir)...)
	git(t, dir, "config", "user.name", "Tester")
	git(t, dir, "config", "user.email", "t@example.com")
	return dir
}

// open opens dir with testEnv and opts, closed when the test ends.
func open(t *testing.T, dir string, opts ...issuez.Option) *issuez.Repo {
	t.Helper()
	r, err := issuez.Open(dir, append([]issuez.Option{issuez.WithEnv(testEnv())}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

// newRepo makes an empty repository and opens it.
func newRepo(t *testing.T, opts ...issuez.Option) *issuez.Repo {
	t.Helper()
	return open(t, initRepo(t), opts...)
}

func create(t *testing.T, r *issuez.Repo, title string, labels ...string) *issuez.Write {
	t.Helper()
	w, err := r.Create(context.Background(), new(issuez.Edit).SetTitle(title).SetLabels(labels...), ada)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// script writes an executable shell script into dir.
func script(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}
