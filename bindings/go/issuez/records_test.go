package issuez_test

import (
	"bytes"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez/internal/recordgen"
)

const apiJSON = "../../../docs/issuez-api.json"

// TestRecordsGenerated: records_gen.go is what internal/recordgen writes
// from the API's JSON (`go generate`). Outside the repository the JSON
// isn't there, and the test skips.
func TestRecordsGenerated(t *testing.T) {
	api, err := os.ReadFile(apiJSON)
	if err != nil {
		t.Skip("docs/issuez-api.json isn't here:", err)
	}
	want, err := recordgen.Generate(api)
	if err != nil {
		t.Fatal(err)
	}
	have, err := os.ReadFile("records_gen.go")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(want, have) {
		t.Fatal("records_gen.go is stale: run go generate in bindings/go/issuez")
	}
}

// handWritten are the records and values the binding copies by hand: for
// each, every C field, and what the Go side does with it. A field the C
// API adds fails the test until it is read here (or left out, saying why).
var handWritten = map[string]map[string]string{
	"issuez_attachment_spec": {"id": "AttachmentSpec.ID", "name": "AttachmentSpec.Name",
		"media_type": "AttachmentSpec.MediaType", "sha256": "AttachmentSpec.SHA256", "size": "AttachmentSpec.Size"},
	"issuez_short_id": {"id": "Repo.ShortIDs", "prefix": "Repo.ShortIDs"},
	"issuez_time":     {"unix_seconds": "goTime", "tz_offset_minutes": "goTime"},
	"issuez_date":     {"year": "goDate", "month": "goDate", "day": "goDate"},
	"issuez_person":   {"name": "goPerson", "email": "goPerson", "user_id": "goPerson"},
	"issuez_progress": {"done": "Progress", "total": "Progress"},
	"issuez_problem": {
		"kind": "Problem.Kind", "field": "Problem.Field", "key": "Problem.Key",
		"value": "Problem.Value", "subject": "Problem.Subject", "message": "Problem.Message",
		"op_index": "Problem.Op",
	},
	"issuez_log_event": {
		"level": "LogEvent.Level", "operation": "LogEvent.Operation",
		"message": "LogEvent.Message", "repo_path": "LogEvent.RepoPath",
		"subject": "LogEvent.Subject", "duration_ns": "LogEvent.Duration (a time.Duration)",
		"attempt": "LogEvent.Attempt",
	},
	"issuez_diff_entry": {
		"kind": "DiffEntry.RefKey", "id": "DiffEntry.RefKey",
		"change":  "left out: Diff compares Snapshots in Go",
		"old_tip": "left out: Diff compares Snapshots in Go",
		"new_tip": "left out: Diff compares Snapshots in Go",
	},
	"issuez_reaction": {"emoji": "Reaction.Emoji", "user_count": "Reaction.Users"},
	"issuez_comment": {
		"id": "Comment.ID", "author": "Comment.Author", "created": "Comment.Created",
		"updated": "Comment.Updated", "text": "Comment.Text", "edited": "Comment.Edited",
		"deleted": "Comment.Deleted", "attachment_count": "Comment.Attachments",
		"original_author": "Comment.OriginalAuthor", "original_id": "Comment.OriginalID",
		"purged": "Comment.Purged",
	},
	"issuez_change": {
		"field": "Change.Field", "key": "Change.Key", "op": "Change.Op",
		"old_value": "Change.Old", "new_value": "Change.New",
		"old_person": "Change.OldPerson (nil for none)", "new_person": "Change.NewPerson",
		"old_date": "Change.OldDate (nil for none)", "new_date": "Change.NewDate",
		"old_done": "Change.OldDone", "new_done": "Change.NewDone", "reason": "Change.Reason",
	},
	"issuez_entry": {
		"kind": "Entry.Kind", "commit": "Entry.Commit", "author": "Entry.Author",
		"at": "Entry.At", "comment": "Entry.Comment, Entry.CommentAuthor",
		"change_count": "Entry.Changes", "is_new": "Entry.New",
	},
	"issuez_revision": {
		"commit": "Revision.Commit", "author": "Revision.Author", "at": "Revision.At",
		"kind": "Revision.Kind", "text": "Revision.Text (Previous from the one before)",
	},
	"issuez_remote_setup": {
		"configured": "RemoteSetup.Configured", "removed_unsafe": "RemoteSetup.RemovedUnsafe",
		"unsafe": "RemoteSetup.Unsafe", "reserved": "left out: room to grow",
	},
	"issuez_push_verdict": {
		"ref": "PushVerdict.Ref", "kind": "PushVerdict.Kind", "id": "PushVerdict.ID",
		"action": "PushVerdict.Action", "accept": "PushVerdict.Accept",
		"problems": "PushVerdict.Problems", "needs_number": "PushVerdict.NeedsNumber",
		"touches_locked": "PushVerdict.TouchesLocked", "commit_count": "PushVerdict.CommitCount",
		"entry_count": "PushVerdict.Entries", "issue_author": "PushVerdict.IssueAuthor",
		"attachment_count": "PushVerdict.Attachments",
	},
}

// TestRecordFieldsMapped: every C record or value is generated
// (records_gen.go) or listed in handWritten with each of its fields.
func TestRecordFieldsMapped(t *testing.T) {
	data, err := os.ReadFile(apiJSON)
	if err != nil {
		t.Skip("docs/issuez-api.json isn't here:", err)
	}
	var api struct {
		Types []struct {
			Name   string `json:"name"`
			Kind   string `json:"kind"`
			Fields []struct {
				Name string `json:"name"`
			} `json:"fields"`
		} `json:"types"`
	}
	if err := json.Unmarshal(data, &api); err != nil {
		t.Fatal(err)
	}
	generated := map[string]bool{}
	for _, name := range recordgen.Generated() {
		generated[name] = true
	}
	seen := map[string]bool{}
	for _, ty := range api.Types {
		if ty.Kind != "record" && ty.Kind != "value" {
			continue
		}
		seen[ty.Name] = true
		// The binding's own conversions (goStr, goOID).
		if generated[ty.Name] || ty.Name == "issuez_str" || ty.Name == "issuez_oid" {
			continue
		}
		fields, ok := handWritten[ty.Name]
		if !ok {
			t.Errorf("%s: neither generated (internal/recordgen) nor in handWritten", ty.Name)
			continue
		}
		var c []string
		for _, f := range ty.Fields {
			c = append(c, f.Name)
			if _, ok := fields[f.Name]; !ok {
				t.Errorf("%s.%s: the C API has it, the binding doesn't read it", ty.Name, f.Name)
			}
		}
		for f := range fields {
			if !contains(c, f) {
				t.Errorf("%s.%s: handWritten lists it, the C API doesn't have it", ty.Name, f)
			}
		}
	}
	var stale []string
	for name := range handWritten {
		if !seen[name] {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)
	if len(stale) > 0 {
		t.Errorf("handWritten lists types the API doesn't have: %s", strings.Join(stale, ", "))
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
