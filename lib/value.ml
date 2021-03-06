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

module Log = Log.Make(struct let section = "value" end)

module T = struct

  type t =
    | Blob   of Blob.t
    | Commit of Commit.t
    | Tag    of Tag.t
    | Tree   of Tree.t

  let equal = (=)
  let hash = Hashtbl.hash
  let compare = compare

  let pp ppf = function
    | Blob b   -> Format.fprintf ppf "@[<hov 2>Blob@ %a@]" Blob.pp b
    | Commit c -> Format.fprintf ppf "@[<hov 2>Commit@ %a@]" Commit.pp c
    | Tag t    -> Format.fprintf ppf "@[<hov 2>Tag@ %a@]" Tag.pp t
    | Tree t   -> Format.fprintf ppf "@[<hov 2>Tree@ %a@]" Tree.pp t

  let pretty t = Misc.pretty pp t

end

include T

let commit c = Commit c
let blob b = Blob b
let tree t = Tree t
let tag t = Tag t

let type_of = function
  | Blob _   -> Object_type.Blob
  | Commit _ -> Object_type.Commit
  | Tag _    -> Object_type.Tag
  | Tree _   -> Object_type.Tree

let type_of_inflated buf =
  let obj_type =
    match Mstruct.get_string_delim buf Misc.sp with
    | None   -> Mstruct.parse_error_buf buf "value: type"
    | Some t -> t in
  match Object_type.of_string obj_type with
  | Some t -> t
  | None   ->
    Mstruct.parse_error_buf buf "%S is not a valid object type." obj_type

module IO (D: SHA.DIGEST) (I: Inflate.S) = struct

  include T
  module SHA_IO = SHA.IO(D)
  module Commit_IO = Commit.IO(D)
  module Tag_IO = Tag.IO(D)
  module Tree_IO = Tree.IO(D)

  let add_header buf typ size =
    Buffer.add_string buf (Object_type.to_string typ);
    Buffer.add_char   buf Misc.sp;
    Buffer.add_string buf (string_of_int size);
    Buffer.add_char   buf Misc.nul

  let add_contents buf = function
    | Blob b   -> Blob.add buf b
    | Commit c -> Commit_IO.add buf c
    | Tag t    -> Tag_IO.add buf t
    | Tree t   -> Tree_IO.add buf t

  let add_inflated buf t =
    Log.debug "add_inflated";
    let tmp = Buffer.create 1024 in
    add_contents tmp t;
    let size = Buffer.length tmp in
    add_header buf (type_of t) size;
    Buffer.add_buffer buf tmp

  let sha1 t =
    let buf = Misc.with_buffer (fun buf -> add_inflated buf t) in
    D.string buf

  let input_inflated buf =
    let obj_type = type_of_inflated buf in
    let size =
      match Mstruct.get_string_delim buf Misc.nul with
      | None   -> Mstruct.parse_error_buf buf "value: size"
      | Some s ->
        try int_of_string s
        with Failure _ ->
          Mstruct.parse_error_buf buf
            "Value.input_inflated: %S is not a valid integer." s
    in
    if size <> Mstruct.length buf then
      Mstruct.parse_error_buf buf
        "[expected-size: %d; actual-size: %d]\n"
        size (Mstruct.length buf);
    let buf = Mstruct.sub buf 0 size in
    match obj_type with
    | Object_type.Blob   -> Blob.input buf      |> blob
    | Object_type.Commit -> Commit_IO.input buf |> commit
    | Object_type.Tag    -> Tag_IO.input buf    |> tag
    | Object_type.Tree   -> Tree_IO.input buf   |> tree

  let add buf ?level t =
    Log.debug "add %s" (pretty t);
    let inflated = Misc.with_buffer' (fun buf -> add_inflated buf t) in
    let deflated = I.deflate ?level inflated in
    Buffer.add_string buf (Cstruct.to_string deflated)

  let fail fmt = Printf.ksprintf failwith ("Value: " ^^ fmt)
  let err_inflate () = fail "not a valid compressed object"

  let input buf = match I.inflate buf with
    | None   -> err_inflate ()
    | Some s -> input_inflated s

end

module Cache = struct

  let len = 512
  let cache: t LRU.t ref = ref (LRU.make len)
  let cache_inflated: string LRU.t ref = ref (LRU.make len)

  let clear () =
    LRU.clear !cache;
    LRU.clear !cache_inflated

  let set_size len =
    cache := LRU.make len;
    cache_inflated := LRU.make len

  let find sha1 = LRU.find !cache sha1
  let find_inflated sha1 = LRU.find !cache_inflated sha1
  let add sha1 t = LRU.add !cache sha1 t
  let add_inflated sha1 str = LRU.add !cache_inflated sha1 str

end

type read = SHA.t -> t option Lwt.t
type read_inflated = SHA.t -> string option Lwt.t
type write = t -> SHA.t Lwt.t
type write_inflated = string -> SHA.t Lwt.t

module type IO = sig
  include Object.IO with type t = t
  val sha1: t -> SHA.t
  val add_header: Buffer.t -> Object_type.t -> int -> unit
  val add_inflated: Buffer.t -> t -> unit
  val input_inflated: Mstruct.t -> t
end
