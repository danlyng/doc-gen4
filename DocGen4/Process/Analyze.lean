/-
Copyright (c) 2022 Henrik Böving. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Henrik Böving
-/

import Lean.Elab.Tactic.Doc
import Lean.Meta.Basic
import Lean.Parser.Extension
import Std.Data.HashMap
import Std.Data.HashSet

import DocGen4.Process.Base
import DocGen4.Process.Hierarchy
import DocGen4.Process.DocInfo

namespace DocGen4.Process

open Lean Meta
open Lean.Elab.Tactic.Doc

/-- Represents a non-verso docstring; these will be rendered using `Output.docStringToHtml`. -/
abbrev MarkdownDocstring := String

/--
Member of a module, either a declaration or some module doc string.
-/
inductive ModuleMember where
| docInfo (info : DocInfo) : ModuleMember
| modDoc (doc : ModuleDoc) : ModuleMember
deriving Inhabited

/-- Information about a tactic declaration which will be rendered on the Tactics page.

This datastructure contains slightly different contents compared to a `TacticDoc` to make
it easily serializable as JSON. It is designed to be easy to instantiate,
using `{ tacticDoc with ... }`.
-/
structure TacticInfo (textType : Type) where
  /-- The name of the canonical parser for the tactic -/
  internalName : Name
  /-- The user-facing name to display (typically the first keyword token) -/
  userName : String
  /-- The tags that have been applied to the tactic -/
  tags : Array Name
  /-- The docstring for the tactic, including any extension docstrings. -/
  docString : textType
  /-- Name of the module where the tactic is declared. -/
  definingModule : Name
deriving FromJson, ToJson

/--
A Lean module.
-/
structure Module where
  /--
  Name of the module.
  -/
  name : Name
  /--
  All members of the module, sorted according to their line numbers.
  -/
  members : Array ModuleMember
  imports : Array Name
  /--
  Tactics declared in this module.
  -/
  tactics : Array (TacticInfo MarkdownDocstring)
  deriving Inhabited

/--
The result of running a full doc-gen analysis on a project.
-/
structure AnalyzerResult where
  /--
  The map from module names to indices of the `moduleNames` array.
  -/
  name2ModIdx : Std.HashMap Name ModuleIdx
  /--
  The list of all modules, accessible nicely via `name2ModIdx`.
  -/
  moduleNames : Array Name
  /--
  A map from module names to information about these modules.
  -/
  moduleInfo : Std.HashMap Name Module
  /--
  For each rendered declaration, the set of names whose declaration ranges are contained within it.
  Used to determine whether auto-generated projections should receive anchor IDs in the HTML output.

  This field is only populated when the result is read from the database. Prior to that, it is
  empty.
  -/
  containedNames : Std.HashMap Name (Std.HashSet Name) := {}
  deriving Inhabited

namespace ModuleMember

def getDeclarationRange : ModuleMember → DeclarationRange
| docInfo i => i.getDeclarationRange
| modDoc i => i.declarationRange

def getName : ModuleMember → Name
| docInfo i => i.getName
| modDoc _ => Name.anonymous

/--
A total order for module members, based on their declaration range, with ties (members sharing a
start position) broken by name. The tie-break makes the order total so that `qsort` produces
output independent of the insertion order — important because the parallel analyzer collects
members in a nondeterministic order across worker tasks.
-/
def order (l r : ModuleMember) : Bool :=
  let lp := l.getDeclarationRange.pos
  let rp := r.getDeclarationRange.pos
  if lp.line == rp.line && lp.column == rp.column then
    l.getName.toString < r.getName.toString
  else
    Position.lt lp rp

def getDocString : ModuleMember → Option (String ⊕ VersoDocString)
| docInfo i => i.getDocString
| modDoc i => some (.inl i.doc)

def shouldRender : ModuleMember → Bool
| docInfo i => i.shouldRender
| modDoc _ => true

end ModuleMember

inductive AnalyzeTask where
| analyzePrefixModules (topLevel : Name) : AnalyzeTask
| analyzeConcreteModules (modules : Array Name) : AnalyzeTask

def AnalyzeTask.getLoad (task : AnalyzeTask) : Array Name :=
  match task with
  | .analyzePrefixModules topLevel => #[topLevel]
  | .analyzeConcreteModules modules => modules

/-- Collect tactic info for pages to display, grouped by defining module. `allTacticDocs` enumerates
*every* tactic in the environment, so it must be computed once for the whole run — not once per
module (which is `O(modules × tactics)` and dominates a whole-library batch). -/
def collectTacticsByModule (env : Environment) :
    MetaM (Std.HashMap Name (Array (TacticInfo MarkdownDocstring))) := do
  let docs ← Elab.Tactic.Doc.allTacticDocs
  let mut res := {}
  for doc in docs do
    let some modIdx := env.getModuleIdxFor? doc.internalName | continue
    let definingModule := env.header.moduleNames[modIdx]!
    let info := {
      doc with
      docString := doc.docString.getD "This tactic has no documentation." ++
        ("\n\n".intercalate doc.extensionDocs.toList)
      tags := doc.tags.toArray,
      definingModule := definingModule,
    }
    res := res.insert definingModule ((res.getD definingModule #[]).push info)
  return res

def getAllModuleDocs (relevantModules : Array Name) : MetaM (Std.HashMap Name Module) := do
  let env ← getEnv
  let tacticsByModule ← collectTacticsByModule env
  let mut res := Std.HashMap.emptyWithCapacity relevantModules.size
  for module in relevantModules do
    let modDocs := getModuleDoc? env module |>.getD #[] |>.map .modDoc
    let some modIdx := env.getModuleIdx? module | unreachable!
    let moduleData := env.header.moduleData[modIdx]!
    let imports := moduleData.imports.map Import.module
    let tactics := tacticsByModule.getD module #[]
    res := res.insert module <| Module.mk module modDocs imports tactics
  return res

def mkOptions : IO DocGenOptions := do
  match ← IO.getEnv "DISABLE_EQUATIONS" with
  | some "1" => return ⟨false⟩
  | _ => return {}

/--
Number of worker threads for the parallel analyzer. Honors `DOCGEN_NUM_THREADS`; otherwise queries
the number of online processors via `getconf` (portable across Linux and macOS), falling back to a
conservative default if that fails.
-/
def detectNumThreads : IO Nat := do
  if let some s ← IO.getEnv "DOCGEN_NUM_THREADS" then
    if let some n := s.trimAscii.toString.toNat? then
      return max 1 n
  try
    let out ← IO.Process.output { cmd := "getconf", args := #["_NPROCESSORS_ONLN"] }
    if let some n := out.stdout.trimAscii.toString.toNat? then
      return max 1 n
  catch _ => pure ()
  return 8

/-- The set of modules an `AnalyzeTask` asks us to document. -/
def relevantModulesOf (task : AnalyzeTask) (allModules : Array Name) : Std.HashSet Name :=
  match task with
  | .analyzePrefixModules topLevel =>
    let modules := allModules.filter (topLevel.isPrefixOf ·)
    Std.HashSet.insertMany (Std.HashSet.emptyWithCapacity modules.size) modules
  | .analyzeConcreteModules modules =>
    Std.HashSet.insertMany (Std.HashSet.emptyWithCapacity modules.size) modules

/--
The constants to analyze, as `(name, info, definingModule)` triples, restricted to
`relevantModules`. Iterates each relevant module's `ModuleData.constants` directly rather than
scanning the whole imported environment and filtering — the latter is `O(closure size)` per run,
which is wasteful when only a few modules are relevant.
-/
def collectWork (env : Environment) (relevantModules : Std.HashSet Name) :
    Array (Name × ConstantInfo × Name) := Id.run do
  let mut work := #[]
  for moduleName in relevantModules do
    let some modIdx := env.getModuleIdx? moduleName | continue
    let modData := env.header.moduleData[modIdx]!
    for cinfo in modData.constants do
      work := work.push (cinfo.name, cinfo, moduleName)
  return work

/-- The standard core configuration used to run per-constant analysis. -/
def mkCoreContext : MetaM Core.Context := do
  return {
    maxHeartbeats := 5000000,
    options := ← getOptions,
    fileName := ← getFileName,
    fileMap := ← getFileMap,
  }

/--
Analyze a single constant. Non-interrupt exceptions are caught and returned as a warning string
(matching the original behavior) rather than aborting the run.
-/
def analyzeOne (options : DocGenOptions) (name : Name) (cinfo : ConstantInfo) :
    MetaM (Option DocInfo × Option String) :=
  tryCatchRuntimeEx
    (do return (← (DocInfo.ofConstant (name, cinfo)).run options, none))
    (fun e => do
      return (none, some s!"WARNING: Failed to obtain information for: {name}: {← e.toMessageData.toString}"))

/-- Output of one parallel analysis chunk: the produced infos (tagged with their defining module)
and any warnings, buffered so they can be replayed deterministically on the main thread. -/
structure ChunkOut where
  docInfos : Array (Name × DocInfo)
  warnings : Array String

/-- Analyze a contiguous chunk of the work list. Each constant runs in its own fresh `CoreM`/`MetaM`
state seeded from the shared (read-only, persistent) `env`. -/
def analyzeChunk (env : Environment) (coreCtx : Core.Context) (options : DocGenOptions)
    (work : Array (Name × ConstantInfo × Name)) : IO ChunkOut := do
  let mut docInfos := #[]
  let mut warnings := #[]
  for (name, cinfo, moduleName) in work do
    let ((dinfo?, warn?), _, _) ← (analyzeOne options name cinfo).toIO coreCtx { env := env } {} {}
    if let some di := dinfo? then
      docInfos := docInfos.push (moduleName, di)
    if let some w := warn? then
      warnings := warnings.push w
  return { docInfos, warnings }

/-- Compute the equations of a definition, catching exceptions into a warning string. -/
def computeEqnsSafe (options : DocGenOptions) (v : DefinitionVal) :
    MetaM (Option (Array RenderedCode) × Option String) :=
  tryCatchRuntimeEx
    (do return (← (computeEquations? v).run options, none))
    (fun e => do
      return (none, some s!"WARNING: Failed to calculate equational lemmata for {v.name}: {← e.toMessageData.toString}"))

/--
Fill in the equations of a definition/instance `DocInfo` (phase 2 of the parallel analyzer).
Equation generation (`getEqnsFor?`) can realize lemmas on demand, mutating the shared environment's
import-realization context, so it is NOT safe to run concurrently — it must happen here, serially.
Runs in a fresh state seeded from `env`, exactly as the serial analyzer does per constant.
-/
def fillEquations (env : Environment) (coreCtx : Core.Context) (options : DocGenOptions)
    (di : DocInfo) : IO DocInfo := do
  let patch (name : Name) (rebuild : Option (Array RenderedCode) → DocInfo) : IO DocInfo := do
    match env.find? name with
    | some (.defnInfo v) =>
      let ((eqs?, warn?), _, _) ← (computeEqnsSafe options v).toIO coreCtx { env := env } {} {}
      if let some w := warn? then IO.println w
      return rebuild eqs?
    | _ => return di
  match di with
  | .definitionInfo info => patch info.name (fun eqs => .definitionInfo { info with equations := eqs })
  | .instanceInfo info => patch info.name (fun eqs => .instanceInfo { info with equations := eqs })
  | _ => return di

/--
Run the doc-gen analysis on all modules that are loaded into the `Environment`
of this `MetaM` run and mentioned by the `AnalyzeTask`. Serial; used by the per-module path.
-/
def process (task : AnalyzeTask) : MetaM AnalyzerResult := do
  let env ← getEnv
  let allModules := env.header.moduleNames
  let relevantModules := relevantModulesOf task allModules
  let mut res ← getAllModuleDocs relevantModules.toArray
  let options ← liftM mkOptions
  let coreCtx ← mkCoreContext

  for (name, cinfo, moduleName) in collectWork env relevantModules do
    let ((dinfo?, warn?), _, _) ← (analyzeOne options name cinfo).toIO coreCtx { env := env } {} {}
    if let some w := warn? then IO.println w
    if let some dinfo := dinfo? then
      let module := res[moduleName]!
      res := res.insert moduleName {module with members := module.members.push (ModuleMember.docInfo dinfo)}

  -- TODO: This could probably be faster if we did sorted insert above instead
  for (moduleName, module) in res.toArray do
    res := res.insert moduleName {module with members := module.members.qsort ModuleMember.order}

  return {
    name2ModIdx := env.const2ModIdx,
    moduleNames := allModules,
    moduleInfo := res,
  }

/--
Like `process`, but fans the per-constant analysis out across worker threads. Used by the batch
(`DOCGEN_BATCH`) path, which imports a whole library's closure once and documents all of it in a
single process.

Two phases:
1. **Parallel** — analyze every constant *without* equations across `detectNumThreads` chunks.
   Concurrent reads of the persistent (`leakEnv`) environment and per-task `CoreM`/`MetaM` state are
   safe.
2. **Serial** — fill in definition/instance equations, which must not run concurrently (see
   `fillEquations`).

Produces output identical to `process` (members are re-sorted with the total `ModuleMember.order`).
-/
def processParallel (task : AnalyzeTask) : MetaM AnalyzerResult := do
  let env ← getEnv
  let allModules := env.header.moduleNames
  let relevantModules := relevantModulesOf task allModules
  let mut res ← getAllModuleDocs relevantModules.toArray
  let options ← liftM mkOptions
  let coreCtx ← mkCoreContext
  let work := collectWork env relevantModules
  let numThreads ← liftM detectNumThreads
  let chunkSize := work.size / numThreads + 1

  -- Phase 1: parallel analysis without equations.
  let phase1Opts := { options with genEquations := false }
  let mut tasks := #[]
  let mut i := 0
  while i < work.size do
    let chunk := work.extract i (i + chunkSize)
    tasks := tasks.push (← IO.asTask (analyzeChunk env coreCtx phase1Opts chunk))
    i := i + chunkSize
  -- Await in spawn order and replay warnings on the main thread (deterministic, non-interleaved).
  for t in tasks do
    let out ← liftM (m := IO) (IO.ofExcept (← IO.wait t))
    for w in out.warnings do IO.println w
    for (moduleName, di) in out.docInfos do
      let module := res[moduleName]!
      res := res.insert moduleName {module with members := module.members.push (ModuleMember.docInfo di)}

  -- Phase 2: fill equations serially.
  if options.genEquations then
    for (moduleName, module) in res.toArray do
      let mut members := #[]
      for mem in module.members do
        match mem with
        | .docInfo di => members := members.push (.docInfo (← liftM (fillEquations env coreCtx options di)))
        | other => members := members.push other
      res := res.insert moduleName {module with members}

  for (moduleName, module) in res.toArray do
    res := res.insert moduleName {module with members := module.members.qsort ModuleMember.order}

  return {
    name2ModIdx := env.const2ModIdx,
    moduleNames := allModules,
    moduleInfo := res,
  }

open Std (Iterator Iter)

def filterDocInfo [Iterator α Id ModuleMember] (ms : @Iter α ModuleMember) :=
  ms.filterMap fun
    | ModuleMember.docInfo i => some i
    | _ => none

end DocGen4.Process
