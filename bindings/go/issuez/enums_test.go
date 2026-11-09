package issuez

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez/internal/enumgen"
)

// TestEnumsGenerated: enums_gen.go is what internal/enumgen writes from
// the package (go generate).
func TestEnumsGenerated(t *testing.T) {
	names, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{}
	for _, n := range names {
		if files[n], err = os.ReadFile(n); err != nil {
			t.Fatal(err)
		}
	}
	want, err := enumgen.Generate(files)
	if err != nil {
		t.Fatal(err)
	}
	if string(want) != string(files["enums_gen.go"]) {
		t.Fatal("enums_gen.go is stale: run go generate in bindings/go/issuez")
	}
}

// wantString: v prints as want, through %v too.
func wantString(t *testing.T, v fmt.Stringer, want string) {
	t.Helper()
	if got := v.String(); got != want {
		t.Errorf("%T: String() = %q, want %q", v, got, want)
	}
	if got := fmt.Sprint(v); got != want {
		t.Errorf("%T: %%v = %q, want %q", v, got, want)
	}
}

// TestEnumNames: one name of each enum, written by hand, as a check on the
// generator: TestEnumsGenerated only says enums_gen.go is what it writes.
//
// covers: AuthorPolicy_String, ChangeKind_String, EntryKind_String, FsckKind_String, Kind_String
// covers: LogLevel_String, MilestoneStatus_String, Priority_String, ProblemKind_String
// covers: PushAction_String, QuarantineReason_String, RevisionKind_String, Sort_String
// covers: SyncOutcome_String, Tri_String, Verb_String
func TestEnumNames(t *testing.T) {
	for _, c := range []struct {
		v    fmt.Stringer
		want string
	}{
		{AuthorEnforce, "enforce"},
		{AuthorPolicy(99), "AuthorPolicy(99)"},
		{ChangeRemoved, "removed"},
		{EntryCommentEdit, "comment_edit"},
		{FsckQuarantined, "quarantined"},
		{KindMilestone, "milestone"},
		{LogWarn, "warn"},
		{MilestoneCompleted, "completed"},
		{PriorityNone, "none"},
		{PriorityCritical, "critical"},
		{ProblemTooLong, "too_long"},
		{PushFastForward, "fast_forward"},
		{QuarantineUnrelatedHistory, "unrelated_history"},
		{RevisionEdit, "edit"},
		{SortDueDate, "due_date"},
		{SyncUpToDate, "up_to_date"},
		{TriAny, "any"},
		{VerbInherit, "inherit"},
	} {
		if got := c.v.String(); got != c.want || fmt.Sprint(c.v) != c.want {
			t.Errorf("%T: String() = %q, %%v = %q, want %q", c.v, got, fmt.Sprint(c.v), c.want)
		}
	}
}

func TestWatchChange_String(t *testing.T) {
	wantString(t, WatchNone, "none")
	wantString(t, WatchRefs, "refs")
	wantString(t, WatchRefs|WatchConfig, "refs|config")
	wantString(t, WatchChange(4), "0x4")
}
