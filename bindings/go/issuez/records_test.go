package issuez_test

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"
)

const apiJSON = "../../../docs/issuez-api.json"

// handWritten are the records and values the binding copies: for each,
// every C field, and what the Go side does with it. A field the C API adds
// fails the test until it is read here (or left out, saying why).
var handWritten = map[string]map[string]string{
	"issuez_fsck_finding": {
		"kind": "FsckFinding.Kind", "is_error": "FsckFinding.IsError", "subject_kind": "FsckFinding.SubjectKind",
		"subject": "FsckFinding.Subject", "message": "FsckFinding.Message",
	},
	"issuez_attachment": {
		"id": "Attachment.ID", "media_type": "Attachment.MediaType", "size": "Attachment.Size",
		"sha256": "Attachment.SHA256", "name": "Attachment.Name", "added_in": "Attachment.AddedIn",
		"added_by": "Attachment.AddedBy", "removed": "Attachment.Removed", "comment": "Attachment.Comment",
		"at": "Attachment.At",
	},
	"issuez_attachment_spec": {"id": "AttachmentSpec.ID", "name": "AttachmentSpec.Name",
		"media_type": "AttachmentSpec.MediaType", "sha256": "AttachmentSpec.SHA256", "size": "AttachmentSpec.Size"},
	"issuez_time":   {"unix_seconds": "goTime", "tz_offset_minutes": "goTime"},
	"issuez_date":   {"year": "goDate", "month": "goDate", "day": "goDate"},
	"issuez_person": {"name": "goPerson", "email": "goPerson", "user_id": "goPerson"},
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
	"issuez_reaction": {"emoji": "Reaction.Emoji", "user_count": "Reaction.Users"},
	"issuez_issue_info": {
		"id": "Issue.ID", "tip": "Issue.Tip", "has_number": "left out: Issue.Number 0 is none",
		"number": "Issue.Number", "format_version": "Issue.FormatVersion",
		"commit_count": "Issue.CommitCount", "title": "Issue.Title", "description": "Issue.Description",
		"author": "Issue.Author", "created": "Issue.Created", "updated": "Issue.Updated",
		"state": "left out: Issue.State is the name", "state_name": "Issue.State", "is_done": "Issue.Done",
		"workflow_state": "Issue.WorkflowState", "closed_by": "Closure.By (nil Closed for none)",
		"closed_at": "Closure.At", "fixed_by": "Closure.FixedBy", "release": "Closure.Release",
		"reason": "Closure.Reason", "is_deleted": "Issue.Deleted", "is_locked": "Issue.Locked",
		"lock_reason": "Issue.LockReason", "priority": "Issue.Priority", "milestone_id": "Issue.MilestoneID",
		"parent_id": "Issue.ParentID", "start_date": "Issue.StartDate (nil for none)",
		"due_date":             "Issue.DueDate (nil for none)",
		"has_estimate_minutes": "left out: Issue.Estimate 0 is none", "estimate_minutes": "Issue.Estimate",
		"ref": "Issue.Ref", "original_author": "Issue.OriginalAuthor", "original_id": "Issue.OriginalID",
		"rewritten": "Issue.Rewritten",
	},
	"issuez_milestone_info": {
		"id": "Milestone.ID", "tip": "Milestone.Tip", "name": "Milestone.Name",
		"description": "Milestone.Description", "status": "Milestone.Status",
		"due_date": "Milestone.DueDate (nil for none)", "created": "Milestone.Created",
		"updated": "Milestone.Updated", "has_status_changed": "Milestone.StatusChanged (nil for none)",
		"status_changed": "Milestone.StatusChanged", "author": "Milestone.Author",
	},
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
	"issuez_push_verdict": {
		"ref": "PushVerdict.Ref", "kind": "PushVerdict.Kind", "id": "PushVerdict.ID",
		"action": "PushVerdict.Action", "accept": "PushVerdict.Accept",
		"problems": "PushVerdict.Problems", "needs_number": "PushVerdict.NeedsNumber",
		"touches_locked": "PushVerdict.TouchesLocked", "commit_count": "PushVerdict.CommitCount",
		"entry_count": "PushVerdict.Entries", "issue_author": "PushVerdict.IssueAuthor",
		"attachment_count": "PushVerdict.Attachments",
	},
}

// TestRecordFieldsMapped: every C record or value is listed in handWritten
// with each of its fields.
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
	seen := map[string]bool{}
	for _, ty := range api.Types {
		if ty.Kind != "record" && ty.Kind != "value" {
			continue
		}
		seen[ty.Name] = true
		// The binding's own conversions (goStr, goOID).
		if ty.Name == "issuez_str" || ty.Name == "issuez_oid" {
			continue
		}
		fields, ok := handWritten[ty.Name]
		if !ok {
			t.Errorf("%s: not in handWritten", ty.Name)
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
