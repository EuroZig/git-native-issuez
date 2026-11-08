// Command recordgen writes records_gen.go:
//
//	go run ./internal/recordgen/cmd <issuez-api.json> <records_gen.go>
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/EuroZig/git-native-issuez/bindings/go/issuez/internal/recordgen"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "recordgen:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 2 {
		return errors.New("usage: recordgen <issuez-api.json> <records_gen.go>")
	}
	in, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	out, err := recordgen.Generate(in)
	if err != nil {
		return err
	}
	return os.WriteFile(args[1], out, 0o644)
}
