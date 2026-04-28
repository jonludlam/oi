[@@@ai_disclosure "ai-assisted"]
[@@@ai_model "claude-opus-4-7"]
[@@@ai_provider "Anthropic"]

let log_src = Logs.Src.create "oi.doc_execute"

module Log = (val Logs.src_log log_src : Logs.LOG)

type outcome =
  | Built of Doc_plan.node
  | Cached of Doc_plan.node
  | Cascaded of { node : Doc_plan.node; missing_dep : string }
  | Failed of { node : Doc_plan.node; error : string }

let pkg_of_outcome = function
  | Built n | Cached n -> n.pkg
  | Cascaded { node; _ } -> node.pkg
  | Failed { node; _ } -> node.pkg

let is_success = function
  | Built _ | Cached _ -> true
  | Cascaded _ | Failed _ -> false

(* A node can dispatch iff every layer it would mount has
   [Layer.succeeded] in the d10 cache. The mount inputs are: the
   package's build layer, [node.doc_dep_hashes], and the tool layer
   sets (driver + odoc). The tool layers are common across the run,
   so the caller is expected to have already ensured they exist —
   we still verify, defensively. *)
let first_missing ~d10 ~driver_layer_hashes ~odoc_layer_hashes
    (node : Doc_plan.node) =
  let candidates =
    node.build_hash
    :: (node.doc_dep_hashes @ driver_layer_hashes @ odoc_layer_hashes)
  in
  List.find_opt (fun h -> not (D10.Layer.succeeded d10 ~hash:h)) candidates

let run ~proc_mgr ~fs ~d10 ?toolchain ~dune_cache_root ~bin_paths
    ~context_layers ~driver_layer_hashes ~odoc_layer_hashes plan =
  let outcomes = ref [] in
  let push o = outcomes := o :: !outcomes in
  List.iter
    (fun (node : Doc_plan.node) ->
      if D10.Layer.succeeded d10 ~hash:node.hash then begin
        Log.debug (fun m -> m "doc-cached: %s [%s]"
          (OpamPackage.to_string node.pkg)
          (match node.kind with
           | Compile -> "compile" | Link -> "link" | Doc_all -> "doc-all"));
        push (Cached node)
      end
      else
        match
          first_missing ~d10 ~driver_layer_hashes ~odoc_layer_hashes node
        with
        | Some missing_dep ->
          Log.debug (fun m -> m "doc-cascade: %s [%s] (missing %s)"
            (OpamPackage.to_string node.pkg)
            (match node.kind with
             | Compile -> "compile" | Link -> "link" | Doc_all -> "doc-all")
            missing_dep);
          push (Cascaded { node; missing_dep })
        | None ->
          (try
            Doc_build.run ~proc_mgr ~fs ~d10 ?toolchain ~dune_cache_root
              ~bin_paths ~context_layers
              ~driver_layer_hashes ~odoc_layer_hashes node;
            push (Built node)
          with
          | exn ->
            let error = Printexc.to_string exn in
            Log.warn (fun m -> m "doc-fail %s: %s"
              (OpamPackage.to_string node.pkg) error);
            push (Failed { node; error })))
    (Doc_plan.nodes plan);
  List.rev !outcomes
