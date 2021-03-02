(*
 * Copyright (C) 2020-2021 Anil Madhavapeddy
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

(** Io_uring interface. 
    FIXME: Since this library is still unreleased, all the interfaces here are
    being iterated on.
*)

(** Allocate memory buffers outside the OCaml heap to pass to system calls *)
module Iovec : sig
  type buf = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  (** [buf] is an OCaml Bigarray.
      This may move to a more efficient structure in the future without reference counting. *)

  type iovec
  (** [iovec] is equivalent to a C [struct iovec] *)

  type t
  (** [t] represents the [iovec] and the backing [buf] list which the [iovec] points at *)

  val alloc : buf array -> t
  (** [alloc bufs] create an iovec from the array of memory buffers passed in. *)

  val alloc_buf : int -> buf
  (** [alloc_buf l] creates an iovec with a single malloced block of memory of length [l] *)

  val free : t -> unit
  (** [free t] will free the memory buffers pointed to by [t]. The memory buffers will be
      NULL after this call. *)

  val nr_vecs : t -> int
  (** [nr_vecs t] will return the number of memory buffers tracked by the iovec. *)

  val bufs : t -> buf array
  (** [bufs t] returns the underlying memory buffers tracked by the iovec. *)

  val empty : t
  (** [empty] is an iovec pointing to no memory buffers. *)

  val advance : t -> idx:int -> adj:int -> unit
  (** FIXME [advance] is a way to adjust the iovec, but an unfinished and unsafe interface. *)
end

(** [Region] handles carving up a block of external memory into
    smaller chunks.  This is currently just a slab allocator of
    a fixed size, on the basis that most IO operations operate on
    predictable chunks of memory. Since the block of memory in a
    region is contiguous, it can be used in Uring's fixed buffer
    model to map it into kernel space for more efficient IO. *)
module Region : sig

  type t
  (** [t] is a contiguous region of memory *)

  type chunk
  (** [chunk] is an offset into a region of memory allocated
      from some region [t].  It is of a length set when the
      region [t] associated with it was initialised. *)

  exception No_space
  (** [No_space] is raised when an allocation request cannot
      be satisfied. *)

  val init: block_size:int -> Iovec.buf -> int -> t
  (** [init ~block_size buf slots] initialises a region from
      the buffer [buf] with total size of [block_size * slots]. *)

  val alloc : t -> chunk
  (** [alloc t] will allocate a single chuck of length [block_size]
      from the region [t]. *)

  val free : chunk -> unit
  (** [free chunk] will return the memory [chunk] back to the region
      [t] where it can be reallocated. *)

  val to_offset : chunk -> int
  (** [to_offset chunk] will convert the [chunk] into an integer
      offset in its associated region.  This can be used in IO calls
      involving that memory. *)

  val to_bigstring : ?len:int -> chunk -> Iovec.buf
  (** [to_bigstring ?len chunk] will create a {!Bigarray} into the
      chunk of memory. Note that this is a zero-copy view into the
      underlying region [t] and so the [chunk] should not be freed
      until this Bigarray reference is no longer used.

      If [len] is specified then the returned view is of that size,
      and otherwise it defaults to [block_size]. *)

  val to_string : ?len:int -> chunk -> string
  (** [to_string ?len chunk] will return a copy of the [chunk]
      as an OCaml string.

      If [len] is specified then the returned view is of that size,
      and otherwise it defaults to [block_size]. *)

  val avail : t -> int
  (** [avail t] is the number of free chunks of memory remaining
      in the region. *)
end

(* {1 Io_uring. *)

type 'a t
(** ['a t] is a reference to an Io_uring structure. *)

val create : ?fixed_buf_len:int -> queue_depth:int -> default:'a -> unit -> 'a t
(** [create ?fixed_buf_len ~queue_depth ~default] will return a fresh
    Io_uring structure [t].  Each [t] has associated with it a fixed region of
    memory that is used for the "fixed buffer" mode of io_uring to avoid data
    copying between userspace and the kernel. *)

val queue_depth : 'a t -> int
(** [queue_depth t] returns the total number of submission slots for the uring [t] *)

val exit : 'a t -> unit
(** [exit t] will shut down the uring [t]. Any subsequent requests will fail. *)

val readv : 'a t -> ?offset:int -> Unix.file_descr -> Iovec.t -> 'a -> bool
(** [readv t ?offset fd iov d] will submit a [readv(2)] request to uring [t].
    It reads from absolute file [offset] on the [fd] file descriptor and writes
    the results into the memory pointed to by [iov].  The user data [d] will
    be returned by {!wait} or {!peek} upon completion. *)

val writev : 'a t -> ?offset:int -> Unix.file_descr -> Iovec.t -> 'a -> bool
(** [writev t ?offset fd iov d] will submit a [writev(2)] request to uring [t].
    It writes to absolute file [offset] on the [fd] file descriptor from the
    the memory pointed to by [iov].  The user data [d] will be returned by
    {!wait} or {!peek} upon completion. *)

val read : 'a t -> ?file_offset:int -> Unix.file_descr -> int -> int -> 'a -> bool
(** [read t ?file_offset fd off d] will submit a [read(2)] request to uring [t].
    It read from absolute [file_offset] on the [fd] file descriptor and writes
    the results into the fixed memory buffer associated with uring [t] at offset
    [off]. TODO: replace [off] with {!Region.chunk} instead?
    The user data [d] will be returned by {!wait} or {!peek} upon completion. *)

val write : 'a t -> ?file_offset:int -> Unix.file_descr -> int -> int -> 'a -> bool
(** [write t ?file_offset fd off d] will submit a [write(2)] request to uring [t].
    It writes into absolute [file_offset] on the [fd] file descriptor from
    the fixed memory buffer associated with uring [t] at offset [off].
    TODO: replace [off] with {!Region.chunk} instead?
    The user data [d] will be returned by {!wait} or {!peek} upon completion. *)

val submit : 'a t -> int
(** [submit t] will submit all the outstanding queued requests on uring [t]
    to the kernel. Their results can subsequently be retrieved using {!wait}
    or {!peek}. *)

val wait : ?timeout:float -> 'a t -> ('a * int) option
(** [wait ?timeout t] will block indefinitely (the default) or for [timeout]
    seconds for any outstanding events to complete on uring [t].  Events should
    have been queued via {!submit} previously to this call.
    It returns the user data associated with the original request and the 
    integer syscall result. TODO: replace int res with a GADT of the request type. *)

val peek : 'a t -> ('a * int) option
(** [peek t] looks for completed requests on the uring [t] without blocking.
    It returns the user data associated with the original request and the 
    integer syscall result. TODO: replace int res with a GADT of the request type. *)

val realloc : 'a t -> Iovec.buf -> unit
(** [realloc t buf] will replace the internal fixed buffer associated with
    uring [t] with a fresh one. TODO: specify semantics of outstanding requests. *)

val buf : 'a t -> Iovec.buf
(** [buf t] will return the fixed internal memory buffer associated with
    uring [t]. TODO: replace with {!Region.t} instead. *)

