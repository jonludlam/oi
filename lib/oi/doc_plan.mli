(** Doc DAG construction.

    Pure function from a {!Plan.graph} to a topologically-ordered list of
    doc-layer nodes. Three node kinds:

    - [Compile]: produces the package's [.odoc] files; lower-stack is the
      package's build-deps view.
    - [Link]: links + generates HTML; lower-stack is the package's doc-deps
      view (build-deps plus [{with-doc}] / [{post}] / [x-extra-doc-deps]).
    - [Doc_all]: combined fast path — when [Doc_deps.needs_separate_link]
      returns false for a package, its compile and link can run in a single
      container.

    Per package the planner emits either one [Doc_all] node, or one [Compile]
    plus one [Link]. Non-documentable packages get no node.

    Hashes are content-addressed and deterministic, derived from the build
    layer hash, the doc tools hash, and the dep doc-layer hashes. The
    [Doc_all] / [Compile] hash recipes share salt so a package whose own
    classification flips (split vs combined) gets a different hash and so
    re-builds. *)

type kind = Compile | Link | Doc_all

type node = {
  pkg : OpamPackage.t;
  kind : kind;
  hash : string;
      (** Content hash of this doc layer. *)
  build_hash : string;
      (** Package's underlying build-layer hash (from {!Plan.node.layer_hash}). *)
  doc_dep_hashes : string list;
      (** Hashes of the doc layers that must be mounted as lowers when this
          node runs. For [Compile] / [Doc_all]: build-deps' compile-side
          hashes. For [Link]: doc-deps' compile-side hashes (a superset of
          build-deps' for packages with [{with-doc}] / [x-extra-doc-deps]
          edges). Sorted, deduplicated. *)
}

type t

val build : tool_hash:string -> Plan.graph -> t
(** [build ~tool_hash plan] derives the doc DAG. [tool_hash] identifies the
    odoc + odoc-driver build (caller computes via {!Doc_tools}). *)

val nodes : t -> node list
(** Topologically ordered: every node appears after each of its deps. *)

val for_pkg : t -> OpamPackage.Name.t -> node list
(** [[]] for non-documentable packages, one [Doc_all] node, or two
    [Compile + Link] nodes. *)

val compile_side_for : t -> OpamPackage.Name.t -> node option
(** The node that other packages should mount as a lower when they reference
    this package's docs. For split packages → [Compile]; for combined →
    [Doc_all]; non-documentable → [None]. *)
