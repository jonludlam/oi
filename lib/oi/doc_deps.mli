(** Documentation-related dep helpers.

    Pure helpers that the solver and the upcoming doc DAG planner share:

    - {!get_extra_doc_deps} extracts the [x-extra-doc-deps] opam extension
      field, which lists packages whose docs should be in scope for cross-
      reference resolution but which aren't part of the runtime closure
      (e.g. [odoc-driver] declares [["sherlodoc"; "odig"]]).
    - {!needs_separate_link} asks whether a package's build-deps view differs
      from its doc-deps view; if so the doc DAG must emit separate compile and
      link layers for the package, because the two phases need different
      lower-layer mounts. *)

val get_extra_doc_deps : OpamFile.OPAM.t -> OpamPackage.Name.Set.t
(** [get_extra_doc_deps opam] returns the package names listed in the
    [x-extra-doc-deps] extension field, or the empty set if absent or
    malformed. Strings and option-wrapped strings are both accepted. *)

val needs_separate_link :
  build_deps:OpamPackage.Set.t OpamPackage.Map.t ->
  doc_deps:OpamPackage.Set.t OpamPackage.Map.t ->
  OpamPackage.t ->
  bool
(** [needs_separate_link ~build_deps ~doc_deps pkg] is [true] when [pkg]'s
    build-deps differ from its doc-deps — in which case its compile stage
    (using build-deps as lowers) and link stage (using doc-deps as lowers)
    cannot be combined into a single [doc_all] container run. *)
