# Test corpus

`canterbury.bin` is the [Canterbury Corpus](http://corpus.canterbury.ac.nz/),
the standard corpus for lossless-compression benchmarking. Its 11 files are
concatenated in sorted filename order into a single deterministic blob, which
`tests/ratios.roc` compresses to guard against ratio regressions.

Committing it keeps the ratio gate offline and byte-identical across machines
and over time, independent of the compiler `roc-src` revision.

## Provenance

- Source: `http://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz`
  (sha256 `f140e8a5b73d3f53198555a63bfb827889394a42f20825df33c810c3d5e3f8fb`)
- `canterbury.bin`: 2,810,784 bytes,
  sha256 `0737d6c25a3337923a1429471546118448f07133e55c8f43fadde7984384982c`

Rebuild it from the tarball with:

```sh
curl -fsSL http://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz | tar -xz -C "$tmp"
(cd "$tmp" && find . -type f | LC_ALL=C sort | xargs cat) > canterbury.bin
```

## Files (sorted order)

| File | Bytes | Content |
| --- | --- | --- |
| `alice29.txt` | 152,089 | English text (Alice in Wonderland) |
| `asyoulik.txt` | 125,179 | Shakespeare play |
| `cp.html` | 24,603 | HTML |
| `fields.c` | 11,150 | C source |
| `grammar.lsp` | 3,721 | Lisp source |
| `kennedy.xls` | 1,029,744 | Excel spreadsheet (binary) |
| `lcet10.txt` | 426,754 | Technical writing |
| `plrabn12.txt` | 481,861 | Poetry |
| `ptt5` | 513,216 | CCITT fax image (binary) |
| `sum` | 38,240 | SPARC executable (binary) |
| `xargs.1` | 4,227 | man page (troff) |
