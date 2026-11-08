package recordgen

import (
	"strings"
	"testing"
)

const tiny = `{"types":[
 {"name":"issuez_kind","kind":"enum"},
 {"name":"issuez_person","kind":"value","fields":[]},
 {"name":"issuez_search_hit","kind":"record","fields":[
  {"name":"issue_id","type":"issuez_str ","doc":""},
  {"name":"line","type":"issuez_str ","doc":"the line"}]},
 {"name":"issuez_label_count","kind":"record","fields":[
  {"name":"name","type":"issuez_str","doc":""},
  {"name":"open","type":"uint32_t","doc":"of them not done"},
  {"name":"total","type":"uint32_t","doc":""}]},
 {"name":"issuez_known_person","kind":"record","fields":[
  {"name":"person","type":"issuez_person","doc":""},
  {"name":"authored","type":"uint32_t","doc":""},
  {"name":"assigned","type":"uint32_t","doc":""}]},
 {"name":"issuez_sync_item","kind":"record","fields":[
  {"name":"kind","type":"uint32_t","doc":"issuez_kind: ISSUE or MILESTONE"},
  {"name":"tip","type":"issuez_oid","doc":""},
  {"name":"at","type":"issuez_time","doc":""},
  {"name":"due","type":"issuez_date","doc":""},
  {"name":"n","type":"int64_t","doc":""},
  {"name":"size","type":"uint64_t","doc":""},
  {"name":"ok","type":"bool","doc":""}]},
 {"name":"issuez_fsck_finding","kind":"record","fields":[]},
 {"name":"issuez_quarantined","kind":"record","fields":[]},
 {"name":"issuez_attachment","kind":"record","fields":[
  {"name":"added_by","type":"const issuez_person *","doc":""}]}
]}`

func TestGenerate(t *testing.T) {
	out, err := Generate([]byte(tiny))
	if err != nil {
		t.Fatal(err)
	}
	// Fields as gofmt aligns them: one space apart.
	src := strings.Join(strings.Fields(string(out)), " ")
	for _, want := range []string{
		"DO NOT EDIT", `import "time"`, "IssueID string", "// The line.",
		"Kind Kind", "// ISSUE or MILESTONE.", "struct { Person Authored int", "Tip OID", "At time.Time",
		"Due Date", "N int64", "Size uint64", "Ok bool", "goPerson(&x.person)",
		"AddedBy Person", "func goSearchHit(x *C.issuez_search_hit) SearchHit",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("no %q in:\n%s", want, src)
		}
	}
}

func TestGenerate_errors(t *testing.T) {
	if _, err := Generate([]byte("{")); err == nil {
		t.Error("bad JSON: no error")
	}
	if _, err := Generate([]byte(`{"types":[]}`)); err == nil {
		t.Error("a record missing: no error")
	}
	odd := strings.Replace(tiny, `"type":"bool"`, `"type":"float"`, 1)
	if _, err := Generate([]byte(odd)); err == nil {
		t.Error("an unknown C type: no error")
	}
}

func TestGenerated(t *testing.T) {
	got := Generated()
	if len(got) != len(Records) || got[0] > got[len(got)-1] {
		t.Errorf("Generated: %v", got)
	}
}
