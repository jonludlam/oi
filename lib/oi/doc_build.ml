[@@@ai_disclosure "ai-assisted"]
[@@@ai_model "claude-opus-4-7"]
[@@@ai_provider "Anthropic"]

let log_src = Logs.Src.create "oi.doc_build"

module Log = (val Logs.src_log log_src : Logs.LOG)

type bin_paths = {
  odoc : string;
  odoc_md : string;
  odoc_driver_voodoo : string;
  sherlodoc : string;
}

let actions_for_kind : Doc_plan.kind -> string = function
  | Compile -> "compile-only"
  | Link -> "link-and-gen"
  | Doc_all -> "all"

(* Spawn the doc tool, capture stdout+stderr, raise on non-zero exit.
   Mirrors the pattern in [Execute.run_cmd] but inlined so [Doc_build]
   doesn't depend on Execute internals. *)
let spawn_and_capture ~proc_mgr ~fs ~env ~cwd ~pkg cmd =
  let cmd_s = String.concat " " cmd in
  Log.debug (fun m -> m "doc_build %s: + %s" pkg cmd_s);
  Eio.Switch.run @@ fun sw ->
  let r, w = Eio.Process.pipe ~sw proc_mgr in
  let child =
    Eio.Process.spawn ~sw proc_mgr ~env
      ~cwd:Eio.Path.(fs / cwd)
      ~stdout:w ~stderr:w cmd
  in
  Eio.Flow.close w;
  let output =
    try Eio.Buf_read.(parse_exn take_all) r ~max_size:max_int
    with End_of_file -> ""
  in
  Eio.Flow.close r;
  match Eio.Process.await child with
  | `Exited 0 -> ()
  | `Exited n ->
    Error.build_failed ~pkg ~cmd:cmd_s
      ~output:(Fmt.str "exited with code %d\n\n%s" n output)
  | `Signaled n ->
    Error.build_failed ~pkg ~cmd:cmd_s
      ~output:(Fmt.str "killed by signal %d\n\n%s" n output)

let run ~proc_mgr ~fs ~d10 ~env ~bin_paths
    ~driver_layer_hashes ~odoc_layer_hashes
    (node : Doc_plan.node) =
  if D10.Layer.succeeded d10 ~hash:node.hash then begin
    Log.debug (fun m -> m "doc cache hit: %s/%s/%s"
      (OpamPackage.to_string node.pkg)
      (match node.kind with Compile -> "compile" | Link -> "link"
       | Doc_all -> "doc_all")
      node.hash);
    ()
  end else begin
    (* Assemble: build layer + dep doc layers + driver tools + odoc.
       Order matters for hardlink overlay semantics — last writer
       wins, so put the more-specific layers (this package's build,
       its dep doc layers) BEFORE the tool layers, since tool files
       in [bin/] / [lib/] should take precedence over the package's
       own copies of e.g. [odoc] if any. *)
    let layer_hashes =
      [ node.build_hash ]
      @ node.doc_dep_hashes
      @ driver_layer_hashes
      @ odoc_layer_hashes
    in
    let prefix = D10.Prefix.assemble_cached d10 ~layer_hashes in
    let pkg_str = OpamPackage.to_string node.pkg in
    let pkg_name = OpamPackage.Name.to_string (OpamPackage.name node.pkg) in
    let _pkg_ver = OpamPackage.Version.to_string (OpamPackage.version node.pkg) in
    let html_dir = Filename.concat prefix "odoc_docs" in
    let odoc_dir = Filename.concat prefix "odoc_docs/.odoc" in
    let odocl_dir = Filename.concat prefix "odoc_docs/.odocl" in
    (* Pre-create the output dirs so the tool can find/create per-package
       subtrees beneath them. odoc_driver_voodoo treats [--odoc-dir] as
       required; placing it under [odoc_docs/] means the intermediate
       [.odoc] / [.odocl] files become part of the captured layer. *)
    List.iter
      (fun d ->
        try Unix.mkdir d 0o755
        with Unix.Unix_error (EEXIST, _, _) -> ())
      [ html_dir; odoc_dir; odocl_dir ];
    let before = D10.Prefix.snapshot ~fs prefix in
    let cmd =
      [ bin_paths.odoc_driver_voodoo
      ; pkg_name
      ; "--html-dir"; html_dir
      ; "--odoc-dir"; odoc_dir
      ; "--odocl-dir"; odocl_dir
      ; "--actions"; actions_for_kind node.kind
      ; "--odoc"; bin_paths.odoc
      ; "--odoc-md"; bin_paths.odoc_md
      ; "-v"
      ]
    in
    spawn_and_capture ~proc_mgr ~fs ~env ~cwd:prefix ~pkg:pkg_str cmd;
    let files = D10.Prefix.diff ~fs ~prefix ~before |> List.map fst in
    let parent_hashes = layer_hashes in
    D10.Layer.store d10
      ~hash:node.hash
      ~prefix
      ~files
      ~package:pkg_str
      ~deps:[]  (* doc layers are leaves wrt opam-deps semantics *)
      ~parent_hashes
      ~exit_status:0
      ()
  end
