/-
Copyright (c) 2022 Henrik Böving. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Henrik Böving
-/
import Lean

import DocGen4.Process.Base
import DocGen4.Process.Attributes
import DocGen4.RenderedCode

namespace DocGen4.Process
open Lean Meta

open Lean.Parser.Tactic.Doc in
/-- Gets the rendered extensions for the given canonical tactic name as Verso content -/
def getTacticExtensionText (env : Environment) (tactic : Name) : Option (Doc.Block ElabInline ElabBlock) :=
  let exts := getTacticExtensions env tactic
  if exts.size == 0 then none
  else
    some <| .concat #[
      .para #[.text "Extensions:"],
      .ul <| exts.map (⟨#[.para #[.text ·]]⟩)
    ]

open Lean.Parser.Term.Doc in
/--
Renders the recommended spellings for the given declaration into Verso content for appending to
the docstring.
-/
def getRecommendedSpellingText (env : Environment) (declName : Name) : Option (Doc.Block ElabInline ElabBlock) := Id.run do
  let spellings := getRecommendedSpellingsForName env declName
  if spellings.size == 0 then none
  else some <| .concat #[
    .para #[.text "Conventions for notations in identifiers:"],
    .ul (spellings.map bullet)
  ]
where
  bullet (spelling : RecommendedSpelling) : Doc.ListItem (Doc.Block ElabInline ElabBlock) :=
    let firstLine : Array (Doc.Inline ElabInline) := #[
      .text "The recommended spelling of ",
      .code spelling.«notation»,
      .text " in identifiers is ",
      .code spelling.recommendedSpelling
    ]
    let additionalInfoLines := spelling.additionalInformation?.map (·.split '\n' |>.toStringList)
    match additionalInfoLines with
    | none | some [] =>
      .mk #[.para (firstLine ++ #[.text ".", .linebreak "\n", .linebreak "\n"])]
    | some [l] =>
      .mk #[.para (firstLine ++ #[.text s!" ({l.trimAsciiEnd}).", .linebreak "\n", .linebreak "\n"])]
    | some ls =>
      .mk <| #[.para (firstLine ++ #[.text "."])] ++ additionalInfoBlocks ls
  additionalInfoBlocks (lines : List String) : Array (Doc.Block ElabInline ElabBlock) := Id.run do
    let mut blocks := #[]
    let mut paragraph := #[]
    for line in lines do
      let line := line.trimAscii.copy
      if line.isEmpty then
        if !paragraph.isEmpty then
          blocks := blocks.push (.para #[.text (String.intercalate " " paragraph.toList)])
          paragraph := #[]
      else
        paragraph := paragraph.push line
    if !paragraph.isEmpty then
      blocks := blocks.push (.para #[.text (String.intercalate " " paragraph.toList)])
    return blocks


open Lean.Parser.Tactic.Doc in
open Lean.Parser.Term.Doc in
def getDocString? (env : Environment) (name : Name) : IO (Option (String ⊕ (VersoDocString × String))) := do
  let name := alternativeOfTactic env name |>.getD name
  match (← findInternalDocString? env name) with
  | none => return none
  | some (.inr verso) =>
    let exts := getTacticExtensionText env name |>.map (#[·]) |>.getD #[]
    let spellings := getRecommendedSpellingText env name |>.map (#[·]) |>.getD #[]
    let verso := { verso with text := verso.text ++ exts ++ spellings }
    return some <| .inr (verso, ← versoDocToMarkdown env verso)
  | some (.inl _) =>
    return (·.map .inl) (← Lean.findDocString? env name)


def NameInfo.ofTypedName (n : Name) (t : Expr) : MetaM NameInfo := do
  let env ← getEnv
  return { name := n, type := ← prettyPrintTerm t, doc := ← getDocString? env n}

/--
Pretty prints a `Lean.Parser.Term.bracketedBinder`.
-/
private def prettyPrintBinder (stx : Syntax) (infos : SubExpr.PosMap Elab.Info) : MetaM RenderedCode := do
  let fmt ← PrettyPrinter.format Parser.Term.bracketedBinder.formatter stx
  let tt := Widget.TaggedText.prettyTagged fmt
  let ctx := {
    env := ← getEnv
    mctx := ← getMCtx
    options := ← getOptions
    currNamespace := ← getCurrNamespace
    openDecls := ← getOpenDecls
    fileMap := default,
    ngen := ← getNGen
  }
  return renderTagged (← Widget.tagCodeInfos ctx infos tt)

private def prettyPrintTermStx (stx : Term) (infos : SubExpr.PosMap Elab.Info) : MetaM RenderedCode := do
  let fmt ← PrettyPrinter.formatTerm stx
  let tt := Widget.TaggedText.prettyTagged fmt
  let ctx := {
    env := ← getEnv
    mctx := ← getMCtx
    options := ← getOptions
    currNamespace := ← getCurrNamespace
    openDecls := ← getOpenDecls
    fileMap := default,
    ngen := ← getNGen
  }
  return renderTagged (← Widget.tagCodeInfos ctx infos tt)

-- Find implicit arguments that cannot be recovered from the result type or the types of
-- explicit arguments and instances. Work backwards so that a named argument also determines
-- its own implicit type parameters, rather than printing those parameters separately.
private def signatureNamedArgs (e : Expr) : MetaM (Array Nat) := withoutModifyingState <| withNewMCtxDepth do
  let args := e.getAppArgs
  let (params, binderInfos, result) ← forallMetaBoundedTelescope (← inferType e.getAppFn) args.size
  if params.size != args.size then return #[]
  discard <| isDefEq result (← inferType e)
  for i in *...args.size do
    if binderInfos[i]!.isExplicit || binderInfos[i]! == .instImplicit then
      discard <| isDefEq (← inferType params[i]!) (← inferType args[i]!)
  let mut needed := #[]
  for i in (List.range args.size).reverse do
    if binderInfos[i]! == .implicit || binderInfos[i]! == .strictImplicit then
      if (← instantiateMVars params[i]!).hasExprMVar then
        needed := needed.push i
        discard <| isDefEq (← inferType params[i]!) (← inferType args[i]!)
        discard <| isDefEq params[i]! args[i]!
  return needed

open PrettyPrinter.Delaborator SubExpr in
private def delabSignatureApp : Delab := do
  let e ← getExpr
  guard e.getAppFn.isConst
  let needed ← signatureNamedArgs e
  guard !needed.isEmpty
  let mut optionsPerPos := (← read).optionsPerPos
  for i in needed do
    let pos ← withNaryArg i getPos
    let opts := optionsPerPos.get? pos |>.getD {}
    optionsPerPos := optionsPerPos.insert pos (opts.setBool `pp.analysis.namedArg true)
  withReader (fun ctx => { ctx with optionsPerPos }) delabApp

def Info.ofTypedName (n : Name) (t : Expr) : MetaM Info := do
  -- Install the application delaborator only for signatures. Unlike `pp.analyze`, this keeps
  -- the usual notation and universe/type annotation settings, including in the result type.
  let env := PrettyPrinter.Delaborator.delabAttribute.ext.addLocalEntry (← getEnv)
    { key := `app, declName := ``delabSignatureApp, value := delabSignatureApp, isBuiltin := false }
  -- Use the main signature delaborator. We need to run sanitization, parenthesization, and formatting ourselves
  -- to be able to extract the pieces of the signature right before they are formatted
  -- and then format them individually.
  let (sigStx, infos) ← withEnv env <| withTheReader Core.Context ({ · with currNamespace := n.getPrefix }) <|
    PrettyPrinter.delabCore t (delab := PrettyPrinter.Delaborator.delabForallParamsWithSignature fun binders type =>
      -- Use `declSig` as a data structure so that the binders and type can be put through the sanitizer all together.
      `(declSig| $binders* : $type))
  let sigStx := (sanitizeSyntax sigStx).run' { options := (← getOptions) }
  let sigStx ← PrettyPrinter.parenthesize Parser.Command.declSig.parenthesizer sigStx
  let `(declSig| $binders* : $type) := sigStx
    | throwError "signature pretty printer failure for {n}"
  let args ← binders.mapM fun binder => do
    let fmt ← prettyPrintBinder binder infos
    return Arg.mk fmt (!binder.isOfKind ``Parser.Term.explicitBinder)
  let type ← prettyPrintTermStx type infos
  match ← findDeclarationRanges? n with
  -- TODO: Maybe selection range is more relevant? Figure this out in the future
  | some range =>
    return {
      toNameInfo := { name := n, type, doc := ← getDocString? (← getEnv) n},
      args,
      declarationRange := range.range,
      attrs := ← getAllAttributes n
    }
  | none => panic! s!"{n} is a declaration without position"

def Info.ofConstantVal (v : ConstantVal) : MetaM Info := do
  let e := Expr.const v.name (v.levelParams.map mkLevelParam)
  ofTypedName v.name (← inferType e)
end DocGen4.Process
