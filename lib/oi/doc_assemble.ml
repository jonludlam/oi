[@@@ai_disclosure "ai-assisted"]
[@@@ai_model "claude-opus-4-7"]
[@@@ai_provider "Anthropic"]

let log_src = Logs.Src.create "oi.doc_assemble"

module Log = (val Logs.src_log log_src : Logs.LOG)

let assemble ~d10 ~(outcomes : Doc_execute.outcome list) ~dst =
  (* Pick out only the layers that contribute to the final HTML tree:
     [Built] / [Cached] [Link] or [Doc_all] outcomes. [Compile]
     outcomes are intermediate (.odoc files for downstream link
     stages) and don't belong in the assembled docs. *)
  let layer_hashes =
    List.filter_map
      (fun (o : Doc_execute.outcome) ->
        match o with
        | Built n | Cached n
          when n.kind <> Doc_plan.Compile -> Some n.hash
        | _ -> None)
      outcomes
  in
  Log.info (fun m -> m "Assembling %d doc layers into %a"
    (List.length layer_hashes) Eio.Path.pp dst);
  D10.Prefix.assemble d10 ~layer_hashes ~dst
