package main

import (
	"context"
	"os"

	"github.com/kptdev/krm-functions-catalog/functions/go/set-standard-labels/transformer"
	"github.com/kptdev/krm-functions-sdk/go/fn"
)

func main() {
	runner := fn.WithContext(context.Background(), &transformer.SetStandardLabels{})
	if err := fn.AsMain(runner); err != nil {
		os.Exit(1)
	}
}
