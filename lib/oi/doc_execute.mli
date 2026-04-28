(** Doc DAG executor.

    Walks a {!Doc_plan.t} in topological order and dispatches each
    node to {!Doc_build.run}. A node is cascade-skipped (not
    dispatched) when any of the layers it would need to mount is
    missing or failed in the d10 cache — i.e. its own build layer or
    one of its [doc_dep_hashes].

    Returns a per-node outcome list so callers can summarise / report
    progress. Layers from cascade-skipped nodes don't get added to
    the output assembly. *)

type outcome =
  | Built of Doc_plan.node
  | Cached of Doc_plan.node
  | Cascaded of { node : Doc_plan.node; missing_dep : string }
  | Failed of { node : Doc_plan.node; error : string }

val run :
  proc_mgr:_ Eio.Process.mgr ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  d10:D10.Config.t ->
  env:string array ->
  bin_paths:Doc_build.bin_paths ->
  driver_layer_hashes:string list ->
  odoc_layer_hashes:string list ->
  Doc_plan.t ->
  outcome list

val pkg_of_outcome : outcome -> OpamPackage.t
val is_success : outcome -> bool
