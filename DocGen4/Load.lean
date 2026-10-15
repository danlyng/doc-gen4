/-
Copyright (c) 2021 Henrik Böving. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Henrik Böving
-/
import DocGen4.Process

namespace DocGen4

open Lean System IO

def envOfImports (imports : Array Name) : IO Environment := do
  -- needed for modules which use syntax registered with `initialize add_parser_alias ..`
  unsafe Lean.enableInitializersExecution
  importModules (imports.map (Import.mk · false true false)) Options.empty (leakEnv := true) (loadExts := true)

/--
Load a list of modules from the current Lean search path into an `Environment`
to process for documentation.

When `parallel` is `true`, the per-constant analysis is fanned out across worker threads (see
`Process.processParallel`); this is used by the batch path that imports a whole library at once.
-/
def load (task : Process.AnalyzeTask) (parallel : Bool := false) : IO Process.AnalyzerResult := do
  initSearchPath (← findSysroot)
  let env ← envOfImports task.getLoad
  let config := {
    -- TODO: parameterize maxHeartbeats
    maxHeartbeats := 100000000,
    options :=
      Options.empty
        |>.setBool `pp.tagAppFns true
        |>.setBool `pp.funBinderTypes true
        |>.setBool `debug.skipKernelTC true
        |>.setBool `Elab.async false,
    -- TODO: Figure out whether this could cause some bugs
    fileName := default,
    fileMap := default,
  }

  let analyze := if parallel then Process.processParallel task else Process.process task
  Prod.fst <$> Meta.MetaM.toIO analyze config { env := env } {} {}

end DocGen4
