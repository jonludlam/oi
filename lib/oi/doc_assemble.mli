(** Reflink-merge a set of doc layers into a target directory.

    Layers from [Doc_execute] outcomes are content-addressed in the
    d10 cache. This module hardlinks (which the kernel turns into a
    reflink on btrfs/xfs/apfs/zfs and a same-inode hardlink elsewhere)
    every layer's content into [<dst>/], so the user gets an editable
    HTML tree without copying actual file bytes.

    Per-package files live under [odoc_docs/p/<pkg>/<ver>/...] with no
    cross-layer collisions; shared support files at [odoc_docs/<file>]
    are written from each contributing layer (typically byte-identical
    output from [odoc-driver-voodoo]). The merge order is the
    [Doc_execute] outcome order; layer-stacking semantics (later
    overwrites earlier) keep the result deterministic. *)

val assemble :
  d10:D10.Config.t ->
  outcomes:Doc_execute.outcome list ->
  dst:Eio.Fs.dir_ty Eio.Path.t ->
  unit
(** [assemble ~d10 ~outcomes ~dst] reflink-merges every [Built] /
    [Cached] [Link] or [Doc_all] outcome into [dst]. [Compile] outcomes
    contribute only [.odoc] intermediates so they're skipped — they're
    inputs to link, not parts of the final HTML tree. Cascade-skipped
    and failed outcomes are skipped. *)
