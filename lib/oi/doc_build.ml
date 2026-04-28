(* Stub: the .mli is authoritative for the planned interface; the
   implementation lands in a follow-up commit once Doc_tools resolves
   the bin paths and we can exercise it end-to-end. *)

type bin_paths = {
  odoc : string;
  odoc_md : string;
  odoc_driver_voodoo : string;
  sherlodoc : string;
}

let run ~proc_mgr:_ ~fs:_ ~clock:_ ~sys:_ ~d10:_ ~bin_paths:_
    ~driver_layer_hashes:_ ~odoc_layer_hashes:_ (_ : Doc_plan.node) =
  failwith "Doc_build.run: not implemented yet"
