package issuez

// White-box: the exact ops each Edit builder adds (docs/test-plan.md
// §3.2). edit_test.go applies them through the library.

import (
	"reflect"
	"testing"
	"time"
)

var (
	grace  = Person{Email: "grace@example.invalid", UserID: "0c8d7a52-3f1e-4b6a-9d2c-5e4f3a2b1c0d"}
	someID = "0b6c4f63-6f5a-4a3e-9c2b-1d2e3f4a5b6c"
	day    = Date{Year: 2026, Month: time.December, Day: 1}
	tip, _ = ParseOID("5186cff79af42ee5c6a80d822eec95a842832b34")
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

func TestEdit_SetTitle(t *testing.T) {
	e := start()
	if got := e.SetTitle("T"); got != e {
		t.Fatal("SetTitle doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldTitle), str: "T"})
}

func TestEdit_SetDescription(t *testing.T) {
	e := start()
	if got := e.SetDescription("D"); got != e {
		t.Fatal("SetDescription doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldDescription), str: "D"})
}

func TestEdit_AddComment(t *testing.T) {
	e := start()
	if got := e.AddComment("C"); got != e {
		t.Fatal("AddComment doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldComment), str: "C"})
}

func TestEdit_SetState(t *testing.T) {
	e := start()
	if got := e.SetState(StateClosed); got != e {
		t.Fatal("SetState doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldState), str: "closed"})
}

func TestEdit_SetFixedBy(t *testing.T) {
	e := start()
	if got := e.SetFixedBy("abc"); got != e {
		t.Fatal("SetFixedBy doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldFixedBy), str: "abc"})
}

func TestEdit_SetRelease(t *testing.T) {
	e := start()
	if got := e.SetRelease("1.2"); got != e {
		t.Fatal("SetRelease doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldRelease), str: "1.2"})
}

func TestEdit_SetReason(t *testing.T) {
	e := start()
	if got := e.SetReason("completed"); got != e {
		t.Fatal("SetReason doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldReason), str: "completed"})
}

func TestEdit_SetWorkflowState(t *testing.T) {
	e := start()
	if got := e.SetWorkflowState("ready"); got != e {
		t.Fatal("SetWorkflowState doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldWorkflowState), str: "ready"})
}

func TestEdit_SetWorkflowState_zeroClears(t *testing.T) {
	wantOps(t, start().SetWorkflowState(""), op{verb: VerbClear, target: uint32(FieldWorkflowState)})
}

func TestEdit_SetLabels(t *testing.T) {
	e := start()
	if got := e.SetLabels("a", "b"); got != e {
		t.Fatal("SetLabels doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbClear, target: uint32(FieldLabels)}, op{verb: VerbAdd, target: uint32(FieldLabels), str: "a"}, op{verb: VerbAdd, target: uint32(FieldLabels), str: "b"})
}

func TestEdit_AddLabel(t *testing.T) {
	e := start()
	if got := e.AddLabel("a"); got != e {
		t.Fatal("AddLabel doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbAdd, target: uint32(FieldLabels), str: "a"})
}

func TestEdit_RemoveLabel(t *testing.T) {
	e := start()
	if got := e.RemoveLabel("a"); got != e {
		t.Fatal("RemoveLabel doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbRemove, target: uint32(FieldLabels), str: "a"})
}

func TestEdit_SetAssignees(t *testing.T) {
	e := start()
	if got := e.SetAssignees(grace); got != e {
		t.Fatal("SetAssignees doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbClear, target: uint32(FieldAssignees)}, op{verb: VerbAdd, target: uint32(FieldAssignees), person: grace})
}

func TestEdit_AddAssignee(t *testing.T) {
	e := start()
	if got := e.AddAssignee(grace); got != e {
		t.Fatal("AddAssignee doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbAdd, target: uint32(FieldAssignees), person: grace})
}

func TestEdit_RemoveAssignee(t *testing.T) {
	e := start()
	if got := e.RemoveAssignee(grace); got != e {
		t.Fatal("RemoveAssignee doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbRemove, target: uint32(FieldAssignees), person: grace})
}

func TestEdit_SetPriority(t *testing.T) {
	e := start()
	if got := e.SetPriority(PriorityHigh); got != e {
		t.Fatal("SetPriority doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldPriority), num: int64(PriorityHigh)})
}

func TestEdit_SetPriority_zeroClears(t *testing.T) {
	wantOps(t, start().SetPriority(PriorityNone), op{verb: VerbClear, target: uint32(FieldPriority)})
}

func TestEdit_SetMilestone(t *testing.T) {
	e := start()
	if got := e.SetMilestone(someID); got != e {
		t.Fatal("SetMilestone doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldMilestone), str: someID})
}

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

func TestEdit_SetParent(t *testing.T) {
	e := start()
	if got := e.SetParent(someID); got != e {
		t.Fatal("SetParent doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldParent), str: someID})
}

func TestEdit_SetParent_zeroClears(t *testing.T) {
	wantOps(t, start().SetParent(""), op{verb: VerbClear, target: uint32(FieldParent)})
}

func TestEdit_SetBlockers(t *testing.T) {
	e := start()
	if got := e.SetBlockers(someID); got != e {
		t.Fatal("SetBlockers doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbClear, target: uint32(FieldBlockedBy)}, op{verb: VerbAdd, target: uint32(FieldBlockedBy), str: someID})
}

func TestEdit_AddBlocker(t *testing.T) {
	e := start()
	if got := e.AddBlocker(someID); got != e {
		t.Fatal("AddBlocker doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbAdd, target: uint32(FieldBlockedBy), str: someID})
}

func TestEdit_RemoveBlocker(t *testing.T) {
	e := start()
	if got := e.RemoveBlocker(someID); got != e {
		t.Fatal("RemoveBlocker doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbRemove, target: uint32(FieldBlockedBy), str: someID})
}

func TestEdit_SetStartDate(t *testing.T) {
	e := start()
	if got := e.SetStartDate(day); got != e {
		t.Fatal("SetStartDate doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldStartDate), date: day})
}

func TestEdit_SetStartDate_zeroClears(t *testing.T) {
	wantOps(t, start().SetStartDate(Date{}), op{verb: VerbClear, target: uint32(FieldStartDate)})
}

func TestEdit_SetDueDate(t *testing.T) {
	e := start()
	if got := e.SetDueDate(day); got != e {
		t.Fatal("SetDueDate doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldDueDate), date: day})
}

func TestEdit_SetDueDate_zeroClears(t *testing.T) {
	wantOps(t, start().SetDueDate(Date{}), op{verb: VerbClear, target: uint32(FieldDueDate)})
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

func TestEdit_SetLocked(t *testing.T) {
	e := start()
	if got := e.SetLocked(true, "heated"); got != e {
		t.Fatal("SetLocked doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldLocked), num: 1, str: "heated"})
}

func TestEdit_SetRef(t *testing.T) {
	e := start()
	if got := e.SetRef("v2"); got != e {
		t.Fatal("SetRef doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldRef), str: "v2"})
}

func TestEdit_SetRef_zeroClears(t *testing.T) {
	wantOps(t, start().SetRef(""), op{verb: VerbClear, target: uint32(FieldRef)})
}

func TestEdit_SetDeleted(t *testing.T) {
	e := start()
	if got := e.SetDeleted(true); got != e {
		t.Fatal("SetDeleted doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldDeleted), num: 1})
}

func TestEdit_SetNumber(t *testing.T) {
	e := start()
	if got := e.SetNumber(7); got != e {
		t.Fatal("SetNumber doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldNumber), num: 7})
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

func TestMilestoneEdit_SetName(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetName("v1") },
		op{verb: VerbSet, target: uint32(FieldName), str: "v1"})
}

func TestMilestoneEdit_SetDescription(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetDescription("First.") },
		op{verb: VerbSet, target: uint32(FieldDescription), str: "First."})
}

func TestMilestoneEdit_SetDueDate(t *testing.T) {
	due := Date{Year: 2026, Month: 6, Day: 30}
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetDueDate(due) },
		op{verb: VerbSet, target: uint32(FieldDueDate), date: due})
}

func TestMilestoneEdit_SetDueDate_zeroClears(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetDueDate(Date{}) },
		op{verb: VerbClear, target: uint32(FieldDueDate)})
}

func TestMilestoneEdit_SetStatus(t *testing.T) {
	milestoneOps(t, func(m *MilestoneEdit) *MilestoneEdit { return m.SetStatus(MilestoneCompleted) },
		op{verb: VerbSet, target: uint32(FieldMilestoneStatus), num: int64(MilestoneCompleted)})
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

func TestEdit_SetExtra(t *testing.T) {
	e := start()
	if got := e.SetExtra("X-Forgejo-Project", "3"); got != e {
		t.Fatal("SetExtra doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: uint32(FieldExtra), name: "X-Forgejo-Project", str: "3"})
}

func TestEdit_SetSubject(t *testing.T) {
	e := start()
	if got := e.SetSubject("Rework"); got != e {
		t.Fatal("SetSubject doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: targetSubject, str: "Rework"})
}

func TestEdit_SetOriginal(t *testing.T) {
	e := start()
	if got := e.SetOriginal("octo@github", "gh-1"); got != e {
		t.Fatal("SetOriginal doesn't return its edit")
	}
	wantOps(t, e, op{verb: VerbSet, target: targetOriginalAuthor, str: "octo@github"}, op{verb: VerbSet, target: targetOriginalID, str: "gh-1"})
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
