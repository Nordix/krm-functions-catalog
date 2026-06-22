#!/bin/bash
# Copyright 2026 The kpt Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# convert-golden-to-e2e.sh
#
# Converts SDK golden test cases (testdata/_expected.yaml) to the catalog's
# e2e test format (tests/.expected/diff.patch).
#
# Usage:
#   ./scripts/convert-golden-to-e2e.sh <function-name> [--clean]
#
# Options:
#   --clean   Remove testdata/ and golden_test.go after successful conversion.
#             Without this flag, golden tests are preserved alongside the new e2e tests.
#
# Examples:
#   ./scripts/convert-golden-to-e2e.sh set-standard-labels          # keep golden tests
#   ./scripts/convert-golden-to-e2e.sh set-standard-labels --clean  # remove golden tests
#
# This script will:
#   1. Copy input files from testdata/<case>/ to tests/<case>/
#   2. Ensure each Kptfile has the correct pipeline image reference
#   3. Build the function container image
#   4. Run the e2e harness with KPT_E2E_UPDATE_EXPECTED=true to generate .expected/diff.patch
#   5. (With --clean) Remove the old testdata/ directory and golden_test.go
#
# Prerequisites:
#   - docker buildx available
#   - kpt installed
#   - Run from the repository root

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <function-name> [--clean]"
  echo "Example: $0 set-standard-labels"
  echo "         $0 set-standard-labels --clean"
  exit 1
fi

FN="$1"
CLEAN=false
if [[ "${2:-}" == "--clean" ]]; then
  CLEAN=true
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FUNC_DIR="${REPO_ROOT}/functions/go/${FN}"
SRC="${FUNC_DIR}/testdata"
DST="${FUNC_DIR}/tests"
DEFAULT_CR="${DEFAULT_CR:-ghcr.io/kptdev/krm-functions-catalog}"
TAG="${TAG:-latest}"
IMAGE="${DEFAULT_CR}/${FN}:${TAG}"

# Validate
if [[ ! -d "${FUNC_DIR}" ]]; then
  echo "ERROR: Function directory not found: ${FUNC_DIR}"
  exit 1
fi

if [[ ! -d "${SRC}" ]]; then
  echo "ERROR: No testdata/ directory found at: ${SRC}"
  exit 1
fi

echo "=== Converting golden tests to e2e for: ${FN} ==="
echo "    Image: ${IMAGE}"
echo ""

# Step 1: Copy input files from testdata/ to tests/
echo "--- Step 1: Copying test cases from testdata/ to tests/ ---"
converted=0
skipped=0

for case_dir in "${SRC}"/*/; do
  [[ -d "${case_dir}" ]] || continue
  name=$(basename "${case_dir}")

  if [[ -d "${DST}/${name}/.expected" ]]; then
    echo "  SKIP: ${name} (already exists in tests/ with .expected/)"
    skipped=$((skipped + 1))
    continue
  fi

  mkdir -p "${DST}/${name}/.expected"

  # Copy everything except _expected.yaml
  find "${case_dir}" -maxdepth 1 -type f ! -name '_expected.yaml' -exec cp {} "${DST}/${name}/" \;

  echo "  COPIED: ${name}"
  converted=$((converted + 1))
done

echo ""
echo "  Converted: ${converted}, Skipped: ${skipped}"
echo ""

# Step 2: Ensure Kptfiles have the pipeline section with correct image
echo "--- Step 2: Checking Kptfiles for pipeline image reference ---"

for case_dir in "${DST}"/*/; do
  [[ -d "${case_dir}" ]] || continue
  name=$(basename "${case_dir}")
  kptfile="${case_dir}/Kptfile"

  if [[ ! -f "${kptfile}" ]]; then
    echo "  WARN: No Kptfile in ${name} — creating one"
    cat > "${kptfile}" <<EOF
apiVersion: kpt.dev/v1
kind: Kptfile
metadata:
  name: ${name}
  annotations:
    config.kubernetes.io/local-config: "true"
pipeline:
  mutators:
    - image: ${IMAGE}
EOF
    echo "  CREATED: ${name}/Kptfile"
    continue
  fi

  # Check if pipeline section exists
  if ! grep -q "^pipeline:" "${kptfile}"; then
    echo "  WARN: ${name}/Kptfile has no pipeline section — appending"
    # Ensure file ends with newline before appending
    [[ -s "${kptfile}" && "$(tail -c1 "${kptfile}")" != "" ]] && echo "" >> "${kptfile}"
    cat >> "${kptfile}" <<EOF
pipeline:
  mutators:
    - image: ${IMAGE}
EOF
    echo "  UPDATED: ${name}/Kptfile"
  else
    # Pipeline exists — check the image reference
    current_image=$(grep "image:" "${kptfile}" | head -1 | sed 's/.*image: *//')
    if [[ "${current_image}" != "${IMAGE}" ]]; then
      echo "  NOTE: ${name}/Kptfile has image '${current_image}' (keeping as-is)"
    else
      echo "  OK: ${name}/Kptfile"
    fi
  fi
done

echo ""

# Step 3: Build the function image
echo "--- Step 3: Building function image ---"
echo "  Running: make ${FN}-BUILD (in functions/go/)"
(cd "${REPO_ROOT}/functions/go" && make "${FN}-BUILD" TAG="${TAG}" DEFAULT_CR="${DEFAULT_CR}")

echo ""

# Step 4: Run e2e harness to generate .expected/diff.patch
echo "--- Step 4: Generating .expected/diff.patch via e2e harness ---"
echo "  Running: KPT_E2E_UPDATE_EXPECTED=true go test ..."
(cd "${REPO_ROOT}/tests/e2etest" && \
  KPT_E2E_UPDATE_EXPECTED=true go test -v -count=1 ./... \
    -run "TestE2E/../../functions/go/${FN}/tests")

echo ""

# Step 5: Verify and optionally clean up
echo "--- Step 5: Verify and clean up ---"

# Check that .expected/diff.patch files were generated
missing=0
for case_dir in "${DST}"/*/; do
  [[ -d "${case_dir}" ]] || continue
  name=$(basename "${case_dir}")
  if [[ ! -f "${case_dir}/.expected/diff.patch" ]]; then
    echo "  WARN: No diff.patch generated for ${name}"
    missing=$((missing + 1))
  fi
done

if [[ ${missing} -gt 0 ]]; then
  echo ""
  echo "  WARNING: ${missing} test case(s) did not generate a diff.patch."
  echo "  The testdata/ and golden_test.go have NOT been removed."
  echo "  Please investigate the failures above before cleaning up manually."
  exit 1
fi

if [[ "${CLEAN}" == "true" ]]; then
  # Remove old golden test artifacts
  rm -rf "${SRC}"
  echo "  REMOVED: testdata/"

  golden_test="${FUNC_DIR}/golden_test.go"
  if [[ -f "${golden_test}" ]]; then
    rm "${golden_test}"
    echo "  REMOVED: golden_test.go"
  fi
else
  echo "  Golden tests preserved (testdata/ and golden_test.go kept)."
  echo "  Use --clean to remove them."
fi

echo ""
echo "=== Done! ==="
echo ""
echo "The following e2e test cases are now ready:"
for case_dir in "${DST}"/*/; do
  [[ -d "${case_dir}" ]] || continue
  echo "  - tests/$(basename "${case_dir}")/"
done
echo ""
echo "Run the tests with:"
echo "  cd tests/e2etest"
echo "  go test -v -count=1 ./... -run \"TestE2E/../../functions/go/${FN}/tests\""
 
