import Lake
open System Lake DSL

package «doc-gen4»

lean_lib DocGen4

@[default_target]
lean_exe «doc-gen4» {
  root := `Main
  supportInterpreter := true
}

require MD4Lean from git
  "https://github.com/acmepjz/md4lean" @ "main"

require BibtexQuery from git
  "https://github.com/dupuisf/BibtexQuery" @ "master"

require «UnicodeBasic» from git
  "https://github.com/fgdorais/lean4-unicode-basic" @ "main"

require Cli from git
  "https://github.com/leanprover/lean4-cli" @ "main"

require leansqlite from git
  -- Pin the pre-4.29 API used by this Lean 4.28 backport.
  "https://github.com/leanprover/leansqlite" @ "2765af4d645eb7a482f6555ac4e5cf9fb69e1ab1"

/--
Obtains the subdirectory of the Lean package relative to the root of the enclosing git repository.
-/
def getGitSubDirectory (directory : System.FilePath := "." ) : IO System.FilePath := do
  let out ← IO.Process.output {
    cmd := "git",
    args := #["rev-parse", "--show-prefix"],
    cwd := directory
  }
  if out.exitCode != 0 then
    let explanation := "Failed to execute git rev-parse --show-prefix"
    let err := s!"git exited with code {out.exitCode} while looking for the git subdirectory in {directory}"
    throw <| IO.userError <| explanation ++ "\n" ++ err
  let subdir := out.stdout.trimAsciiEnd
  -- e.g. if the Lean package is under a directory "myleanpackage",
  -- `git rev-parse --show-prefix` would return "myleanpackage/".
  -- We drop the trailing path separator.
  return if subdir == "".toSlice then "." else subdir.dropEnd 1 |>.copy

/--
Obtains the GitHub URL of a project by parsing the origin remote.
-/
def getGitRemoteUrl (directory : System.FilePath := "." ) (remote : String := "origin") : IO String := do
  let out ← IO.Process.output {
    cmd := "git",
    args := #["remote", "get-url", remote],
    cwd := directory
  }
  if out.exitCode != 0 then
    let explanation := "Failed to find a git remote in your project, consider reading: https://github.com/leanprover/doc-gen4#source-locations"
    let err := s!"git exited with code {out.exitCode} while looking for the git remote in {directory}"
    throw <| IO.userError <| explanation ++ "\n" ++ err
  return out.stdout.trimAsciiEnd.copy

/--
Obtains the Git commit hash of the project that is currently getting analyzed.
-/
def getProjectCommit (directory : System.FilePath := "." ) : IO String := do
  let out ← IO.Process.output {
    cmd := "git",
    args := #["rev-parse", "HEAD"]
    cwd := directory
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| s!"git exited with code {out.exitCode} while looking for the current commit in {directory}"
  return out.stdout.trimAsciiEnd.copy

def filteredPath (path : FilePath) : List String := path.components.filter (· != ".")

/--
Turns a Github git remote URL into an HTTPS Github URL.
Three link types from git supported:
- https://github.com/org/repo
- https://github.com/org/repo.git
- git@github.com:org/repo.git
-/
def getGithubBaseUrl (url : String) : Option String :=
  if url.startsWith "git@github.com:" && url.endsWith ".git" then
    let url := url.drop "git@github.com:".length
    let url := url.dropEnd ".git".length
    .some s!"https://github.com/{url}"
  else if url.startsWith "https://github.com/" then
    if url.endsWith ".git" then
      .some <| url.dropEnd ".git".length |>.copy
    else
      .some url
  else
    .none

inductive UriSource
  | github
  | vscode
  | file

def UriSource.parse : IO UriSource := do
  match ← IO.getEnv "DOCGEN_SRC" with
  | .none | .some "github" | .some "" => pure .github
  | "vscode" => pure .vscode
  | "file" => pure .file
  | _ => error "$DOCGEN_SRC should be github, file, or vscode."

/-! Note that all URIs can use `/` even when the system path separator is `\`. -/


/-- The GitHub URI of the source code of the package. -/
package_facet srcUri.github (pkg) : String := Job.async do
  let url ← getGitRemoteUrl pkg.dir "origin"
  let .some baseUrl := getGithubBaseUrl url
      | error <|
        s!"Could not interpret Git remote uri {url} as a Github source repo.\n"
          ++ "See README on source URIs for more details."
  let commit ← getProjectCommit pkg.dir
  logInfo s!"Found git remote for {pkg.baseName} at {baseUrl} @ {commit}"
  let subdir ← getGitSubDirectory pkg.dir
  return "/".intercalate <| baseUrl :: "blob" :: commit :: filteredPath (subdir / pkg.config.srcDir)

/-- The `vscode://` URI of the source code of the package. -/
package_facet srcUri.vscode (pkg) : String := .pure <$> do
  let dir ← IO.FS.realPath (pkg.dir / pkg.config.srcDir)
  return s!"vscode://file/{dir}"

/-- The `file://` URI of the source code of the package. -/
package_facet srcUri.file (pkg) : String := .pure <$> do
  let dir ← IO.FS.realPath (pkg.dir / pkg.config.srcDir)
  return s!"file://{dir}"

/-- The URI of the source code of the package, respecting `DOCGEN_SRC`. -/
package_facet srcUri (pkg) : String := do
  match ← UriSource.parse with
  | .github => fetch <| pkg.facet `srcUri.github
  | .vscode => fetch <| pkg.facet `srcUri.vscode
  | .file => fetch <| pkg.facet `srcUri.file


private def makeLibSrcUriFacet (lib : LeanLib) (which : Lean.Name)
    [FamilyDef FacetOut (Package.facetKind ++ which) String] :
    FetchM (Job String) := do
  let pkgUri ← fetch <| lib.pkg.facet which
  pkgUri.mapM (sync := true) fun pkgUri => do
    return "/".intercalate (pkgUri :: filteredPath lib.config.srcDir)

/-- The github URI of the source code of the library. -/
library_facet srcUri.github (lib) : String := makeLibSrcUriFacet lib `srcUri.github
/-- The `vscode://` URI of the source code of the library. -/
library_facet srcUri.vscode (lib) : String := makeLibSrcUriFacet lib `srcUri.vscode
/-- The `file://` URI of the source code of the library. -/
library_facet srcUri.file (lib) : String := makeLibSrcUriFacet lib `srcUri.file
/-- The URI of the source code of the library, respecting `DOCGEN_SRC`. -/
library_facet srcUri (lib) : String := makeLibSrcUriFacet lib `srcUri

private def makeModuleSrcUriFacet (mod : Module) (which : Lean.Name)
    [FamilyDef FacetOut (LeanLib.facetKind ++ which) String] :
    FetchM (Job String) := do
  let libUri ← fetch <| mod.lib.facet which
  libUri.mapM (sync := true) fun libUri => do
    return mod.name.components.foldl (init := libUri) (·.push '/' ++ ·.toString (escape := False)) ++ ".lean"

/-- The GitHub URI of the source code of the module. -/
module_facet srcUri.github (mod) : String := makeModuleSrcUriFacet mod `srcUri.github
/-- The `vscode://` URI of the source code of the module. -/
module_facet srcUri.vscode (mod) : String := makeModuleSrcUriFacet mod `srcUri.vscode
/-- The `file://` URI of the source code of the module. -/
module_facet srcUri.file (mod) : String := makeModuleSrcUriFacet mod `srcUri.file
/-- The URI of the source code of the module, respecting `DOCGEN_SRC`. -/
module_facet srcUri (mod) : String := makeModuleSrcUriFacet mod `srcUri

target bibPrepass : FilePath := do
  let exeJob ← «doc-gen4».fetch
  let buildDir := (← getRootPackage).buildDir
  let dataPath := buildDir / "doc-data"
  let inputJsonFile := (← getRootPackage).srcDir / "docs" / "references.json"
  let inputBibFile := (← getRootPackage).srcDir / "docs" / "references.bib"
  let outputFile := dataPath / "references.json"
  let tryJson : JobM (Array String) := do
    addTrace <| ← computeTrace inputJsonFile
    addTrace <| BuildTrace.ofHash (.ofString "json")
    return #["--build", buildDir.toString, "--json", inputJsonFile.toString]
  let tryBib : JobM (Array String) := do
    addTrace <| ← computeTrace inputBibFile
    addTrace <| BuildTrace.ofHash (.ofString "bib")
    return #["--build", buildDir.toString, inputBibFile.toString]
  let tryBibFailed : JobM (Array String) := do
    addTrace .nil
    return #["--build", buildDir.toString, "--none"]
  exeJob.mapM fun exeFile => do
    let args ← tryJson <|> tryBib <|> tryBibFailed
    buildFileUnlessUpToDate' outputFile do
      proc {
        cmd := exeFile.toString
        args := #["bibPrepass"] ++ args
        env := ← getAugmentedEnv
      }
    return outputFile

def coreTarget (component : Lean.Name) : FetchM (Job FilePath) := do
  let exeJob ← «doc-gen4».fetch
  let bibPrepassJob ← bibPrepass.fetch
  let buildDir := (← getRootPackage).buildDir
  -- Building the core targets adds their information to the database file. While it would be
  -- possible to hash just the relevant content of the database (e.g. using SQLite's SHA3 module)
  -- and write the result to a file, this adds a significant overhead. Instead, we write a timestamp
  -- to a marker file so its content hash propagates actual rebuilds to downstream targets.
  let markerFile := buildDir / "doc-data" / s!"core-{component}.doc"
  bibPrepassJob.bindM fun _ => do
    exeJob.mapM fun exeFile => do
      buildFileUnlessUpToDate' markerFile do
        proc {
          cmd := exeFile.toString
          args := #["genCore", "--build", buildDir.toString, component.toString, "api-docs.db"]
          env := ← getAugmentedEnv
        }
        createParentDirs markerFile
        -- See the note on the equivalent write in `module_facet docInfo` below: writing a fresh
        -- timestamp (rather than an empty string) makes the marker's content hash change on every
        -- actual rebuild, so downstream `docs` targets re-run instead of being replayed.
        IO.FS.writeFile markerFile (toString (← IO.monoNanosNow))
      return markerFile

/--
Populates the database with documentation data for core Lean. Returns a set of marker files that
indicate that the database has been updated for the corresponding modules, allowing Lake to track
changes and dependencies.
-/
target coreDocs : Array FilePath := do
  let coreComponents := #[`Init, `Std, `Lake, `Lean]
  return ← (Job.collectArray <| ← coreComponents.mapM coreTarget).mapM fun deps =>
    return deps

/--
Places the module's documentation content into the package's documentation database.

Returns a marker file that indicates the database has been populated for this module.
The marker file participates in Lake's dependency tracking, allowing for incremental updates.
-/
module_facet docInfo (mod) : FilePath := do
  let exeJob ← «doc-gen4».fetch
  let bibPrepassJob ← bibPrepass.fetch
  let coreJob ← coreDocs.fetch
  let modJob ← mod.leanArts.fetch
  -- Build all documentation for imported modules
  let imports ← (← mod.imports.fetch).await
  let depDocJobs := Job.mixArray <| ← imports.mapM fun mod => fetch <| mod.facet `docInfo
  let buildDir := (← getRootPackage).buildDir
  -- Building the documentation info for the module adds or updates the relevant content in the
  -- database. If the dependencies change, then this needs to be re-done. While it would be possible
  -- to hash just the relevant content of the database (e.g. using SQLite's SHA3 module) and write
  -- the result to a file, this adds a significant overhead. Instead, we write a timestamp to a marker
  -- file so its content hash propagates actual rebuilds to downstream targets.
  let markerFile := buildDir / "doc-data" / s!"{mod.name}.doc"
  coreJob.bindM fun _ => do
    depDocJobs.bindM fun _ => do
      bibPrepassJob.bindM fun _ => do
        exeJob.bindM fun exeFile => do
          modJob.mapM fun _ => do
            buildFileUnlessUpToDate' markerFile do
              let uriJob ← fetch <| mod.facet `srcUri
              let srcUri ← uriJob.await
              proc {
                cmd := exeFile.toString
                args := #["single", "--build", buildDir.toString, mod.name.toString, "api-docs.db", srcUri]
                env := ← getAugmentedEnv
              }
              createParentDirs markerFile
              -- Write a timestamp instead of an empty string so that downstream targets (e.g. the
              -- per-library/-package `docs` facet) see a fresh content hash whenever this action
              -- actually runs. With an empty marker, Lake propagates the unchanged content hash to
              -- downstream targets and they're replayed instead of rebuilt, which means `fromDb`
              -- never re-runs when a module's source changes — and stale rows are never pruned.
              IO.FS.writeFile markerFile (toString (← IO.monoNanosNow))
            return markerFile

/--
Populates the database with information for all modules in a library.
-/
library_facet docInfo (lib) : Array FilePath := do
  let mods ← (← lib.modules.fetch).await
  pure <| Job.collectArray <| ← mods.mapM (fetch <| ·.facet `docInfo)

/--
Like `docInfo`, but populates the database for the *entire* library in a single `doc-gen4 batch`
process: the library's transitive closure is imported once and all of its modules are analyzed in
parallel. This is much faster for from-scratch builds than the per-module `docInfo` facet (which
re-imports the closure once per module), at the cost of coarser incrementality — editing any module
re-analyzes the whole library. Opt in by setting `DOCGEN_BATCH=1` (see the `docs` facets).

Returns a single marker file recording that the database was populated for this library.
-/
library_facet docInfoBatch (lib) : FilePath := do
  let exeJob ← «doc-gen4».fetch
  let bibPrepassJob ← bibPrepass.fetch
  let coreJob ← coreDocs.fetch
  let mods ← (← lib.modules.fetch).await
  -- All of the library's oleans must exist before we import the closure.
  let artsJob := Job.mixArray <| ← mods.mapM (·.leanArts.fetch)
  let libUriJob ← fetch <| lib.facet `srcUri
  let buildDir := (← getRootPackage).buildDir
  let markerFile := buildDir / "doc-data" / s!"{lib.name}--library.docInfoBatch.doc"
  let modulesFile := buildDir / "doc-data" / s!"{lib.name}--library.modules.txt"
  coreJob.bindM fun _ => do
    artsJob.bindM fun _ => do
      bibPrepassJob.bindM fun _ => do
        libUriJob.bindM fun libUri => do
          exeJob.mapM fun exeFile => do
            buildFileUnlessUpToDate' markerFile do
              createParentDirs modulesFile
              IO.FS.writeFile modulesFile (String.intercalate "\n" (mods.toList.map (·.name.toString)))
              proc {
                cmd := exeFile.toString
                args := #["batch", "--build", buildDir.toString, "api-docs.db", libUri, modulesFile.toString]
                env := ← getAugmentedEnv
              }
              createParentDirs markerFile
              -- Timestamp (not empty) so downstream `fromDb` re-runs whenever analysis re-runs; see
              -- the note on the per-module `docInfo` marker write.
              IO.FS.writeFile markerFile (toString (← IO.monoNanosNow))
            return markerFile

/--
A facet to collect docInfo dependencies for a package (no HTML generation).
This populates the database with all module data and core docs for all packages
in the workspace (including dependencies).
Returns the database file path.
-/
package_facet docInfo (pkg) : FilePath := do
  let ws ← getWorkspace
  let allLibs := ws.packages.flatMap (·.leanLibs)
  let libDocJobs := Job.collectArray <| ← allLibs.mapM (fetch <| ·.facet `docInfo)
  let coreJobs ← coreDocs.fetch
  let dbPath := pkg.buildDir / "api-docs.db"
  coreJobs.bindM fun _ => do
    libDocJobs.mapM fun _ =>
      return dbPath

library_facet docsHeader (lib) : FilePath := do
  -- Depend on the package docs facet to ensure HTML is generated first
  let pkgDocsJob ← fetch <| lib.pkg.facet `docs
  let exeJob ← «doc-gen4».fetch
  -- Shared with DocGen4.Output
  let buildDir := (← getRootPackage).buildDir
  let basePath := buildDir / "doc"
  let dataFile := basePath / "declarations" / "header-data.bmp"
  let markerFile := buildDir / "doc-data" / s!"{lib.name}--library.docsHeader_built"
  exeJob.bindM fun exeFile => do
    pkgDocsJob.mapM fun _ => do
      buildFileUnlessUpToDate' markerFile do
        logInfo "Documentation header indexing"
        proc {
          cmd := exeFile.toString
          args := #["headerData", "--build", buildDir.toString]
        }
        createParentDirs markerFile
        IO.FS.writeFile markerFile ""
      return dataFile


/--
Generate HTML documentation for the given root modules.
Fetches docInfo for all roots, ensures core docs are built, then runs a single `fromDb` process.
Returns an array of all generated file paths.

If `prunePrefixes` is non-empty, `fromDb` is told that rows in `api-docs.db` whose module name has
one of those prefixes "belong" to this build. Any such row not reachable from the configured roots
is treated as stale (e.g. its source file was deleted) and is removed from the database. Use `#[]`
to leave the database untouched.
-/
def generateHtmlDocs {α} (markerName : String) (rootMods : Array Module)
    (prunePrefixes : Array Lean.Name) (description : String)
    (analysisJob : Job α) : FetchM (Job (Array FilePath)) := do
  let exeJob ← «doc-gen4».fetch
  let bibPrepassJob ← bibPrepass.fetch
  let coreJob ← coreDocs.fetch
  let buildDir := (← getRootPackage).buildDir
  let basePath := buildDir / "doc"
  let dbPath := buildDir / "api-docs.db"
  let dataFile := basePath / "declarations" / "declaration-data.bmp"
  let markerFile := buildDir / "doc-data" / s!"{markerName}.docs_built"
  let pruneArgs : Array String :=
    if prunePrefixes.isEmpty then #[]
    else #["--prune-prefix", ",".intercalate (prunePrefixes.toList.map (·.toString))]
  let staticFiles := #[
    basePath / "style.css",
    basePath / "favicon.svg",
    basePath / "declaration-data.js",
    basePath / "color-scheme.js",
    basePath / "nav.js",
    basePath / "jump-src.js",
    basePath / "expand-nav.js",
    basePath / "how-about.js",
    basePath / "search.js",
    basePath / "mathjax-config.js",
    basePath / "instances.js",
    basePath / "importedBy.js",
    basePath / "index.html",
    basePath / "404.html",
    basePath / "navbar.html",
    basePath / "search.html",
    basePath / "foundational_types.html",
    basePath / "references.html",
    basePath / "references.bib",
    basePath / "tactics.html",
    basePath / "find" / "index.html",
    basePath / "find" / "find.js"
  ]
  let coreRoots := #[`Init, `Std, `Lake, `Lean]
  let rootNames := rootMods.map (·.name) ++ coreRoots
  let manifestFile := buildDir / "doc-manifest.json"
  coreJob.bindM fun _ => do
    analysisJob.bindM fun _ => do
      bibPrepassJob.bindM fun _ => do
        exeJob.mapM fun exeFile => do
          buildFileUnlessUpToDate' markerFile do
            logInfo description
            proc {
              cmd := exeFile.toString
              args := #["fromDb", "--build", buildDir.toString, "--manifest", manifestFile.toString]
                ++ pruneArgs
                ++ #[dbPath.toString]
                ++ rootNames.map (·.toString)
              env := ← getAugmentedEnv
            }
            createParentDirs markerFile
            IO.FS.writeFile markerFile ""
          let traces ← staticFiles.mapM computeTrace
          addTrace <| mixTraceArray traces
          -- We read the manifest to determine which HTML files were generated because we only
          -- pass root module names to fromDb, which computes the transitive closure internally.
          -- This avoids passing potentially thousands of module names on the command line.
          match Lean.Json.parse <| ← IO.FS.readFile manifestFile with
          | .error _ => return #[dataFile] ++ staticFiles
          | .ok manifestData =>
            match Lean.fromJson? manifestData with
            | .error _ => return #[dataFile] ++ staticFiles
            | .ok (manifestDeps : Array System.FilePath) =>
              return #[dataFile] ++ staticFiles ++ manifestDeps.map (buildDir / ·)

-- Core component names; doubles as a prefix list for pruning toolchain-removed core modules from
-- the database whenever a `library`/`package` docs build runs.
private def coreDocPrefixes : Array Lean.Name := #[`Init, `Std, `Lake, `Lean]

/-- Whether to use the single-process batch analyzer (`DOCGEN_BATCH=1`) instead of the per-module
`docInfo` facet. Batch is much faster for from-scratch builds but re-analyzes a whole library when
any of its modules change. -/
private def useBatchAnalysis : FetchM Bool := return (← IO.getEnv "DOCGEN_BATCH").isSome

/-- Generate HTML for this module and its transitive imports. -/
module_facet docs (mod) : Array FilePath := do
  -- A single-module target doesn't own a stable namespace, so we don't prune.
  -- Single-module builds always use the per-module analyzer (there is no library to batch).
  let analysisJob := Job.collectArray <| ← #[mod].mapM (fetch <| ·.facet `docInfo)
  generateHtmlDocs s!"{mod.name}--module" #[mod] #[]
    s!"Generating documentation for {mod.name} and dependencies" analysisJob

/-- Generate HTML for all modules in this library. -/
library_facet docs (lib) : Array FilePath := do
  let rootMods := lib.rootModules
  let prunePrefixes := #[lib.name] ++ coreDocPrefixes
  let desc := s!"Generating documentation for {lib.name} ({rootMods.size} root modules)"
  if ← useBatchAnalysis then
    let analysisJob ← fetch <| lib.facet `docInfoBatch
    generateHtmlDocs s!"{lib.name}--library" rootMods prunePrefixes desc analysisJob
  else
    let analysisJob := Job.collectArray <| ← rootMods.mapM (fetch <| ·.facet `docInfo)
    generateHtmlDocs s!"{lib.name}--library" rootMods prunePrefixes desc analysisJob

/--
Generates documentation for the package's default library targets. Runs a single HTML generation
process for all root modules across all default libraries.
-/
package_facet docs (pkg) : Array FilePath := do
  let defaultTargets := pkg.defaultTargets
  let libs := pkg.leanLibs.filter fun lib => defaultTargets.contains lib.name
  let rootMods := libs.flatMap (·.rootModules)
  let prunePrefixes := libs.map (·.name) ++ coreDocPrefixes
  let desc := s!"Generating documentation for {pkg.baseName} ({rootMods.size} root modules)"
  if ← useBatchAnalysis then
    let analysisJob := Job.collectArray <| ← libs.mapM (fetch <| ·.facet `docInfoBatch)
    generateHtmlDocs s!"{pkg.baseName}--package" rootMods prunePrefixes desc analysisJob
  else
    let analysisJob := Job.collectArray <| ← rootMods.mapM (fetch <| ·.facet `docInfo)
    generateHtmlDocs s!"{pkg.baseName}--package" rootMods prunePrefixes desc analysisJob
