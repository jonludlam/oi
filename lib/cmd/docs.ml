[@@@ai_disclosure "ai-assisted"]
[@@@ai_model "claude-opus-4-7"]
[@@@ai_provider "Anthropic"]

open Cmdliner

let log_src = Logs.Src.create "oi.cmd.docs"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( / ) = Filename.concat

(* v1: hardcoded paths to the locally-installed odoc-driver toolchain.
   [Doc_tools.resolve] will replace this with a proper two-compiler
   solve+build (driver compiler for [odoc-driver], project compiler
   for [odoc]) — see TODO at the bottom. *)
let hardcoded_bin_paths : Oi.Doc_build.bin_paths =
  let home = try Unix.getenv "HOME" with Not_found -> "/home/jjl25" in
  let bin n = home / ".opam" / "default" / "bin" / n in
  {
    odoc = bin "odoc";
    odoc_md = bin "odoc-md";
    odoc_driver_voodoo = bin "odoc_driver_voodoo";
    sherlodoc = bin "sherlodoc";
  }

(* Placeholder until Doc_tools resolves the actual layer set. With
   empty lists the cascade-skip in Doc_execute will only fire on the
   project's own build/doc deps, which is exactly what we want for a
   first end-to-end test. *)
let placeholder_tool_hash = "manual-bin-paths"

let do_docs ?refresh ~proc_mgr ~fs ~clock ~sys ~platform ~os_key ~cache
    ~data_dir ~cwd () =
  Oi.Pipeline.init_opam_root ~fs ~data_dir;
  ignore (Oi.Source.Reporepo.ensure_base ~fs ~sys ~data_dir ?refresh ());
  let project = Oi.Project.load ~fs cwd in
  let deps = project.deps in
  if deps = [] then
    Oi.Error.config_error
      "No .opam files found in %s — run [oi docs] inside a project." cwd;
  let conf =
    Oi.Pipeline.make_conf ~platform ~ocaml_version:Workspace.ocaml_version
  in
  let toolchain =
    Oi.Pipeline.resolve_toolchain ~fs ~sys ~data_dir ~conf ~install:true
      ~override:None ~handles:project.overlays ()
  in
  let conf, _ = Oi.Pipeline.toolchain_views toolchain conf in
  let names = List.map OpamPackage.Name.of_string deps in
  let names =
    Oi.Pipeline.drop_override_compiler_roots ~override:None ~toolchain names
  in
  let constraints = OpamPackage.Name.Map.empty in
  Fmt.pr "Building project deps...@.";
  let _layer_hashes =
    Oi.Pipeline.build ~sys ~proc_mgr ~fs ~clock ~cache ~data_dir ~conf ~os_key
      ~pins:project.pins ~constraints ?refresh ?toolchain names
  in
  (* Re-solve to obtain the solved package list (Pipeline.build doesn't
     expose the graph). The solve cache turns this into a hit. *)
  let cache_root = Oi.Cache.root_s cache in
  let prefix =
    let p = cache_root / "build" / "prefix" in
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / p);
    p
  in
  let packages_dirs =
    match toolchain with
    | Some (info : Oi.Toolchain.info) -> info.packages_dirs
    | None -> []
  in
  let _, tc_ctx = Oi.Pipeline.toolchain_views toolchain conf in
  let ctx =
    Oi.Solver.Ctx.create ~prefix ~packages_dirs ~conf ?toolchain:tc_ctx ()
  in
  let pkgs =
    match
      Oi.Solver.solve ~fs ~cache_root ctx ~packages_dirs ~constraints names
    with
    | Ok pkgs -> pkgs
    | Error msg -> Oi.Error.config_error "Solver: %s" msg
  in
  let d10 =
    Oi.Pipeline.make_d10 ~sys ~fs ~clock ~cache ~os_key
  in
  let plan_graph = Oi.Plan.build ctx ~d10 ~packages_dirs pkgs in
  let doc_plan =
    Oi.Doc_plan.build ~tool_hash:placeholder_tool_hash plan_graph
  in
  let n_doc_nodes = List.length (Oi.Doc_plan.nodes doc_plan) in
  Fmt.pr "Doc DAG: %d node(s)@." n_doc_nodes;
  if n_doc_nodes = 0 then begin
    Fmt.pr "No documentable packages — done.@.";
    ()
  end
  else begin
    let dune_cache_root = data_dir / "dune-cache" in
    let env =
      Oi.Solver.Env.make_env ?toolchain:tc_ctx ~prefix ~dune_cache_root ()
    in
    let outcomes =
      Oi.Doc_execute.run ~proc_mgr ~fs ~d10 ~env
        ~bin_paths:hardcoded_bin_paths
        ~driver_layer_hashes:[] ~odoc_layer_hashes:[]
        doc_plan
    in
    let n_built = List.length (List.filter (function
      | Oi.Doc_execute.Built _ -> true | _ -> false) outcomes) in
    let n_cached = List.length (List.filter (function
      | Oi.Doc_execute.Cached _ -> true | _ -> false) outcomes) in
    let n_failed = List.length (List.filter (function
      | Oi.Doc_execute.Failed _ -> true | _ -> false) outcomes) in
    let n_cascade = List.length (List.filter (function
      | Oi.Doc_execute.Cascaded _ -> true | _ -> false) outcomes) in
    Fmt.pr "Built %d, cached %d, failed %d, cascaded %d@."
      n_built n_cached n_failed n_cascade;
    let dst_str = cwd / "_oi" / "docs" in
    Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / dst_str);
    Oi.Doc_assemble.assemble ~d10 ~outcomes ~dst:Eio.Path.(fs / dst_str);
    Fmt.pr "Assembled to %s@." dst_str
  end

let cmd =
  let run () data_dir cache_dir refresh =
    Harness.run @@ fun env ->
    let { Harness.proc_mgr; fs; clock; sys; platform; os_key; cache } =
      Harness.bootstrap env cache_dir
    in
    let cwd, _ = Workspace.resolved_cwd fs in
    do_docs ~refresh ~proc_mgr ~fs ~clock ~sys ~platform ~os_key ~cache
      ~data_dir ~cwd ()
  in
  let info =
    Cmd.info "docs"
      ~doc:"Generate odoc HTML for the project's deps into _oi/docs/"
      ~man:[
        `S Manpage.s_description;
        `P "Build documentation for every documentable package in the \
            project's dep closure. Each package's HTML is captured as \
            its own content-addressed doc layer, then reflink-merged \
            into [_oi/docs/].";
        `P "v1: uses [odoc] / [odoc_driver_voodoo] from the host opam \
            switch (under \\$HOME/.opam/default/bin/). A future revision \
            will solve+build the doc tools internally so the command \
            becomes self-contained.";
      ]
  in
  Cmd.v info
    Term.(const run $ Terms.log $ Terms.data_dir
          $ Terms.cache_dir $ Terms.refresh)
