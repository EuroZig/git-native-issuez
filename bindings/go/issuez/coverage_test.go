package issuez_test

import (
	"bufio"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestEveryExportedSymbolHasATest: every exported function F and method
// T.M has a TestF / TestT_M or an ExampleF / ExampleT_M, or a test with a
// `// covers: T_M, F` line right above it that calls it.
// testdata/untested.txt lists those still
// waiting; a name both listed and tested fails too, so the list only
// shrinks.
func TestEveryExportedSymbolHasATest(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var exported []string
	tests := map[string]bool{}
	for _, f := range files {
		file, err := parser.ParseFile(fset, f, nil, parser.ParseComments)
		if err != nil {
			t.Fatal(err)
		}
		testFile := strings.HasSuffix(f, "_test.go")
		for _, d := range file.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok {
				continue
			}
			name := fn.Name.Name
			if testFile {
				if strings.HasPrefix(name, "Test") || strings.HasPrefix(name, "Example") {
					tests[name] = true
					for _, c := range coveredBy(t, fn) {
						tests["Test"+c] = true
					}
				}
				continue
			}
			if !ast.IsExported(name) {
				continue
			}
			if fn.Recv == nil {
				exported = append(exported, name)
				continue
			}
			recv := receiverName(fn.Recv.List[0].Type)
			if ast.IsExported(recv) {
				exported = append(exported, recv+"_"+name)
			}
		}
	}
	untested := readList(t, filepath.Join("testdata", "untested.txt"))
	var missing, stale []string
	for _, name := range exported {
		has := tests["Test"+name] || tests["Example"+name]
		switch {
		case has && untested[name]:
			stale = append(stale, name)
		case !has && !untested[name]:
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(stale)
	for _, name := range missing {
		t.Errorf("%s has no test: add Test%s or Example%s", name, name, name)
	}
	for _, name := range stale {
		t.Errorf("%s has a test: take it off testdata/untested.txt", name)
	}
}

// coveredBy is what fn's `// covers:` lines name; a name fn doesn't call
// fails the test.
func coveredBy(t *testing.T, fn *ast.FuncDecl) []string {
	t.Helper()
	var names []string
	if fn.Doc != nil {
		for _, c := range fn.Doc.List {
			if list, ok := strings.CutPrefix(c.Text, "// covers: "); ok {
				names = append(names, strings.Split(list, ", ")...)
			}
		}
	}
	called := map[string]bool{}
	ast.Inspect(fn, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok {
			called[id.Name] = true
		}
		return true
	})
	for _, name := range names {
		if !called[name[strings.LastIndex(name, "_")+1:]] {
			t.Errorf("%s covers %s but doesn't call it", fn.Name.Name, name)
		}
	}
	return names
}

func receiverName(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.StarExpr:
		return receiverName(x.X)
	case *ast.Ident:
		return x.Name
	case *ast.IndexExpr:
		return receiverName(x.X)
	}
	return ""
}

func readList(t *testing.T, path string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return out
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			out[line] = true
		}
	}
	return out
}
