(** Per-doc-node primitive: assemble a prefix, run odoc-driver-voodoo
    against it, capture the new files as a content-addressed doc layer
    in the d10 cache.

    Independent of {!Execute}: callers supply already-resolved tool bin
    paths plus the env vars needed for the doc tools to find the
    package's installed artifacts in the prefix. The doc DAG executor
    ({!Doc_execute}) walks {!Doc_plan.t} in topological order and
    dispatches each node here.

    {1 Layer contents}

    A doc layer's [fs/] contains exactly the files [Prefix.diff]
    reports as new after [odoc-driver-voodoo] runs. With [--html-dir]
    pointed at [<prefix>/odoc_docs/], that's:

    - [<prefix>/odoc_docs/p/<pkg-name>/<version>/...] — the package's
      HTML, layered into a [p/<pkg>/<version>] tree so multiple
      packages' layers union without collision.
    - [<prefix>/odoc_docs/<top-level support files>] — CSS, search JS,
      landing-page chrome. These overlap across packages; assembly
      treats them first-wins so the per-package layers can be
      reflink-merged into a single [<dst>/odoc_docs/] tree. *)

type bin_paths = {
  odoc : string;
  odoc_md : string;
  odoc_driver_voodoo : string;
  sherlodoc : string;
}
(** Pre-resolved tool binary paths. The driver tools live inside the
    "driver tool" layer set; [odoc] lives in its own layer (matched to
    the project compiler). {!Doc_tools.resolve} produces this record. *)

val run :
  proc_mgr:_ Eio.Process.mgr ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  d10:D10.Config.t ->
  env:string array ->
  bin_paths:bin_paths ->
  driver_layer_hashes:string list ->
  odoc_layer_hashes:string list ->
  Doc_plan.node ->
  unit
(** [run … node] builds a single doc layer (cache hit short-circuits).

    Steps:
    + If [D10.Layer.succeeded d10 ~hash:node.hash] — no-op.
    + Otherwise: compose the layer-hash list to assemble — the
      package's build layer, [node.doc_dep_hashes], and both tool
      layer sets — and call [D10.Prefix.assemble_cached] to materialise
      a working prefix.
    + Snapshot the prefix, spawn [odoc-driver-voodoo] with [--html-dir
      <prefix>/odoc_docs] and [--actions] derived from [node.kind].
    + Diff yields the new files; [D10.Layer.store] commits them at
      [node.hash].

    Raises on non-zero exit from the doc tool. Cascade-skip on
    upstream failures lives in {!Doc_execute}. *)
