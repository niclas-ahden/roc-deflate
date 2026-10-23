import Inflate
import CompressLazy
import CompressFast
import CompressOptimal

## DEFLATE (RFC 1951) compression and decompression in pure Roc, ported from
## libdeflate.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it reads streams produced by zlib, gzip, and ZIP tools.
## `compress` takes a `Level` from 0 to 12 with the same meaning libdeflate
## gives it: the level selects the parser and how hard it searches.

## Errors that can occur when decompressing a DEFLATE stream.
##
## `UnexpectedEnd` means the input ran out before the final block ended, so
## any truncated stream, an empty input included, reports it. `CorruptData`
## means the bytes that are there are not a valid DEFLATE stream.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
]

Deflate := [].{

	## A compression level from 0 to 12, with libdeflate's meaning: 0 stores the
	## input without compressing it, 1 is the fastest, 6 the usual default, and
	## 12 searches hardest.
	##
	## A number literal is a `Level` wherever one is expected, so
	## `Deflate.compress(bytes, 6)` works, and a literal outside 0 to 12 is a
	## compile-time error. A level only known at runtime, such as one read from
	## a command-line argument, goes through `from_u64`.
	Level :: U8.{
		is_eq : _
		to_hash : _

		## Turn a number literal into a level when the program is compiled,
		## rejecting any literal that is not a whole number from 0 to 12.
		from_numeral : Numeral -> Try(Level, [InvalidNumeral(Str)])
		from_numeral = |numeral|
			match U8.from_numeral(numeral) {
				Ok(n) if n <= 12 => Ok(Level.(n))
				_ => Err(InvalidNumeral("A compression level is a whole number from 0 to 12."))
			}

		## The level for a number only known at runtime.
		from_u64 : U64 -> Try(Level, [OutOfRange])
		from_u64 = |n|
			if n <= 12 {
				Ok(Level.(n.to_u8_wrap()))
			} else {
				Err(OutOfRange)
			}

		## The level's number, from 0 to 12.
		to_u64 : Level -> U64
		to_u64 = |Level.(n)| n.to_u64()

		## Every level, from 0 to 12.
		all : List(Level)
		all = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
	}

	## Compress bytes into a raw DEFLATE stream at the given level.
	##
	## This never fails. It crashes only on a bug in this package.
	compress : List(U8), Level -> List(U8)
	compress = |input, chosen|
		Deflate.compress_into(input, chosen, [])

	## Compress bytes into a raw DEFLATE stream at the given level, appending
	## the stream to `out`.
	##
	## The compressor reserves `compress_bound` bytes past what `out` holds
	## before writing, so passing a list with that much spare capacity means
	## it never reallocates, and a returned list can be emptied with its
	## capacity kept and passed back in for the next stream. Reusing one
	## buffer that way also reuses its memory, which a fresh list for every
	## stream has to fetch from the system again.
	compress_into : List(U8), Level, List(U8) -> List(U8)
	compress_into = |input, chosen, out| {
		level = chosen.to_u64()
		# Level 0 never compresses. Above it, inputs this short are not worth
		# trying to compress, and the higher the level, the shorter an input it
		# still tries on (libdeflate's `max_passthrough_size`).
		max_passthrough = if level == 0 { 18446744073709551615 } else { 55 - 4 * level }
		if List.len(input) <= max_passthrough {
			store_uncompressed(input, out)
		} else if level == 1 {
			CompressFast.compress(input, 32, out)
		} else if level >= 10 {
			CompressOptimal.compress(input, optimal_params_for(level), out)
		} else {
			params = params_for(level)
			if params.lazy == 0 {
				CompressLazy.compress_greedy(input, params, out)
			} else {
				CompressLazy.compress(input, params, out)
			}
		}
	}

	## The largest a compressed stream can be, matching libdeflate's bound.
	##
	## The compressor never uses a compressed block where an uncompressed one
	## would be cheaper, so the worst case is all uncompressed blocks: five
	## bytes of header each, over blocks no shorter than the minimum block
	## length.
	compress_bound : U64 -> U64
	compress_bound = |in_nbytes| {
		max_blocks = ((in_nbytes + CompressLazy.min_block_length - 1) // CompressLazy.min_block_length).max(1)
		5 * max_blocks + in_nbytes
	}

	## Decompress a raw DEFLATE stream.
	decompress : List(U8) -> Try(List(U8), DeflateError)
	decompress = |input|
		Inflate.decompress(input)

	## Decompress a raw DEFLATE stream, appending the output to `out`.
	##
	## Passing a list with enough spare capacity for the whole result means
	## the decompressor never reallocates mid-stream, and a returned list can
	## be emptied with its capacity kept and passed back in for the next
	## stream.
	##
	## The stream cannot refer back into the bytes `out` already holds. A
	## match that reaches past the start of the stream's own output is
	## `CorruptData`, the same as with an empty `out`.
	decompress_into : List(U8), List(U8) -> Try(List(U8), DeflateError)
	decompress_into = |input, out|
		Inflate.decompress_into(input, out)
}

# Emit the input as stored blocks, which is what the format requires even
# for empty input.
store_uncompressed : List(U8), List(U8) -> List(U8)
store_uncompressed = |input, out| {
	in_end = List.len(input)
	var $out = List.reserve(out, in_end + 5 * (in_end // 65535 + 1))
	if in_end == 0 {
		$out = List.append($out, 1)
		$out = match 0xFFFF0000.U64.append_le_bytes_to($out, 4) {
			Ok(next) => next
			Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
		}
		$out
	} else {
		var $in_next = 0.U64
		var $storing = 1.U64
		while $storing == 1 {
			remaining = in_end - $in_next
			len = remaining.min(65535)
			bfinal = if remaining <= 65535 { 1.U64 } else { 0 }
			$out = List.append($out, bfinal.to_u8_wrap())
			$out = match len.append_le_bytes_to($out, 2) {
				Ok(next) => next
				Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
			}
			$out = match len.bitwise_not().append_le_bytes_to($out, 2) {
				Ok(next) => next
				Err(_) => crash "Deflate.store_uncompressed: appended more than 8 bytes"
			}
			$out = List.append_sublist($out, input, { start: $in_next, len })
			$in_next = $in_next + len
			if $in_next == in_end {
				$storing = 0
			} else {
			}
		}
		$out
	}
}

# The search parameters libdeflate uses at each level.
params_for : U64 -> CompressLazy.Params
params_for = |level|
	if level <= 2 {
		{ max_search_depth: 6, nice_match_length: 10, lazy: 0 }
	} else if level == 3 {
		{ max_search_depth: 12, nice_match_length: 14, lazy: 0 }
	} else if level == 4 {
		{ max_search_depth: 16, nice_match_length: 30, lazy: 0 }
	} else if level == 5 {
		{ max_search_depth: 16, nice_match_length: 30, lazy: 1 }
	} else if level == 6 {
		{ max_search_depth: 35, nice_match_length: 65, lazy: 1 }
	} else if level == 7 {
		{ max_search_depth: 100, nice_match_length: 130, lazy: 1 }
	} else if level == 8 {
		{ max_search_depth: 300, nice_match_length: 258, lazy: 2 }
	} else {
		{ max_search_depth: 600, nice_match_length: 258, lazy: 2 }
	}

# The near-optimal parser's parameters at each of the levels that use it.
#
# As well as searching harder, the higher levels spend more optimization
# passes on each block, keep going for smaller improvements, and are
# willing to optimize the static-Huffman alternative for longer blocks.
optimal_params_for : U64 -> CompressOptimal.Params
optimal_params_for = |level|
	if level == 10 {
		{
			max_search_depth: 35,
			nice_match_length: 75,
			max_optim_passes: 2,
			min_improvement_to_continue: 32,
			min_bits_to_use_nonfinal_path: 32,
			max_len_to_optimize_static_block: 0,
		}
	} else if level == 11 {
		{
			max_search_depth: 100,
			nice_match_length: 150,
			max_optim_passes: 4,
			min_improvement_to_continue: 16,
			min_bits_to_use_nonfinal_path: 16,
			max_len_to_optimize_static_block: 1000,
		}
	} else {
		{
			max_search_depth: 300,
			nice_match_length: 258,
			max_optim_passes: 10,
			min_improvement_to_continue: 1,
			min_bits_to_use_nonfinal_path: 1,
			max_len_to_optimize_static_block: 10000,
		}
	}

# The tests here are the fast ones, so `roc test` stays quick on every
# backend, the interpreter included. Hand-built streams pin the decoder to the
# format itself rather than to this package's compressor. tests/harness.roc
# covers the large inputs, byte-identity with libdeflate at every level, and
# the decoder's error cases in bulk.

# A final fixed Huffman block holding only the end-of-block code.
expect Deflate.decompress([0x03, 0x00]) == Ok([])

# A final stored block of "Hello": LEN 5, then NLEN, its complement.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F]) == Ok("Hello".to_utf8())

# The same block with an NLEN that is not LEN's complement.
expect Deflate.decompress([0x01, 0x05, 0x00, 0xFB, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F]) == Err(CorruptData)

# BTYPE 3 is reserved.
expect Deflate.decompress([0x07]) == Err(CorruptData)

# Input that ends before the stream does, the empty input included, wherever
# it stops: in a block header, in a stored block's payload, or in a dynamic
# block's code lengths.
expect Deflate.decompress([]) == Err(UnexpectedEnd)

expect Deflate.decompress([0x03]) == Err(UnexpectedEnd)

expect Deflate.decompress([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65]) == Err(UnexpectedEnd)

expect {
	stream = Deflate.compress("abcdefghijklmnopqrstuvwxyz, abcdefghijklmnopqrstuvwxyz, and the alphabet again".to_utf8(), 6)
	Deflate.decompress(List.sublist(stream, { start: 0, len: 3 })) == Err(UnexpectedEnd)
}

# A fixed block holding one match, length 3 at distance 3, with no output
# before it to copy from.
expect Deflate.decompress([0x03, 0x22, 0x00]) == Err(CorruptData)

# The bytes `out` already holds are not part of the stream, so the match is
# just as corrupt when there is something there to copy.
expect Deflate.decompress_into([0x03, 0x22, 0x00], [1, 2, 3]) == Err(CorruptData)

# The output is appended to what `out` holds.
expect Deflate.decompress_into([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], [1, 2]) == Ok([1, 2, 0x48, 0x65, 0x6C, 0x6C, 0x6F])

# Every level round-trips the shortest inputs and the two lengths either side
# of its passthrough limit, the longest input it stores without trying to
# compress, and stays within `compress_bound`.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	var $ok = True
	for level in Deflate.Level.all {
		n = level.to_u64()
		limit = if n == 0 { 64 } else { 55 - 4 * n }
		for len in [0, 1, 2, 3, 4, 5, limit, limit + 1] {
			original = List.sublist(text, { start: 0, len })
			compressed = Deflate.compress(original, level)
			if Deflate.decompress(compressed) != Ok(original) or List.len(compressed) > Deflate.compress_bound(len) {
				$ok = False
			} else {}
		}
	}
	$ok
}

# Bytes that do not compress at all are where `compress_bound` is tightest.
expect {
	noise = List.repeat(0.U8, 3000).map_with_index(|_, i| {
		a = i.times_wrap(0x9E3779B97F4A7C15)
		b = a.bitwise_xor(a.shr_zf_wrap(29)).times_wrap(0xBF58476D1CE4E5B9)
		b.bitwise_xor(b.shr_zf_wrap(32)).shr_zf_wrap(56).to_u8_wrap()
	})
	var $ok = True
	for level in Deflate.Level.all {
		compressed = Deflate.compress(noise, level)
		if Deflate.decompress(compressed) != Ok(noise) or List.len(compressed) > Deflate.compress_bound(3000) {
			$ok = False
		} else {}
	}
	$ok
}

# `compress_into` appends to what `out` holds, and the stream it appends is
# the one `compress` returns, at every level, whether or not `out` already
# has spare capacity.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	var $ok = True
	for level in Deflate.Level.all {
		alone = Deflate.compress(text, level)
		appended = Deflate.compress_into(text, level, [7, 8])
		reused = Deflate.compress_into(text, level, List.with_capacity(Deflate.compress_bound(List.len(text))))
		if appended != List.concat([7, 8], alone) or reused != alone {
			$ok = False
		} else {}
	}
	$ok
}

# A level from a runtime number is checked there, and every level is listed
# once, in order.
expect Deflate.Level.from_u64(12).map_ok(|level| level.to_u64()) == Ok(12)

expect Deflate.Level.from_u64(13).is_err()

expect Deflate.Level.all.map(|level| level.to_u64()) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
