package main

import (
	"context"
	_ "embed"
	"os"

	"github.com/kptdev/krm-functions-catalog/functions/go/set-standard-labels/transformer"
	"github.com/kptdev/krm-functions-sdk/go/fn"
)

//go:embed README.md
var readme []byte

//go:embed metadata.yaml
var metadata []byte

func main() {
	runner := fn.WithContext(context.Background(), &transformer.SetStandardLabels{})
	if err := fn.AsMain(runner, fn.WithDocs(readme, metadata)); err != nil {
		os.Exit(1)
	}
}
