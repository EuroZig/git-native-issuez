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
	wantTest, err := enumgen.GenerateTest(files)
	if err != nil {
		t.Fatal(err)
	}
	if string(want) != string(files["enums_gen.go"]) ||
		string(wantTest) != string(files["enums_gen_test.go"]) {
		t.Fatal("enums_gen.go or its test is stale: run go generate in bindings/go/issuez")
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

func TestAuthorPolicy_String(t *testing.T) {
	wantString(t, AuthorEnforce, "enforce")
	wantString(t, AuthorPolicy(99), "AuthorPolicy(99)")
}

func TestChangeKind_String(t *testing.T) { wantString(t, ChangeRemoved, "removed") }
func TestEntryKind_String(t *testing.T)  { wantString(t, EntryCommentEdit, "comment_edit") }
func TestFsckKind_String(t *testing.T)   { wantString(t, FsckQuarantined, "quarantined") }
func TestKind_String(t *testing.T)       { wantString(t, KindMilestone, "milestone") }
func TestLogLevel_String(t *testing.T)   { wantString(t, LogWarn, "warn") }
func TestMilestoneStatus_String(t *testing.T) {
	wantString(t, MilestoneCompleted, "completed")
}
func TestPriority_String(t *testing.T) {
	wantString(t, PriorityNone, "none")
	wantString(t, PriorityCritical, "critical")
}
func TestProblemKind_String(t *testing.T) { wantString(t, ProblemTooLong, "too_long") }
func TestPushAction_String(t *testing.T)  { wantString(t, PushFastForward, "fast_forward") }
func TestQuarantineReason_String(t *testing.T) {
	wantString(t, QuarantineUnrelatedHistory, "unrelated_history")
}
func TestRevisionKind_String(t *testing.T) { wantString(t, RevisionEdit, "edit") }
func TestSort_String(t *testing.T)         { wantString(t, SortDueDate, "due_date") }
func TestSyncOutcome_String(t *testing.T)  { wantString(t, SyncUpToDate, "up_to_date") }
func TestTri_String(t *testing.T)          { wantString(t, TriAny, "any") }
func TestVerb_String(t *testing.T)         { wantString(t, VerbInherit, "inherit") }

func TestWatchChange_String(t *testing.T) {
	wantString(t, WatchNone, "none")
	wantString(t, WatchRefs, "refs")
	wantString(t, WatchRefs|WatchConfig, "refs|config")
	wantString(t, WatchChange(4), "0x4")
}
