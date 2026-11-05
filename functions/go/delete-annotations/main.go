// Copyright 2026 The kpt Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/kptdev/krm-functions-sdk/go/fn"

	"github.com/kptdev/kpt/api/kubeobject"
)

const (
	annotationKeysLiteral = "annotationKeys"
	annotationDelimeter   = ","
)

// nolint
func main() {
	if err := fn.AsMain(kubeobject.ResourceListProcessorFunc(deleteAnnotations)); err != nil {
		os.Exit(1)
	}
}

func deleteAnnotations(rl *kubeobject.ResourceList) (bool, error) {

	var annotationKeys []string
	annotationKeys, err := getAnnotationKeys(rl.FunctionConfig)

	if err != nil {
		rl.Results = append(rl.Results, kubeobject.ErrorResult(err))
		return false, err
	}

	items, err := processResources(rl.Items, annotationKeys)
	if err != nil {
		rl.Results = append(rl.Results, kubeobject.ErrorResult(err))
		return false, err
	}

	for _, resultItem := range items {
		rl.Results = append(rl.Results, resultItem)
	}

	return true, nil
}

func processResources(objects []*kubeobject.KubeObject, annotationKeys []string) ([]*kubeobject.Result, error) {
	var resultItems []*kubeobject.Result
	var currObjName string
	var prunedObjCtr int
	for _, o := range objects {
		if o.GetKind() == "" || o.GetName() == "" || o.GetAPIVersion() == "" {
			continue
		}

		for _, annotationKey := range annotationKeys {
			removed, err := o.RemoveNestedField("metadata", "annotations", annotationKey)
			if err != nil {
				return nil, err
			}

			if removed {
				if o.GetName() != currObjName {
					prunedObjCtr++
					currObjName = o.GetName()
				}

				itemFilePath := o.GetAnnotations()["internal.config.kubernetes.io/path"]

				resultItems = append(resultItems, &kubeobject.Result{
					Message: fmt.Sprintf("Annonation: [%s] removed from resource: [%s]", annotationKey, o.GetName()),
					File: &kubeobject.File{
						Path: itemFilePath,
					},
					Severity: kubeobject.Info,
				})
			}
		}
	}

	if len(resultItems) > 0 {
		var infoResultSlice []*kubeobject.Result
		infoResultSlice = append(infoResultSlice, &kubeobject.Result{
			Severity: kubeobject.Info,
			Message:  fmt.Sprintf("The provided annotations were deleted from %d resource(s)", prunedObjCtr),
		})

		resultItems = append(infoResultSlice, resultItems...)
	} else if len(resultItems) == 0 {
		resultItems = append(resultItems, &kubeobject.Result{
			Message:  "None of the resources had the provided annotations to delete",
			Severity: kubeobject.Info,
		})
	}

	return resultItems, nil
}

// getAnnotationKeys gets the keys to delete from resources from the functionConfig
func getAnnotationKeys(fc *kubeobject.KubeObject) ([]string, error) {
	annotationKeysString, found, err := fc.NestedString("data", annotationKeysLiteral)

	if !found || annotationKeysString == "" {
		return nil, fmt.Errorf("%s was not provided as part of the config or paramters to the function, %w", annotationKeysLiteral, err)
	}

	annotationKeys := strings.Split(strings.TrimSpace(annotationKeysString), annotationDelimeter)
	return annotationKeys, nil
}
