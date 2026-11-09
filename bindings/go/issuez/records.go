package issuez

/*
#include "issuez.h"
*/
import "C"

import "time"

// FsckFinding is one thing fsck found; notes aren't errors.
type FsckFinding struct {
	Kind FsckKind
	// Counted as an error; notes aren't.
	IsError bool
	// What it is about: an issue or milestone (SubjectKind), a remote
	// (FsckQuarantined), or "" for the repository.
	SubjectKind Kind
	Subject     string
	// One sentence without a front end's commands.
	Message string
}

func goFsckFinding(x *C.issuez_fsck_finding) FsckFinding {
	return FsckFinding{
		Kind:        FsckKind(x.kind),
		IsError:     bool(x.is_error),
		SubjectKind: Kind(x.subject_kind),
		Subject:     goStr(x.subject),
		Message:     goStr(x.message),
	}
}

// Attachment is an image on the issue (format.md §7). Its bytes are the
// LFS object SHA256.
type Attachment struct {
	// A v4 UUID; text links to it as "attachment:<ID>".
	ID string
	// image/png, image/jpeg or image/webp.
	MediaType string
	Size      uint64
	// 64 lowercase hex digits: the LFS object ID.
	SHA256 string
	Name   string
	// The root, a comment, a description or comment edit.
	AddedIn OID
	AddedBy Person
	// Hidden by X-Attachment-Removed; its bytes are still referenced.
	Removed bool
	// The comment it belongs to: AddedIn's, or the one AddedIn edits;
	// zero for the description's.
	Comment OID
	// When AddedIn was written.
	At time.Time
}

func goAttachment(x *C.issuez_attachment) Attachment {
	return Attachment{
		ID:        goStr(x.id),
		MediaType: goStr(x.media_type),
		Size:      uint64(x.size),
		SHA256:    goStr(x.sha256),
		Name:      goStr(x.name),
		AddedIn:   goOID(x.added_in),
		AddedBy:   goPerson(x.added_by),
		Removed:   bool(x.removed),
		Comment:   goOID(x.comment),
		At:        goTime(x.at),
	}
}
