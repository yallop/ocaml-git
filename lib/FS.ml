(*
 * Copyright (c) 2013-2015 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix
open Misc.OP
open Printf

let fail fmt = Printf.ksprintf failwith ("Git.FS." ^^ fmt)

let err_not_found n k = fail "%s: %s not found" n k

module LogMake = Log.Make

module Log = LogMake(struct let section = "fs" end)

module type IO = sig
  val getcwd: unit -> string Lwt.t
  val realpath: string -> string Lwt.t
  val mkdir: string -> unit Lwt.t
  val remove: string -> unit Lwt.t
  val file_exists: string -> bool Lwt.t
  val directories: string -> string list Lwt.t
  val files: string -> string list Lwt.t
  val rec_files: string -> string list Lwt.t
  val read_file: string -> Cstruct.t Lwt.t
  val write_file: string -> ?temp_dir:string -> Cstruct.t -> unit Lwt.t
  val chmod: string -> int -> unit Lwt.t
  val stat_info: string -> Index.stat_info
end

module type S = sig
  include Store.S
  val remove: t -> unit Lwt.t
  val create_file: t -> string -> Tree.perm -> Blob.t -> unit Lwt.t
  val entry_of_file: t -> Index.t ->
    string -> Tree.perm -> SHA.Blob.t -> Blob.t -> Index.entry option Lwt.t
  val clear: unit -> unit
end

module Make (IO: IO) (D: SHA.DIGEST) (I: Inflate.S) = struct

  module Value_IO = Value.IO(D)(I)
  module Pack_IO = Pack.IO(D)(I)
  module SHA_IO = SHA.IO(D)
  module Packed_value_IO = Packed_value.IO(D)(I)
  module Pack_index = Pack_index.Make(D)
  module Packed_refs_IO = Packed_refs.IO(D)

  module File_cache : sig
    val read : string -> Cstruct.t Lwt.t
    val clear: unit -> unit
  end = struct

    (* Search key and value stored in the weak table.
       The path is used to find the file.
       When searching, file is a dummy empty value.
       This value should be alive as long as the file
       is alive, to ensure that, a finaliser is attached
       to the file referencing its key to maintain it alive.
       Notice that the key don't maintain the file alive to
       avoid making both values always reachable.
    *)
    type key =
      { path : string;
        file : Cstruct.t Weak.t }

    module WeakTbl = Weak.Make(struct
        type t = key
        let hash t = Hashtbl.hash t.path
        let equal t1 t2 = t1.path = t2.path
      end)

    let cache = WeakTbl.create 10
    let clear () = WeakTbl.clear cache
    let dummy = Weak.create 0 (* only used to create a search key *)

    let find path =
      try
        let search_key = { path; file = dummy } in
        let cached_value = WeakTbl.find cache search_key in
        match Weak.get cached_value.file 0 with
        | None -> WeakTbl.remove cache cached_value; None
        | Some f -> Some f
      with Not_found -> None

    let add path file =
      let w = Weak.create 1 in
      Weak.set w 0 (Some file);
      let v = { path; file = w } in
      Gc.finalise (fun _ -> Weak.set v.file 0 None) file;
      (* Maintain v alive while file is alive by forcing v to be
         present in the function closure. The effect is useless, but
         it ensures that the compiler won't optimise the refence to
         v away. This is guaranteed to work as long as the compiler
         don't have a deep knowledge of Weak.set behaviour.
         Maybe some kind of "ignore" external function would be better.
      *)
      WeakTbl.add cache v

    let read file =
      match find file with
      | Some v -> Lwt.return v
      | None ->
        IO.read_file file >>= fun cs ->
        add file cs;
        Lwt.return cs

  end

  type t = { root: string; dot_git: string; level: int; }

  let root t = t.root
  let dot_git t = t.dot_git
  let level t = t.level

  let temp_dir t = t.dot_git / "tmp"

  let create ?root ?dot_git ?(level=6) () =
    if level < 0 || level > 9 then
      fail "create: level should be between 0 and 9";
    begin match root with
      | None   -> IO.getcwd ()
      | Some r ->
        IO.mkdir r >>= fun () ->
        IO.realpath r
    end >>= fun root' ->
    let dot_git = match dot_git with
      | None    -> root' / ".git"
      | Some s -> s
    in
    Lwt.return { root = root'; level; dot_git }

  let remove t =
    Log.info "remove %s" t.dot_git;
    IO.remove t.dot_git

  (* Loose objects *)
  module Loose = struct

    module Log = LogMake(struct let section = "fs-loose" end)

    let file t sha1 =
      let hex = SHA.to_hex sha1 in
      let prefix = String.sub hex 0 2 in
      let suffix = String.sub hex 2 (String.length hex - 2) in
      t.dot_git / "objects" / prefix / suffix

    let mem t sha1 =
      IO.file_exists (file t sha1)

    let ambiguous sha1 = raise (SHA.Ambiguous (SHA.pretty sha1))

    let get_file t sha1 =
      IO.directories (t.dot_git / "objects") >>= fun dirs ->
      let hex = SHA.to_hex sha1 in
      let len = String.length hex in
      let dcands =
        if len <= 2 then
          List.filter
            (fun d ->
               (String.sub (Filename.basename d) 0 len) = hex
            ) dirs
        else
          List.filter (fun d -> Filename.basename d = String.sub hex 0 2) dirs
      in
      match dcands with
      | []      -> Lwt.return_none
      | _::_::_ -> ambiguous sha1
      | [dir] ->
        Log.debug "get_file: %s" dir;
        IO.files dir >>= fun files ->
        let fcands =
          if len <= 2 then files
          else
            let len' = len - 2 in
            let suffix = String.sub hex 2 len' in
            List.filter
              (fun f -> String.sub (Filename.basename f) 0 len' = suffix)
              files
        in
        match fcands with
        | []     -> Lwt.return_none
        | [file] -> Lwt.return (Some file)
        | _      -> ambiguous sha1


    let some x = Lwt.return (Some x)

    let value_of_file file =
      File_cache.read file >>= fun buf ->
      Mstruct.of_cstruct buf
      |> Value_IO.input
      |> some

    let inflated_of_file file =
      File_cache.read file >>= fun buf ->
      match I.inflate (Mstruct.of_cstruct buf) with
      | None   -> fail "%s is not a valid compressed file." file;
      | Some s -> some (Mstruct.to_string s)

    let read_aux name read_file t sha1 =
      Log.debug "%s %a" name SHA.output sha1;
      if SHA_IO.is_short sha1 then (
        Log.debug "read: short sha1";
        get_file t sha1 >>= function
        | Some file -> read_file file
        | None      -> Lwt.return_none
      ) else (
        let file = file t sha1 in
        IO.file_exists file >>= function
        | false -> Lwt.return_none
        | true  -> read_file file
      )
    let read  = read_aux "read" value_of_file
    let read_inflated = read_aux "read_inflated" inflated_of_file

    let write_inflated t inflated =
      let sha1 = D.string inflated in
      let file = file t sha1 in
      IO.file_exists file >>= function
      | true  -> Log.debug "write: file %s already exists!" file; Lwt.return sha1
      | false ->
        let level = t.level in
        let deflated = I.deflate ~level (Cstruct.of_string inflated) in
        let temp_dir = temp_dir t in
        IO.write_file file ~temp_dir deflated >>= fun () ->
        Lwt.return sha1

    let write t value =
      Log.debug "write";
      let inflated =
        Misc.with_buffer (fun buf -> Value_IO.add_inflated buf value)
      in
      write_inflated t inflated

    let list t =
      Log.debug "Loose.list %s" t.dot_git;
      let objects = t.dot_git / "objects" in
      IO.directories objects >>= fun objects ->
      let objects = List.map Filename.basename objects in
      let objects = List.filter (fun s -> (s <> "info") && (s <> "pack")) objects in
      Lwt_list.map_s (fun prefix ->
          let dir = t.dot_git / "objects" / prefix in
          IO.files dir >>= fun suffixes ->
          let suffixes = List.map Filename.basename suffixes in
          let objects = List.map (fun suffix ->
              SHA_IO.of_hex (prefix ^ suffix)
            ) suffixes in
          Lwt.return objects
        ) objects
      >>= fun files ->
      Lwt.return (List.concat files)

  end

  module Packed = struct

    module Log = LogMake(struct let section = "fs-packed" end)

    let file t sha1 =
      let pack_dir = t.dot_git / "objects" / "pack" in
      let pack_file = "pack-" ^ (SHA.to_hex sha1) ^ ".pack" in
      pack_dir / pack_file

    let list t =
      Log.debug "list %s" t.dot_git;
      let packs = t.dot_git / "objects" / "pack" in
      IO.files packs >>= fun packs ->
      let packs = List.map Filename.basename packs in
      let packs = List.filter (fun f -> Filename.check_suffix f ".idx") packs in
      let packs = List.map (fun f ->
          let p = Filename.chop_suffix f ".idx" in
          let p = String.sub p 5 (String.length p - 5) in
          SHA_IO.of_hex p
        ) packs in
      Lwt.return packs

    let index t sha1 =
      let pack_dir = t.dot_git / "objects" / "pack" in
      let idx_file = "pack-" ^ (SHA.to_hex sha1) ^ ".idx" in
      pack_dir / idx_file

    let index_lru = LRU.make 8
    let keys_lru = LRU.make (128 * 1024)

    let clear () =
      LRU.clear index_lru;
      LRU.clear keys_lru

    let read_pack_index t sha1 =
      Log.debug "read_pack_index %a" SHA.output sha1;
      match LRU.find index_lru sha1 with
      | Some i -> Log.debug "read_pack_index cache hit!"; Lwt.return i
      | None ->
        let file = index t sha1 in
        IO.file_exists file >>= function
        | true ->
          File_cache.read file >>= fun buf ->
          let index = Pack_index.input (Cstruct.to_bigarray buf) in
          LRU.add index_lru sha1 index;
          Lwt.return index
        | false -> fail "read_pack_index: %s does not exist" file

    let write_pack_index t sha1 idx =
      let file = index t sha1 in
      IO.file_exists file >>= function
      | true  -> Lwt.return_unit
      | false ->
        let buf = Buffer.create 1024 in
        Pack_index.Raw.add buf idx;
        let temp_dir = temp_dir t in
        let buf = Cstruct.of_string (Buffer.contents buf) in
        IO.write_file file ~temp_dir buf

    let read_keys t sha1 =
      Log.debug "read_keys %a" SHA.output sha1;
      match LRU.find keys_lru sha1 with
      | Some ks -> Lwt.return ks
      | None    ->
        Log.debug "read_keys: cache miss!";
        read_pack_index t sha1 >>= fun index ->
        let keys = Pack_index.keys index |> SHA.Set.of_list in
        LRU.add keys_lru sha1 keys;
        Lwt.return keys

    let write_pack t sha1 pack =
      Log.debug "write pack";
      let file = file t sha1 in
      IO.file_exists file >>= function
      | true  -> Lwt.return_unit
      | false ->
        let pack = Pack.Raw.buffer pack in
        let temp_dir = temp_dir t in
        IO.write_file file ~temp_dir pack

    let mem_in_pack t pack_sha1 sha1 =
      Log.debug "mem_in_pack %a:%a" SHA.output pack_sha1 SHA.output sha1;
      read_pack_index t pack_sha1 >>= fun idx ->
      Lwt.return (Pack_index.mem idx sha1)

    let read_in_pack name pack_read ~read t pack_sha1 sha1 =
      Log.debug "read_in_pack(%s) %a:%a" name
        SHA.output pack_sha1 SHA.output sha1;
      read_pack_index t pack_sha1 >>= fun i ->
      let index = Pack_index.find_offset i in
      match index sha1 with
      | None   ->
        Log.debug "read_in_pack: not found"; Lwt.return_none
      | Some _ ->
        let file = file t pack_sha1 in
        IO.file_exists file >>= function
        | true ->
          File_cache.read file >>= fun buf ->
          pack_read ~index ~read (Mstruct.of_cstruct buf) sha1
        | false ->
          fail "read_in_pack: cannot read the pack object %s" (SHA.to_hex pack_sha1)

    let read_aux read_in_pack ~read t sha1 =
      list t >>= fun packs ->
      Lwt_list.fold_left_s (fun acc pack ->
          match acc with
          | Some v -> Lwt.return (Some v)
          | None   -> read_in_pack ~read t pack sha1
        ) None packs

    let read = read_aux (read_in_pack "read" Pack_IO.Raw.read)
    let read_inflated =
      read_aux (read_in_pack "read_inflated" Pack_IO.Raw.read_inflated)

    let mem t sha1 =
      list t >>= fun packs ->
      Lwt_list.fold_left_s (fun acc pack ->
          if acc then Lwt.return acc
          else mem_in_pack t pack sha1
        ) false packs

  end

  let list t =
    Log.debug "list";
    Loose.list t  >>= fun objects ->
    Packed.list t >>= fun packs   ->
    Lwt_list.map_p (fun p -> Packed.read_keys t p) packs >>= fun keys ->
    let keys = List.fold_left SHA.Set.union (SHA.Set.of_list objects) keys in
    let keys = SHA.Set.to_list keys in
    Lwt.return keys

  let cache_add sha1 = function
    | None   -> None
    | Some v -> Value.Cache.add sha1 v; Some v

  let cache_add_inflated sha1 = function
    | None   -> None
    | Some v -> Value.Cache.add_inflated sha1 v; Some v

  let rec read t sha1 =
    Log.debug "read %a" SHA.output sha1;
    match Value.Cache.find sha1 with
    | Some v -> Lwt.return (Some v)
    | None   ->
      Log.debug "read: cache miss!";
      begin Loose.read t sha1 >>= function
      | Some v -> Lwt.return (Some v)
      | None   ->
        let read = read_inflated t in
        Packed.read ~read t sha1
      end >|=
      cache_add sha1

  and read_inflated t sha1 =
    Log.debug "read_inflated %a" SHA.output sha1;
    match Value.Cache.find_inflated sha1 with
    | Some v -> Lwt.return (Some v)
    | None   ->
      Log.debug "read_inflated: cache miss!";
      begin Loose.read_inflated t sha1 >>= function
      | Some v -> Lwt.return (Some v)
      | None   ->
        let read = read_inflated t in
        Packed.read_inflated ~read t sha1
      end >|=
      cache_add_inflated sha1

  let read_exn t sha1 =
    read t sha1 >>= function
    | Some v -> Lwt.return v
    | None   -> err_not_found "read_exn" (SHA.pretty sha1)

  let mem t sha1 =
    match Value.Cache.find sha1 with
    | Some _ -> Lwt.return true
    | None   ->
      Log.debug "mem: cache miss!";
      Loose.mem t sha1 >>= function
      | true  -> Lwt.return true
      | false -> Packed.mem t sha1

  let contents t =
    Log.debug "contents";
    list t >>= fun sha1s ->
    Lwt_list.map_p (fun sha1 ->
        read_exn t sha1 >>= fun value ->
        Lwt.return (sha1, value)
      ) sha1s

  let dump t =
    contents t >>= fun contents ->
    List.iter (fun (sha1, value) ->
        let typ = Value.type_of value in
        Log.error "%a %a" SHA.output sha1 Object_type.output typ;
      ) contents;
    Lwt.return_unit

  let packed_refs t = t.dot_git / "packed-refs"

  let references t =
    let refs = t.dot_git / "refs" in
    IO.rec_files refs >>= fun files ->
    let n = String.length (t.dot_git / "") in
    let refs = List.map (fun file ->
        let ref = String.sub file n (String.length file - n) in
        Reference.of_raw ref
      ) files in
    let packed_refs = packed_refs t in
    let packed_refs =
      IO.file_exists packed_refs >>= function
      | false -> Lwt.return_nil
      | true  ->
        IO.read_file packed_refs >>= fun buf ->
        let pr = Packed_refs_IO.input (Mstruct.of_cstruct buf) in
        Lwt.return (Packed_refs.references pr)
    in
    packed_refs >|= fun packed_refs -> refs @ packed_refs

  let file_of_ref t ref = t.dot_git / Reference.to_raw ref

  let mem_reference t ref =
    let file = file_of_ref t ref in
    IO.file_exists file

  let remove_reference t ref =
    let file = file_of_ref t ref in
    Lwt.catch
      (fun () -> IO.remove file)
      (fun _ -> Lwt.return_unit)

  let rec read_reference t ref =
    let file = file_of_ref t ref in
    IO.file_exists file >>= fun exists ->
    if exists then
      (* We use `IO.read_file` here as the contents of the file might
         change. *)
      IO.read_file file >>= fun buf ->
      let str = Cstruct.to_string buf in
      match Reference.head_contents_of_string ~of_hex:SHA_IO.of_hex str with
      | Reference.SHA x -> Lwt.return (Some x)
      | Reference.Ref r -> read_reference t r
    else
      let packed_refs = packed_refs t in
      IO.file_exists packed_refs >>= function
      | false -> Lwt.return_none
      | true  ->
        (* We use `IO.read_file` here as the contents of the file
           might change. *)
        IO.read_file packed_refs >>= fun buf ->
        let refs = Packed_refs_IO.input (Mstruct.of_cstruct buf) in
        let sha1 = Packed_refs.find refs ref in
        Lwt.return sha1

  let read_head t =
    let file = file_of_ref t Reference.head in
    IO.file_exists file >>= function
    | true ->
      (* We use `IO.read_file` here as the contents of the file might
         change. *)
      IO.read_file file >|= fun buf ->
      let str = Cstruct.to_string buf in
      Some (Reference.head_contents_of_string ~of_hex:SHA_IO.of_hex str)
    | false ->
      Lwt.return None

  let read_reference_exn t ref =
    read_reference t ref >>= function
    | Some s -> Lwt.return s
    | None   -> err_not_found "read_reference_exn" (Reference.pretty ref)

  let write t value =
    Loose.write t value >>= fun sha1 ->
    Log.debug "write -> %a" SHA.output sha1;
    Value.Cache.add sha1 value;
    Lwt.return sha1

  let write_inflated t value =
    Loose.write_inflated t value >>= fun sha1 ->
    Log.debug "write -> %a" SHA.output sha1;
    Value.Cache.add_inflated sha1 value;
    Lwt.return sha1

  let write_pack t pack =
    Log.debug "write_pack";
    let sha1 = Pack.Raw.sha1 pack in
    let index = Pack.Raw.index pack in
    Packed.write_pack t sha1 pack   >>= fun () ->
    Packed.write_pack_index t sha1 index >>= fun () ->
    Lwt.return (Pack.Raw.keys pack)

  let write_reference t ref sha1 =
    let file = t.dot_git / Reference.to_raw ref in
    let contents = SHA.Commit.to_hex sha1 in
    let temp_dir = temp_dir t in
    IO.write_file file ~temp_dir (Cstruct.of_string contents)

  let write_head t = function
    | Reference.SHA sha1 -> write_reference t Reference.head sha1
    | Reference.Ref ref   ->
      let file = t.dot_git / "HEAD" in
      let contents = sprintf "ref: %s" (Reference.to_raw ref) in
      let temp_dir = temp_dir t in
      IO.write_file file ~temp_dir (Cstruct.of_string contents)

  type 'a tree =
    | Leaf of 'a
    | Node of (string * 'a tree) list

  let iter fn t =
    let rec aux path = function
      | Leaf l -> fn (List.rev path) l
      | Node n ->
        Lwt_list.iter_p (fun (l, t) ->
            aux (l::path) t
          ) n in
    aux [] t

  (* XXX: do not load the blobs *)
  let id = let n = ref 0 in fun () -> incr n; !n

  let load_filesystem t head =
    Log.debug "load_filesystem head=%a" SHA.Commit.output head;
    let blobs_c = ref 0 in
    let id = id () in
    let error expected got =
      fail "load_filesystem: expecting a %s, got a %s"
        expected (Object_type.pretty (Value.type_of got))
    in
    let blob mode sha1 k =
      Log.debug "blob %d %a" id SHA.output sha1;
      assert (mode <> `Dir);
      incr blobs_c;
      read_exn t sha1 >>= function
      | Value.Blob b -> k (Leaf (mode, (SHA.to_blob sha1, b)))
      | obj          -> error "blob" obj
    in
    let rec tree mode sha1 k =
      Log.debug "tree %d %a" id SHA.output sha1;
      assert (mode = `Dir);
      read_exn t sha1 >>= function
      | Value.Tree t -> tree_entries t [] k
      | obj          -> error "tree" obj
    and tree_entries trees children k =
      match trees with
      | []   -> k (Node children)
      | e::t ->
        let k n = tree_entries t ((e.Tree.name, n)::children) k in
        match e.Tree.perm with
        | `Dir -> tree `Dir e.Tree.node k
        | mode -> blob mode e.Tree.node k
    in
    let commit sha1 =
      Log.debug "commit %d %a" id SHA.output sha1;
      read_exn t sha1 >>= function
      | Value.Commit c -> tree `Dir (SHA.of_tree c.Commit.tree) Lwt.return
      | obj            -> error "commit" obj
    in
    commit (SHA.of_commit head) >>= fun t ->
    Lwt.return (!blobs_c, t)

  let iter_blobs t ~f ~init =
    load_filesystem t init >>= fun (n, trie) ->
    let i = ref 0 in
    Log.debug "iter_blobs %a" SHA.Commit.output init;
    iter (fun path (mode, (sha1, blob)) ->
        incr i;
        f (!i, n) (t.root :: path) mode sha1 blob
      ) trie

  let create_file t file mode blob =
    Log.debug "create_file %s" file;
    let blob = Blob.to_raw blob in
    match mode with
    | `Link -> (*q Lwt_unix.symlink file ??? *) failwith "TODO"
    | _     ->
      let temp_dir = temp_dir t in
      let contents = Cstruct.of_string blob in
      let rec write n =
        let one () =
          Log.debug "one %S" file;
          IO.write_file file ~temp_dir contents
        in
        if n <= 1 then one () else
          Lwt.catch one (fun e ->
              Log.debug "write (%d/10): Got %S, retrying."
                (11-n) (Printexc.to_string e);
              IO.remove file >>= fun () ->
              write (n-1))
      in
      write 10 >>= fun () ->
      match mode with
      | `Exec -> IO.chmod file 0o755
      | _     -> Lwt.return_unit

  let index_file t = t.dot_git / "index"

  module Index_IO = Index.IO(D)

  let read_index t =
    Log.debug "read_index";
    let file = index_file t in
    IO.file_exists file >>= function
    | false -> Lwt.return Index.empty
    | true  ->
      (* We use `IO.read_file` here as the contents of the file might
         change. *)
      IO.read_file file >>= fun buf ->
      let buf = Mstruct.of_cstruct buf in
      Lwt.return (Index_IO.input buf)

  let entry_of_file_aux t index file mode sha1 blob =
    IO.realpath file >>= fun file ->
    Log.debug "entry_of_file %a %s" SHA.Blob.output sha1 file;
    begin
      IO.file_exists file >>= function
      | false ->
        Log.debug "%s does not exist on the filesystem, creating!" file;
        create_file t file mode blob
      | true  ->
        let entry =
          try
            List.find (fun e -> t.root / e.Index.name = file) index.Index.entries
            |> fun x -> Some x
          with Not_found ->
            None
        in
        match entry with
        | None  ->
          Log.debug "%s does not exist in the index, adding!" file;
          (* in doubt, overide the current version -- git will just refuse
             to do anything in that case. *)
          create_file t file mode blob
        | Some e ->
          if e.Index.id <> sha1 then (
            Log.debug "%s has an old version in the index, updating!" file;
            create_file t file mode blob
          ) else
            let stats = IO.stat_info file in
            if e.Index.stats <> stats then (
              (* same thing here, usually Git just stops in that case. *)
              Log.debug "%s has been modified on the filesystem, reversing!" file;
              create_file t file mode blob
            ) else (
              Log.debug "%a: %s unchanged!" SHA.Blob.output sha1 file;
              Lwt.return_unit
            )
    end >>= fun () ->
    let id = sha1 in
    let stats = IO.stat_info file in
    let stage = 0 in
    match Misc.string_chop_prefix ~prefix:(t.root / "") file with
    | None      -> fail "entry_of_file: %s" file
    | Some name ->
      let entry = { Index.stats; id; stage; name } in
      Lwt.return (Some entry)

  let entry_of_file t index file mode sha1 blob =
    Lwt.catch
      (fun () -> entry_of_file_aux t index file mode sha1 blob)
      (function Failure _ | Sys_error _ -> Lwt.return_none | e -> Lwt.fail e)

  let write_index t ?index head =
    Log.debug "write_index %a" SHA.Commit.output head;
    let buf = Buffer.create 1024 in
    match index with
    | Some index ->
      Index_IO.add buf index;
      let temp_dir = temp_dir t in
      IO.write_file (index_file t) ~temp_dir
        (Cstruct.of_string (Buffer.contents buf)) >>= fun () ->
      let all = List.length index.Index.entries in
      Log.info "Checking out files: 100%% (%d/%d), done." all all;
      Lwt.return_unit
    | None ->
      let entries = ref [] in
      let all = ref 0 in
      read_index t >>= fun index ->
      Log.info "Checking out files...";
      iter_blobs t ~init:head ~f:(fun (i,n) path mode sha1 blob ->
          all := n;
          let file = String.concat Filename.dir_sep path in
          Log.debug "write_index: %d/%d blob:%s" i n file;
          entry_of_file t index file mode sha1 blob >>= function
          | None   -> Lwt.return_unit
          | Some e -> entries := e :: !entries; Lwt.return_unit
        ) >>= fun () ->
      let index = Index.create !entries in
      let temp_dir = temp_dir t in
      Index_IO.add buf index;
      IO.write_file (index_file t) ~temp_dir
        (Cstruct.of_string (Buffer.contents buf)) >>= fun () ->
      Log.info "Checking out files: 100%% (%d/%d), done." !all !all;
      Lwt.return_unit

  let kind = `Disk

  let clear () =
    File_cache.clear ();
    Packed.clear ()

  module Digest = D
  module Inflate = I

end
