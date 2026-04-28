[@@@ai_disclosure "ai-assisted"]
[@@@ai_model "claude-opus-4-7"]
[@@@ai_provider "Anthropic"]

let log_src = Logs.Src.create "oi.doc_prep"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( / ) = Filename.concat

let lib_extensions =
  [ ".cmi"; ".cmti"; ".cmt"; ".cma"; ".cmxa"; ".cmx"; ".ml"; ".mli" ]

let lib_filenames = [ "META"; "dune-package" ]

let doc_extensions = [ ".mld" ]

let doc_filenames = [ "odoc-config.sexp" ]

let scan_dir ~extensions ~filenames base_dir =
  let result = ref [] in
  let rec walk prefix dir =
    try
      if Sys.file_exists dir && Sys.is_directory dir then
        Sys.readdir dir |> Array.iter (fun name ->
          let full_path = dir / name in
          let rel_path =
            if prefix = "" then name else prefix ^ "/" ^ name
          in
          try
            if Sys.is_directory full_path then walk rel_path full_path
            else if List.exists
                      (fun ext -> Filename.check_suffix name ext) extensions
                 || List.mem name filenames
            then result := rel_path :: !result
          with Sys_error _ -> ())
    with Sys_error _ -> ()
  in
  walk "" base_dir;
  List.sort String.compare !result

let scan_libs ~prefix ~pkg =
  let pkg_name = OpamPackage.Name.to_string (OpamPackage.name pkg) in
  scan_dir ~extensions:lib_extensions ~filenames:lib_filenames
    (prefix / "lib" / pkg_name)

let scan_docs ~prefix ~pkg =
  let pkg_name = OpamPackage.Name.to_string (OpamPackage.name pkg) in
  scan_dir ~extensions:doc_extensions ~filenames:doc_filenames
    (prefix / "doc" / pkg_name)

let rec mkdir_p path =
  try Unix.mkdir path 0o755
  with Unix.Unix_error (EEXIST, _, _) -> ()
     | Unix.Unix_error (ENOENT, _, _) ->
       (* parent missing; recurse *)
       let parent = Filename.dirname path in
       if parent <> path then begin
         mkdir_p parent;
         try Unix.mkdir path 0o755
         with Unix.Unix_error (EEXIST, _, _) -> ()
       end

let symlink ~target ~link =
  try Unix.symlink target link
  with Unix.Unix_error (EEXIST, _, _) ->
    Unix.unlink link;
    Unix.symlink target link

let create ~prefix ~prep_root ~pkg ~universe
    ~installed_libs ~installed_docs =
  let pkg_name = OpamPackage.Name.to_string (OpamPackage.name pkg) in
  let pkg_version = OpamPackage.Version.to_string (OpamPackage.version pkg) in
  let pkg_prep =
    prep_root / "universes" / universe / pkg_name / pkg_version
  in
  let lib_dest = pkg_prep / "lib" in
  let doc_dest = pkg_prep / "doc" in
  mkdir_p lib_dest;
  mkdir_p doc_dest;
  (* Top-level subdirs of <prefix>/lib/<pkg>/ — the structure
     odoc_driver_voodoo expects beneath
     [universes/<u>/<pkg>/<ver>/lib/<libname>/]. We symlink each
     [<prefix>/lib/<pkg>/<libname>] tree by walking files; the
     directories get created on demand. *)
  let lib_src = prefix / "lib" / pkg_name in
  List.iter (fun rel ->
    let src = lib_src / rel in
    let dst = lib_dest / rel in
    if Sys.file_exists src then begin
      mkdir_p (Filename.dirname dst);
      symlink ~target:src ~link:dst
    end
  ) installed_libs;
  Log.debug (fun m -> m "prep: %d lib files for %s" (List.length installed_libs) pkg_name);
  (* Same for doc files. day11 copies these (small in count); we
     symlink for symmetry — the [.mld] files are just text. *)
  let doc_src = prefix / "doc" / pkg_name in
  List.iter (fun rel ->
    let src = doc_src / rel in
    let dst = doc_dest / rel in
    if Sys.file_exists src then begin
      mkdir_p (Filename.dirname dst);
      symlink ~target:src ~link:dst
    end
  ) installed_docs;
  Log.debug (fun m -> m "prep: %d doc files for %s" (List.length installed_docs) pkg_name)
