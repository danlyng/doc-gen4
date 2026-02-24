import DocGen4
import Lean
import Cli

open DocGen4 DocGen4.DB DocGen4.Output Lean Cli

def runHeaderDataCmd (p : Parsed) : IO UInt32 := do
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  headerDataOutput buildDir
  return 0

def runSingleCmd (p : Parsed) : IO UInt32 := do
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  let dbFile := p.positionalArg! "db" |>.as! String
  let relevantModules := #[p.positionalArg! "module" |>.as! String |> String.toName]
  let sourceUri := p.positionalArg! "sourceUri" |>.as! String
  let doc ← load <| .analyzeConcreteModules relevantModules
  updateModuleDb builtinDocstringValues doc buildDir dbFile (fun _ => some sourceUri)
  return 0

/-- Reconstruct the source URL of a module from the library's base source URI, matching the
per-module URI computed by Lake's `srcUri` facet (`<libBaseUri>/<module/path>.lean`). -/
def mkModuleSourceUrl (libBaseUri : String) (mod : Name) : String :=
  mod.components.foldl (init := libBaseUri) (fun acc c => acc.push '/' ++ c.toString (escape := false)) ++ ".lean"

def runBatchCmd (p : Parsed) : IO UInt32 := do
  IO.println "-*- Running in Batch Mode -*-"
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  let dbFile := p.positionalArg! "db" |>.as! String
  let libBaseUri := p.positionalArg! "sourceUri" |>.as! String
  let modulesFile := p.positionalArg! "modules" |>.as! String
  let modules := (← IO.FS.readFile modulesFile).split (· == '\n')
    |>.filterMap (fun s => let s := s.trimAscii.toString; if s.isEmpty then none else some s.toName)
    |>.toArray
  -- Import the whole library's closure once and document all of it in this single process,
  -- fanning the analysis out across worker threads.
  let doc ← load (.analyzeConcreteModules modules) (parallel := true)
  updateModuleDb builtinDocstringValues doc buildDir dbFile (fun m => some (mkModuleSourceUrl libBaseUri m))
  return 0

def runGenCoreCmd (p : Parsed) : IO UInt32 := do
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  let dbFile := p.positionalArg! "db" |>.as! String
  let module := p.positionalArg! "module" |>.as! String |> String.toName
  let doc ← load <| .analyzePrefixModules module
  updateModuleDb builtinDocstringValues doc buildDir dbFile (fun _ => none)
  return 0

def runDocGenCmd (_p : Parsed) : IO UInt32 := do
  IO.println "You most likely want to use me via Lake now, check my README on Github on how to:"
  IO.println "https://github.com/leanprover/doc-gen4"
  return 0

/-- A source linker that uses URLs from the database, falling back to core module URLs -/
def dbSourceLinker (sourceUrls : Std.HashMap Name String) (_gitUrl? : Option String) (module : Name) : Option DeclarationRange → String :=
  let root := module.getRoot
  let leanHash := Lean.githash
  if root == `Lean ∨ root == `Init ∨ root == `Std then
    let parts := module.components.map (Name.toString (escape := false))
    let path := "/".intercalate parts
    Output.SourceLinker.mkGithubSourceLinker s!"https://github.com/leanprover/lean4/blob/{leanHash}/src/{path}.lean"
  else if root == `Lake then
    let parts := module.components.map (Name.toString (escape := false))
    let path := "/".intercalate parts
    Output.SourceLinker.mkGithubSourceLinker s!"https://github.com/leanprover/lean4/blob/{leanHash}/src/lake/{path}.lean"
  else
    -- Look up source URL from database
    match sourceUrls[module]? with
    | some url =>
      if url.startsWith "vscode://file/" then
        Output.SourceLinker.mkVscodeSourceLinker url
      else if url.startsWith "https://github.com" then
        Output.SourceLinker.mkGithubSourceLinker url
      else
        fun _ => url
    | none =>
      -- Fallback for modules without source URL
      fun _ => "#"

/-- Flush the WAL so the database file is self-contained. Connection is closed on return. -/
def walCheckpoint (dbPath : String) : IO Unit := do
  -- The checkpoint requires a read-write connection, which can be blocked by concurrent
  -- documentation info writes for other libraries that this library doesn't depend on. This uses a
  -- very long timeout (24h) because a full Mathlib build on a slow machine could in principle keep
  -- the DB locked for a long time.
  let db ← SQLite.open dbPath (busyTimeoutMs := 86400000)
  db.exec "PRAGMA wal_checkpoint(TRUNCATE)"
  db.exec "PRAGMA optimize"

def runFromDbCmd (p : Parsed) : IO UInt32 := do
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  let dbPath := p.positionalArg! "db" |>.as! String
  let manifestOutput? := (p.flag? "manifest").map (·.as! String)
  let moduleRoots := (p.variableArgsAs! String).map String.toName
  -- Comma-separated list of module-name prefixes whose stale modules should be pruned. Empty/absent
  -- disables pruning entirely (back-compat for direct `fromDb` invocations).
  let prunePrefixes : Array Name := match p.flag? "prune-prefix" with
    | some f => ((f.as! String).splitOn ",").toArray.filterMap fun s =>
        let s := s.trimAscii.toString
        if s.isEmpty then none else some s.toName
    | none => #[]

  -- Prune stale modules before reading anything else, so the loaded linking context and the
  -- generated HTML reflect the pruned state.
  pruneStaleModules dbPath prunePrefixes moduleRoots builtinDocstringValues

  -- Flush WAL so the database file is self-contained for concurrent readers
  walCheckpoint dbPath

  -- Load linking context (module names, source URLs, declaration locations)
  let db ← openForReading dbPath builtinDocstringValues
  let linkCtx ← db.loadLinkingContext

  -- Determine which modules to generate HTML for
  let targetModules ←
    if moduleRoots.isEmpty then
      pure linkCtx.moduleNames
    else
      db.getTransitiveImports moduleRoots

  let baseConfig ← getSimpleBaseContext buildDir (Hierarchy.fromArray targetModules)
  -- Add `references` pseudo-module to hierarchy only when bibliography data exists
  let hierarchy := Hierarchy.fromArray
    (if baseConfig.refs.isEmpty then targetModules else targetModules.push `references)
  let baseConfig := { baseConfig with hierarchy }

  -- Parallel HTML generation
  let (outputs, jsonModules) ← htmlOutputResultsParallel baseConfig dbPath linkCtx targetModules (sourceLinker? := some (dbSourceLinker linkCtx.sourceUrls))

  -- Load all tactics from DB in sorted order and convert markdown docstrings to HTML
  let allTacticsRaw ← db.loadAllTactics
  let refsMap : Std.HashMap String BibItem :=
    Std.HashMap.emptyWithCapacity baseConfig.refs.size |>.insertMany
      (baseConfig.refs.iter.map fun x => (x.citekey, x))
  let minimalSiteCtx : SiteContext := {
    result := { name2ModIdx := linkCtx.name2ModIdx, moduleNames := linkCtx.moduleNames, moduleInfo := {} }
    sourceLinker := fun _ _ => "#"
    refsMap := refsMap
  }
  let (allTactics, _) := allTacticsRaw.mapM Process.TacticInfo.docStringToHtml |>.run {} minimalSiteCtx baseConfig

  -- Generate the search index (declaration-data.bmp)
  htmlOutputIndex baseConfig jsonModules allTactics

  -- Update navbar to include all modules on disk
  updateNavbarFromDisk buildDir
  if let .some manifestOutput := manifestOutput? then
    IO.FS.writeFile manifestOutput (Lean.toJson outputs).compress
  return 0

def runBibPrepassCmd (p : Parsed) : IO UInt32 := do
  let buildDir := match p.flag? "build" with
    | some dir => dir.as! String
    | none => ".lake/build"
  if p.hasFlag "none" then
    IO.println "INFO: reference page disabled"
    disableBibFile buildDir
  else
    match p.variableArgsAs! String with
    | #[source] =>
      let contents ← IO.FS.readFile source
      if p.hasFlag "json" then
        IO.println "INFO: 'references.json' will be copied to the output path; there will be no 'references.bib'"
        preprocessBibJson buildDir contents
      else
        preprocessBibFile buildDir contents Bibtex.process
    | _ => throw <| IO.userError "there should be exactly one source file"
  return 0

def singleCmd := `[Cli|
  single VIA runSingleCmd;
  "Populate the database with documentation for the specified module."

  FLAGS:
    b, build : String; "Build directory."

  ARGS:
    module : String; "The module to document."
    db : String; "Path to the SQLite database (relative to build dir)"
    sourceUri : String; "The sourceUri as computed by the Lake facet"
]

def batchCmd := `[Cli|
  batch VIA runBatchCmd;
  "Populate the database with documentation for an entire library in a single process. Imports the \
   library's transitive closure once and analyzes all listed modules in parallel."

  FLAGS:
    b, build : String; "Build directory."

  ARGS:
    db : String; "Path to the SQLite database (relative to build dir)"
    sourceUri : String; "The library's base sourceUri as computed by the Lake facet"
    modules : String; "Path to a file listing the library's module names, one per line"
]

def genCoreCmd := `[Cli|
  genCore VIA runGenCoreCmd;
  "Populate the database with documentation for the specified Lean core module (Init, Std, Lake, Lean)."

  FLAGS:
    b, build : String; "Build directory."

  ARGS:
    module : String; "The core module prefix to document (e.g., Init, Lean)."
    db : String; "Path to the SQLite database (relative to build dir)"
]

def bibPrepassCmd := `[Cli|
  bibPrepass VIA runBibPrepassCmd;
  "Run the bibliography prepass: copy the bibliography file to output directory. By default it assumes the input is '.bib'."

  FLAGS:
    n, none; "Disable bibliography in this project."
    j, json; "The input file is '.json' which contains an array of objects with 4 fields: 'citekey', 'tag', 'html' and 'plaintext'."
    b, build : String; "Build directory."

  ARGS:
    ...source : String; "The bibliography file. We only support one file for input. Should be '.bib' or '.json' according to flags."
]

def headerDataCmd := `[Cli|
  headerData VIA runHeaderDataCmd;
  "Produce `header-data.bmp`, this allows embedding of doc-gen declarations into other pages and more."

  FLAGS:
    b, build : String; "Build directory."
]

-- Prior versions of doc-gen4 generated HTML for one module at a time, directly from the olean, and
-- then ran an index command at the end to create the search index. Now, `fromDb` generates all HTML
-- and the search index in a single pass from the DB.
def fromDbCmd := `[Cli|
  fromDb VIA runFromDbCmd;
  "Generate HTML documentation from a SQLite database."

  FLAGS:
    b, build : String;        "Build directory (default: .lake/build)"
    m, manifest : String;     "Manifest output file, listing all generated HTML files."
    "prune-prefix" : String;  "Comma-separated list of module-name prefixes; rows under one of these prefixes that are not reachable from the given roots are deleted from the database."

  ARGS:
    db : String; "Path to the SQLite database"
    ...modules : String; "Optional: Module roots to generate docs for (computes transitive closure)"
]

def docGenCmd : Cmd := `[Cli|
  "doc-gen4" VIA runDocGenCmd; ["0.3.0"]
  "A documentation generator for Lean 4."

  SUBCOMMANDS:
    singleCmd;
    batchCmd;
    genCoreCmd;
    bibPrepassCmd;
    headerDataCmd;
    fromDbCmd
]

def main (args : List String) : IO UInt32 :=
  docGenCmd.validate args
