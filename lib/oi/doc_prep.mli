(** Construct the [prep/] tree that [odoc_driver_voodoo] hardcodes.

    The "voodoo" wrapper opens [prep/] from cwd and walks
    [prep/universes/<universe>/<pkg-name>/<version>/lib/<libname>/...]
    to find the [.cmti] / [.cmt] inputs it should compile and the
    [META] / [dune-package] metadata. Without that tree the tool
    [exit_group(1)]s silently before opening anything else.

    Day11's approach (in [day11/doc/prep.ml]) is to bind-mount each
    library subdir from a built layer into the prep tree inside a
    container. We don't have containers here; symlinks do the
    same job on the host filesystem.

    Inputs match {!Day11_opam_layer.Installed_files.scan_libs} —
    relative paths under [<prefix>/lib/<pkg>/] with the file
    extensions [odoc] cares about ([.cmi], [.cmti], [.cmt], [.cma],
    [.cmxa], [.ml], [.mli]) plus filenames [META] and [dune-package].

    Caller cleans up [prep_root] when done. *)

val create :
  prefix:string ->
  prep_root:string ->
  pkg:OpamPackage.t ->
  universe:string ->
  installed_libs:string list ->
  installed_docs:string list ->
  unit
(** [create ~prefix ~prep_root ~pkg ~universe ~installed_libs
    ~installed_docs] builds [<prep_root>/universes/<universe>/<pkg>/<ver>/]
    populated with symlinks back into [<prefix>/lib/] and
    [<prefix>/doc/].

    [installed_libs] is a list of relative paths under [<prefix>/lib/]
    such that the package owns those files. Top-level subdirs of that
    set become the lib symlinks in prep. [installed_docs] is the same
    for [<prefix>/doc/]; doc files are typically few and small, so we
    copy them directly rather than per-file symlinking. *)

val scan_libs : prefix:string -> pkg:OpamPackage.t -> string list
(** [scan_libs ~prefix ~pkg] walks [<prefix>/lib/<pkg-name>/] and
    returns relative paths matching the doc-relevant extensions.
    Mirrors {!Day11_opam_layer.Installed_files.scan_libs} but operates
    on a flat opam-style prefix rather than a layer's [fs/]. *)

val scan_docs : prefix:string -> pkg:OpamPackage.t -> string list
(** Same as {!scan_libs} but for [<prefix>/doc/<pkg-name>/], filtered
    to [.mld] files and [odoc-config.sexp]. *)
