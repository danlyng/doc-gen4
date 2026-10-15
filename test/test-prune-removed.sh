#!/usr/bin/env bash
#
# Regression test: verify that doc-gen4 prunes declarations from api-docs.db when their
# defining module is removed from the project.
#
# Setup: a single-library project with three modules, MRE.lean, MRE/A.lean,
# and MRE/B.lean. Build docs once; delete MRE/B.lean and drop its import from
# MRE.lean; build docs again. Inspect api-docs.db to see whether MRE.B and
# its declaration `fooB` are still present.
#
# Requirements: elan/lake on PATH, sqlite3 on PATH.
#
# Usage:
#   ./test/test-prune-removed.sh
#   ./test/test-prune-removed.sh /path/to/doc-gen4

set -euo pipefail

DOCGEN4_DIR="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "doc-gen4:     $DOCGEN4_DIR"
echo "test project: $TEST_DIR"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "FAIL: sqlite3 not on PATH; this script needs it to inspect api-docs.db"
  exit 2
fi

# --- Project setup ---

cp "$DOCGEN4_DIR/lean-toolchain" "$TEST_DIR/"

cat > "$TEST_DIR/lakefile.lean" << EOF
import Lake
open Lake DSL

package mre

require «doc-gen4» from "$DOCGEN4_DIR"

lean_lib MRE
EOF

cat > "$TEST_DIR/MRE.lean" << 'EOF'
import MRE.A
import MRE.B
EOF

mkdir -p "$TEST_DIR/MRE"
cat > "$TEST_DIR/MRE/A.lean" << 'EOF'
/-- The A-side greeting. -/
def fooA : String := "a"
EOF

cat > "$TEST_DIR/MRE/B.lean" << 'EOF'
/-- The B-side greeting. Will be deleted to test pruning. -/
def fooB : String := "b"
EOF

export LEAN_ABORT_ON_PANIC=1
export DOCGEN_SRC=file

DB="$TEST_DIR/.lake/build/api-docs.db"

count_module_rows() {
  # Count rows in `modules` whose name matches the given Lean module name.
  local mod="$1"
  sqlite3 "$DB" "SELECT COUNT(*) FROM modules WHERE name = '$mod';"
}

count_decl_rows() {
  # Count rows in `name_info` for the given declaration name (e.g. `fooB`).
  local decl="$1"
  sqlite3 "$DB" "SELECT COUNT(*) FROM name_info WHERE name = '$decl';"
}

# --- Phase 1: initial build, both modules present ---

echo "=== Phase 1: initial build with MRE.A and MRE.B ==="
(cd "$TEST_DIR" && lake build MRE:docs)

a_rows=$(count_module_rows MRE.A)
b_rows=$(count_module_rows MRE.B)
foob_rows=$(count_decl_rows fooB)

echo "  modules where name=MRE.A:  $a_rows"
echo "  modules where name=MRE.B:  $b_rows"
echo "  name_info where name=fooB: $foob_rows"

if [ "$a_rows" -ne 1 ] || [ "$b_rows" -ne 1 ] || [ "$foob_rows" -lt 1 ]; then
  echo "FAIL: expected MRE.A, MRE.B, and fooB to be in the database after the initial build"
  exit 1
fi

# --- Phase 2: delete MRE/B.lean, drop the import, rebuild ---

echo "=== Phase 2: deleting MRE/B.lean and rebuilding ==="
rm "$TEST_DIR/MRE/B.lean"
cat > "$TEST_DIR/MRE.lean" << 'EOF'
import MRE.A
EOF

(cd "$TEST_DIR" && lake build MRE:docs)

a_rows=$(count_module_rows MRE.A)
b_rows=$(count_module_rows MRE.B)
foob_rows=$(count_decl_rows fooB)

echo "  modules where name=MRE.A:  $a_rows"
echo "  modules where name=MRE.B:  $b_rows  (expected 0 after pruning)"
echo "  name_info where name=fooB: $foob_rows  (expected 0 after pruning)"

if [ "$a_rows" -ne 1 ]; then
  echo "FAIL: MRE.A was unexpectedly removed from the database"
  exit 1
fi

if [ "$b_rows" -eq 0 ] && [ "$foob_rows" -eq 0 ]; then
  echo "SUCCESS: MRE.B and fooB were pruned from api-docs.db"
  exit 0
fi

echo
echo "BUG REPRODUCED: MRE.B and/or fooB are still in api-docs.db after the source was deleted."
echo "  api-docs.db path: $DB"
echo "  Stale rows in \`modules\`:"
sqlite3 "$DB" "SELECT name FROM modules WHERE name = 'MRE.B';" | sed 's/^/    /'
echo "  Stale rows in \`name_info\`:"
sqlite3 "$DB" "SELECT module_name, name FROM name_info WHERE name = 'fooB';" | sed 's/^/    /'
exit 1
