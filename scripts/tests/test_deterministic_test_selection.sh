#!/bin/bash
# Semantic regression test for the blocking unit and coverage test allowlist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/deterministic-test-selection.sh"

required_classes=(
  MacTalkTests/OutputCoordinatorTests
  MacTalkTests/PermissionFlowCoordinatorTests
  MacTalkTests/StatusBarControllerTests
  MacTalkTests/WhisperModelDownloadClientTests
)

for required_class in "${required_classes[@]}"; do
  count=0
  for selected_class in "${DETERMINISTIC_TEST_CLASSES[@]}"; do
    [[ "$selected_class" == "$required_class" ]] && ((count += 1))
  done
  if [[ "$count" -ne 1 ]]; then
    echo "deterministic test allowlist must select $required_class exactly once (found $count)" >&2
    exit 1
  fi

done

selection_args=()
while IFS= read -r argument; do
  selection_args+=("$argument")
done < <(append_deterministic_test_selection)
for required_class in "${required_classes[@]}"; do
  expected="-only-testing:$required_class"
  if ! printf '%s\n' "${selection_args[@]}" | grep -Fqx -e "$expected"; then
    echo "deterministic test selection omitted $expected" >&2
    exit 1
  fi
done

echo 'deterministic test selection semantic contract passed'
