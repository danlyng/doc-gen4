#!/usr/bin/env bash
# Check signature binders, result types, and structure fields with hidden game arguments.
set -euo pipefail

DOCGEN4_DIR="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/NamedArgs.lean" <<'LEAN'
import DocGen4.Process.StructureInfo

open Lean Meta Elab Command DocGen4.Process

namespace NamedArgs

structure Game (A V : Type) where
  payoff : A → V

def Game.IsDominant {A V : Type} [LE V] {G : Game A V} (a : A) : Prop :=
  ∀ b, G.payoff b ≤ G.payoff a

axiom equilibrium {A V : Type} [LE V] {G : Game A V} {a : A}
    (ha : Game.IsDominant (G := G) a) : True

axiom dominant (G : Game Nat Nat) (a : Nat) : Game.IsDominant (G := G) a

def utilityGame (G : Game Nat Nat) : Game Nat Nat := G

axiom utilityDominant (G : Game Nat Nat) (a : Nat) :
    Game.IsDominant (G := utilityGame G) a

structure Certificate (G : Game Nat Nat) where
  dominant : Game.IsDominant (G := G) 0

-- Here the implicit game is determined by the expected type of `id G`.
axiom expected (G : Game Nat Nat) (h : id G = G) : True

run_cmd liftTermElabM do
  let binder ← Info.ofConstantVal (← getConstInfo ``equilibrium).toConstantVal
  let some ha := binder.args.back? | throwError "missing hypothesis"
  let ha := ha.binder.stripTags
  unless ha == "(ha : Game.IsDominant (G := G) a)" do
    throwError "unexpected hypothesis: {ha}"
  for (n, wanted) in #[(``dominant, "Game.IsDominant (G := G) a"),
      (``utilityDominant, "Game.IsDominant (G := utilityGame G) a")] do
    let info ← Info.ofConstantVal (← getConstInfo n).toConstantVal
    unless info.type.stripTags == wanted do
      throwError "unexpected result for {n}: {info.type.stripTags}"
  let .inductInfo cert ← getConstInfo ``Certificate | throwError "expected structure"
  let (_, fields) ← getFieldTypes cert
  let some field := fields[0]? | throwError "missing field"
  unless field.type.stripTags == "Game.IsDominant (G := G) 0" do
    throwError "unexpected field: {field.type.stripTags}"
  let expected ← Info.ofConstantVal (← getConstInfo ``expected).toConstantVal
  let some h := expected.args.back? | throwError "missing expected-type hypothesis"
  unless h.binder.stripTags == "(h : id G = G)" do
    throwError "redundant implicit argument: {h.binder.stripTags}"
  -- Signature rendering must not change the general term printer or leak a delaborator.
  let raw ← prettyPrintTerm (← getConstInfo ``dominant).type
  if (raw.stripTags.splitOn "(G :=").length > 1 then
    throwError "signature delaborator leaked into prettyPrintTerm"
  IO.println "SUCCESS: named game arguments preserved in binders, results, and fields"

end NamedArgs
LEAN

cd "$DOCGEN4_DIR"
LAKE_RESTORE_ARTIFACTS=true lake build DocGen4.Process.StructureInfo
lake env lean "$TEST_DIR/NamedArgs.lean"
