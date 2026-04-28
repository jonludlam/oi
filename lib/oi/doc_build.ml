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
(* On failure, dump the full env + captured output to a debug file
   under [/tmp/oi-doc-debug/<pkg>-<pid>.log]. odoc_driver_voodoo can
   exit with code 1 silently when its env is wrong; without this dump
   the only signal upstream is "exited with code 1" with no body. *)
let dump_failure_log ~pkg ~cmd_s ~env ~output =
  let dir = "/tmp/oi-doc-debug" in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (EEXIST, _, _) -> ());
  let path = Filename.concat dir
    (Printf.sprintf "%s-%d.log"
       (String.map (fun c -> if c = '/' then '_' else c) pkg)
       (Unix.getpid ())) in
  let oc = open_out path in
  Printf.fprintf oc "CMD: %s\n\n" cmd_s;
  Printf.fprintf oc "ENV:\n";
  Array.iter (fun e -> Printf.fprintf oc "  %s\n" e) env;
  Printf.fprintf oc "\nOUTPUT (%d bytes):\n%s\n"
    (String.length output) output;
  close_out oc;
  path

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
    let path = dump_failure_log ~pkg ~cmd_s ~env ~output in
    Error.build_failed ~pkg ~cmd:cmd_s
      ~output:(Fmt.str "exited with code %d (full env+output: %s)\n\n%s"
                 n path output)
  | `Signaled n ->
    let path = dump_failure_log ~pkg ~cmd_s ~env ~output in
    Error.build_failed ~pkg ~cmd:cmd_s
      ~output:(Fmt.str "killed by signal %d (full env+output: %s)\n\n%s"
                 n path output)

let run ~proc_mgr ~fs ~d10 ?toolchain ~dune_cache_root ~bin_paths
    ~context_layers ~driver_layer_hashes ~odoc_layer_hashes
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
    (* Assemble the FULL project closure plus tools. odoc_driver_voodoo
       scans the prefix for every dep's [META] / [.cmt] / [.cmti], so a
       per-node prefix containing only [node.build_hash] +
       day11-style compile-layer mounts is too sparse — the tool exits
       1 silently with an empty switch. [context_layers] is what
       [Pipeline.build] returned for the project's solve. *)
    let layer_hashes =
      context_layers
      @ driver_layer_hashes
      @ odoc_layer_hashes
    in
    let prefix = D10.Prefix.assemble_cached d10 ~layer_hashes in
    let pkg_str = OpamPackage.to_string node.pkg in
    let pkg_name = OpamPackage.Name.to_string (OpamPackage.name node.pkg) in
    let _pkg_ver = OpamPackage.Version.to_string (OpamPackage.version node.pkg) in
    (* Build the [prep/] tree odoc_driver_voodoo hardcodes. The
       wrapper opens [./prep] from cwd and walks
       [prep/universes/<u>/<pkg>/<ver>/lib/...] for inputs; without
       that tree it exit_group(1)s silently. We construct the tree as
       symlinks back into the assembled prefix's [lib/<pkg>/] so no
       file copies are needed. The universe is per-package — same
       recipe day11 uses (hash of the build hash). *)
    let universe =
      Digest.string node.build_hash |> Digest.to_hex
      |> fun s -> String.sub s 0 12
    in
    (* Build cwd / prep tree OUTSIDE the assembled prefix so that
       [D10.Prefix.diff] doesn't capture them as part of the doc
       layer. Same for the [.odoc] / [.odocl] intermediates: keep
       them out of [<prefix>/odoc_docs/] so the captured layer is
       just the user-visible HTML.

       Cleaned up at end of run. *)
    let tmp_root = Filename.temp_dir "oi_doc_" "" in
    let prep_root = Filename.concat tmp_root "prep" in
    let installed_libs = Doc_prep.scan_libs ~prefix ~pkg:node.pkg in
    let installed_docs = Doc_prep.scan_docs ~prefix ~pkg:node.pkg in
    if installed_libs = [] then begin
      (* No findlib libs in [<prefix>/lib/<pkg>/] — likely the OCaml
         compiler itself or a CLI-only package. Same short-circuit
         day11's [prepare] does. We still record an empty layer so
         the cache key resolves and downstream cascade-skip works. *)
      Log.info (fun m -> m "doc-skip %s: no documentable libraries"
        (OpamPackage.to_string node.pkg));
      D10.Layer.store d10
        ~hash:node.hash
        ~prefix
        ~files:[]
        ~package:(OpamPackage.to_string node.pkg)
        ~deps:[]
        ~parent_hashes:layer_hashes
        ~exit_status:0
        ()
    end
    else begin
    Doc_prep.create ~prefix ~prep_root ~pkg:node.pkg ~universe
      ~installed_libs ~installed_docs;
    let html_dir = Filename.concat prefix "odoc_docs" in
    let odoc_dir = Filename.concat tmp_root "odoc" in
    let odocl_dir = Filename.concat tmp_root "odocl" in
    (* Pre-create the output dirs so the tool can find/create per-package
       subtrees beneath them. odoc_driver_voodoo treats [--odoc-dir] as
       required; placing it under [odoc_docs/] means the intermediate
       [.odoc] / [.odocl] files become part of the captured layer. *)
    List.iter
      (fun d ->
        try Unix.mkdir d 0o755
        with Unix.Unix_error (EEXIST, _, _) -> ())
      [ html_dir; odoc_dir; odocl_dir ];
    (* Construct env from THIS prefix, not the project's build_prefix.
       odoc_driver_voodoo reads OPAM_SWITCH_PREFIX / OCAMLPATH and
       walks the switch-shaped tree there; if these point at the
       project's build prefix while [cwd] / [--html-dir] are inside
       a different per-node prefix, the tool exits with code 1
       silently. *)
    let env =
      Solver.Env.make_env ?toolchain ~prefix ~dune_cache_root ()
    in
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
      ; "--blessed"
        (* Every package in oi's single-solution model is treated as
           blessed: HTML lands at [p/<pkg>/<ver>/...] in the layer
           rather than the universe-keyed [u/<universe>/...]. *)
      ; "-v"
      ]
    in
    (* cwd at [<tmp_root>/] — odoc_driver_voodoo opens [./prep]
       relative to cwd and finds the symlink tree we just built. *)
    let finally () =
      try
        let _ = Sys.command
          (Printf.sprintf "rm -rf %s" (Filename.quote tmp_root)) in
        ()
      with _ -> ()
    in
    Fun.protect ~finally (fun () ->
      spawn_and_capture ~proc_mgr ~fs ~env ~cwd:tmp_root
        ~pkg:pkg_str cmd);
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
  end
