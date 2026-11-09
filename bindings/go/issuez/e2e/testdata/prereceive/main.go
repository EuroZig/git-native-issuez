// A host's pre-receive hook in Go: checks the push with PushCheck and
// prints each refusal as git's clients show it (`remote: error: ...`).
// The hub's config is its policy:
//
//	e2ehook.pusher        the pusher's verified email
//	e2ehook.authors       any, warn or enforce
//	e2ehook.allowNumbers  true: clients may give numbers
//	e2ehook.allowPurge    true: the pusher may purge
//
// Issues the check reports as needing a number are appended to
// $GIT_DIR/needs-number, one ID per line, for the host to number once
// the push is in.
package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func config(key string) string {
	out, _ := exec.Command("git", "config", "--get", "e2ehook."+key).Output()
	return strings.TrimSpace(string(out))
}

// oid reads a hook line's object ID; git's all-zero ID is none.
func oid(hex string) (issuez.OID, error) {
	if strings.Trim(hex, "0") == "" {
		return issuez.OID{}, nil
	}
	return issuez.ParseOID(hex)
}

func run() error {
	var updates []issuez.RefUpdate
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		f := strings.Fields(in.Text())
		if len(f) != 3 {
			return fmt.Errorf("bad hook input %q", in.Text())
		}
		old, err := oid(f[0])
		if err != nil {
			return err
		}
		next, err := oid(f[1])
		if err != nil {
			return err
		}
		updates = append(updates, issuez.RefUpdate{Ref: f[2], Old: old, New: next})
	}
	gitDir, err := os.Getwd()
	if err != nil {
		return err
	}
	r, err := issuez.Open(gitDir, issuez.WithEnv(os.Environ()))
	if err != nil {
		return err
	}
	defer r.Close()

	policy := issuez.PushPolicy{
		AllowNumbers:        config("allowNumbers") == "true",
		AllowPurge:          config("allowPurge") == "true",
		ObjectDir:           os.Getenv("GIT_OBJECT_DIRECTORY"),
		AlternateObjectDirs: os.Getenv("GIT_ALTERNATE_OBJECT_DIRECTORIES"),
	}
	if p := config("pusher"); p != "" {
		policy.PusherEmails = []string{p}
	}
	switch config("authors") {
	case "warn":
		policy.Authors = issuez.AuthorWarn
	case "enforce":
		policy.Authors = issuez.AuthorEnforce
	}
	verdicts, checkErr := r.PushCheck(context.Background(), updates, policy)
	var numbered []string
	for _, v := range verdicts {
		for _, p := range v.Problems {
			level := "error"
			if v.Accept {
				level = "warning"
			}
			fmt.Fprintf(os.Stderr, "%s: %s: %s\n", level, v.Ref, p.Message)
		}
		if v.Accept && v.NeedsNumber {
			numbered = append(numbered, v.ID)
		}
	}
	if checkErr != nil {
		return fmt.Errorf("push refused: %w", checkErr)
	}
	if len(numbered) > 0 {
		f, err := os.OpenFile(filepath.Join(gitDir, "needs-number"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		for _, id := range numbered {
			fmt.Fprintln(f, id)
		}
	}
	return nil
}
