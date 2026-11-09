package issuez

// White-box: the ops of the builders whose effect a read-back can't tell
// apart. TestEditAppliesEveryBuilder (edit_test.go) reads the others back.

import (
	"reflect"
	"testing"
	"time"
)

// wantOps checks the edit holds exactly want, after one op already there.
func wantOps(t *testing.T, e *Edit, want ...op) {
	t.Helper()
	if e.Len() != len(want)+1 {
		t.Fatalf("Len() = %d, want %d", e.Len(), len(want)+1)
	}
	if !reflect.DeepEqual(e.ops[1:], want) {
		t.Errorf("ops = %+v, want %+v", e.ops[1:], want)
	}
}

// start is an edit with one op, so a builder's ops come after it and
// chaining is checked too.
func start() *Edit { return new(Edit).SetTitle("first") }

func TestEdit_SetMilestone_zeroClears(t *testing.T) {
	wantOps(t, start().SetMilestone(""), op{verb: VerbClear, target: uint32(FieldMilestone)})
}

func TestEdit_InheritMilestone(t *testing.T) {
	e := start()
	if got := e.InheritMilestone(); got != e {
		t.Fatal("InheritMilestone doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbInherit, target: uint32(FieldMilestone)})
}

func TestEdit_SetEstimate(t *testing.T) {
	e := start()
	if got := e.SetEstimate(90*time.Minute + 20*time.Second); got != e {
		t.Fatal("SetEstimate doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldEstimate), num: 90})
}

func TestEdit_SetEstimate_zeroClears(t *testing.T) {
	wantOps(t, start().SetEstimate(0), op{verb: VerbClear, target: uint32(FieldEstimate)})
	wantOps(t, start().SetEstimate(20*time.Second), op{verb: VerbClear, target: uint32(FieldEstimate)})
}

// milestoneOps: f adds want to a MilestoneEdit with one op already, and
// returns it.
func milestoneOps(t *testing.T, f func(*MilestoneEdit) *MilestoneEdit, want ...op) {
	t.Helper()
	m := new(MilestoneEdit).SetName("first")
	if f(m) != m {
		t.Fatal("the method doesn't return its edit")
	}
	wantOps(t, &m.e, want...)
}

func TestMilestoneEdit_SetDueDate_zeroClears(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetDueDate(Date{}) },
		op{verb: VerbClear, target: uint32(FieldDueDate)})
}

func TestMilestoneEdit_SetSubject(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetSubject("Plan v1") },
		op{verb: VerbSet, target: targetSubject, str: "Plan v1"})
}

func TestMilestoneEdit_SetOriginal(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetOriginal("octo@github", "gh-1") },
		op{verb: VerbSet, target: targetOriginalAuthor, str: "octo@github"},
		op{verb: VerbSet, target: targetOriginalID, str: "gh-1"})
}

func TestMilestoneEdit_Len(t *testing.T) {
	if n := new(MilestoneEdit).SetName("v1").SetDescription("d").Len(); n != 2 {
		t.Errorf("Len = %d", n)
	}
}

func TestMilestoneEdit_ValidateCreate(t *testing.T) {
	if p, err := new(MilestoneEdit).SetDescription("No name").ValidateCreate(); err != nil || len(p) != 1 {
		t.Errorf("without a name: %v %+v", err, p)
	}
}

func TestMilestoneEdit_ValidateUpdate(t *testing.T) {
	if p, err := new(MilestoneEdit).SetDescription("Later").ValidateUpdate(); err != nil || len(p) != 0 {
		t.Errorf("without a name: %v %+v", err, p)
	}
}

func TestEdit_Len(t *testing.T) {
	var e Edit
	if e.Len() != 0 {
		t.Errorf("zero Edit has Len %d", e.Len())
	}
	e.SetTitle("a").SetLabels("x", "y")
	if e.Len() != 4 {
		t.Errorf("Len() = %d, want 4 (title, clear, two adds)", e.Len())
	}
}
