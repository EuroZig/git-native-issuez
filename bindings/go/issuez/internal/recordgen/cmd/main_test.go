package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRun(t *testing.T) {
	out := filepath.Join(t.TempDir(), "records_gen.go")
	if err := run([]string{"../../../../../../docs/issuez-api.json", out}); err != nil {
		if _, statErr := os.Stat("../../../../../../docs/issuez-api.json"); statErr != nil {
			t.Skip("docs/issuez-api.json isn't here")
		}
		t.Fatal(err)
	}
	if _, err := os.Stat(out); err != nil {
		t.Fatal(err)
	}
	if run(nil) == nil {
		t.Error("no arguments: no error")
	}
	if run([]string{filepath.Join(t.TempDir(), "missing.json"), out}) == nil {
		t.Error("a missing input: no error")
	}
	bad := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(bad, []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	if run([]string{bad, out}) == nil {
		t.Error("bad JSON: no error")
	}
}
