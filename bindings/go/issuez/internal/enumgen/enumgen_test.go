package enumgen

import (
	"strings"
	"testing"
)

func TestGenerate(t *testing.T) {
	src := map[string][]byte{"a.go": []byte(`package issuez

type Mode uint32

const (
	ModeFastForward Mode = 1
	ModeIDLookup    Mode = 2
	ModeAlias       Mode = 1
)

type Named uint32

const (
	NamedA Named = 1
	NamedB Named = 2
)

func (Named) String() string { return "" }

type Word string

const (
	WordA Word = "a"
	WordB Word = "b"
)

const untyped = 3
`)}
	out, err := Generate(src)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, want := range []string{`case ModeFastForward:`, `return "fast_forward"`, `return "id_lookup"`, `"Mode("`} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %s in:\n%s", want, s)
		}
	}
	for _, not := range []string{"ModeAlias", "Named)", "Word)"} {
		if strings.Contains(s, not) {
			t.Errorf("has %s:\n%s", not, s)
		}
	}
}

func TestCommonPrefix(t *testing.T) {
	for _, c := range []struct {
		names []string
		want  string
	}{
		{[]string{"SyncUpToDate", "SyncNew"}, "Sync"},
		{[]string{"Set", "Clear"}, ""},
		{[]string{"KindIssue", "KindMilestone"}, "Kind"},
		{[]string{"PushCreate", "PushCreateFast"}, "Push"},
	} {
		if got := commonPrefix(c.names); got != c.want {
			t.Errorf("commonPrefix(%v) = %q, want %q", c.names, got, c.want)
		}
	}
}
