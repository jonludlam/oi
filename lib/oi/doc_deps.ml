(** Lifted from [day11/doc/doc_deps.ml] and the helper at the top of
    [day11/solver/solve.ml]. Pure functions; no I/O. *)

let get_extra_doc_deps opamfile =
  let open OpamParserTypes.FullPos in
  let extensions = OpamFile.OPAM.extensions opamfile in
  match OpamStd.String.Map.find_opt "x-extra-doc-deps" extensions with
  | None -> OpamPackage.Name.Set.empty
  | Some value ->
    let extract_name (item : OpamParserTypes.FullPos.value) =
      match item.pelem with
      | String name -> Some name
      | Option (inner, _) ->
        (match inner.pelem with
         | String name -> Some name
         | _ -> None)
      | _ -> None
    in
    let extract_names acc v =
      match v.pelem with
      | List { pelem = items; _ } ->
        List.fold_left (fun acc item ->
          match extract_name item with
          | Some name ->
            OpamPackage.Name.Set.add
              (OpamPackage.Name.of_string name) acc
          | None -> acc) acc items
      | _ -> acc
    in
    extract_names OpamPackage.Name.Set.empty value

let needs_separate_link ~build_deps ~doc_deps pkg =
  let lookup map =
    match OpamPackage.Map.find_opt pkg map with
    | Some s -> s
    | None -> OpamPackage.Set.empty
  in
  let compile_set = lookup build_deps in
  let link_set = lookup doc_deps in
  not (OpamPackage.Set.equal compile_set link_set)
