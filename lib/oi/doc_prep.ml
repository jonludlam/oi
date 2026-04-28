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

let scan_dir ?(skip_subdirs = []) ~extensions ~filenames base_dir =
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
            if Sys.is_directory full_path then begin
              if not (List.mem name skip_subdirs) then walk rel_path full_path
            end
            else if List.exists
                      (fun ext -> Filename.check_suffix name ext) extensions
                 || List.mem name filenames
            then result := rel_path :: !result
          with Sys_error _ -> ())
    with Sys_error _ -> ()
  in
  walk "" base_dir;
  List.sort String.compare !result

(* Compiler [lib/ocaml/] sub-directories that don't follow the
   one-cmti-per-libname layout odoc_driver_voodoo expects. We skip
   them when scanning a compiler package — Stdlib (which lives at the
   flat top-level of [lib/ocaml/] with [stdlib/META] pointing here)
   and the [stdlib/] META file itself are still found.

   Re-enabling these requires custom per-sub-lib handling
   (compiler-libs/META declares 4 sub-packages, all .cmti in one dir;
   threads/str/unix have their own quirks). Future work. *)
let compiler_lib_skip_subdirs =
  [ "compiler-libs"; "threads"; "str"; "unix"; "dynlink"
  ; "ocamldoc"; "runtime_events"; "profiling"; "caml"; "stublibs" ]

(* The "real compiler" packages whose build installs [lib/ocaml/] —
   stdlib lives under [lib/ocaml/stdlib.cmti] etc. Documenting these
   is what makes [Stdlib.List] cross-references resolve in downstream
   packages. Lifted from
   [day11/opam_build/compiler_pkg.ml:names], plus [relocatable-compiler]
   which is what oi's default toolchain pulls in.

   Wrappers like [ocaml-variants] and [ocaml-system] are NOT in this
   list — they install nothing of substance. *)
let compiler_pkg_names =
  [ "ocaml-compiler"
  ; "ocaml-base-compiler"
  ; "oxcaml-compiler"
  ; "relocatable-compiler" ]

let is_compiler_pkg pkg =
  List.mem (OpamPackage.Name.to_string (OpamPackage.name pkg))
    compiler_pkg_names

(* Lib subdirs to include in the scan. By default: [<libname>/...]
   where [<libname>] starts with the package name (canonical
   [lib/<pkg>/] plus multi-lib variants). For compiler packages,
   ALSO include [lib/ocaml/] — that's where stdlib lives. *)
let lib_subdirs ~pkg available =
  let pkg_name = OpamPackage.Name.to_string (OpamPackage.name pkg) in
  let prefix_match n =
    n = pkg_name
    || (String.length n > String.length pkg_name
        && String.sub n 0 (String.length pkg_name) = pkg_name
        && (let c = n.[String.length pkg_name] in
            c = '_' || c = '-' || c = '.'))
  in
  available
  |> List.filter (fun n ->
    prefix_match n
    || (is_compiler_pkg pkg && n = "ocaml"))

(* Scan from [<prefix>/lib/], picking subdirs per [lib_subdirs].
   Returned paths look like [<libname>/<file>] relative to
   [<prefix>/lib/], matching day11's prep recipe. *)
let scan_lib_root ~prefix ~pkg ~extensions ~filenames root_segment =
  let base = prefix / root_segment in
  if not (Sys.file_exists base && Sys.is_directory base) then []
  else
    let available = Sys.readdir base |> Array.to_list in
    lib_subdirs ~pkg available
    |> List.concat_map (fun libname ->
      let libdir = base / libname in
      let skip_subdirs =
        if is_compiler_pkg pkg && libname = "ocaml"
        then compiler_lib_skip_subdirs
        else []
      in
      scan_dir ~skip_subdirs ~extensions ~filenames libdir
      |> List.map (fun rel -> libname ^ "/" ^ rel))

let scan_libs ~prefix ~pkg =
  scan_lib_root ~prefix ~pkg ~extensions:lib_extensions
    ~filenames:lib_filenames "lib"

let scan_docs ~prefix ~pkg =
  scan_lib_root ~prefix ~pkg ~extensions:doc_extensions
    ~filenames:doc_filenames "doc"

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
  (* [installed_libs] entries are [<libname>/<rel>] relative to
     [<prefix>/lib/]. We mirror that structure into the prep tree so
     odoc_driver_voodoo finds files at
     [universes/<u>/<pkg>/<ver>/lib/<libname>/<rel>]. *)
  let lib_src = prefix / "lib" in
  List.iter (fun rel ->
    let src = lib_src / rel in
    let dst = lib_dest / rel in
    if Sys.file_exists src then begin
      mkdir_p (Filename.dirname dst);
      symlink ~target:src ~link:dst
    end
  ) installed_libs;
  Log.debug (fun m -> m "prep: %d lib files for %s" (List.length installed_libs) pkg_name);
  let doc_src = prefix / "doc" in
  List.iter (fun rel ->
    let src = doc_src / rel in
    let dst = doc_dest / rel in
    if Sys.file_exists src then begin
      mkdir_p (Filename.dirname dst);
      symlink ~target:src ~link:dst
    end
  ) installed_docs;
  Log.debug (fun m -> m "prep: %d doc files for %s" (List.length installed_docs) pkg_name)
