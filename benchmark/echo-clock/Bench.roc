import pf.Host exposing [echo!, now!]
import deflate.Deflate

Bench := [].{
	# The clock chooses the first case, so neither the selected input stream's
	# level nor the compression can be evaluated at compile time. Every case
	# still runs exactly once; only the order changes.
	run! : List(U8), List({ level : U64, expected : List(U8) }), U64 => {}
	run! = |input, cases, reps| {
		count = cases.len()
		first_case = now!() % count
		var $case = 0.U64
		while $case < count {
			item = List.get(cases, (first_case + $case) % count) ?? crash "missing case"
			level = Deflate.Level.from_u64(item.level) ?? crash "bad level"
			first = Deflate.compress(input, level)
			if first != item.expected {
				crash "libdeflate output differs"
			}
			decoded = Deflate.decompress(first) ?? crash "decompression failed"
			if decoded != input {
				crash "round-trip differs"
			}
			var $buf = List.with_capacity(Deflate.compress_bound(input.len()))
			var $rep = 0.U64
			while $rep < reps {
				empty = List.clear($buf)
				start = now!()
				$buf = Deflate.compress_into(input, level, empty)
				elapsed = now!() - start
				# Checking every repetition is outside the timed region.
				if $buf != item.expected {
					crash "timed output differs"
				}
				echo!("rep\t${item.level.to_str()}\t${$rep.to_str()}\t${elapsed.to_str()}\t${$buf.len().to_str()}")
				$rep = $rep + 1
			}
			$case = $case + 1
		}
	}
}
