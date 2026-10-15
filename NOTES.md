# Notes

## Lake facets exposed by doc-gen4

The custom Lake facets are declared in `lakefile.lean`. The most important user-facing facet is `docs`, which generates the HTML documentation tree under `.lake/build/doc`.

### Source URI facets

These facets compute source links for packages, libraries, and modules.

| Facet | Scope | Output | Meaning |
| --- | --- | --- | --- |
| `srcUri.github` | package, library, module | `String` | GitHub source URI. |
| `srcUri.vscode` | package, library, module | `String` | Local `vscode://` source URI. |
| `srcUri.file` | package, library, module | `String` | Local `file://` source URI. |
| `srcUri` | package, library, module | `String` | Dispatches to one of the above according to `DOCGEN_SRC`. |

`DOCGEN_SRC` accepts:

- `github`, or unset: infer source links from the package's GitHub remote.
- `vscode`: generate links that open local files in VS Code.
- `file`: generate local file links.

### Documentation data facets

These facets populate `api-docs.db` and related marker files. They are useful when documentation data is needed without necessarily generating HTML.

| Facet | Scope | Output | Meaning |
| --- | --- | --- | --- |
| `docInfo` | module | `FilePath` | Populates database rows for one module and returns that module's marker file. |
| `docInfo` | library | `Array FilePath` | Collects `docInfo` marker files for every module in the library. |
| `docInfo` | package | `FilePath` | Populates the documentation database for all workspace libraries and core docs, then returns the database path. |
| `docInfoBatch` | library | `FilePath` | Analyzes all library modules in one process, using parallel workers, and returns a marker file. |

The module-level `docInfo` facet also recursively fetches `docInfo` for imported modules, so imported module documentation data is available before the current module is inserted.

Set `DOCGEN_BATCH=1` to select `docInfoBatch` for library and package `docs` builds. `DOCGEN_NUM_THREADS` overrides the detected worker count. Ordinary `docInfo` and module `docs` builds keep the per-module analyzer. Batch analysis rebuilds the entire library when one of its modules changes.

### HTML generation facets

These facets run HTML generation from the documentation database.

| Facet | Scope | Output | Meaning |
| --- | --- | --- | --- |
| `docs` | module | `Array FilePath` | Generates HTML for the module and its transitive imports. |
| `docs` | library | `Array FilePath` | Generates HTML for all root modules in the library. |
| `docs` | package | `Array FilePath` | Generates HTML for the package's default library targets. |
| `docsHeader` | library | `FilePath` | Generates declaration header index data after package docs have been built. |

Examples:

```sh
lake build MyLibrary:docs
lake build MyModule:docs
lake build my-package:docs
lake build MyLibrary:docInfo
lake build MyLibrary:docInfoBatch
```

The `docs` facets always include the core Lean documentation roots `Init`, `Std`, `Lake`, and `Lean` in addition to the requested module, library, or package roots.

Library and package `docs` builds pass prune prefixes to `fromDb`, which lets doc-gen4 remove stale database rows for modules that used to belong to the built library or package but are no longer reachable. Module `docs` builds do not prune, because a single module target does not own a stable namespace.

### Related Lake targets

These are Lake targets, not facets, but they support the facet pipeline:

| Target | Output | Meaning |
| --- | --- | --- |
| `bibPrepass` | `FilePath` | Preprocesses bibliography/reference data into `.lake/build/doc-data/references.json`. |
| `coreDocs` | `Array FilePath` | Populates documentation data for the core components `Init`, `Std`, `Lake`, and `Lean`. |
