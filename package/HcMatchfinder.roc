import Matchfinder

## The hash-chains matchfinder, ported from libdeflate's `hc_matchfinder.h`.
##
## Every position is inserted into a length-3 hash bucket and onto the front of
## a length-4 hash chain. A search walks the length-4 chain newest first, so it
## can stop after `max_search_depth` candidates and still have considered the
## nearest ones, which are the cheapest to encode.
##
## This module holds the tables, their layout and the insertion of skipped
## positions. The search itself, libdeflate's `hc_matchfinder_longest_match`,
## is written out in `CompressLazy` at each of its four sites (the greedy loop
## and the lazy loop's three), because a call here returned through memory
## and spilled the loop around it. libdeflate gets the same effect from
## `forceinline` on a single source. Keep the four copies in step with that
## function and with each other.
##
## Two details of the search carry most of the speed and are kept exactly:
##
##   - the walk rejects a candidate on four bytes at a time, and once a match
##     is established it first re-checks the four bytes ending just past the
##     current best length, so a candidate that cannot beat the incumbent is
##     discarded without extending it
##   - the first search and the "already have a length-4 match" search are
##     separate loops rather than one general loop, because each is tuned for
##     what it knows
HcMatchfinder := [].{

	hash3_order : U64
	hash3_order = 15

	hash4_order : U64
	hash4_order = 16

	hash3_size : U64
	hash3_size = 32768

	hash4_size : U64
	hash4_size = 65536

	## The three tables live in one list: the length-4 heads first, then the
	## chain links (one window long), then the length-3 heads. Putting the
	## length-4 heads at offset zero lets the insertion loop load and store
	## them with one scaled-index address, without a separate region offset.
	## One allocation also keeps the tables unique across calls and loops.
	next_base : U64
	next_base = 65536

	hash3_base : U64
	hash3_base = 98304

	hash4_base : U64
	hash4_base = 0

	table_size : U64
	table_size = 131072

	State : {
		tab : List(U16),
		in_cur_base : U64,
		next_hash3 : U64,
		next_hash4 : U64,
	}

	init_tables : {} -> List(U16)
	init_tables = |{}|
		Matchfinder.init_nodes(HcMatchfinder.table_size)

	## Insert `count` positions into the tables without searching them.
	##
	## The result comes back in a `Try` that cannot fail. The compiler at
	## roc-lang/roc 66c32df makes the lazy levels a few percent slower when
	## this returns the bare record instead, though the work is the same.
	skip_bytes : List(U16), U64, U64, U64, List(U8), U64, U64, U64 -> Try(State, [])
	skip_bytes = |tab_0, base_0, nh3_0, nh4_0, input, in_next0, in_end, count| {
		# The run and the four bytes hashed past it stay inside the input.
		# Stated against the input's own length, that lets the hash read on
		# every skipped byte drop its bounds test.
		end = in_next0.plus_wrap(count)
		if end.plus_wrap(5) > in_end or in_end > List.len(input) {
			Ok({
				tab: tab_0,
				in_cur_base: base_0,
				next_hash3: nh3_0,
				next_hash4: nh4_0,
			})
		} else {
			var $tab = tab_0
			var $base = base_0
			var $cur_pos = in_next0.minus_wrap(base_0).to_i64_wrap()
			# One slide covers the whole run, since a match is far shorter than
			# a window. Positions past the slide go in already relative to the
			# new base.
			if $cur_pos.plus_wrap(count.to_i64_wrap()).minus_wrap(1) >= Matchfinder.window_size.to_i64_wrap() {
				$tab = Matchfinder.rebase_nodes($tab)
				$base = $base.plus_wrap(Matchfinder.window_size)
				$cur_pos = $cur_pos.minus_wrap(Matchfinder.window_size.to_i64_wrap())
			} else {
			}
			# The table holds all three regions, and the incoming hashes are
			# already reduced to their region's size. Establishing both once
			# here lets the bounds test on every table access in the loop fold
			# away instead of running per byte.
			if List.len($tab) < HcMatchfinder.table_size
				or nh3_0 >= HcMatchfinder.hash3_size
				or nh4_0 >= HcMatchfinder.hash4_size {
				crash "HcMatchfinder.skip_bytes: hash-chain tables too short or hash out of range"
			} else {
			}
			# Wrapping arithmetic: the run was bounded against the input above and
			# the table indices are a region base plus a reduced hash, so nothing
			# here can overflow and a checked add would only cost a branch per byte.
			var $in_next = in_next0
			var $hash3 = nh3_0
			var $hash4 = nh4_0
			while $in_next < end {
				pos = $cur_pos.plus_wrap(Matchfinder.node_bias.to_i64_wrap()).to_u16_wrap()
				slot = HcMatchfinder.next_base.plus_wrap($cur_pos.to_u64_wrap().bitwise_and(32767))
				prev_head = List.get($tab, HcMatchfinder.hash4_base.plus_wrap($hash4)) ?? 0
				tab1 = match List.set($tab, HcMatchfinder.hash3_base.plus_wrap($hash3), pos) {
					Ok(next) => next
					Err(_) => crash "HcMatchfinder.skip_bytes: tab index out of bounds"
				}
				tab2 = match List.set(tab1, slot, prev_head) {
					Ok(next) => next
					Err(_) => crash "HcMatchfinder.skip_bytes: tab1 index out of bounds"
				}
				$tab = match List.set(tab2, HcMatchfinder.hash4_base.plus_wrap($hash4), pos) {
					Ok(next) => next
					Err(_) => crash "HcMatchfinder.skip_bytes: tab2 index out of bounds"
				}
				$in_next = $in_next.plus_wrap(1)
				next_hashseq = U32.from_le_bytes(input, $in_next) ?? 0
				$hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
				$hash4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
				$cur_pos = $cur_pos.plus_wrap(1)
			}
			Ok({
				tab: $tab,
				in_cur_base: $base,
				next_hash3: $hash3,
				next_hash4: $hash4,
			})
		}
	}
}
