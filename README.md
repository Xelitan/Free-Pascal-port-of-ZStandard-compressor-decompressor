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

Add ZstdSimple to your uses. These functions are available:

```
function ZStd(Uncompressed: AnsiString): AnsiString;
function UnZSTD(Compressed: AnsiString): AnsiString;
function ZStdCompressFile(const Infilename, Outfilename: String): Integer;
function ZStdDecompressFile(const Infilename, Outfilename: String): Integer;
```

## License

BSD
