// Command enumgen writes enums_gen.go from the package's Go files:
//
//	go run ./internal/enumgen/cmd enums_gen.go
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez/internal/enumgen"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "enumgen:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: enumgen <enums_gen.go>")
	}
	names, err := filepath.Glob("*.go")
	if err != nil {
		return err
	}
	files := map[string][]byte{}
	for _, n := range names {
		if files[n], err = os.ReadFile(n); err != nil {
			return err
		}
	}
	out, err := enumgen.Generate(files)
	if err != nil {
		return err
	}
	return os.WriteFile(args[0], out, 0o644)
}
