# zstd — Free Pascal Port

Zstandard (zstd) compression algorithm ported to Free Pascal.

Based on the C reference implementation (v1.4.8) from https://github.com/facebook/zstd

## Usage

```bash
# Compress
zstd-pas c input.txt input.txt.zst

# Decompress
zstd-pas d input.txt.zst output.txt
```

## Structure

- `common/` — Shared types, MEM functions, error handling, bitstream, FSE/Huffman tables, xxHash
- `compress/` — Compression engine (all strategies: fast, dfast, greedy, lazy, btopt, btultra)
- `decompress/` — Decompression engine
- `dictBuilder/` — Dictionary training (cover, fastcover, divsufsort)

## Not yet ported

- Multi-threaded compression (`zstdmt_compress`)
- Legacy format support

## Using as a library

Just copy functions from zstd-pas.lpr to your program. There are:

```
function ZStd(Uncompressed: AnsiString): AnsiString;
function UnZSTD(Compressed: AnsiString): AnsiString;
function CompressFile(Infilename, Outfilename: String): Integer;
function DecompressFile(Infilename, Outfilename: String): Integer;
```

In next realese these functions will move to a separate unit.

## License

BSD
