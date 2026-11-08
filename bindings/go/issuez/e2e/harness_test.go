//go:build e2e

// End-to-end tests: the Go binding as a host
// uses it, against the real CLI as clients use it. The build passes the
// tools by environment:
//
//	ISSUEZ_GIT_ISSUE  the built git-issue (required)
//	ISSUEZ_UPSTREAM   upstream's bin directory, for the interop scenario
//
// and git-lfs comes from PATH. `zig build test-go-e2e` sets them.
package e2e_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

var (
	// The directory of the git-issue under test, first on PATH.
	cliDir string
	// The pre-receive hook built from testdata/prereceive.
	hookBin string
)

func TestMain(m *testing.M) {
	os.Exit(run(m))
}

func run(m *testing.M) int {
	cli := os.Getenv("ISSUEZ_GIT_ISSUE")
	if cli == "" {
		fmt.Fprintln(os.Stderr, "e2e: set ISSUEZ_GIT_ISSUE to the built git-issue (zig build test-go-e2e does)")
		return 1
	}
	// Tests run in this package's directory; another git-issue on PATH
	// (upstream's) must not stand in for a path that doesn't resolve.
	abs, err := filepath.Abs(cli)
	if err == nil {
		_, err = os.Stat(abs)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e: ISSUEZ_GIT_ISSUE:", err)
		return 1
	}
	cliDir = filepath.Dir(abs)
	tmp, err := os.MkdirTemp("", "issuez-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e:", err)
		return 1
	}
	defer os.RemoveAll(tmp)
	hookBin = filepath.Join(tmp, "pre-receive")
	build := exec.Command("go", "build", "-o", hookBin, "./testdata/prereceive")
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "e2e: building the hook: %v\n%s", err, out)
		return 1
	}
	return m.Run()
}

// env is every git's environment: the user's config left out, the CLI
// under test first on PATH.
func env() []string {
	return envWith(cliDir)
}

// envWith puts dir first on PATH instead.
func envWith(dir string) []string {
	out := []string{"GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	for _, kv := range os.Environ() {
		switch {
		case strings.HasPrefix(kv, "PATH="):
			out = append(out, "PATH="+dir+string(os.PathListSeparator)+kv[len("PATH="):])
		case strings.HasPrefix(kv, "GIT_"):
		default:
			out = append(out, kv)
		}
	}
	return out
}

// gitTry runs git in dir and returns its combined output, trimmed.
func gitTry(dir string, environ []string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = environ
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// git runs git in dir with env and fails the test when it fails.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitTry(dir, env(), args...)
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, filepath.Base(dir), err, out)
	}
	return out
}

// cli runs `git issue args...` in a client.
func cli(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return git(t, dir, append([]string{"issue"}, args...)...)
}

// newHub makes a bare repository, the host's, and returns its file://
// URL's path.
func newHub(t *testing.T) string {
	t.Helper()
	hub := filepath.Join(t.TempDir(), "hub.git")
	git(t, filepath.Dir(hub), "init", "-q", "--bare", hub)
	return hub
}

// newClient makes a work tree with hub as origin and name's identity.
func newClient(t *testing.T, hub, name string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	git(t, filepath.Dir(dir), "init", "-q", dir)
	git(t, dir, "config", "user.name", name)
	git(t, dir, "config", "user.email", strings.ToLower(name)+"@example.com")
	git(t, dir, "remote", "add", "origin", "file://"+hub)
	return dir
}

// openHost opens the hub with the binding, as the host does.
func openHost(t *testing.T, hub string, opts ...issuez.Option) *issuez.Repo {
	t.Helper()
	r, err := issuez.Open(hub, append([]issuez.Option{issuez.WithEnv(env())}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

// refsUnder lists the names under prefix in dir.
func refsUnder(t *testing.T, dir, prefix string) []string {
	t.Helper()
	out := git(t, dir, "for-each-ref", "--format=%(refname)", prefix)
	if out == "" {
		return nil
	}
	return strings.Split(out, "\n")
}

// create runs `git issue create` in a client and returns the full ID.
func create(t *testing.T, dir, title string, args ...string) string {
	t.Helper()
	before := refsUnder(t, dir, "refs/issues/")
	cli(t, dir, append([]string{"create", title}, args...)...)
	for _, r := range refsUnder(t, dir, "refs/issues/") {
		if !slices.Contains(before, r) {
			return strings.TrimPrefix(r, "refs/issues/")
		}
	}
	t.Fatalf("create %q made no issue", title)
	return ""
}

// shown is the part of `git issue show --json` the tests read.
type shown struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	State    string  `json:"state"`
	Number   *uint64 `json:"number"`
	Comments []struct {
		Subject string `json:"subject"`
		Text    string `json:"text"`
	} `json:"comments"`
}

func show(t *testing.T, dir, id string) shown {
	t.Helper()
	var s shown
	out := cli(t, dir, "show", id, "--json")
	if err := json.Unmarshal([]byte(out), &s); err != nil {
		t.Fatalf("show --json: %v\n%s", err, out)
	}
	return s
}

// texts is each comment's whole text.
func (s shown) texts() []string {
	var out []string
	// The first paragraph is the subject.
	for _, c := range s.Comments {
		out = append(out, strings.TrimSpace(c.Subject+"\n\n"+c.Text))
	}
	return out
}

// installHook makes the Go pre-receive hook the hub's, configured by
// e2ehook.* keys in the hub's config (see testdata/prereceive).
func installHook(t *testing.T, hub string, config map[string]string) {
	t.Helper()
	data, err := os.ReadFile(hookBin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hub, "hooks", "pre-receive"), data, 0o755); err != nil {
		t.Fatal(err)
	}
	for k, v := range config {
		git(t, hub, "config", "e2ehook."+k, v)
	}
}

var bg = context.Background()

var host = issuez.Actor{Name: "Forge", Email: "forge@example.com"}
