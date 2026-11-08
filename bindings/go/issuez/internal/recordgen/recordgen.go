// Package recordgen writes records_gen.go: the Go form of the C API's
// records that map field for field (docs/issuez-api.json), and the
// function copying each out of C. Records with a Go form of their own
// (Problem, Comment, Entry, Change, ...) stay hand-written; the binding's
// TestRecordFieldsMapped checks that they still read every C field.
package recordgen

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/format"
	"sort"
	"strings"
)

// Record is one generated record.
type Record struct {
	C   string // issuez_search_hit
	Go  string // SearchHit
	Doc string // the type's doc comment, without the name
	// Per C field: a Go name or doc other than the default.
	Names map[string]string
	Docs  map[string]string
}

// Records are the records generated, in output order.
var Records = []Record{
	{C: "issuez_search_hit", Go: "SearchHit", Doc: "is one matching line of an issue."},
	{C: "issuez_label_count", Go: "LabelCount", Doc: "is a label in use: for pickers and filters."},
	{
		C: "issuez_known_person", Go: "KnownPerson",
		Doc: "is someone the history knows: candidates for assignee and\nauthor pickers.",
	},
	{C: "issuez_sync_item", Go: "SyncItem", Doc: "is what a sync did to one issue or milestone."},
	{
		C: "issuez_fsck_finding", Go: "FsckFinding", Doc: "is one thing fsck found; notes aren't errors.",
		Docs: map[string]string{
			"subject_kind": "What it is about: an issue or milestone (SubjectKind), a remote\n(FsckQuarantined), or \"\" for the repository.",
			"subject":      "",
		},
	},
	{C: "issuez_quarantined", Go: "Quarantined", Doc: "is a remote version a merge refused."},
	{
		C: "issuez_attachment", Go: "Attachment",
		Doc: "is an image on the issue (format.md §7). Its bytes are the\nLFS object SHA256.",
		Docs: map[string]string{
			"id":         "A v4 UUID; text links to it as \"attachment:<ID>\".",
			"media_type": "image/png, image/jpeg or image/webp.",
			"added_in":   "The root, a comment, a description or comment edit.",
			"comment":    "The comment it belongs to: AddedIn's, or the one AddedIn edits;\nzero for the description's.",
			"at":         "When AddedIn was written.",
			"removed":    "Hidden by X-Attachment-Removed; its bytes are still referenced.",
		},
	},
}

type field struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Doc  string `json:"doc"`
}

type api struct {
	Types []struct {
		Name   string  `json:"name"`
		Kind   string  `json:"kind"`
		Fields []field `json:"fields"`
	} `json:"types"`
}

// Enums are the C enums with a Go type, by C name.
func enums(a api) map[string]string {
	out := map[string]string{}
	for _, t := range a.Types {
		if t.Kind == "enum" {
			out[t.Name] = camel(strings.TrimPrefix(t.Name, "issuez_"))
		}
	}
	return out
}

var initialisms = map[string]string{"id": "ID", "uuid": "UUID", "sha256": "SHA256", "ns": "NS"}

func camel(snake string) string {
	var b strings.Builder
	for _, w := range strings.Split(snake, "_") {
		if up, ok := initialisms[w]; ok {
			b.WriteString(up)
		} else if w != "" {
			b.WriteString(strings.ToUpper(w[:1]) + w[1:])
		}
	}
	return b.String()
}

// goField is a field's Go type and the expression copying it from x.
func goField(cType, name, doc string, enums map[string]string) (typ, expr string, err error) {
	x := "x." + name
	switch strings.TrimSpace(cType) {
	case "issuez_str":
		return "string", "goStr(" + x + ")", nil
	case "issuez_oid":
		return "OID", "goOID(" + x + ")", nil
	case "issuez_time":
		return "time.Time", "goTime(" + x + ")", nil
	case "issuez_date":
		return "Date", "goDate(" + x + ")", nil
	case "const issuez_person *":
		return "Person", "goPerson(" + x + ")", nil
	case "issuez_person":
		return "Person", "goPerson(&" + x + ")", nil
	case "bool":
		return "bool", "bool(" + x + ")", nil
	case "uint64_t":
		return "uint64", "uint64(" + x + ")", nil
	case "int64_t":
		return "int64", "int64(" + x + ")", nil
	case "uint32_t", "size_t":
		// An enum's field says which in its doc: "issuez_kind ...".
		if goName, ok := enums[enumOf(doc)]; ok {
			return goName, goName + "(" + x + ")", nil
		}
		return "int", "int(" + x + ")", nil
	}
	return "", "", fmt.Errorf("no Go type for %q (%s)", cType, name)
}

// enumOf is the first word of a doc, which names an enum field's enum.
func enumOf(doc string) string {
	first := strings.Fields(doc)
	if len(first) == 0 {
		return ""
	}
	return strings.TrimRight(first[0], ":,;")
}

// fieldDoc is the C doc without the enum name it starts with.
func fieldDoc(doc string, enums map[string]string) string {
	if e := enumOf(doc); enums[e] != "" {
		doc = strings.TrimLeft(strings.TrimPrefix(strings.TrimSpace(doc), e), ":,; ")
	}
	if doc == "" {
		return ""
	}
	return strings.ToUpper(doc[:1]) + doc[1:] + "."
}

func comment(b *bytes.Buffer, indent, text string) {
	for _, l := range strings.Split(text, "\n") {
		fmt.Fprintf(b, "%s// %s\n", indent, l)
	}
}

// Generate writes records_gen.go from the API's JSON.
func Generate(apiJSON []byte) ([]byte, error) {
	var a api
	if err := json.Unmarshal(apiJSON, &a); err != nil {
		return nil, err
	}
	en := enums(a)
	var b bytes.Buffer
	for _, r := range Records {
		var fields []field
		for _, t := range a.Types {
			if t.Name == r.C {
				fields = t.Fields
			}
		}
		if fields == nil {
			return nil, fmt.Errorf("%s isn't in the API", r.C)
		}
		var conv bytes.Buffer
		fmt.Fprintf(&b, "\n")
		comment(&b, "", r.Go+" "+r.Doc)
		fmt.Fprintf(&b, "type %s struct {\n", r.Go)
		for _, f := range fields {
			typ, expr, err := goField(f.Type, f.Name, f.Doc, en)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", r.C, err)
			}
			name := camel(f.Name)
			if n, ok := r.Names[f.Name]; ok {
				name = n
			}
			doc := fieldDoc(f.Doc, en)
			if d, ok := r.Docs[f.Name]; ok {
				doc = d
			}
			if f.Name == "person" && typ == "Person" {
				// Embedded: KnownPerson.Email.
				fmt.Fprintf(&b, "\tPerson\n")
				fmt.Fprintf(&conv, "\t\tPerson: %s,\n", expr)
				continue
			}
			if doc != "" {
				comment(&b, "\t", doc)
			}
			fmt.Fprintf(&b, "\t%s %s\n", name, typ)
			fmt.Fprintf(&conv, "\t\t%s: %s,\n", name, expr)
		}
		b.WriteString("}\n\n")
		fmt.Fprintf(&b, "func go%s(x *C.%s) %s {\n\treturn %s{\n%s\t}\n}\n", r.Go, r.C, r.Go, r.Go, conv.String())
	}
	var out bytes.Buffer
	out.WriteString("// Code generated by internal/recordgen from docs/issuez-api.json; DO NOT EDIT.\n\n")
	out.WriteString("package issuez\n\n/*\n#include \"issuez.h\"\n*/\nimport \"C\"\n")
	if bytes.Contains(b.Bytes(), []byte("time.")) {
		out.WriteString("\nimport \"time\"\n")
	}
	out.Write(b.Bytes())
	return format.Source(out.Bytes())
}

// Generated are the C names of the generated records, sorted.
func Generated() []string {
	var out []string
	for _, r := range Records {
		out = append(out, r.C)
	}
	sort.Strings(out)
	return out
}
