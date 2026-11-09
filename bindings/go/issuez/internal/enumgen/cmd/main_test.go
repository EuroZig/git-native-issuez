package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	dir := t.TempDir()
	src := `package issuez

type Mode uint32

const (
	ModeA Mode = 1
	ModeB Mode = 2
)
`
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	if err := run([]string{"enums_gen.go"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat("enums_gen.go"); err != nil {
		t.Fatal(err)
	}
	if run(nil) == nil {
		t.Error("no arguments: no error")
	}
	empty := t.TempDir()
	t.Chdir(empty)
	if run([]string{"x.go"}) == nil {
		t.Error("no enums: no error")
	}
}
