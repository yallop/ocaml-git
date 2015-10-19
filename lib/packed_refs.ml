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

type entry =
  [ `Newline
  | `Comment of string
  | `Entry of (SHA.Commit.t * Reference.t) ]

let to_line ppf = function
  | `Newline -> Format.fprintf ppf "\n"
  | `Comment c -> Format.fprintf ppf "# %s\n" c
  | `Entry (s,r) ->
    Format.fprintf ppf "%a %s" SHA.Commit.pp s (Reference.to_raw r)

module T = struct
  type t = entry list
  let equal t1 t2 = List.length t1 = List.length t2 && t1 = t2
  let hash = Hashtbl.hash
  let compare = Pervasives.compare
  let pp ppf t = List.iter (to_line ppf) t
  let pretty = Misc.pretty pp
  let output ch t = output_string ch (pretty t)
end

include T

let find t r =
  let rec aux = function
    | [] -> None
    | (`Newline | `Comment _) :: t -> aux t
    | `Entry (x, y) :: t -> if Reference.equal y r then Some x else aux t
  in
  aux t

module Set = Set.Make(Reference)

let references (t:t) =
  let rec aux acc = function
    | [] -> Set.elements acc
    | (`Newline | `Comment _) :: t -> aux acc t
    | `Entry (_, r) :: t -> aux (Set.add r acc) t
  in
  aux Set.empty t

module IO (D: SHA.DIGEST) = struct

  module SHA_IO = SHA.IO(D)
  include T

  let of_line line =
    let line = String.trim line in
    if String.length line = 0 then Some `Newline
    else if line.[0] = '#' then
      let str = String.sub line 1 (String.length line - 1) in
      Some (`Comment str)
    else match Stringext.cut line ~on:" " with
      | None  -> None
      | Some (sha1, ref) ->
        let sha1 = SHA_IO.Commit.of_hex sha1 in
        let ref = Reference.of_raw ref in
        Some (`Entry (sha1, ref))

  let add buf ?level:_ t =
    let ppf = Format.formatter_of_buffer buf in
    List.iter (to_line ppf) t

  let input buf =
    let rec aux acc =
      let line, cont = match Mstruct.get_string_delim buf '\n' with
        | None   -> Mstruct.to_string buf, false
        | Some s -> s, true
      in
      let acc = match of_line line with
        | None   -> acc
        | Some e -> e :: acc
      in
      if cont then aux acc else List.rev acc
    in
    aux []

end
