#!/usr/bin/env bash
# Execute this trusted copy outside the candidate, with no publishing credentials.
set -euo pipefail
cd "${1:?candidate checkout required}"
candidate="$(git rev-parse HEAD)"
receipt="${2:-}"
export LEAN_ABORT_ON_PANIC=1
unset DOCGEN_BATCH DOCGEN_NUM_THREADS DISABLE_EQUATIONS
export LEAN_NUM_THREADS=4 DOCGEN_NUM_THREADS=4

# Fresh build of this package and every dependency. Only disposable checkouts.
rm -rf .lake/build
if [[ -d .lake/packages ]]; then
  find .lake/packages -type d -path '*/.lake/build' -prune -exec rm -rf '{}' +
fi
lake build --wfail
./test/test-multi-lib-docs.sh
DOCGEN_BATCH=1 DOCGEN_NUM_THREADS=2 ./test/test-multi-lib-docs.sh
./test/test-prune-removed.sh
./test/test-batch-analysis.sh
./test/test-verso-moduledocs.sh

rm -rf .lake/build/doc .lake/build/docs
lake build --wfail DocGen4:docs
comparison="$(mktemp -d)"
trap 'rm -rf "$comparison"' EXIT
lake query DocGen4:docs | sort > "$comparison/expected.txt"
find "$(pwd)/.lake/build/doc" -type f ! -name '*.trace' ! -name '*.hash' | sort > "$comparison/actual.txt"
diff "$comparison/actual.txt" "$comparison/expected.txt"
git diff --exit-code HEAD
test -z "$(git status --porcelain --untracked-files=normal)"
test "$(git rev-parse HEAD)" = "$candidate"
if [[ -n "$receipt" ]]; then
  python3 - "$receipt" "$candidate" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'candidate': sys.argv[2], 'gate': 1}) + '\n')
PY
fi
