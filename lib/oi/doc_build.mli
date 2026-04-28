(** Per-doc-node primitive: assemble a prefix, run odoc-driver-voodoo
    against it, capture the new files as a content-addressed doc layer
    in the d10 cache.

    Independent of {!Execute}: callers supply already-resolved tool bin
    paths and let this module orchestrate prefix assembly + spawn +
    capture. The doc DAG executor ({!Doc_execute}) walks
    {!Doc_plan.t} in topological order and dispatches each node here.

    {1 Layer contents}

    A doc layer's [fs/] contains exactly the files
    [Prefix.diff] reports as new after [odoc-driver-voodoo] runs. With
    [--html-dir] pointed at [<prefix>/odoc_docs/], that's:

    - [<prefix>/odoc_docs/p/<pkg-name>/<version>/...] — the package's
      HTML, layered into a [p/<pkg>/<version>] tree so multiple
      packages' layers union without collision.
    - [<prefix>/odoc_docs/<top-level support files>] — CSS, search JS,
      landing-page chrome. These overlap across packages; assembly
      treats them first-wins so the per-package layers can be
      reflink-merged into a single [<dst>/odoc_docs/] tree. *)

type bin_paths = {
  odoc : string;
      (** Absolute path to the [odoc] binary built against the
          {b project's} compiler. *)
  odoc_md : string;
      (** Absolute path to [odoc-md], built against the
          {b driver compiler} (needs eio, so OCaml >= 5.x). *)
  odoc_driver_voodoo : string;
      (** Absolute path to [odoc-driver-voodoo], also from the driver. *)
  sherlodoc : string;
      (** Absolute path to [sherlodoc], also from the driver. *)
}
(** Pre-resolved tool binary paths. The driver tools live inside the
    "driver tool" layer set; [odoc] lives in its own layer (matched to
    the project compiler). {!Doc_tools.resolve} produces this record. *)

val run :
  proc_mgr:_ Eio.Process.mgr ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:D10.Config.clk ->
  sys:D10.Sysops.t ->
  d10:D10.Config.t ->
  bin_paths:bin_paths ->
  driver_layer_hashes:string list ->
  odoc_layer_hashes:string list ->
  Doc_plan.node ->
  unit
(** [run … node] builds a single doc layer.

    {2 Steps}

    + Compute the layer-hash list to assemble: [node.build_hash] +
      [node.doc_dep_hashes] + [driver_layer_hashes] + [odoc_layer_hashes].
    + [D10.Prefix.assemble_cached] hardlinks all those layers into a
      fresh prefix [<dst>].
    + [D10.Prefix.snapshot] before the doc tool runs.
    + Spawn [odoc-driver-voodoo <node.pkg's name>
            --html-dir <dst>/odoc_docs
            --actions <compile-only | link-and-gen | all>  (* per node.kind *)
            --odoc <bin_paths.odoc>
            --odoc-md <bin_paths.odoc_md>
            -j $(nproc) -v]
      with cwd [<dst>] and [<dst>/bin] prepended to PATH.
    + [D10.Prefix.diff] yields the new files relative to the snapshot.
    + [D10.Layer.store ~hash:node.hash ~prefix:<dst> ~files ...] commits
      them as a layer.

    {2 Caching}

    Short-circuits at step 1 when [D10.Layer.succeeded d10 ~hash:node.hash]
    — the layer is already on disk and a no-op.

    {2 Failure}

    A non-zero exit from [odoc-driver-voodoo] raises with the captured
    log. Cascade-level handling (skip this node when an upstream doc
    layer is missing or failed) lives in {!Doc_execute}. *)
