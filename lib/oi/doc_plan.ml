type kind = Compile | Link | Doc_all

type node = {
  pkg : OpamPackage.t;
  kind : kind;
  hash : string;
  build_hash : string;
  doc_dep_hashes : string list;
}

type t = {
  topo : node list;
  by_pkg : (OpamPackage.Name.t, node list) Hashtbl.t;
  compile_side : (OpamPackage.Name.t, node) Hashtbl.t;
}

(* Hash recipe lifted from [day11/layer/hash.ml]: NUL-joined parts, MD5,
   hex-encoded. The strings inside [parts] follow the day11 convention so a
   doc layer keyed by the same inputs gets the same hash, even though
   typical caches won't actually share because oi's [build_hash] (input #3)
   is computed by [D10.Layer.hash] rather than day11's per-package recipe. *)
let hash_of_strings parts =
  Digest.string (String.concat "\000" parts) |> Digest.to_hex

(* Documentability admission: lifted from day11's [is_ocaml_package] —
   either the package IS the OCaml compiler, or its build-deps reference the
   [ocaml] virtual. CLI-only packages (e.g. [conf-*], pure system bindings)
   that depend on the compiler purely to {b build} but install no findlib
   libraries pass this filter; the runtime [has_documentable_libs] check
   weeds them out at dispatch time, after their build layer is on disk. *)
let compiler_names =
  List.map OpamPackage.Name.of_string
    [ "ocaml-base-compiler"; "ocaml-variants"; "ocaml-system" ]

let is_compiler_pkg pkg =
  List.exists
    (fun n -> OpamPackage.Name.equal n (OpamPackage.name pkg))
    compiler_names

let ocaml_name = OpamPackage.Name.of_string "ocaml"

let is_documentable (node : Plan.node) =
  is_compiler_pkg node.pkg
  || List.exists (OpamPackage.Name.equal ocaml_name) node.deps

let needs_split (node : Plan.node) =
  let to_set xs =
    List.fold_left (fun s n -> OpamPackage.Name.Set.add n s)
      OpamPackage.Name.Set.empty xs
  in
  not (OpamPackage.Name.Set.equal (to_set node.deps) (to_set node.doc_deps))

(* For each name in [dep_names] that's documentable, look up its
   compile-side hash. The list is sorted+deduped so the resulting hash is
   stable under reordering. *)
let dep_hashes ~compile_side dep_names =
  let seen = Hashtbl.create 16 in
  let acc = ref [] in
  List.iter
    (fun n ->
      match Hashtbl.find_opt compile_side n with
      | None -> ()
      | Some node ->
          if not (Hashtbl.mem seen node.hash) then begin
            Hashtbl.add seen node.hash ();
            acc := node.hash :: !acc
          end)
    dep_names;
  List.sort String.compare !acc

let build ~tool_hash plan =
  let by_pkg : (OpamPackage.Name.t, node list) Hashtbl.t =
    Hashtbl.create 64
  in
  let compile_side : (OpamPackage.Name.t, node) Hashtbl.t =
    Hashtbl.create 64
  in
  let topo = ref [] in
  List.iter
    (fun pkg_node ->
      if is_documentable pkg_node then begin
        let { Plan.pkg; layer_hash = build_hash; deps; doc_deps; _ } =
          pkg_node
        in
        let pkg_name = OpamPackage.name pkg in
        if needs_split pkg_node then begin
          let compile_dep_hashes =
            dep_hashes ~compile_side deps
          in
          let compile_hash =
            hash_of_strings
              ([ "compile"; "v3"; build_hash; tool_hash ]
              @ compile_dep_hashes)
          in
          let compile_node =
            { pkg; kind = Compile; hash = compile_hash; build_hash;
              doc_dep_hashes = compile_dep_hashes }
          in
          let link_dep_hashes =
            dep_hashes ~compile_side doc_deps
          in
          let link_hash =
            hash_of_strings
              ([ "link"; "v2"; compile_hash; tool_hash ]
              @ link_dep_hashes)
          in
          (* link_dep_hashes already covers doc-deps' compile-side
             layers; the package's OWN compile layer must also be
             mounted so the linker can find its own .odoc files. *)
          let link_node =
            { pkg; kind = Link; hash = link_hash; build_hash;
              doc_dep_hashes = compile_hash :: link_dep_hashes }
          in
          Hashtbl.replace compile_side pkg_name compile_node;
          Hashtbl.replace by_pkg pkg_name [ compile_node; link_node ];
          topo := link_node :: compile_node :: !topo
        end
        else begin
          let dep_hashes = dep_hashes ~compile_side deps in
          let hash =
            hash_of_strings
              ([ "doc-all"; "v3"; build_hash; tool_hash ] @ dep_hashes)
          in
          let n =
            { pkg; kind = Doc_all; hash; build_hash;
              doc_dep_hashes = dep_hashes }
          in
          Hashtbl.replace compile_side pkg_name n;
          Hashtbl.replace by_pkg pkg_name [ n ];
          topo := n :: !topo
        end
      end)
    (Plan.nodes plan);
  { topo = List.rev !topo; by_pkg; compile_side }

let nodes t = t.topo

let for_pkg t name =
  match Hashtbl.find_opt t.by_pkg name with
  | Some xs -> xs
  | None -> []

let compile_side_for t name = Hashtbl.find_opt t.compile_side name
