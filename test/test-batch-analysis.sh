#!/usr/bin/env bash
# Compare per-module and parallel batch output, then check incremental pruning.
set -euo pipefail

DOCGEN4_DIR="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

cp "$DOCGEN4_DIR/lean-toolchain" "$TEST_DIR/"
cat > "$TEST_DIR/lakefile.lean" << EOF
import Lake
open Lake DSL

package batchTest
require «doc-gen4» from "$DOCGEN4_DIR"
lean_lib BatchFixture
EOF

mkdir -p "$TEST_DIR/BatchFixture"
cat > "$TEST_DIR/BatchFixture.lean" << 'EOF'
import BatchFixture.Base
import BatchFixture.Extra

/-! A library used to compare serial and parallel documentation analysis. -/
EOF
cat > "$TEST_DIR/BatchFixture/Base.lean" << 'EOF'
namespace BatchFixture

/-- A pair with documented fields. -/
structure Pair where
  /-- The left entry. -/
  left : Nat
  /-- The right entry. -/
  right : Nat

/-- A recursive definition with generated equations. -/
def double : Nat → Nat
  | 0 => 0
  | n + 1 => double n + 2

/-- Values with a size. -/
class Sized (α : Type) where
  /-- Compute the size. -/
  size : α → Nat

instance : Sized Pair where
  size p := p.left + p.right

end BatchFixture
EOF
cat > "$TEST_DIR/BatchFixture/Extra.lean" << 'EOF'
import BatchFixture.Base

namespace BatchFixture

/-- A concrete pair using declarations from another module. -/
def sample : Pair := ⟨double 2, 3⟩

/-- An inductive type with two constructors. -/
inductive Choice where
  | first
  | second

end BatchFixture
EOF

export LEAN_ABORT_ON_PANIC=1
export DOCGEN_SRC=file
unset DOCGEN_BATCH DISABLE_EQUATIONS

# Snapshot every fixture row, including binary types/equations and source URLs,
# plus the generated HTML. Core rows are outside the scope of this comparison.
cat > "$TEST_DIR/check-output.py" << 'PY'
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]
with sqlite3.connect(f"{(root / '.lake/build/api-docs.db').as_uri()}?mode=ro", uri=True) as db:
    assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    if mode == "pruned":
        assert db.execute("SELECT name FROM modules WHERE name = 'BatchFixture.Base'").fetchone()
        assert not db.execute("SELECT name FROM modules WHERE name = 'BatchFixture.Extra'").fetchone()
        assert not db.execute("SELECT name FROM name_info WHERE name = 'BatchFixture.sample'").fetchone()
        assert db.execute("SELECT name FROM name_info WHERE name = 'BatchFixture.double'").fetchone()
        print("OK: batch rebuild preserved live declarations and pruned the removed module")
        sys.exit(0)

    result = {}
    keys = {"modules": "name", "module_imports": "importer", "internal_names": "target_module"}
    tables = db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
    for (table,) in tables:
        columns = {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')}
        key = "module_name" if "module_name" in columns else keys.get(table)
        if key is None:
            continue
        rows = db.execute(
            f'SELECT * FROM "{table}" WHERE "{key}" = ? OR "{key}" LIKE ?',
            ("BatchFixture", "BatchFixture.%"),
        ).fetchall()
        result[table] = sorted(
            [[{"hex": value.hex()} if isinstance(value, bytes) else value for value in row] for row in rows],
            key=repr,
        )
    assert result["definition_equations"], "The fixture should exercise equation generation"
    assert result["structures"] and result["instances"] and result["inductives"]
    assert len(result["modules"]) == 3
    doc = root / ".lake/build/doc"
    pages = [doc / "BatchFixture.html", *sorted((doc / "BatchFixture").rglob("*.html"))]
    assert len(pages) == 3
    result["html"] = {str(page.relative_to(doc)): hashlib.sha256(page.read_bytes()).hexdigest() for page in pages}

baseline = root / "serial-output.json"
if mode == "serial":
    baseline.write_text(json.dumps(result, sort_keys=True))
    print("OK: saved serial database and HTML output")
else:
    expected = json.loads(baseline.read_text())
    for key in expected.keys() | result.keys():
        assert expected.get(key) == result.get(key), f"Serial and batch output differ: {key}"
    print("OK: parallel database rows, equations, source URLs, and HTML match serial output")
PY

echo "=== Preparing core documentation without equations ==="
# Exercise equation generation on the fixture, avoiding expensive core equations.
(cd "$TEST_DIR" && DISABLE_EQUATIONS=1 lake build doc-gen4/coreDocs)

echo "=== Building per-module documentation ==="
(cd "$TEST_DIR" && lake build BatchFixture:docs)
python3 "$TEST_DIR/check-output.py" "$TEST_DIR" serial

echo "=== Building parallel batch documentation ==="
export DOCGEN_BATCH=1 DOCGEN_NUM_THREADS=2
(cd "$TEST_DIR" && lake build BatchFixture:docs)
python3 "$TEST_DIR/check-output.py" "$TEST_DIR" batch

echo "=== Checking an unchanged batch build ==="
MARKER="$TEST_DIR/.lake/build/doc-data/BatchFixture--library.docInfoBatch.doc"
BEFORE="$(cat "$MARKER")"
(cd "$TEST_DIR" && lake build BatchFixture:docs)
test "$BEFORE" = "$(cat "$MARKER")"

echo "=== Removing a module and rebuilding in batch mode ==="
rm "$TEST_DIR/BatchFixture/Extra.lean"
cat > "$TEST_DIR/BatchFixture.lean" << 'EOF'
import BatchFixture.Base
EOF
(cd "$TEST_DIR" && lake build BatchFixture:docs)
test "$BEFORE" != "$(cat "$MARKER")"
python3 "$TEST_DIR/check-output.py" "$TEST_DIR" pruned

echo "SUCCESS: batch analysis matches serial output and supports incremental pruning"
