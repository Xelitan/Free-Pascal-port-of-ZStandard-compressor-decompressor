unit zstd_compressf;
{$mode objfpc}{$H+}
interface
uses 
{-*************************************
*  Dependencies
**************************************}
hist,           { HIST_countFast_wksp }
fse,
huf,ZSTD_CWKSPF,ZSTD_COMPRESS_internal,zstd_common,error_private,ZSTD_internal,zstd_ldm,bitstream,ZSTD_COMPRESS_LITERALS,
zstd_compress_sequences,zstd,math,xxHash,zstd_fastf,ZSTD_DOUBLE_FAST,zstd_lazyf,zstd_opt,zstd_compress_superblock
,huf_compress,entropy_common,fse_compress;
//zstd_compress_literals,
//zstd_fast,
//zstd_double_fast,
//zstd_lazy,
//zstd_opt,
//zstd_ldm,
//zstd_compress_superblock;

{ ***************************************************************
*  Tuning parameters
****************************************************************}
{not 
 * COMPRESS_HEAPMODE :
 * Select how default decompression function ZSTD_compress() allocates its context,
 * on stack (0, default), or into heap (1).
 * Note that functions with explicit context such as ZSTD_compressCCtx() are unaffected.
 }
const 
  ZSTD_COMPRESS_HEAPMODE = 0;
  ZSTD_MAX_CLEVEL    = 22;
  ZSTD_ROWSIZE  = 16;
  ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF = (128 * 1024 );
  ZSTD_USE_CDICT_PARAMS_DICTSIZE_MULTIPLIER:int64 = 6;
  ZSTD_INDEXOVERFLOW_MARGIN = (16 * 1024 * 1024 );
  ZSTDMT_JOBSIZE_MIN = 1024*1024;
  ZSTDMT_JOBLOG_MAX = 30;//29 for 32 bit CPU
  ZSTDMT_JOBSIZE_MAX = 1024*1024*1024; //512 *1024*1024 for 32 bit CPU
{-==:=  Pre-defined compression levels  ==:=-}
   ZSTD_defaultCParameters: array [0..3,0..ZSTD_MAX_CLEVEL] of ZSTD_compressionParameters = (
(   { 'default' - for any srcSize > 256 KB }
    { W;  C;  H;  S;  L; TL; strat }
    ( windowLog:19; chainLog:12; hashLog:13;  searchLog:1;  minMatch:6;targetLength:  1; strategy:ZSTD_fast    ),  { base for negative levels }
    ( windowLog:19; chainLog:13; hashLog:14;  searchLog:1;  minMatch:7;targetLength:  0; strategy:ZSTD_fast    ),  { level  1 }
    ( windowLog:20; chainLog:15; hashLog:16;  searchLog:1;  minMatch:6;targetLength:  0; strategy:ZSTD_fast    ),  { level  2 }
    ( windowLog:21; chainLog:16; hashLog:17;  searchLog:1;  minMatch:5;targetLength:  0; strategy:ZSTD_dfast   ),  { level  3 }
    ( windowLog:21; chainLog:18; hashLog:18;  searchLog:1;  minMatch:5;targetLength:  0; strategy:ZSTD_dfast   ),  { level  4 }
    ( windowLog:21; chainLog:18; hashLog:19;  searchLog:2;  minMatch:5;targetLength:  2; strategy:ZSTD_greedy  ),  { level  5 }
    ( windowLog:21; chainLog:19; hashLog:19;  searchLog:3;  minMatch:5;targetLength:  4; strategy:ZSTD_greedy  ),  { level  6 }
    ( windowLog:21; chainLog:19; hashLog:19;  searchLog:3;  minMatch:5;targetLength:  8; strategy:ZSTD_lazy    ),  { level  7 }
    ( windowLog:21; chainLog:19; hashLog:19;  searchLog:3;  minMatch:5;targetLength: 16; strategy:ZSTD_lazy2   ),  { level  8 }
    ( windowLog:21; chainLog:19; hashLog:20;  searchLog:4;  minMatch:5;targetLength: 16; strategy:ZSTD_lazy2   ),  { level  9 }
    ( windowLog:22; chainLog:20; hashLog:21;  searchLog:4;  minMatch:5;targetLength: 16; strategy:ZSTD_lazy2   ),  { level 10 }
    ( windowLog:22; chainLog:21; hashLog:22;  searchLog:4;  minMatch:5;targetLength: 16; strategy:ZSTD_lazy2   ),  { level 11 }
    ( windowLog:22; chainLog:21; hashLog:22;  searchLog:5;  minMatch:5;targetLength: 16; strategy:ZSTD_lazy2   ),  { level 12 }
    ( windowLog:22; chainLog:21; hashLog:22;  searchLog:5;  minMatch:5;targetLength: 32; strategy:ZSTD_btlazy2 ),  { level 13 }
    ( windowLog:22; chainLog:22; hashLog:23;  searchLog:5;  minMatch:5;targetLength: 32; strategy:ZSTD_btlazy2 ),  { level 14 }
    ( windowLog:22; chainLog:23; hashLog:23;  searchLog:6;  minMatch:5;targetLength: 32; strategy:ZSTD_btlazy2 ),  { level 15 }
    ( windowLog:22; chainLog:22; hashLog:22;  searchLog:5;  minMatch:5;targetLength: 48; strategy:ZSTD_btopt   ),  { level 16 }
    ( windowLog:23; chainLog:23; hashLog:22;  searchLog:5;  minMatch:4;targetLength: 64; strategy:ZSTD_btopt   ),  { level 17 }
    ( windowLog:23; chainLog:23; hashLog:22;  searchLog:6;  minMatch:3;targetLength: 64; strategy:ZSTD_btultra ),  { level 18 }
    ( windowLog:23; chainLog:24; hashLog:22;  searchLog:7;  minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 19 }
    ( windowLog:25; chainLog:25; hashLog:23;  searchLog:7;  minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 20 }
    ( windowLog:26; chainLog:26; hashLog:24;  searchLog:7;  minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 21 }
    ( windowLog:27; chainLog:27; hashLog:25;  searchLog:9;  minMatch:3;targetLength:999; strategy:ZSTD_btultra2)  { level 22 }
),
(   { for srcSize <= 256 KB }
    { W;  C;  H;  S;  L;  T; strat }
    ( windowLog:18; chainLog:12; hashLog:13; searchLog: 1;  minMatch:5;targetLength:  1; strategy:ZSTD_fast    ),  { base for negative levels }
    ( windowLog:18; chainLog:13; hashLog:14; searchLog: 1;  minMatch:6;targetLength:  0; strategy:ZSTD_fast    ),  { level  1 }
    ( windowLog:18; chainLog:14; hashLog:14; searchLog: 1;  minMatch:5;targetLength:  0; strategy:ZSTD_dfast   ),  { level  2 }
    ( windowLog:18; chainLog:16; hashLog:16; searchLog: 1;  minMatch:4;targetLength:  0; strategy:ZSTD_dfast   ),  { level  3 }
    ( windowLog:18; chainLog:16; hashLog:17; searchLog: 2;  minMatch:5;targetLength:  2; strategy:ZSTD_greedy  ),  { level  4.}
    ( windowLog:18; chainLog:18; hashLog:18; searchLog: 3;  minMatch:5;targetLength:  2; strategy:ZSTD_greedy  ),  { level  5.}
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 3;  minMatch:5;targetLength:  4; strategy:ZSTD_lazy    ),  { level  6.}
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 4;  minMatch:4;targetLength:  4; strategy:ZSTD_lazy    ),  { level  7 }
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 4;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  8 }
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 5;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  9 }
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 6;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level 10 }
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 5;  minMatch:4;targetLength: 12; strategy:ZSTD_btlazy2 ),  { level 11.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog: 7;  minMatch:4;targetLength: 12; strategy:ZSTD_btlazy2 ),  { level 12.}
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 4;  minMatch:4;targetLength: 16; strategy:ZSTD_btopt   ),  { level 13 }
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 4;  minMatch:3;targetLength: 32; strategy:ZSTD_btopt   ),  { level 14.}
    ( windowLog:18; chainLog:18; hashLog:19; searchLog: 6;  minMatch:3;targetLength:128; strategy:ZSTD_btopt   ),  { level 15.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog: 6;  minMatch:3;targetLength:128; strategy:ZSTD_btultra ),  { level 16.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog: 8;  minMatch:3;targetLength:256; strategy:ZSTD_btultra ),  { level 17.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog: 6;  minMatch:3;targetLength:128; strategy:ZSTD_btultra2),  { level 18.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog: 8;  minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 19.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog:10;  minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 20.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog:12;  minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 21.}
    ( windowLog:18; chainLog:19; hashLog:19; searchLog:13;  minMatch:3;targetLength:999; strategy:ZSTD_btultra2)  { level 22.}
),
(  { for srcSize <= 128 KB }
    { W;  C;  H;  S;  L;  T; strat }
    ( windowLog:17; chainLog:12; hashLog:12; searchLog: 1;  minMatch:5;targetLength:  1; strategy:ZSTD_fast    ),  { base for negative levels }
    ( windowLog:17; chainLog:12; hashLog:13; searchLog: 1;  minMatch:6;targetLength:  0; strategy:ZSTD_fast    ),  { level  1 }
    ( windowLog:17; chainLog:13; hashLog:15; searchLog: 1;  minMatch:5;targetLength:  0; strategy:ZSTD_fast    ),  { level  2 }
    ( windowLog:17; chainLog:15; hashLog:16; searchLog: 2;  minMatch:5;targetLength:  0; strategy:ZSTD_dfast   ),  { level  3 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 2;  minMatch:4;targetLength:  0; strategy:ZSTD_dfast   ),  { level  4 }
    ( windowLog:17; chainLog:16; hashLog:17; searchLog: 3;  minMatch:4;targetLength:  2; strategy:ZSTD_greedy  ),  { level  5 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 3;  minMatch:4;targetLength:  4; strategy:ZSTD_lazy    ),  { level  6 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 3;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  7 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 4;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  8 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 5;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  9 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 6;  minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level 10 }
    ( windowLog:17; chainLog:17; hashLog:17; searchLog: 5;  minMatch:4;targetLength:  8; strategy:ZSTD_btlazy2 ),  { level 11 }
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 7;  minMatch:4;targetLength: 12; strategy:ZSTD_btlazy2 ),  { level 12 }
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 3;  minMatch:4;targetLength: 12; strategy:ZSTD_btopt   ),  { level 13.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 4;  minMatch:3;targetLength: 32; strategy:ZSTD_btopt   ),  { level 14.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 6;  minMatch:3;targetLength:256; strategy:ZSTD_btopt   ),  { level 15.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 6;  minMatch:3;targetLength:128; strategy:ZSTD_btultra ),  { level 16.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 8;  minMatch:3;targetLength:256; strategy:ZSTD_btultra ),  { level 17.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog:10;  minMatch:3;targetLength:512; strategy:ZSTD_btultra ),  { level 18.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 5;  minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 19.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 7;  minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 20.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog: 9;  minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 21.}
    ( windowLog:17; chainLog:18; hashLog:17; searchLog:11;  minMatch:3;targetLength:999; strategy:ZSTD_btultra2)  { level 22.}
),
(   { for srcSize <= 16 KB }
    { W;  C;  H;  S;  L;  T; strat }
    ( windowLog:14; chainLog:12; hashLog:13; searchLog: 1;   minMatch:5;targetLength:  1; strategy:ZSTD_fast    ),  { base for negative levels }
    ( windowLog:14; chainLog:14; hashLog:15; searchLog: 1;   minMatch:5;targetLength:  0; strategy:ZSTD_fast    ),  { level  1 }
    ( windowLog:14; chainLog:14; hashLog:15; searchLog: 1;   minMatch:4;targetLength:  0; strategy:ZSTD_fast    ),  { level  2 }
    ( windowLog:14; chainLog:14; hashLog:15; searchLog: 2;   minMatch:4;targetLength:  0; strategy:ZSTD_dfast   ),  { level  3 }
    ( windowLog:14; chainLog:14; hashLog:14; searchLog: 4;   minMatch:4;targetLength:  2; strategy:ZSTD_greedy  ),  { level  4 }
    ( windowLog:14; chainLog:14; hashLog:14; searchLog: 3;   minMatch:4;targetLength:  4; strategy:ZSTD_lazy    ),  { level  5.}
    ( windowLog:14; chainLog:14; hashLog:14; searchLog: 4;   minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  6 }
    ( windowLog:14; chainLog:14; hashLog:14; searchLog: 6;   minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  7 }
    ( windowLog:14; chainLog:14; hashLog:14; searchLog: 8;   minMatch:4;targetLength:  8; strategy:ZSTD_lazy2   ),  { level  8.}
    ( windowLog:14; chainLog:15; hashLog:14; searchLog: 5;   minMatch:4;targetLength:  8; strategy:ZSTD_btlazy2 ),  { level  9.}
    ( windowLog:14; chainLog:15; hashLog:14; searchLog: 9;   minMatch:4;targetLength:  8; strategy:ZSTD_btlazy2 ),  { level 10.}
    ( windowLog:14; chainLog:15; hashLog:14; searchLog: 3;   minMatch:4;targetLength: 12; strategy:ZSTD_btopt   ),  { level 11.}
    ( windowLog:14; chainLog:15; hashLog:14; searchLog: 4;   minMatch:3;targetLength: 24; strategy:ZSTD_btopt   ),  { level 12.}
    ( windowLog:14; chainLog:15; hashLog:14; searchLog: 5;   minMatch:3;targetLength: 32; strategy:ZSTD_btultra ),  { level 13.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 6;   minMatch:3;targetLength: 64; strategy:ZSTD_btultra ),  { level 14.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 7;   minMatch:3;targetLength:256; strategy:ZSTD_btultra ),  { level 15.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 5;   minMatch:3;targetLength: 48; strategy:ZSTD_btultra2),  { level 16.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 6;   minMatch:3;targetLength:128; strategy:ZSTD_btultra2),  { level 17.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 7;   minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 18.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 8;   minMatch:3;targetLength:256; strategy:ZSTD_btultra2),  { level 19.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 8;   minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 20.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog: 9;   minMatch:3;targetLength:512; strategy:ZSTD_btultra2),  { level 21.}
    ( windowLog:14; chainLog:15; hashLog:15; searchLog:10;   minMatch:3;targetLength:999; strategy:ZSTD_btultra2)  { level 22.}
)
);
{ These are the approximate sizes for each strategy past which copying the
 * dictionary tables into the working context is faster than using them
 * in-place.
 }
 attachDictSizeCutoffs:array [0..9{ZSTD_STRATEGY_MAX}] of int32 = (
    8  * 1024,  { unused }
    8  * 1024,  { ZSTD_fast }
    16 * 1024, { ZSTD_dfast }
    32 * 1024, { ZSTD_greedy }
    32 * 1024, { ZSTD_lazy }
    32 * 1024, { ZSTD_lazy2 }
    32 * 1024, { ZSTD_btlazy2 }
    32 * 1024, { ZSTD_btopt }
    8  * 1024,  { ZSTD_btultra }
    8  * 1024   { ZSTD_btultra2 }
);
type
{*
 * Controls, for this matchState reset, whether the tables need to be cleared /
 * prepared for the coming compression (ZSTDcrp_makeClean), or whether the
 * tables can be left unclean (ZSTDcrp_leaveDirty), because we know that a
 * subsequent operation will overwrite the table space anyways (e.g., copying
 * the matchState contents in from a CDict).
 }
ZSTD_compResetPolicy_e=(
    ZSTDcrp_makeClean,
    ZSTDcrp_leaveDirty
);

{*
 * Controls, for this matchState reset, whether indexing can continue where it
 * left off (ZSTDirp_continue), or whether it needs to be restarted from zero
 * (ZSTDirp_reset).
 }
ZSTD_indexResetPolicy_e=(
    ZSTDirp_continue,
    ZSTDirp_reset
);

ZSTD_resetTarget_e=(
    ZSTD_resetTarget_CDict,
    ZSTD_resetTarget_CCtx
);
ZSTD_buildSeqStore_e = ( ZSTDbss_compress, ZSTDbss_noCompress );
{-*************************************
*  Context memory management
**************************************}

ZSTD_sequenceCopier=function(cctx:pZSTD_CCtx; seqPos:pZSTD_sequencePosition;
                                       inSeqs:pZSTD_Sequence;inSeqsSize:int32;
                                       src:pbyte;blockSize:int32):int32;
function ZSTD_cParam_getBounds(param:ZSTD_cParameter):ZSTD_bounds;
function ZSTD_CCtx_reset(cctx:pZSTD_CCtx; reset:ZSTD_ResetDirective):int32;
function ZSTD_freeCDict(cdict:pZSTD_CDict):int32;
function ZSTD_sizeof_CDict(cdict:pZSTD_CDict):int32;
function ZSTD_CCtxParams_init(cctxParams:pZSTD_CCtx_params; compressionLevel:int32):int32;
//procedure ZSTD_ldm_adjustParameters(params:pldmParams_t;cParams:pZSTD_compressionParameters);
function ZSTD_checkCParams(cParams:ZSTD_compressionParameters):int32;
function ZSTD_maxCLevel():int32; 
function ZSTD_minCLevel():int32;
function ZSTD_compress_usingCDict(cctx:pZSTD_CCtx;
                                dst:pbyte;  dstCapacity:int32;
                                src:pbyte;  srcSize:int32;
                                const cdict:pZSTD_CDict):int32;
function ZSTD_createCDict(dict:pbyte;dictSize:int32; compressionLevel:int32):pZSTD_CDict;
function ZSTD_freeCCtx(cctx:pZSTD_CCtx):int32;
function ZSTD_createCDict_advanced2(
        dict:pbyte;dictSize:int32;
        dictLoadMethod:ZSTD_dictLoadMethod_e;
        dictContentType:ZSTD_dictContentType_e;
        const originalCctxParams:pZSTD_CCtx_params;
        customMem:ZSTD_customMem):pZSTD_CDict;
function ZSTD_CCtx_refPrefix_advanced(
        cctx:pZSTD_CCtx; prefix:pbyte;prefixSize:int32; dictContentType:ZSTD_dictContentType_e):int32;
function ZSTD_getCParams_internal(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):ZSTD_compressionParameters;
function ZSTD_referenceExternalSequences(cctx:pZSTD_CCtx;seq:prawSeq;nbSeq:int32):int32;
procedure ZSTD_dedicatedDictSearch_revertCParams(cParams:pZSTD_compressionParameters);
procedure ZSTD_resetSeqStore(ssPtr:pseqStore_t);
function ZSTD_compress2(cctx:pZSTD_CCtx;
                      dst:pbyte;  dstCapacity:int32;
                      const src:pbyte;srcSize:int32):int32;
procedure ZSTD_seqToCodes(const seqStorePtr:pseqStore_t);
function ZSTD_getParams_internal(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):ZSTD_parameters;
function ZSTD_getCParams(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32):ZSTD_compressionParameters;
function ZSTD_compressStream2( cctx:pZSTD_CCtx;output:pZSTD_outBuffer;
  input:pZSTD_inBuffer;endOp:ZSTD_EndDirective):int32;
function ZSTD_CCtxParams_setParameter(cctxParams:pZSTD_CCtx_params;param:ZSTD_cParameter;value:int32):int32;
function ZSTD_CCtxParams_getParameter(cctxParams:pZSTD_CCtx_params;param:ZSTD_cParameter;value:pint32):int32;
function ZSTD_selectBlockCompressor(strat:ZSTD_strategy;dictMode:ZSTD_dictMode_e):ZSTD_blockCompressor;
procedure ZSTD_reset_compressedBlockState(bs:pZSTD_compressedBlockState_t);
function ZSTD_loadCEntropy(bs:pZSTD_compressedBlockState_t; workspace:pbyte;
                         dict:pbyte; dictSize:int32):int32;
function ZSTD_compressBegin_usingCDict_advanced(
    cctx:pZSTD_CCtx;cdict:pZSTD_CDict;
    fParams:ZSTD_frameParameters;pledgedSrcSize:uint64):int32;
function ZSTD_compressBegin_usingCDict(cctx:pZSTD_CCtx; const cdict:pZSTD_CDict):int32;
function ZSTD_compressBlock(cctx:pZSTD_CCtx; dst:pbyte;  dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
function ZSTD_getSeqStore(const ctx:pZSTD_CCtx):pseqStore_t;
function ZSTD_getParams(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32):ZSTD_parameters;
function ZSTD_createCDict_advanced_internal(dictSize:int32;dictLoadMethod:ZSTD_dictLoadMethod_e;
  cParams:ZSTD_compressionParameters; customMem:ZSTD_customMem):pZSTD_CDict;
function ZSTD_createCDict_advanced(const dictBuffer:pbyte; dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e;
  cParams:ZSTD_compressionParameters;customMem:ZSTD_customMem):pZSTD_CDict;
function ZSTD_createCCtx():pZSTD_CCtx;
function ZSTD_compressBound(srcSize:int32):int32; 
function ZSTD_compress(dst:pbyte; dstCapacity:int32;
  src:pbyte;  srcSize:int32;compressionLevel:int32):int32;
function ZSTD_CCtx_setParameter(cctx:pZSTD_CCtx; param:ZSTD_cParameter;value:int32):int32;
implementation
{-*************************************
*  Helper functions
**************************************}
{ ZSTD_compressBound()
 * Note that the result from this function is only compatible with the 'normal'
 * full-block strategy.
 * When there are a lot of small blocks due to frequent flush in streaming mode
 * the overhead of headers can make the compressed data to be larger than the
 * return value of ZSTD_compressBound().
 }
function ZSTD_compressBound(srcSize:int32):int32; 
begin
    { C macro: ((srcSize) + ((srcSize)>>8) + (((srcSize) < (128<<10)) ? (((128<<10) - (srcSize)) >> 11) : 0)) }
    result := srcSize + (srcSize shr 8);
    if srcSize < (128 shl 10) then
      result := result + (((128 shl 10) - srcSize) shr 11);
end;



procedure ZSTD_initCCtx(cctx:pZSTD_CCtx; memManager:ZSTD_customMem);
var
  err:int32;
begin
    assert(cctx <> nil);
    fillbyte(cctx^, sizeof(ZSTD_CCtx), 0);
    cctx^.customMem := memManager;
    //cctx^.bmi2 := ZSTD_cpuid_bmi2(ZSTD_cpuid());
     
    err := ZSTD_CCtx_reset(cctx, ZSTD_reset_parameters);
    //assert(not ZSTD_isError(err));
end;

function ZSTD_createCCtx_advanced(customMem:ZSTD_customMem):pZSTD_CCtx;
var
  cctx:pZSTD_CCtx;
begin
    ////ZSTD_STATIC_ASSERT(zcss_init=0);
    ////ZSTD_STATIC_ASSERT(ZSTD_CONTENTSIZE_UNKNOWN=(0ULL - 1));
    if ((customMem.customAlloc=nil) xor (customMem.customFree=nil)) then
      exit(nil);
 
    cctx := pZSTD_CCtx(ZSTD_customMalloc(sizeof(ZSTD_CCtx), customMem));
    if (cctx=nil) then
      exit(nil);
    ZSTD_initCCtx(cctx, customMem);
    result := cctx;
end;
function ZSTD_createCCtx():pZSTD_CCtx;
begin
    result := ZSTD_createCCtx_advanced(ZSTD_defaultCMem);
end;
function ZSTD_initStaticCCtx(workspace:pbyte; workspaceSize:int32 ):pZSTD_CCtx;
var
  ws:ZSTD_cwksp;
  cctx:pZSTD_CCtx;
begin
    if (workspaceSize <= sizeof(ZSTD_CCtx)) then
      exit(nil);  { minimum size }
    if (PtrUInt(workspace) and 7)<>0 then
      exit(nil);  { must be 8-aligned }
    ZSTD_cwksp_init(@ws, workspace, workspaceSize, ZSTD_cwksp_static_alloc);

    cctx := pZSTD_CCtx(ZSTD_cwksp_reserve_object(@ws, sizeof(ZSTD_CCtx)));
    if (cctx = nil) then
      exit(nil);

    fillbyte(cctx^, sizeof(ZSTD_CCtx), 0);
    ZSTD_cwksp_move(@cctx^.workspace, @ws);
    cctx^.staticSize := workspaceSize;

    { statically sized space. entropyWorkspace never moves (but prev/next block swap places) }
    if (ZSTD_cwksp_check_available(@cctx^.workspace, ENTROPY_WORKSPACE_SIZE + 2 * sizeof(ZSTD_compressedBlockState_t))=0) then
      exit(nil);
    cctx^.blockState.prevCBlock := pZSTD_compressedBlockState_t(ZSTD_cwksp_reserve_object(@cctx^.workspace, sizeof(ZSTD_compressedBlockState_t)));
    cctx^.blockState.nextCBlock := pZSTD_compressedBlockState_t(ZSTD_cwksp_reserve_object(@cctx^.workspace, sizeof(ZSTD_compressedBlockState_t)));
    cctx^.entropyWorkspace := puint32(ZSTD_cwksp_reserve_object(@cctx^.workspace, ENTROPY_WORKSPACE_SIZE));
    //cctx^.bmi2 := ZSTD_cpuid_bmi2(ZSTD_cpuid());
    result := cctx;
end;

{*
 * Clears and frees all of the dictionaries in the CCtx.
 }
procedure ZSTD_clearAllDicts(cctx:pZSTD_CCtx);
begin
    ZSTD_customfree(cctx^.localDict.dictBuffer, cctx^.customMem);
    ZSTD_freeCDict(cctx^.localDict.cdict);
    fillbyte(cctx^.localDict , sizeof(cctx^.localDict) , 0);
    fillbyte(cctx^.prefixDict, sizeof(cctx^.prefixDict), 0);
    cctx^.cdict := nil;
end;

function ZSTD_sizeof_localDict(dict:ZSTD_localDict):int32;
var
  bufferSize,cdictSize:int32;
begin
  if dict.dictBuffer <> nil then
    bufferSize := dict.dictSize
  else
    bufferSize := 0;
  cdictSize := ZSTD_sizeof_CDict(dict.cdict);
  result := bufferSize + cdictSize;
end;

procedure ZSTD_freeCCtxContent(cctx:pZSTD_CCtx);
begin
    assert(cctx <> nil);
    assert(cctx^.staticSize = 0);
    ZSTD_clearAllDicts(cctx);
    ZSTD_cwksp_freemem(@cctx^.workspace, cctx^.customMem);
end;

function ZSTD_freeCCtx(cctx:pZSTD_CCtx):int32;
var
  cctxInWorkspace:int32;
begin
    if (cctx=nil) then
      exit(0);   { support free on nil }
    if cctx^.staticSize<>0 then
    begin
      //log(3, ' memory_allocation not compatible with static CCtx');
      exit(ERROR(memory_allocation));
    end;
    cctxInWorkspace := ZSTD_cwksp_owns_buffer(@cctx^.workspace, pbyte(cctx));
    ZSTD_freeCCtxContent(cctx);
    if (cctxInWorkspace=0) then
    begin
        ZSTD_customfree(pbyte(cctx), cctx^.customMem);
    end;

    result := 0;
end;


function ZSTD_sizeof_mtctx(cctx:pZSTD_CCtx):int32;
begin
    exit(0);
end;


function ZSTD_sizeof_CCtx(cctx:pZSTD_CCtx):int32;
begin
    if (cctx=nil) then
      exit(0);   { support sizeof on nil }
    { cctx may be in the workspace }
    if cctx^.workspace.workspace = pbyte(cctx) then
      result := 0
           + ZSTD_cwksp_sizeof(@cctx^.workspace)
           + ZSTD_sizeof_localDict(cctx^.localDict)
           + ZSTD_sizeof_mtctx(cctx)
    else
        result := sizeof(ZSTD_CCtx)
           + ZSTD_cwksp_sizeof(@cctx^.workspace)
           + ZSTD_sizeof_localDict(cctx^.localDict)
           + ZSTD_sizeof_mtctx(cctx);
end;

function ZSTD_sizeof_CStream(const zcs:pZSTD_CStream):int32;
begin
    result := ZSTD_sizeof_CCtx(zcs);  { same object }
end;

{ private API call, for dictBuilder only }
function ZSTD_getSeqStore(const ctx:pZSTD_CCtx):pseqStore_t;
begin 
  result := @(ctx^.seqStore); 
end;

{ Returns 1 if compression parameters are such that we should
 * enable long distance matching (wlog >= 27, strategy >= btopt).
 * Returns 0 otherwise.
 }
function ZSTD_CParams_shouldEnableLdm(cParams:pZSTD_compressionParameters):uint32; 
begin
    result := ord( (cParams^.strategy >= ZSTD_btopt)  and  (cParams^.windowLog >= 27));
end;

function ZSTD_makeCCtxParamsFromCParams(cParams:ZSTD_compressionParameters):ZSTD_CCtx_params;
var
  cctxParams:ZSTD_CCtx_params;
begin
    { should not matter, as all cParams are presumed properly defined }
    ZSTD_CCtxParams_init(@cctxParams, ZSTD_CLEVEL_DEFAULT);
    cctxParams.cParams := cParams;

    if (ZSTD_CParams_shouldEnableLdm(@cParams)<>0) then
    begin
        ////log(3, 'ZSTD_makeCCtxParamsFromCParams(): Including LDM into cctx params');
        cctxParams.ldmParams.enableLdm := 1;
        { LDM is enabled by default for optimal parser and window size >= 128MB }
        ZSTD_ldm_adjustParameters(@cctxParams.ldmParams, @cParams);
        assert(cctxParams.ldmParams.hashLog >= cctxParams.ldmParams.bucketSizeLog);
        assert(cctxParams.ldmParams.hashRateLog < 32);
    end;

    assert(ZSTD_checkCParams(cParams)=0);
    result := cctxParams;
end;

function ZSTD_createCCtxParams_advanced(customMem:ZSTD_customMem):pZSTD_CCtx_params;
var
  params:pZSTD_CCtx_params;
begin
    if ((customMem.customAlloc=nil) xor (customMem.customFree=nil)) then
      exit(nil);
    params := pZSTD_CCtx_params(ZSTD_customCalloc(sizeof(ZSTD_CCtx_params), customMem));
    if (params=nil) then
      exit(nil);
    ZSTD_CCtxParams_init(params, ZSTD_CLEVEL_DEFAULT);
    params^.customMem := customMem;
    result := params;
end;

function ZSTD_createCCtxParams():pZSTD_CCtx_params;
begin
    result := ZSTD_createCCtxParams_advanced(ZSTD_defaultCMem);
end;

function ZSTD_freeCCtxParams(params:pZSTD_CCtx_params):int32;
begin
    if (params = nil) then
     exit(0);
    ZSTD_customfree(pbyte(params), params^.customMem);
    exit(0);
end;

function ZSTD_CCtxParams_reset(params:pZSTD_CCtx_params):int32;
begin
    result := ZSTD_CCtxParams_init(params, ZSTD_CLEVEL_DEFAULT);
end;

function ZSTD_CCtxParams_init(cctxParams:pZSTD_CCtx_params; compressionLevel:int32):int32;
begin
    if (cctxParams=nil) then
    begin
      ////log(3, 'nil pointernot ');
      exit(ERROR(GENERIC_ERROR));
    end;
    fillbyte(cctxParams^, sizeof(ZSTD_CCtx_params), 0);
    cctxParams^.compressionLevel := compressionLevel;
    cctxParams^.fParams.contentSizeFlag := 1;
    exit(0);
end;

function ZSTD_CCtxParams_init_advanced(cctxParams:pZSTD_CCtx_params; params:ZSTD_parameters):int32;
var
  err:int32;
begin
    IF (cctxParams=nil) then
    begin
        exit(ERROR(GENERIC_ERROR));
    end;
    err:=ZSTD_checkCParams(params.cParams);
    if (ERR_isError(err)<>0) then
       exit(err);
    fillbyte(cctxParams^, sizeof(ZSTD_CCtx_params), 0);
    assert(err=0);
    cctxParams^.cParams := params.cParams;
    cctxParams^.fParams := params.fParams;
    cctxParams^.compressionLevel := ZSTD_CLEVEL_DEFAULT;   { should not matter, as all cParams are presumed properly defined }
    exit(0);
end;

{ ZSTD_assignParamsToCCtxParams() :
 * params is presumed valid at this stage }
function ZSTD_assignParamsToCCtxParams(const cctxParams:pZSTD_CCtx_params; params:pZSTD_parameters):ZSTD_CCtx_params;
var
  ret:ZSTD_CCtx_params;
begin
    ret := cctxParams^;
    assert(ZSTD_checkCParams(params^.cParams)=0);
    ret.cParams := params^.cParams;
    ret.fParams := params^.fParams;
    ret.compressionLevel := ZSTD_CLEVEL_DEFAULT;   { should not matter, as all cParams are presumed properly defined }
    result := ret;
end;

function ZSTD_cParam_getBounds(param:ZSTD_cParameter):ZSTD_bounds;
const
  bounds:ZSTD_bounds=(error:0; lowerBound:0; upperBound:0);

begin
    case(param) of
      ZSTD_c_compressionLevel:
        begin
        bounds.lowerBound := ZSTD_minCLevel();
        bounds.upperBound := ZSTD_maxCLevel();
        end;

      ZSTD_c_windowLog:
        begin
        bounds.lowerBound := ZSTD_WINDOWLOG_MIN;
        bounds.upperBound := ZSTD_WINDOWLOG_MAX;
        end;

      ZSTD_c_hashLog:
        begin
        bounds.lowerBound := ZSTD_HASHLOG_MIN;
        bounds.upperBound := ZSTD_HASHLOG_MAX;
        end;

      ZSTD_c_chainLog:
        begin
        bounds.lowerBound := ZSTD_CHAINLOG_MIN;
        bounds.upperBound := ZSTD_CHAINLOG_MAX;
        end;

      ZSTD_c_searchLog:
        begin
        bounds.lowerBound := ZSTD_SEARCHLOG_MIN;
        bounds.upperBound := ZSTD_SEARCHLOG_MAX;
        end;

      ZSTD_c_minMatch:
        begin
        bounds.lowerBound := ZSTD_MINMATCH_MIN;
        bounds.upperBound := ZSTD_MINMATCH_MAX;
        end;

      ZSTD_c_targetLength:
        begin
        bounds.lowerBound := ZSTD_TARGETLENGTH_MIN;
        bounds.upperBound := ZSTD_TARGETLENGTH_MAX;
        end;

      ZSTD_c_strategy:
        begin
        bounds.lowerBound := ZSTD_STRATEGY_MIN;
        bounds.upperBound := ZSTD_STRATEGY_MAX;
        end;

      ZSTD_c_contentSizeFlag:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_checksumFlag:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_dictIDFlag:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_nbWorkers:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 0;
        end;

      ZSTD_c_jobSize:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 0;
        end;

      ZSTD_c_overlapLog:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 0;
        end;

      ZSTD_c_enableDedicatedDictSearch:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_enableLongDistanceMatching:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_ldmHashLog:
        begin
        bounds.lowerBound := ZSTD_LDM_HASHLOG_MIN;
        bounds.upperBound := ZSTD_LDM_HASHLOG_MAX;
        end;

      ZSTD_c_ldmMinMatch:
        begin
        bounds.lowerBound := ZSTD_LDM_MINMATCH_MIN;
        bounds.upperBound := ZSTD_LDM_MINMATCH_MAX;
        end;

      ZSTD_c_ldmBucketSizeLog:
        begin
        bounds.lowerBound := ZSTD_LDM_BUCKETSIZELOG_MIN;
        bounds.upperBound := ZSTD_LDM_BUCKETSIZELOG_MAX;
        end;

      ZSTD_c_ldmHashRateLog:
        begin
        bounds.lowerBound := ZSTD_LDM_HASHRATELOG_MIN;
        bounds.upperBound := ZSTD_LDM_HASHRATELOG_MAX;
        end;

    { experimental parameters }
      ZSTD_c_rsyncable:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_forceMaxWindow :
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      ZSTD_c_format:
        begin
        //ZSTD_STATIC_ASSERT(ZSTD_f_zstd1 < ZSTD_f_zstd1_magicless);
        bounds.lowerBound := ord(ZSTD_f_zstd1);
        bounds.upperBound := ord(ZSTD_f_zstd1_magicless);   { note : how to ensure at compile time that this is the highest value enum ? }
        end;

      ZSTD_c_forceAttachDict:
        begin
        //ZSTD_STATIC_ASSERT(ZSTD_dictDefaultAttach < ZSTD_dictForceLoad);
        bounds.lowerBound := ord(ZSTD_dictDefaultAttach);
        bounds.upperBound := ord(ZSTD_dictForceLoad);       { note : how to ensure at compile time that this is the highest value enum ? }
        end;

      ZSTD_c_literalCompressionMode:
        begin
        //ZSTD_STATIC_ASSERT(ZSTD_lcm_auto < ZSTD_lcm_huffman  and  ZSTD_lcm_huffman < ZSTD_lcm_uncompressed);
        bounds.lowerBound := ord(ZSTD_lcm_auto);
        bounds.upperBound := ord(ZSTD_lcm_uncompressed);
        end;

      ZSTD_c_targetCBlockSize: 
        begin
        bounds.lowerBound := ZSTD_TARGETCBLOCKSIZE_MIN;
        bounds.upperBound := ZSTD_TARGETCBLOCKSIZE_MAX;
        end;

      ZSTD_c_srcSizeHint:
        begin
        bounds.lowerBound := ZSTD_SRCSIZEHINT_MIN;
        bounds.upperBound := ZSTD_SRCSIZEHINT_MAX;
        end;

      ZSTD_c_stableInBuffer,
      ZSTD_c_stableOutBuffer:
        begin
        bounds.lowerBound := ord(ZSTD_bm_buffered);
        bounds.upperBound := ord(ZSTD_bm_stable);
        end;

      ZSTD_c_blockDelimiters:
        begin
        bounds.lowerBound := ord(ZSTD_sf_noBlockDelimiters);
        bounds.upperBound := ord(ZSTD_sf_explicitBlockDelimiters);
        end;

      ZSTD_c_validateSequences:
        begin
        bounds.lowerBound := 0;
        bounds.upperBound := 1;
        end;

      else
        begin
        bounds.error := ERROR(parameter_unsupported);
        end;
    end;
    result:=bounds;
end;

{ ZSTD_cParam_clampBounds:
 * Clamps the value into the bounded range.
 }
function ZSTD_cParam_clampBounds(cParam:ZSTD_cParameter; value:pint32):int32;
var
  bounds:ZSTD_bounds;
begin
    bounds := ZSTD_cParam_getBounds(cParam);
    if (ZSTD_isError(bounds.error)<>0) then
      exit(bounds.error);
    if (value^< bounds.lowerBound) then
      value^:= bounds.lowerBound;
    if (value^> bounds.upperBound) then
      value^:= bounds.upperBound;
    exit(0);
end;

function ZSTD_isUpdateAuthorized(param:ZSTD_cParameter):int32;
begin
    case (param) of
      ZSTD_c_compressionLevel,
      ZSTD_c_hashLog,
      ZSTD_c_chainLog,
      ZSTD_c_searchLog,
      ZSTD_c_minMatch,
      ZSTD_c_targetLength,
      ZSTD_c_strategy:exit(1);
      ZSTD_c_format,
      ZSTD_c_windowLog,
      ZSTD_c_contentSizeFlag,
      ZSTD_c_checksumFlag,
      ZSTD_c_dictIDFlag,
      ZSTD_c_forceMaxWindow ,
      ZSTD_c_nbWorkers,
      ZSTD_c_jobSize,
      ZSTD_c_overlapLog,
      ZSTD_c_rsyncable,
      ZSTD_c_enableDedicatedDictSearch,
      ZSTD_c_enableLongDistanceMatching,
      ZSTD_c_ldmHashLog,
      ZSTD_c_ldmMinMatch,
      ZSTD_c_ldmBucketSizeLog,
      ZSTD_c_ldmHashRateLog,
      ZSTD_c_forceAttachDict,
      ZSTD_c_literalCompressionMode,
      ZSTD_c_targetCBlockSize,
      ZSTD_c_srcSizeHint,
      ZSTD_c_stableInBuffer,
      ZSTD_c_stableOutBuffer,
      ZSTD_c_blockDelimiters,
      ZSTD_c_validateSequences:exit(0);
      else
          exit(0);
    end;
end;

function ZSTD_CCtx_setParameter(cctx:pZSTD_CCtx; param:ZSTD_cParameter;value:int32):int32;
begin
    ////log(3, 'ZSTD_CCtx_setParameter (%i, %i)', param, value);
    if (cctx^.streamStage <> zcss_init) then
    begin
        if (ZSTD_isUpdateAuthorized(param)<>0) then
        begin
            cctx^.cParamsChanged := 1;
        end
        else 
        begin
            EXIT(ERROR(stage_wrong));// 'can only set params in ctx init stage');
        end;   
    end;

    case(param) of
      ZSTD_c_nbWorkers:
        IF (value<>0)  and  (cctx^.staticSize<>0) then
          exit(ERROR(parameter_unsupported));//,'MT not compatible with static alloc');

      ZSTD_c_compressionLevel,
      ZSTD_c_windowLog,
      ZSTD_c_hashLog,
      ZSTD_c_chainLog,
      ZSTD_c_searchLog,
      ZSTD_c_minMatch,
      ZSTD_c_targetLength,
      ZSTD_c_strategy,
      ZSTD_c_ldmHashRateLog,
      ZSTD_c_format,
      ZSTD_c_contentSizeFlag,
      ZSTD_c_checksumFlag,
      ZSTD_c_dictIDFlag,
      ZSTD_c_forceMaxWindow,
      ZSTD_c_forceAttachDict,
      ZSTD_c_literalCompressionMode,
      ZSTD_c_jobSize,
      ZSTD_c_overlapLog,
      ZSTD_c_rsyncable,
      ZSTD_c_enableDedicatedDictSearch,
      ZSTD_c_enableLongDistanceMatching,
      ZSTD_c_ldmHashLog,
      ZSTD_c_ldmMinMatch,
      ZSTD_c_ldmBucketSizeLog,
      ZSTD_c_targetCBlockSize,
      ZSTD_c_srcSizeHint,
      ZSTD_c_stableInBuffer,
      ZSTD_c_stableOutBuffer,
      ZSTD_c_blockDelimiters,
      ZSTD_c_validateSequences:;
      else
       exit(ERROR(parameter_unsupported));// 'unknown parameter');
    end;
    result := ZSTD_CCtxParams_setParameter(@cctx^.requestedParams, param, value);
end;

function ZSTD_CCtxParams_setParameter(cctxParams:pZSTD_CCtx_params;param:ZSTD_cParameter;value:int32):int32;
var
  err:int32;
  pref:ZSTD_dictAttachPref_e;
  lcm:ZSTD_literalCompressionMode_e;
begin
    ////log(3, 'ZSTD_CCtxParams_setParameter (%i, %i)', param, value);
    case(param) of
      ZSTD_c_format:
      begin
        if (ZSTD_cParam_withinBounds(ZSTD_c_format, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.format := ZSTD_format_e(value);
        exit(ord(CCtxParams^.format));
      end;
      ZSTD_c_compressionLevel: 
      begin
        err:=ZSTD_cParam_clampBounds(param, @value);
        if (ERR_isError(err)<>0) then
           exit(err);
        if (value = 0) then
          CCtxParams^.compressionLevel := ZSTD_CLEVEL_DEFAULT { 0 = default }
        else
          CCtxParams^.compressionLevel := value;
        
        if (CCtxParams^.compressionLevel >= 0) then
          exit(CCtxParams^.compressionLevel);
        exit(0);  { return type (int32) cannot represent negative values }
      end;

      ZSTD_c_windowLog :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_windowLog, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.windowLog := uint32(value);
        exit(CCtxParams^.cParams.windowLog);
      end;
      ZSTD_c_hashLog :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_hashLog, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.hashLog := uint32(value);
        exit( CCtxParams^.cParams.hashLog);
      end;
      ZSTD_c_chainLog :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_chainLog, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.chainLog := uint32(value);
        exit( CCtxParams^.cParams.chainLog);
      end;
      ZSTD_c_searchLog :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_searchLog, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.searchLog := uint32(value);
        exit( value);
      end;
      ZSTD_c_minMatch :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_minMatch, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.minMatch := value;
        exit( CCtxParams^.cParams.minMatch);
      end;
      ZSTD_c_targetLength :
      begin
        if (ZSTD_cParam_withinBounds(ZSTD_c_targetLength, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.targetLength := value;
        exit( CCtxParams^.cParams.targetLength);
      end;
      ZSTD_c_strategy :
      begin
        if (value<>0) then  { 0 :=> use default }
        if (ZSTD_cParam_withinBounds(ZSTD_c_strategy, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.cParams.strategy := ZSTD_strategy(value);
        exit(ord(CCtxParams^.cParams.strategy));
      end;
      ZSTD_c_contentSizeFlag :
      begin
        { Content size written in frame header _when known_ (default:1) }
        ////log(3, 'set content size flag := %u', ord(value<>0));
        CCtxParams^.fParams.contentSizeFlag := ord(value <> 0);
        exit(CCtxParams^.fParams.contentSizeFlag);
      end;
      ZSTD_c_checksumFlag :
      begin
        { A 32-bits content checksum will be calculated and written at end of frame (default:0) }
        CCtxParams^.fParams.checksumFlag := ord(value <> 0);
        exit( CCtxParams^.fParams.checksumFlag);
      end;
      ZSTD_c_dictIDFlag : { When applicable, dictionary's dictID is provided in frame header (default:1) }
      begin
        ////log(3, 'set dictIDFlag := %u', (value<>0));
        CCtxParams^.fParams.noDictIDFlag := ord(value = 0);
        exit( not CCtxParams^.fParams.noDictIDFlag);
      end;
      ZSTD_c_forceMaxWindow :
      begin
        CCtxParams^.forceWindow := ord(value <> 0);
        exit( CCtxParams^.forceWindow);
      end;
      ZSTD_c_forceAttachDict : 
      begin
        pref := ZSTD_dictAttachPref_e(value);
        if (ZSTD_cParam_withinBounds(ZSTD_c_forceAttachDict, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.attachDictPref := pref;
        exit( ord(CCtxParams^.attachDictPref));
      end;

      ZSTD_c_literalCompressionMode : 
      begin
        lcm := ZSTD_literalCompressionMode_e(value);
        if (ZSTD_cParam_withinBounds(ZSTD_c_literalCompressionMode, value)=0) then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.literalCompressionMode := lcm;
        exit( ord(CCtxParams^.literalCompressionMode));
      end;

      ZSTD_c_nbWorkers :
      begin;
        err:=ZSTD_cParam_clampBounds(param, @value);
        if (ERR_isError(err)<>0) then
           exit(err);
        CCtxParams^.nbWorkers := value;
        exit( CCtxParams^.nbWorkers);
      end;
      ZSTD_c_jobSize :
      begin
        { Adjust to the minimum non-default value. }
        if (value <> 0)  and  (value < ZSTDMT_JOBSIZE_MIN) then
            value := ZSTDMT_JOBSIZE_MIN;
        err:=ZSTD_cParam_clampBounds(param, @value);
        if ERR_isError(err)<>0 then
           exit(err);
        assert(value >= 0);
        CCtxParams^.jobSize := value;
        exit( CCtxParams^.jobSize);
      end;
      ZSTD_c_overlapLog :
      begin
        err:=ZSTD_cParam_clampBounds(ZSTD_c_overlapLog, @value);
        if ERR_isError(err)<>0 then
           exit(err);
        CCtxParams^.overlapLog := value;
        exit(CCtxParams^.overlapLog);
      end;
      ZSTD_c_rsyncable :
      begin
        err:=ZSTD_cParam_clampBounds(ZSTD_c_rsyncable, @value);
        if ERR_isError(err)<>0 then
           exit(err);
        CCtxParams^.rsyncable := value;
        exit( CCtxParams^.rsyncable);
      end;
      ZSTD_c_enableDedicatedDictSearch :
      begin
        CCtxParams^.enableDedicatedDictSearch := ord(value<>0);
        exit( CCtxParams^.enableDedicatedDictSearch);
      end;
      ZSTD_c_enableLongDistanceMatching :
      begin
        CCtxParams^.ldmParams.enableLdm := ord(value<>0);
        exit( CCtxParams^.ldmParams.enableLdm);
      end;
      ZSTD_c_ldmHashLog :
      begin
        if (value<>0) then  { 0 => auto }
            if ZSTD_cParam_withinBounds(ZSTD_c_ldmHashLog, value)=0 then
               exit(ERROR(parameter_outOfBound));
        CCtxParams^.ldmParams.hashLog := value;
        exit( CCtxParams^.ldmParams.hashLog);
      end;
      ZSTD_c_ldmMinMatch :
      begin
        if (value<>0) then  { 0 => default }
        if ZSTD_cParam_withinBounds(ZSTD_c_ldmMinMatch, value)=0 then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.ldmParams.minMatchLength := value;
        exit( CCtxParams^.ldmParams.minMatchLength);
      end;
      ZSTD_c_ldmBucketSizeLog :
      begin
        if (value<>0) then  { 0 => default }
          if ZSTD_cParam_withinBounds(ZSTD_c_ldmBucketSizeLog, value)=0 then
             exit(ERROR(parameter_outOfBound));
        CCtxParams^.ldmParams.bucketSizeLog := value;
        exit( CCtxParams^.ldmParams.bucketSizeLog);
      end;
      ZSTD_c_ldmHashRateLog :
      begin
        if value > ZSTD_WINDOWLOG_MAX - ZSTD_HASHLOG_MIN then
           exit(ERROR(parameter_outOfBound)); //'Param out of boundsnot '
        CCtxParams^.ldmParams.hashRateLog := value;
        exit( CCtxParams^.ldmParams.hashRateLog);
      end;
      ZSTD_c_targetCBlockSize :
      begin
        if (value<>0) then  { 0 => default }
          if ZSTD_cParam_withinBounds(ZSTD_c_targetCBlockSize, value)=0 then
             exit(ERROR(parameter_outOfBound));
        CCtxParams^.targetCBlockSize := value;
        exit( CCtxParams^.targetCBlockSize);
      end;
      ZSTD_c_srcSizeHint :
      begin
        if (value<>0) then   { 0 => default }
          if ZSTD_cParam_withinBounds(ZSTD_c_srcSizeHint, value)=0 then
             exit(ERROR(parameter_outOfBound));
        CCtxParams^.srcSizeHint := value;
        exit( CCtxParams^.srcSizeHint);
      end;
      ZSTD_c_stableInBuffer:
      begin
        if ZSTD_cParam_withinBounds(ZSTD_c_stableInBuffer, value)=0 then
           exit(ERROR(parameter_outOfBound));

        CCtxParams^.inBufferMode := ZSTD_bufferMode_e(value);
        exit( ord(CCtxParams^.inBufferMode));
      end;
      ZSTD_c_stableOutBuffer:
      begin
        if ZSTD_cParam_withinBounds(ZSTD_c_stableOutBuffer, value)=0 then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.outBufferMode := ZSTD_bufferMode_e(value);
        exit( ord(CCtxParams^.outBufferMode));
      end;
      ZSTD_c_blockDelimiters:
      begin
        if ZSTD_cParam_withinBounds(ZSTD_c_blockDelimiters, value)=0 then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.blockDelimiters := ZSTD_sequenceFormat_e(value);
        exit( ord(CCtxParams^.blockDelimiters));
      end;
      ZSTD_c_validateSequences:
      begin
        if ZSTD_cParam_withinBounds(ZSTD_c_validateSequences, value)=0 then
           exit(ERROR(parameter_outOfBound));
        CCtxParams^.validateSequences := value;
        exit( CCtxParams^.validateSequences);
      end;
      else exit(ERROR(parameter_unsupported));//, 'unknown parameter');
    end;
end;

function ZSTD_CCtx_getParameter(cctx:pZSTD_CCtx; param:ZSTD_cParameter;value:pint32):int32;
begin
    result := ZSTD_CCtxParams_getParameter(@cctx^.requestedParams, param, value);
end;

function ZSTD_CCtxParams_getParameter(cctxParams:pZSTD_CCtx_params; param:ZSTD_cParameter;value:pint32):int32;
begin
    case param of
      ZSTD_c_format :
          value^:= ord(CCtxParams^.format);
      ZSTD_c_compressionLevel :
          value^:= CCtxParams^.compressionLevel;
      ZSTD_c_windowLog :
          value^:= int32(CCtxParams^.cParams.windowLog);
      ZSTD_c_hashLog :
          value^:= int32(CCtxParams^.cParams.hashLog);
      ZSTD_c_chainLog :
          value^:= int32(CCtxParams^.cParams.chainLog);
      ZSTD_c_searchLog :
          value^:= CCtxParams^.cParams.searchLog;
      ZSTD_c_minMatch :
          value^:= CCtxParams^.cParams.minMatch;
      ZSTD_c_targetLength :
          value^:= CCtxParams^.cParams.targetLength;
      ZSTD_c_strategy :
          value^:= uint32(CCtxParams^.cParams.strategy);
      ZSTD_c_contentSizeFlag :
          value^:= CCtxParams^.fParams.contentSizeFlag;
      ZSTD_c_checksumFlag :
          value^:= CCtxParams^.fParams.checksumFlag;
      ZSTD_c_dictIDFlag :
          value^:= not CCtxParams^.fParams.noDictIDFlag;
      ZSTD_c_forceMaxWindow :
          value^:= CCtxParams^.forceWindow;
      ZSTD_c_forceAttachDict :
          value^:= ord(CCtxParams^.attachDictPref);
      ZSTD_c_literalCompressionMode :
          value^:= ord(CCtxParams^.literalCompressionMode);
      ZSTD_c_nbWorkers :
          value^:= CCtxParams^.nbWorkers;
      ZSTD_c_jobSize :
      begin
          assert(CCtxParams^.jobSize <= maxint);
          value^:= int32(CCtxParams^.jobSize);
      end;
      ZSTD_c_overlapLog :
          value^:= CCtxParams^.overlapLog;
      ZSTD_c_rsyncable :
          value^:= CCtxParams^.rsyncable;
      ZSTD_c_enableDedicatedDictSearch :
          value^:= CCtxParams^.enableDedicatedDictSearch;
      ZSTD_c_enableLongDistanceMatching :
          value^:= CCtxParams^.ldmParams.enableLdm;
      ZSTD_c_ldmHashLog :
          value^:= CCtxParams^.ldmParams.hashLog;
      ZSTD_c_ldmMinMatch :
          value^:= CCtxParams^.ldmParams.minMatchLength;
      ZSTD_c_ldmBucketSizeLog :
          value^:= CCtxParams^.ldmParams.bucketSizeLog;
      ZSTD_c_ldmHashRateLog :
          value^:= CCtxParams^.ldmParams.hashRateLog;
      ZSTD_c_targetCBlockSize :
          value^:= int32(CCtxParams^.targetCBlockSize);
      ZSTD_c_srcSizeHint :
          value^:= int32(CCtxParams^.srcSizeHint);
      ZSTD_c_stableInBuffer :
          value^:= int32(CCtxParams^.inBufferMode);
      ZSTD_c_stableOutBuffer :
          value^:= int32(CCtxParams^.outBufferMode);
      ZSTD_c_blockDelimiters :
          value^:= int32(CCtxParams^.blockDelimiters);
      ZSTD_c_validateSequences :
          value^:= int32(CCtxParams^.validateSequences);
      else
       exit(ERROR(parameter_unsupported));//, 'unknown parameter');
    end;
    exit(0);
end;

{* ZSTD_CCtx_setParametersUsingCCtxParams() :
 *  just applies `params` into `cctx`
 *  no action is performed, parameters are merely stored.
 *  If ZSTDMT is enabled, parameters are pushed to cctx^.mtctx.
 *    This is possible even if a compression is ongoing.
 *    In which case, new parameters will be applied on the fly, starting with next compression job.
 }
function ZSTD_CCtx_setParametersUsingCCtxParams(
        cctx:pZSTD_CCtx; params:pZSTD_CCtx_params):int32;
begin
    ////log(3, 'ZSTD_CCtx_setParametersUsingCCtxParams');
    if(cctx^.streamStage <> zcss_init) then
      exit(ERROR(stage_wrong)); //'The context is in the wrong stagenot ');
    if (cctx^.cdict<>nil) then
      exit(ERROR(stage_wrong));//'Can''t override parameters with cdict attached (some must ''be inherited from the cdict).');

    cctx^.requestedParams := params^;
    exit(0);
end;

function  ZSTD_CCtx_setPledgedSrcSize(cctx:pZSTD_CCtx;pledgedSrcSize:uint64):int32;
begin
    ////log(3, 'ZSTD_CCtx_setPledgedSrcSize to %u bytes', pledgedSrcSize);
    if (cctx^.streamStage <> zcss_init) then
      exit(ERROR(stage_wrong));//'Can''t set pledgedSrcSize when not in init stage.');
    cctx^.pledgedSrcSizePlusOne := pledgedSrcSize+1;
    exit(0);
end;

{*
 * Initializes the local dict using the requested parameters.
 * NOTE: This does not use the pledged src size, because it may be used for more
 * than one compression.
 }
function  ZSTD_initLocalDict(cctx:pZSTD_CCtx):int32;
var
  dl:pZSTD_localDict;
begin
    dl := @cctx^.localDict;
    if (dl^.dict = nil) then
    begin
        { No local dictionary. }
        assert(dl^.dictBuffer = nil);
        assert(dl^.cdict = nil);
        assert(dl^.dictSize = 0);
        exit(0);
    end;
    if (dl^.cdict <> nil) then
    begin
        assert(cctx^.cdict = dl^.cdict);
        { Local dictionary already initialized. }
        exit(0);
    end;
    assert(dl^.dictSize > 0);
    assert(cctx^.cdict = nil);
    assert(cctx^.prefixDict.dict = nil);

    dl^.cdict := ZSTD_createCDict_advanced2(
            dl^.dict,
            dl^.dictSize,
            ZSTD_dlm_byRef,
            dl^.dictContentType,
            @cctx^.requestedParams,
            cctx^.customMem);
    if (dl^.cdict=nil) then
      EXIT(ERROR(memory_allocation));//, 'ZSTD_createCDict_advanced failed');
    cctx^.cdict := dl^.cdict;
    exit(0);
end;

function ZSTD_CCtx_loadDictionary_advanced(
        cctx:pZSTD_CCtx; dict:pbyte;dictSize:int32;
        dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e):int32;
var
  dictBuffer:pbyte;
begin
    if (cctx^.streamStage <> zcss_init) then
      exit(ERROR(stage_wrong));//'Can''t load a dictionary when ctx is not in init stage.');
    ////log(3, 'ZSTD_CCtx_loadDictionary_advanced (size: %u)', dictSize);
    ZSTD_clearAllDicts(cctx);  { in case one already exists }
    if (dict = nil) or (dictSize = 0) then { no dictionary mode }
        exit(0);
    if (dictLoadMethod = ZSTD_dlm_byRef) then
    begin
        cctx^.localDict.dict := dict;
    end
    else 
    begin
        if (cctx^.staticSize<>0) then
          exit(ERROR(memory_allocation));//'no malloc for static CCtx');
        dictBuffer := ZSTD_customMalloc(dictSize, cctx^.customMem);
        if (dictBuffer=nil) then
          exit(ERROR(memory_allocation));//, 'nil pointernot ');
        move(dict^, dictBuffer^,  dictSize);
        cctx^.localDict.dictBuffer := dictBuffer;
        cctx^.localDict.dict := dictBuffer;
    end;
    cctx^.localDict.dictSize := dictSize;
    cctx^.localDict.dictContentType := dictContentType;
    exit(0);
end;

function  ZSTD_CCtx_loadDictionary_byReference(
      cctx:pZSTD_CCtx; dict:pbyte;dictSize:int32):int32;
begin
    result := ZSTD_CCtx_loadDictionary_advanced(
            cctx, dict, dictSize, ZSTD_dlm_byRef, ZSTD_dct_auto);
end;

function  ZSTD_CCtx_loadDictionary(cctx:pZSTD_CCtx; dict:pbyte;dictSize:int32):int32;
begin
    result := ZSTD_CCtx_loadDictionary_advanced(
            cctx, dict, dictSize, ZSTD_dlm_byCopy, ZSTD_dct_auto);
end;


function ZSTD_CCtx_refCDict(cctx:pZSTD_CCtx; const cdict:pZSTD_CDict):int32;
begin
    if (cctx^.streamStage <> zcss_init) then
      exit(ERROR(stage_wrong));//'Can''t ref a dict when ctx not in init stage.');
    { Free the existing local cdict (if any) to save memory. }
    ZSTD_clearAllDicts(cctx);
    cctx^.cdict := cdict;
    exit(0);
end;
{
function ZSTD_CCtx_refThreadPool(cctx:pZSTD_CCtx; pool:pZSTD_threadPool):int32;
begin
    RETURN_ERROR_IF(cctx^.streamStage <> zcss_init, stage_wrong,
                    'Can''t ref a pool when ctx not in init stage.');
    cctx^.pool := pool;
    exit(0);
end;
}
function ZSTD_CCtx_refPrefix(cctx:pZSTD_CCtx; prefix:pbyte;prefixSize:int32):int32;
begin
    result := ZSTD_CCtx_refPrefix_advanced(cctx, prefix, prefixSize, ZSTD_dct_rawContent);
end;

function ZSTD_CCtx_refPrefix_advanced(
        cctx:pZSTD_CCtx; prefix:pbyte;prefixSize:int32; dictContentType:ZSTD_dictContentType_e):int32;
begin
    if (cctx^.streamStage <> zcss_init) then
      exit(ERROR(stage_wrong));//'Can''t ref a prefix when ctx not in init stage.');
    ZSTD_clearAllDicts(cctx);
    if (prefix <> nil)  and  (prefixSize > 0) then
    begin
        cctx^.prefixDict.dict := prefix;
        cctx^.prefixDict.dictSize := prefixSize;
        cctx^.prefixDict.dictContentType := dictContentType;
    end;
    exit(0);
end;

{not  ZSTD_CCtx_reset() :
 *  Also dumps dictionary }
function ZSTD_CCtx_reset(cctx:pZSTD_CCtx; reset:ZSTD_ResetDirective):int32;
begin
    if ( (reset = ZSTD_reset_session_only)
      or (reset = ZSTD_reset_session_and_parameters) ) then
    begin
        cctx^.streamStage := zcss_init;
        cctx^.pledgedSrcSizePlusOne := 0;
    end;
    if ( (reset = ZSTD_reset_parameters)
      or (reset = ZSTD_reset_session_and_parameters) ) then
    begin
        if (cctx^.streamStage <> zcss_init) then
          EXIT(ERROR(stage_wrong));//'Can''t reset parameters only when not in init stage.');
        ZSTD_clearAllDicts(cctx);
        exit(ZSTD_CCtxParams_reset(@cctx^.requestedParams));
    end;
    exit(0);
end;


{* ZSTD_checkCParams() :
    control CParam values remain within authorized range.
    @return : 0, or an error code if one value is beyond authorized range }
function ZSTD_checkCParams(cParams:ZSTD_compressionParameters):int32;
begin
    if ZSTD_cParam_withinBounds(ZSTD_c_windowLog, cParams.windowLog)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_chainLog,  cParams.chainLog)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_hashLog,   cParams.hashLog)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_searchLog, cParams.searchLog)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_minMatch,  cParams.minMatch)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_targetLength,cParams.targetLength)=0 then
      exit(ERROR(parameter_outOfBound));
    if ZSTD_cParam_withinBounds(ZSTD_c_strategy,  ord(cParams.strategy))=0 then
      exit(ERROR(parameter_outOfBound));
    exit(0);
end;

{* ZSTD_clampCParams() :
 *  make CParam values within valid range.
 *  @return : valid CParams }
function ZSTD_clampCParams(cParams:ZSTD_compressionParameters):ZSTD_compressionParameters;
var
  bounds:ZSTD_bounds;
begin
    bounds := ZSTD_cParam_getBounds(ZSTD_c_windowLog);
    if (cParams.windowLog<bounds.lowerBound) then
      cParams.windowLog:=uint32(bounds.lowerBound)
    else
      if (cParams.windowLog>bounds.upperBound) then
        cParams.windowLog:=uint32(bounds.upperBound);
        
    bounds := ZSTD_cParam_getBounds(ZSTD_c_chainLog);
    if (cParams.chainLog<bounds.lowerBound) then
      cParams.chainLog:=uint32(bounds.lowerBound)
    else
      if (cParams.chainLog>bounds.upperBound) then
        cParams.chainLog:=uint32(bounds.upperBound);

    bounds := ZSTD_cParam_getBounds(ZSTD_c_hashLog);
    if (cParams.hashLog<bounds.lowerBound) then
      cParams.hashLog:=uint32(bounds.lowerBound)
    else
      if (cParams.hashLog>bounds.upperBound) then
        cParams.hashLog:=uint32(bounds.upperBound);    

    bounds := ZSTD_cParam_getBounds(ZSTD_c_searchLog);
    if (cParams.searchLog<bounds.lowerBound) then
      cParams.searchLog:=uint32(bounds.lowerBound)
    else
      if (cParams.searchLog>bounds.upperBound) then
        cParams.searchLog:=uint32(bounds.upperBound);    

    bounds := ZSTD_cParam_getBounds(ZSTD_c_minMatch);
    if (cParams.minMatch<bounds.lowerBound) then
      cParams.minMatch:=uint32(bounds.lowerBound)
    else
      if (cParams.minMatch>bounds.upperBound) then
        cParams.minMatch:=uint32(bounds.upperBound);

    bounds := ZSTD_cParam_getBounds(ZSTD_c_targetLength);
    if (cParams.targetLength<bounds.lowerBound) then
      cParams.targetLength:=uint32(bounds.lowerBound)
    else
      if (cParams.targetLength>bounds.upperBound) then
        cParams.targetLength:=uint32(bounds.upperBound);
                    
    bounds := ZSTD_cParam_getBounds(ZSTD_c_strategy);
    if (ord(cParams.strategy)<bounds.lowerBound) then
      cParams.strategy:=ZSTD_strategy(bounds.lowerBound)
    else
      if (ord(cParams.strategy)>bounds.upperBound) then
        cParams.strategy:=ZSTD_strategy(bounds.upperBound);

    result := cParams;
end;

{* ZSTD_cycleLog() :
 *  condition for correct operation : hashLog > 1 }
function ZSTD_cycleLog(hashLog:uint32;strat:ZSTD_strategy):uint32;
begin
    result := ord(uint32(strat) >= uint32(ZSTD_btlazy2));
    result := hashLog - result;
end;

{* ZSTD_dictAndWindowLog() :
 * Returns an adjusted window log that is large enough to fit the source and the dictionary.
 * The zstd format says that the entire dictionary is valid if one byte of the dictionary
 * is within the window. So the hashLog and chainLog should be large enough to reference both
 * the dictionary and the window. So we must use this adjusted dictAndWindowLog when downsizing
 * the hashLog and windowLog.
 * NOTE: srcSize must not be ZSTD_CONTENTSIZE_UNKNOWN.
 }
function ZSTD_dictAndWindowLog(windowLog:uint32;srcSize,dictSize:uint64):uint32;
var
  maxWindowSize,windowSize,dictAndWindowSize:uint64;
begin
    maxWindowSize :=Uint64(1) shl ZSTD_WINDOWLOG_MAX;
    { No dictionary => No change }
    if (dictSize = 0) then
    begin
        exit(windowLog);
    end;
    assert(windowLog <= ZSTD_WINDOWLOG_MAX);
    assert(srcSize <> ZSTD_CONTENTSIZE_UNKNOWN); { Handled in ZSTD_adjustCParams_internal() }

    windowSize :=Uint64(1) shl windowLog;
    dictAndWindowSize := dictSize + windowSize;
    { If the window size is already large enough to fit both the source and the dictionary
     * then just use the window size. Otherwise adjust so that it fits the dictionary and
     * the window.
     }
    if (windowSize >= dictSize + srcSize) then
    begin
        exit(windowLog); { Window size large enough already }
    end
    else 
    if (dictAndWindowSize >= maxWindowSize) then
    begin
        exit(ZSTD_WINDOWLOG_MAX); { Larger than max window log }
    end
    else
    begin
        exit(ZSTD_highbit32(uint32(dictAndWindowSize) - 1) + 1);
    end;

end;

{* ZSTD_adjustCParams_internal() :
 *  optimize `cPar` for a specified input (`srcSize` and `dictSize`).
 *  mostly downsize to reduce memory consumption and initialization latency.
 * `srcSize` can be ZSTD_CONTENTSIZE_UNKNOWN when not known.
 * `mode` is the mode for parameter adjustment. See docs for `ZSTD_cParamMode_e`.
 *  note : `srcSize=0` means 0not 
 *  condition : cPar is presumed validated (can be checked using ZSTD_checkCParams()). }
 
function ZSTD_adjustCParams_internal(cPar:ZSTD_compressionParameters;srcSize:uint64;dictSize:int32;mode:ZSTD_cParamMode_e):ZSTD_compressionParameters;
var
  minSrcSize,maxWindowResize:uint64;
  tSize,hashSizeMin,srcLog:uint32;
  dictAndWindowLog,cycleLog:uint32;
begin
    minSrcSize := 513; { (1shl9) + 1 }
    maxWindowResize :=Uint64(1) shl (ZSTD_WINDOWLOG_MAX-1);
    assert(ZSTD_checkCParams(cPar)=0);

    if (dictSize<>0)  and  (srcSize = ZSTD_CONTENTSIZE_UNKNOWN) then
        srcSize := minSrcSize;

    case (mode) of
      ZSTD_cpm_noAttachDict,
      ZSTD_cpm_unknown,
      ZSTD_cpm_createCDict:;
      ZSTD_cpm_attachDict:
        dictSize := 0;
      else
        assert(false);
    end;

    { resize windowLog if input is small enough, to use less memory }
    if ( (srcSize < maxWindowResize) and  (dictSize < maxWindowResize) ) then 
    begin
        tSize := uint32(srcSize + dictSize);
        hashSizeMin := 1 shl ZSTD_HASHLOG_MIN;
        if (tSize < hashSizeMin) then
          srcLog := ZSTD_HASHLOG_MIN
        else
          srcLog := ZSTD_highbit32(tSize-1) + 1;
        if (cPar.windowLog > srcLog) then
          cPar.windowLog := srcLog;
    end;
    
    dictAndWindowLog := ZSTD_dictAndWindowLog(cPar.windowLog, Uint64(srcSize), Uint64(dictSize));
    cycleLog := ZSTD_cycleLog(cPar.chainLog, cPar.strategy);
    if (cPar.hashLog > dictAndWindowLog+1) then
      cPar.hashLog := dictAndWindowLog+1;
    if (cycleLog > dictAndWindowLog) then
        cPar.chainLog :=cPar.chainLog - (cycleLog - dictAndWindowLog);

    if (cPar.windowLog < ZSTD_WINDOWLOG_ABSOLUTEMIN) then
        cPar.windowLog := ZSTD_WINDOWLOG_ABSOLUTEMIN;  { minimum wlog required for valid frame header }

    result := cPar;
end;

function ZSTD_adjustCParams(cPar:ZSTD_compressionParameters;
  srcSize:uint64;dictSize:int32):ZSTD_compressionParameters;
begin
    cPar := ZSTD_clampCParams(cPar);   { resulting cPar is necessarily valid (all parameters within range) }
    if (srcSize = 0) then
      srcSize := ZSTD_CONTENTSIZE_UNKNOWN;
    result := ZSTD_adjustCParams_internal(cPar, srcSize, dictSize, ZSTD_cpm_unknown);
end;

procedure ZSTD_overrideCParams(
              cParams:pZSTD_compressionParameters;
        const overrides:pZSTD_compressionParameters) ;
begin
    if (overrides^.windowLog<>0)    then 
      cParams^.windowLog    := overrides^.windowLog;
    if (overrides^.hashLog<>0)      then 
      cParams^.hashLog      := overrides^.hashLog;
    if (overrides^.chainLog<>0)     then 
      cParams^.chainLog     := overrides^.chainLog;
    if (overrides^.searchLog<>0)    then 
      cParams^.searchLog    := overrides^.searchLog;
    if (overrides^.minMatch<>0)     then 
      cParams^.minMatch     := overrides^.minMatch;
    if (overrides^.targetLength<>0) then 
      cParams^.targetLength := overrides^.targetLength;
    if (ord(overrides^.strategy)<>0)     then 
      cParams^.strategy     := overrides^.strategy;
end;

function ZSTD_getCParamsFromCCtxParams(
        const cctxParams:pZSTD_CCtx_params; srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):ZSTD_compressionParameters;
var
  cParams:ZSTD_compressionParameters;
begin
   
    if (srcSizeHint = ZSTD_CONTENTSIZE_UNKNOWN)  and  (CCtxParams^.srcSizeHint > 0) then
    begin
      srcSizeHint := CCtxParams^.srcSizeHint;
    end;
    cParams := ZSTD_getCParams_internal(CCtxParams^.compressionLevel, srcSizeHint, dictSize, mode);
    if (CCtxParams^.ldmParams.enableLdm<>0) then
      cParams.windowLog := ZSTD_LDM_DEFAULT_WINDOW_LOG;
    ZSTD_overrideCParams(@cParams, @CCtxParams^.cParams);
    assert(ZSTD_checkCParams(cParams)=0);
    { srcSizeHint = 0 means 0 }
    result := ZSTD_adjustCParams_internal(cParams, srcSizeHint, dictSize, mode);
end;

function ZSTD_sizeof_matchState(const cParams:pZSTD_compressionParameters;const forCCtx:Uint32):int32;
var
  chainSize,hSize,h3Size,tableSpace,optPotentialSpace,optSpace:int32;
  hashLog3:uint32;
begin
  if (cParams^.strategy = ZSTD_fast) then
    chainSize :=  0
  else
    chainSize :=  (int32(1) shl cParams^.chainLog);
  hSize := (int32(1)) shl cParams^.hashLog;
  if (forCCtx  and  cParams^.minMatch=3) then  
    hashLog3 := MIN(ZSTD_HASHLOG3_MAX, cParams^.windowLog)
  else
    hashLog3 := 0;
  if hashLog3<>0 then
    h3Size := (int32(1)) shl hashLog3
  else
    h3Size := 0;
    { We don't use ZSTD_cwksp_alloc_size() here because the tables aren't
     * surrounded by redzones in ASAN. }
    tableSpace := chainSize * sizeof(uint32)
                            + hSize * sizeof(uint32)
                            + h3Size * sizeof(uint32);
    optPotentialSpace :=
        ZSTD_cwksp_alloc_size((MaxML+1) * sizeof(uint32))
      + ZSTD_cwksp_alloc_size((MaxLL+1) * sizeof(uint32))
      + ZSTD_cwksp_alloc_size((MaxOff+1) * sizeof(uint32))
      + ZSTD_cwksp_alloc_size((1 shl Litbits) * sizeof(uint32))
      + ZSTD_cwksp_alloc_size((ZSTD_OPT_NUM+1) * sizeof(ZSTD_match_t))
      + ZSTD_cwksp_alloc_size((ZSTD_OPT_NUM+1) * sizeof(ZSTD_optimal_t));
    if (forCCtx<>0)  and  (cParams^.strategy >= ZSTD_btopt) then
      optSpace := optPotentialSpace
    else 
      optSpace :=  0;
    ////log(3, 'chainSize: %u - hSize: %u - h3Size: %u', chainSize, hSize, h3Size);
    result := tableSpace + optSpace;
end;
function min(a,b:uint64):uint64;
begin
    if a<b then
       result:=a
    else
      result:=b;
end;
function  ZSTD_estimateCCtxSize_usingCCtxParams_internal(
        const cParams:pZSTD_compressionParameters;
        const ldmParams:pldmParams_t;
        const isStatic:int32;
        const buffInSize:int32;
        const buffOutSize:int32;
        const pledgedSrcSize:uint64):int32;
var
  windowSize,blockSize,maxNbSeq,tokenSpace:int32;
  divider:uint32;
  entropySpace,blockStateSpace,matchStateSize,ldmSpace,maxNbLdmSeq,ldmSeqSpace:int32;
  bufferSpace,cctxSpace,neededSpace:int32;
begin
    windowSize := MAX(1, int32(MIN(Uint64(Uint64(1) shl cParams^.windowLog), pledgedSrcSize)));
    blockSize := MIN(ZSTD_BLOCKSIZE_MAX, windowSize);
    if (cParams^.minMatch=3) then
      divider :=  3
    else
      divider :=  4;
    maxNbSeq := blockSize div divider;
    tokenSpace := ZSTD_cwksp_alloc_size(WILDCOPY_OVERLENGTH + blockSize)
                            + ZSTD_cwksp_alloc_size(maxNbSeq * sizeof(seqDef))
                            + 3 * ZSTD_cwksp_alloc_size(maxNbSeq * sizeof(BYTE));
    
    entropySpace := ZSTD_cwksp_alloc_size(ENTROPY_WORKSPACE_SIZE);
    blockStateSpace := 2 * ZSTD_cwksp_alloc_size(sizeof(ZSTD_compressedBlockState_t));
    matchStateSize := ZSTD_sizeof_matchState(cParams, { forCCtx } 1);

    ldmSpace := ZSTD_ldm_getTableSize(ldmParams^);
    maxNbLdmSeq := ZSTD_ldm_getMaxNbSeq(ldmParams^, blockSize);
    if ldmParams^.enableLdm<>0 then
      ldmSeqSpace :=  ZSTD_cwksp_alloc_size(maxNbLdmSeq * sizeof(rawSeq))
    else
      ldmSeqSpace := 0;

    bufferSpace := ZSTD_cwksp_alloc_size(buffInSize)
                             + ZSTD_cwksp_alloc_size(buffOutSize);
    if isStatic<>0 then
      cctxSpace := ZSTD_cwksp_alloc_size(sizeof(ZSTD_CCtx))
    else
      cctxSpace := 0;

    neededSpace :=
        cctxSpace +
        entropySpace +
        blockStateSpace +
        ldmSpace +
        ldmSeqSpace +
        matchStateSize +
        tokenSpace +
        bufferSpace;

    ////log(3, 'estimate workspace : %u', neededSpace);
    result := neededSpace;
end;

function ZSTD_estimateCCtxSize_usingCCtxParams(params:pZSTD_CCtx_params):int32;
var
  cParams:ZSTD_compressionParameters;
begin
    cParams :=
                ZSTD_getCParamsFromCCtxParams(params, ZSTD_CONTENTSIZE_UNKNOWN, 0, ZSTD_cpm_noAttachDict);

    if (params^.nbWorkers > 0) then
     exit (ERROR(GENERIC_ERROR));//, 'Estimate CCtx size is supported for single-threaded compression only.');
    { estimateCCtxSize is for one-shot compression. So no buffers should
     * be needed. However, we still allocate two 0-sized buffers, which can
     * take space under ASAN. }
    result := ZSTD_estimateCCtxSize_usingCCtxParams_internal(
        @cParams, @params^.ldmParams, 1, 0, 0, ZSTD_CONTENTSIZE_UNKNOWN);
end;

function ZSTD_estimateCCtxSize_usingCParams(cParams:ZSTD_compressionParameters):int32;
var
  params:ZSTD_CCtx_params;
begin
    params := ZSTD_makeCCtxParamsFromCParams(cParams);
    result := ZSTD_estimateCCtxSize_usingCCtxParams(@params);
end;

function ZSTD_estimateCCtxSize_internal(compressionLevel:int32):int32;
var
  cParams:ZSTD_compressionParameters;
begin
  cParams := ZSTD_getCParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, 0, ZSTD_cpm_noAttachDict);
  result := ZSTD_estimateCCtxSize_usingCParams(cParams);
end;

function ZSTD_estimateCCtxSize(compressionLevel:int32):int32;
var
  level,memBudget,newMB:int32;
begin
    memBudget := 0;
    for level:=MIN(compressionLevel, 1) to compressionLevel do 
    begin
        newMB := ZSTD_estimateCCtxSize_internal(level);
        if (newMB > memBudget) then
          memBudget := newMB;
    end;
    result := memBudget;
end;

function ZSTD_estimateCStreamSize_usingCCtxParams(params:pZSTD_CCtx_params):int32;
var
  cParams:ZSTD_compressionParameters; 
  blockSize,inBuffSize,outBuffSize:int32;
begin
    //if (params^.nbWorkers > 0) then
    // exit(ERROR(GENERIC_ERROR);//, 'Estimate CCtx size is supported for single-threaded compression only.');
    cParams :=ZSTD_getCParamsFromCCtxParams(params, ZSTD_CONTENTSIZE_UNKNOWN, 0, ZSTD_cpm_noAttachDict);
    blockSize := MIN(ZSTD_BLOCKSIZE_MAX, int32(1) shl cParams.windowLog);
    if (params^.inBufferMode = ZSTD_bm_buffered) then
      inBuffSize := (int32(1) shl cParams.windowLog) + blockSize
    else
      inBuffSize := 0;
    if (params^.outBufferMode = ZSTD_bm_buffered) then
      outBuffSize := ZSTD_compressBound(blockSize) + 1
    else
      outBuffSize := 0;

    result := ZSTD_estimateCCtxSize_usingCCtxParams_internal(
        @cParams, @params^.ldmParams, 1, inBuffSize, outBuffSize,
        ZSTD_CONTENTSIZE_UNKNOWN);
    
end;

function ZSTD_estimateCStreamSize_usingCParams(cParams:ZSTD_compressionParameters):int32;
var
  params:ZSTD_CCtx_params;
begin
    params := ZSTD_makeCCtxParamsFromCParams(cParams);
    result := ZSTD_estimateCStreamSize_usingCCtxParams(@params);
end;

function ZSTD_estimateCStreamSize_internal(compressionLevel:int32):int32;
var
  cParams:ZSTD_compressionParameters;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, 0, ZSTD_cpm_noAttachDict);
    result := ZSTD_estimateCStreamSize_usingCParams(cParams);
end;

function ZSTD_estimateCStreamSize(compressionLevel:int32):int32;
var
  level,memBudget,newMB:int32;
begin
    memBudget := 0;
    for level:=MIN(compressionLevel, 1) to compressionLevel do
    begin
        newMB := ZSTD_estimateCStreamSize_internal(level);
        if (newMB > memBudget) then
          memBudget := newMB;
    end;
    result := memBudget;
end;

{ ZSTD_getFrameProgression():
 * tells how much data has been consumed (input) and produced (output) for current frame.
 * able to count progression inside worker threads (non-blocking mode).
 }
function ZSTD_getFrameProgression(cctx:pZSTD_CCtx):ZSTD_frameProgression;
var
  fp:ZSTD_frameProgression;
  buffered:int32;
begin
    if (cctx^.inBuff = nil) then
      buffered := 0
    else 
      buffered := cctx^.inBuffPos - cctx^.inToCompress;
    if (buffered<>0) then
      assert(cctx^.inBuffPos >= cctx^.inToCompress);
    assert(buffered <= ZSTD_BLOCKSIZE_MAX);
    fp.ingested := cctx^.consumedSrcSize + buffered;
    fp.consumed := cctx^.consumedSrcSize;
    fp.produced := cctx^.producedCSize;
    fp.flushed  := cctx^.producedCSize;   { simplified; some data might still be left within streaming output buffer }
    fp.currentJobID := 0;
    fp.nbActiveWorkers := 0;
    result := fp;
end;

{not  ZSTD_toFlushNow()
 *  Only useful for multithreading scenarios currently (nbWorkers >= 1).
 }
function ZSTD_toFlushNow(cctx:pZSTD_CCtx):int32;
begin
    exit(0);   { over-simplification; could also check if context is currently running in streaming mode, and in which case, report how many bytes are left to be flushed within output buffer }
end;

procedure ZSTD_assertEqualCParams(cParams1,cParams2:ZSTD_compressionParameters);
begin
    assert(cParams1.windowLog    = cParams2.windowLog);
    assert(cParams1.chainLog     = cParams2.chainLog);
    assert(cParams1.hashLog      = cParams2.hashLog);
    assert(cParams1.searchLog    = cParams2.searchLog);
    assert(cParams1.minMatch     = cParams2.minMatch);
    assert(cParams1.targetLength = cParams2.targetLength);
    assert(cParams1.strategy     = cParams2.strategy);
end;

procedure ZSTD_reset_compressedBlockState(bs:pZSTD_compressedBlockState_t);
var
  i:int32;
begin
    for i := 0 to ZSTD_REP_NUM-1 do
        bs^.rep[i] := repStartValue[i];
    bs^.entropy.huf.repeatMode := HUF_repeat_none;
    bs^.entropy.fse.offcode_repeatMode := FSE_repeat_none;
    bs^.entropy.fse.matchlength_repeatMode := FSE_repeat_none;
    bs^.entropy.fse.litlength_repeatMode := FSE_repeat_none;
end;

{not  ZSTD_invalidateMatchState()
 *  Invalidate all the matches in the match finder tables.
 *  Requires nextSrc and base to be set (can be nil).
 }
procedure ZSTD_invalidateMatchState(ms:pZSTD_matchState_t);
begin
    ZSTD_window_clear(@ms^.window);

    ms^.nextToUpdate := ms^.window.dictLimit;
    ms^.loadedDictEnd := 0;
    ms^.opt.litLengthSum := 0;  { force reset of btopt stats }
    ms^.dictMatchState := nil;
end;

function ZSTD_reset_matchState(ms:pZSTD_matchState_t;
                      ws:pZSTD_cwksp;
                const cParams:pZSTD_compressionParameters;
                const crp:ZSTD_compResetPolicy_e;
                const forceResetIndex:ZSTD_indexResetPolicy_e;
                const forWho:ZSTD_resetTarget_e):int32;
var
  chainSize,hSize,h3Size:int32;
  hashLog3:uint32;
begin
  if (cParams^.strategy = ZSTD_fast) then
    chainSize :=  0
  else
    chainSize := (int32(1) shl cParams^.chainLog);
  hSize := (int32(1)) shl cParams^.hashLog;
  if (forWho = ZSTD_resetTarget_CCtx)  and  (cParams^.minMatch=3) then
    hashLog3 := MIN(ZSTD_HASHLOG3_MAX, cParams^.windowLog)
  else
    hashLog3 := 0;
  if hashLog3<>0 then
    h3Size := (int32(1)) shl hashLog3
  else
    h3Size := 0;

    ////log(3, 'reset indices : %u', forceResetIndex = ZSTDirp_reset);
    if (forceResetIndex = ZSTDirp_reset) then
    begin
        ZSTD_window_init(@ms^.window);
        ZSTD_cwksp_mark_tables_dirty(ws);
    end;

    ms^.hashLog3 := hashLog3;

    ZSTD_invalidateMatchState(ms);

    assert(ZSTD_cwksp_reserve_failed(ws)=0); { check that allocation hasn't already failed }

    ZSTD_cwksp_clear_tables(ws);

    ////log(3, 'reserving table space');
    { table Space }
    ms^.hashTable :=  puint32(ZSTD_cwksp_reserve_table(ws, hSize * sizeof(uint32)));
    ms^.chainTable := puint32(ZSTD_cwksp_reserve_table(ws, chainSize * sizeof(uint32)));
    ms^.hashTable3 := puint32(ZSTD_cwksp_reserve_table(ws, h3Size * sizeof(uint32)));
    if (ZSTD_cwksp_reserve_failed(ws)<>0) then
     exit(ERROR(memory_allocation));//'failed a workspace allocation in ZSTD_reset_matchState');

    ////log(3, 'reset table : %u', crp<>ZSTDcrp_leaveDirty);
    if (crp<>ZSTDcrp_leaveDirty) then
    begin
        { reset tables only }
        ZSTD_cwksp_clean_tables(ws);
    end;

    { opt parser space }
    if ((forWho = ZSTD_resetTarget_CCtx)  and  (cParams^.strategy >= ZSTD_btopt)) then
    begin
        ////log(3, 'reserving optimal parser space');
        ms^.opt.litFreq := puint32(ZSTD_cwksp_reserve_aligned(ws, (1 shl Litbits) * sizeof(uint32)));
        ms^.opt.litLengthFreq := puint32(ZSTD_cwksp_reserve_aligned(ws, (MaxLL+1) * sizeof(uint32)));
        ms^.opt.matchLengthFreq := puint32(ZSTD_cwksp_reserve_aligned(ws, (MaxML+1) * sizeof(uint32)));
        ms^.opt.offCodeFreq := puint32(ZSTD_cwksp_reserve_aligned(ws, (MaxOff+1) * sizeof(uint32)));
        ms^.opt.matchTable := pZSTD_match_t(ZSTD_cwksp_reserve_aligned(ws, (ZSTD_OPT_NUM+1) * sizeof(ZSTD_match_t)));
        ms^.opt.priceTable := pZSTD_optimal_t(ZSTD_cwksp_reserve_aligned(ws, (ZSTD_OPT_NUM+1) * sizeof(ZSTD_optimal_t)));
    end;

    ms^.cParams := cParams^;

    if (ZSTD_cwksp_reserve_failed(ws)<>0) then
     exit(ERROR(memory_allocation));//'failed a workspace allocation in ZSTD_reset_matchState');

    exit(0);
end;

{ ZSTD_indexTooCloseToMax() :
 * minor optimization : prefer memset() rather than reduceIndex()
 * which is measurably slow in some circumstances (reported for Visual Studio).
 * Works when re-using a context for a lot of smallish inputs :
 * if all inputs are smaller than ZSTD_INDEXOVERFLOW_MARGIN,
 * memset() will be triggered before reduceIndex().
 }

function ZSTD_indexTooCloseToMax(w:ZSTD_window_t):int32;
begin
    result := ord(int32(w.nextSrc - w.base) > (ZSTD_CURRENT_MAX - ZSTD_INDEXOVERFLOW_MARGIN));
end;

{not  ZSTD_resetCCtx_internal() :
    note : `params` are assumed fully validated at this stage }
function ZSTD_resetCCtx_internal(zc:pZSTD_CCtx;params:ZSTD_CCtx_params;pledgedSrcSize:Uint64;
  crp:ZSTD_compResetPolicy_e;zbuff:ZSTD_buffered_policy_e):int32;
var
  ws:pZSTD_cwksp;
  windowSize,blockSize,maxNbSeq,buffOutSize,buffInSize,maxNbLdmSeq,indexTooClose,neededSpace:int32;
  divider:uint32;
  workspaceTooSmall,workspaceWasteful,ldmBucketSize,ldmHSize:int32;
  needsIndexReset:ZSTD_indexResetPolicy_e;
  err:int32;
begin
    ws := @zc^.workspace;
    ////log(3, 'ZSTD_resetCCtx_internal: pledgedSrcSize:=%u, wlog:=%u', pledgedSrcSize, params.cParams.windowLog);
    assert( ZSTD_isError(ZSTD_checkCParams(params.cParams))=0);

    zc^.isFirstBlock := 1;

    if (params.ldmParams.enableLdm<>0) then
    begin
        { Adjust long distance matching parameters }
        ZSTD_ldm_adjustParameters(@params.ldmParams, @params.cParams);
        assert(params.ldmParams.hashLog >= params.ldmParams.bucketSizeLog);
        assert(params.ldmParams.hashRateLog < 32);
        zc^.ldmState.hashPower := ZSTD_rollingHash_primePower(params.ldmParams.minMatchLength);
    end;

    windowSize := MAX(1, int32(MIN(Uint64(uint64(1) shl params.cParams.windowLog), pledgedSrcSize)));
    blockSize := MIN(ZSTD_BLOCKSIZE_MAX, windowSize);
    if (params.cParams.minMatch=3) then
      divider :=  3
    else
      divider :=  4;
    maxNbSeq := blockSize div divider;
    if (zbuff = ZSTDb_buffered)  and  (params.outBufferMode = ZSTD_bm_buffered) then
      buffOutSize := ZSTD_compressBound(blockSize) + 1 
    else
      buffOutSize := 0;
    if (zbuff = ZSTDb_buffered)  and  (params.inBufferMode = ZSTD_bm_buffered) then
      buffInSize := windowSize + blockSize
    else
      buffInSize := 0; 

    maxNbLdmSeq := ZSTD_ldm_getMaxNbSeq(params.ldmParams, blockSize);

    indexTooClose := ZSTD_indexTooCloseToMax(zc^.blockState.matchState.window);
    if (indexTooClose=0)  and  (zc^.initialized<>0) then
        needsIndexReset := ZSTDirp_continue
    else
        needsIndexReset := ZSTDirp_reset;

    neededSpace :=ZSTD_estimateCCtxSize_usingCCtxParams_internal(
                @params.cParams, @params.ldmParams, ord(zc^.staticSize <> 0),
                buffInSize, buffOutSize, pledgedSrcSize);
    if (ERR_isError(neededSpace)<>0) then
    begin
         exit(neededSpace);
    end;
    if (zc^.staticSize=0) then
    begin
      ZSTD_cwksp_bump_oversized_duration(ws, 0);


      { Check if workspace is large enough, alloc a new one if needed }

      workspaceTooSmall := ord(ZSTD_cwksp_sizeof(ws) < neededSpace);
      workspaceWasteful := ZSTD_cwksp_check_wasteful(ws, neededSpace);

      ////log(3, 'Need %zu B workspace', neededSpace);
      ////log(3, 'windowSize: %zu - blockSize: %zu', windowSize, blockSize);

      if (workspaceTooSmall<>0) or (0<>workspaceWasteful) then
      begin
          ////log(3, 'Resize workspaceSize from %zuKB to %zuKB', ZSTD_cwksp_sizeof(ws) shr 10, neededSpace shr 10);

          if (zc^.staticSize<>0) then
           exit(ERROR(memory_allocation));//, 'static cctx : no resize');

          needsIndexReset := ZSTDirp_reset;

          ZSTD_cwksp_freemem(ws, zc^.customMem);
          err:=ZSTD_cwksp_create(ws, neededSpace, zc^.customMem);
          if ERR_isError(err)<>0 then
             exit(err);
          ////log(3, 'reserving object space');
          { Statically sized space.
           * entropyWorkspace never moves,
           * though prev/next block swap places }
          assert(ZSTD_cwksp_check_available(ws, 2 * sizeof(ZSTD_compressedBlockState_t))<>0);
          zc^.blockState.prevCBlock := pZSTD_compressedBlockState_t(ZSTD_cwksp_reserve_object(ws, sizeof(ZSTD_compressedBlockState_t)));
          if (zc^.blockState.prevCBlock = nil) then
          exit(ERROR(memory_allocation));// 'couldn't allocate prevCBlock');
          zc^.blockState.nextCBlock := pZSTD_compressedBlockState_t(ZSTD_cwksp_reserve_object(ws, sizeof(ZSTD_compressedBlockState_t)));
          if (zc^.blockState.nextCBlock = nil) then
          exit(ERROR(memory_allocation));// 'couldn't allocate nextCBlock');
          zc^.entropyWorkspace := puint32(ZSTD_cwksp_reserve_object(ws, ENTROPY_WORKSPACE_SIZE));
          if (zc^.blockState.nextCBlock = nil) then
          exit(ERROR(memory_allocation));// 'couldn't allocate entropyWorkspace');
      end;

      ZSTD_cwksp_clear(ws);

      { init params }
      zc^.appliedParams := params;
      zc^.blockState.matchState.cParams := params.cParams;
      zc^.pledgedSrcSizePlusOne := pledgedSrcSize+1;
      zc^.consumedSrcSize := 0;
      zc^.producedCSize := 0;
      if (pledgedSrcSize = ZSTD_CONTENTSIZE_UNKNOWN) then
          zc^.appliedParams.fParams.contentSizeFlag := 0;
      ////log(3, 'pledged content size : %u ; flag : %u',pledgedSrcSize, zc^.appliedParams.fParams.contentSizeFlag);
      zc^.blockSize := blockSize;

      XXH64_reset(@zc^.xxhState, 0);
      zc^.stage := ZSTDcs_init;
      zc^.dictID := 0;

      ZSTD_reset_compressedBlockState(zc^.blockState.prevCBlock);

      { ZSTD_wildcopy() is used to copy into the literals buffer,
       * so we have to oversize the buffer by WILDCOPY_OVERLENGTH bytes.
       }
      zc^.seqStore.litStart := ZSTD_cwksp_reserve_buffer(ws, blockSize + WILDCOPY_OVERLENGTH);
      zc^.seqStore.maxNbLit := blockSize;

      { buffers }
      zc^.bufferedPolicy := zbuff;
      zc^.inBuffSize := buffInSize;
      zc^.inBuff := ZSTD_cwksp_reserve_buffer(ws, buffInSize);
      zc^.outBuffSize := buffOutSize;
      zc^.outBuff := ZSTD_cwksp_reserve_buffer(ws, buffOutSize);

      { ldm bucketOffsets table }
      if (params.ldmParams.enableLdm<>0) then
      begin
          { TODO: avoid memset? }
          ldmBucketSize :=
                (int32(1)) shl (params.ldmParams.hashLog -
                                params.ldmParams.bucketSizeLog);
          zc^.ldmState.bucketOffsets := ZSTD_cwksp_reserve_buffer(ws, ldmBucketSize);
          fillbyte(zc^.ldmState.bucketOffsets^, ldmBucketSize, 0);
      end;

      { sequences storage }
      ZSTD_referenceExternalSequences(zc, nil, 0);
      zc^.seqStore.maxNbSeq := maxNbSeq;
      zc^.seqStore.llCode := ZSTD_cwksp_reserve_buffer(ws, maxNbSeq * sizeof(BYTE));
      zc^.seqStore.mlCode := ZSTD_cwksp_reserve_buffer(ws, maxNbSeq * sizeof(BYTE));
      zc^.seqStore.ofCode := ZSTD_cwksp_reserve_buffer(ws, maxNbSeq * sizeof(BYTE));
      zc^.seqStore.sequencesStart :=pseqDef(ZSTD_cwksp_reserve_aligned(ws, maxNbSeq * sizeof(seqDef)));

      err:=ZSTD_reset_matchState(
          @zc^.blockState.matchState,
          ws,
          @params.cParams,
          crp,
          needsIndexReset,
          ZSTD_resetTarget_CCtx);
      if ERR_isError(err)<>0 then
         exit(err);
      { ldm hash table }
      if (params.ldmParams.enableLdm<>0) then
      begin
          { TODO: avoid memset? }
          ldmHSize := (int32(1)) shl params.ldmParams.hashLog;
          zc^.ldmState.hashTable := pldmEntry_t(ZSTD_cwksp_reserve_aligned(ws, ldmHSize * sizeof(ldmEntry_t)));
          fillbyte(zc^.ldmState.hashTable^, ldmHSize * sizeof(ldmEntry_t), 0);
          zc^.ldmSequences := prawSeq(ZSTD_cwksp_reserve_aligned(ws, maxNbLdmSeq * sizeof(rawSeq)));
          zc^.maxNbLdmSequences := maxNbLdmSeq;

          ZSTD_window_init(@zc^.ldmState.window);
          ZSTD_window_clear(@zc^.ldmState.window);
          zc^.ldmState.loadedDictEnd := 0;
      end;

      { Due to alignment, when reusing a workspace, we can actually consume
       * up to 3 extra bytes for alignment. See the comments in zstd_cwksp.h
       }
      assert((ZSTD_cwksp_used(ws) >= neededSpace)  and 
             (ZSTD_cwksp_used(ws) <= neededSpace + 3));

      ////log(3, 'wksp: finished allocating, %zd bytes remain available', ZSTD_cwksp_available_space(ws));
      zc^.initialized := 1;

      exit(0);
    end;
end;

{ ZSTD_invalidateRepCodes() :
 * ensures next compression will not use repcodes from previous block.
 * Note : only works with regular variant;
 *        do not use with extDict variant not  }
procedure ZSTD_invalidateRepCodes(cctx:pZSTD_CCtx);
var
  i:int32; 
begin
    for i:=0 to ZSTD_REP_NUM-1 do 
      cctx^.blockState.prevCBlock^.rep[i] := 0;
    assert(ZSTD_window_hasExtDict(cctx^.blockState.matchState.window)=0);
end;


function ZSTD_shouldAttachDict(const cdict:pZSTD_CDict;
                                 const params:pZSTD_CCtx_params;
                                 pledgedSrcSize:uint64):int32;
var
  cutoff,dedicatedDictSearch:int32;
begin
    cutoff := attachDictSizeCutoffs[ord(cdict^.matchState.cParams.strategy)];
    dedicatedDictSearch := cdict^.matchState.dedicatedDictSearch;
    result := ord ((dedicatedDictSearch<>0)
        or ( ( (pledgedSrcSize <= cutoff)
            or (pledgedSrcSize = ZSTD_CONTENTSIZE_UNKNOWN)
            or (ord(params^.attachDictPref) = ord(ZSTD_dictForceAttach)) )
           and  (ord(params^.attachDictPref) <> ord(ZSTD_dictForceCopy))
           and  (params^.forceWindow=0) )); { dictMatchState isn't correctly
                                      * handled in _enforceMaxDist }
end;

function ZSTD_resetCCtx_byAttachingCDict(cctx:pZSTD_CCtx;const cdict:pZSTD_CDict;
  params:ZSTD_CCtx_params;pledgedSrcSize:Uint64;zbuff:ZSTD_buffered_policy_e ):int32;
var
  adjusted_cdict_cParams:ZSTD_compressionParameters;
  windowLog:uint32;
  cdictEnd,cdictLen:uint32;
  err:int32;
begin

    adjusted_cdict_cParams := cdict^.matchState.cParams;
    windowLog := params.cParams.windowLog;
    assert(windowLog <> 0);
    { Resize working context table params for input only, since the dict
     * has its own tables. }
    { pledgedSrcSize = 0 means 0not  }

    if (cdict^.matchState.dedicatedDictSearch<>0) then
    begin
        ZSTD_dedicatedDictSearch_revertCParams(@adjusted_cdict_cParams);
    end;

    params.cParams := ZSTD_adjustCParams_internal(adjusted_cdict_cParams, pledgedSrcSize,
                                                 cdict^.dictContentSize, ZSTD_cpm_attachDict);
    params.cParams.windowLog := windowLog;
    err:=(ZSTD_resetCCtx_internal(cctx, params, pledgedSrcSize,ZSTDcrp_makeClean, zbuff));
    if (err_isERROR(err)<>0) then
       exit(err);
    assert(cctx^.appliedParams.cParams.strategy = adjusted_cdict_cParams.strategy);

    cdictEnd := uint32( cdict^.matchState.window.nextSrc
                                  - cdict^.matchState.window.base);
    cdictLen := cdictEnd - cdict^.matchState.window.dictLimit;
        if (cdictLen = 0) then
        begin
            { don't even attach dictionaries with no contents }
            ////log(3, 'skipping attaching empty dictionary');
        end
        else 
        begin
            ////log(3, 'attaching dictionary into context');
            cctx^.blockState.matchState.dictMatchState := @cdict^.matchState;

            { prep working match state so dict matches never have negative indices
             * when they are translated to the working context's index space. }
            if (cctx^.blockState.matchState.window.dictLimit < cdictEnd) then
            begin
                cctx^.blockState.matchState.window.nextSrc :=
                    cctx^.blockState.matchState.window.base + cdictEnd;
                ZSTD_window_clear(@cctx^.blockState.matchState.window);
            end;
            { loadedDictEnd is expressed within the referential of the active context }
            cctx^.blockState.matchState.loadedDictEnd := cctx^.blockState.matchState.window.dictLimit;
        end;

    cctx^.dictID := cdict^.dictID;

    { copy block state }
    move(cdict^.cBlockState, cctx^.blockState.prevCBlock,  sizeof(ZSTD_compressedBlockState_t));

    exit(0);
end;

function ZSTD_resetCCtx_byCopyingCDict(cctx:pZSTD_CCtx;
                            const cdict:pZSTD_CDict;
                            params:ZSTD_CCtx_params;
                            pledgedSrcSize:Uint64;
                            zbuff:ZSTD_buffered_policy_e):int32;
var
  srcMatchState,dstMatchState:pZSTD_matchState_t;
  chainSize,hSize,h3log,h3Size,err:int32;
  cdict_cParams:pZSTD_compressionParameters;
  windowLog:uint32;
begin
    cdict_cParams := @cdict^.matchState.cParams;

    assert(cdict^.matchState.dedicatedDictSearch=0);

    ////log(3, 'copying dictionary into context');

    windowLog := params.cParams.windowLog;
    assert(windowLog <> 0);
    { Copy only compression parameters related to tables. }
    params.cParams := cdict_cParams^;
    params.cParams.windowLog := windowLog;
    err:=ZSTD_resetCCtx_internal(cctx, params, pledgedSrcSize,ZSTDcrp_leaveDirty, zbuff);
    if (err_isERROR(err)<>0) then
       exit(err);
    assert(cctx^.appliedParams.cParams.strategy = cdict_cParams^.strategy);
    assert(cctx^.appliedParams.cParams.hashLog = cdict_cParams^.hashLog);
    assert(cctx^.appliedParams.cParams.chainLog = cdict_cParams^.chainLog);

    ZSTD_cwksp_mark_tables_dirty(@cctx^.workspace);

    { copy tables }
    if (cdict_cParams^.strategy = ZSTD_fast) then
      chainSize :=0
    else
      chainSize :=(int32(1) shl cdict_cParams^.chainLog);
    hSize :=  int32(1) shl cdict_cParams^.hashLog;

    move(cdict^.matchState.hashTable^,cctx^.blockState.matchState.hashTable^,hSize * sizeof(uint32));
    move( cdict^.matchState.chainTable^,cctx^.blockState.matchState.chainTable^,chainSize * sizeof(uint32));

    { Zero the hashTable3, since the cdict never fills it }
    h3log := cctx^.blockState.matchState.hashLog3;
    if h3log<>0 then
      h3Size := (int32(1) shl h3log)
    else
      h3Size := 0;
    assert(cdict^.matchState.hashLog3 = 0);
    fillbyte(cctx^.blockState.matchState.hashTable3^, h3Size * sizeof(uint32), 0);

    ZSTD_cwksp_mark_tables_clean(@cctx^.workspace);

    { copy dictionary offsets }
    srcMatchState := @cdict^.matchState;
    dstMatchState := @cctx^.blockState.matchState;
    dstMatchState^.window       := srcMatchState^.window;
    dstMatchState^.nextToUpdate := srcMatchState^.nextToUpdate;
    dstMatchState^.loadedDictEnd:= srcMatchState^.loadedDictEnd;

    cctx^.dictID := cdict^.dictID;

    { copy block state }
    move(cdict^.cBlockState, cctx^.blockState.prevCBlock,  sizeof(ZSTD_compressedBlockState_t));

    exit(0);
end;

{ We have a choice between copying the dictionary context into the working
 * context, or referencing the dictionary context from the working context
 * in-place. We decide here which strategy to use. }
function  ZSTD_resetCCtx_usingCDict(cctx:pZSTD_CCtx;
                            const cdict:pZSTD_CDict;
                            const params:pZSTD_CCtx_params;
                            pledgedSrcSize:Uint64;
                            zbuff:ZSTD_buffered_policy_e):int32;
begin

    ////log(3, 'ZSTD_resetCCtx_usingCDict (pledgedSrcSize:=%u)',pledgedSrcSize);

    if (ZSTD_shouldAttachDict(cdict, params, pledgedSrcSize)<>0) then
    begin
        result := ZSTD_resetCCtx_byAttachingCDict(
            cctx, cdict, params^, pledgedSrcSize, zbuff);
    end
    else 
    begin
        result := ZSTD_resetCCtx_byCopyingCDict(
            cctx, cdict, params^, pledgedSrcSize, zbuff);
    end;
end;

{not  ZSTD_copyCCtx_internal() :
 *  Duplicate an existing context `srcCCtx` into another one `dstCCtx`.
 *  Only works during stage ZSTDcs_init (i.e. after creation, but before first call to ZSTD_compressContinue()).
 *  The 'context', in this case, refers to the hash and chain tables,
 *  entropy tables, and dictionary references.
 * `windowLog` value is enforced if <> 0, otherwise value is copied from srcCCtx.
 * @return : 0, or an error code }
function ZSTD_copyCCtx_internal(dstCCtx:pZSTD_CCtx;
                            const srcCCtx:pZSTD_CCtx;
                            fParams:ZSTD_frameParameters;
                            pledgedSrcSize:Uint64;
                            zbuff:ZSTD_buffered_policy_e):int32;
var
  srcMatchState,dstMatchState:pZSTD_matchState_t;
  chainSize,hSize,h3log,h3Size,err:int32;
  params:ZSTD_CCtx_params;
begin
    ////log(3, 'ZSTD_copyCCtx_internal');
    if (srcCCtx^.stage<>ZSTDcs_init) then
     exit(ERROR(stage_wrong));//'Can''t copy a ctx that's not in init stage.');

    move(srcCCtx^.customMem, dstCCtx^.customMem,  sizeof(ZSTD_customMem));
    params := dstCCtx^.requestedParams;
    { Copy only compression parameters related to tables. }
    params.cParams := srcCCtx^.appliedParams.cParams;
    params.fParams := fParams;
    ZSTD_resetCCtx_internal(dstCCtx, params, pledgedSrcSize,
                            ZSTDcrp_leaveDirty, zbuff);
    assert(dstCCtx^.appliedParams.cParams.windowLog = srcCCtx^.appliedParams.cParams.windowLog);
    assert(dstCCtx^.appliedParams.cParams.strategy = srcCCtx^.appliedParams.cParams.strategy);
    assert(dstCCtx^.appliedParams.cParams.hashLog = srcCCtx^.appliedParams.cParams.hashLog);
    assert(dstCCtx^.appliedParams.cParams.chainLog = srcCCtx^.appliedParams.cParams.chainLog);
    assert(dstCCtx^.blockState.matchState.hashLog3 = srcCCtx^.blockState.matchState.hashLog3);


    ZSTD_cwksp_mark_tables_dirty(@dstCCtx^.workspace);

    { copy tables }
    if (srcCCtx^.appliedParams.cParams.strategy = ZSTD_fast) then
      chainSize := 0
    else
      chainSize := (int32(1) shl srcCCtx^.appliedParams.cParams.chainLog);
    hSize :=  int32(1) shl srcCCtx^.appliedParams.cParams.hashLog;
    h3log := srcCCtx^.blockState.matchState.hashLog3;
    if h3log<>0 then
      h3Size := (int32(1) shl h3log)
    else
      h3Size := 0;

    move(srcCCtx^.blockState.matchState.hashTable^,
          dstCCtx^.blockState.matchState.hashTable^,
           hSize * sizeof(uint32));
    move(srcCCtx^.blockState.matchState.chainTable^,
          dstCCtx^.blockState.matchState.chainTable^,
           chainSize * sizeof(uint32));
    move(srcCCtx^.blockState.matchState.hashTable3^,
           dstCCtx^.blockState.matchState.hashTable3^,
           h3Size * sizeof(uint32));

    ZSTD_cwksp_mark_tables_clean(@dstCCtx^.workspace);


    { copy dictionary offsets }

    srcMatchState := @srcCCtx^.blockState.matchState;
    dstMatchState := @dstCCtx^.blockState.matchState;
    dstMatchState^.window       := srcMatchState^.window;
    dstMatchState^.nextToUpdate := srcMatchState^.nextToUpdate;
    dstMatchState^.loadedDictEnd:= srcMatchState^.loadedDictEnd;

    dstCCtx^.dictID := srcCCtx^.dictID;

    { copy block state }
    move(srcCCtx^.blockState.prevCBlock^,dstCCtx^.blockState.prevCBlock^,  sizeof(srcCCtx^.blockState.prevCBlock^));

    exit(0);
end;

{not  ZSTD_copyCCtx() :
 *  Duplicate an existing context `srcCCtx` into another one `dstCCtx`.
 *  Only works during stage ZSTDcs_init (i.e. after creation, but before first call to ZSTD_compressContinue()).
 *  pledgedSrcSize=0 means 'unknown'.
*   @return : 0, or an error code }
function ZSTD_copyCCtx(dstCCtx:pZSTD_CCtx; const srcCCtx:pZSTD_CCtx;pledgedSrcSize:uint64):int32;
var
  fParams:ZSTD_frameParameters= (contentSizeFlag:1 {content}; checksumFlag:0 {checksum};noDictIDFlag: 0 {noDictID} );
  zbuff:ZSTD_buffered_policy_e;
begin
    zbuff := srcCCtx^.bufferedPolicy;
    //ZSTD_STATIC_ASSERT((uint32)ZSTDb_buffered=1);
    if (pledgedSrcSize=0) then
       pledgedSrcSize := ZSTD_CONTENTSIZE_UNKNOWN;
    fParams.contentSizeFlag := ord(pledgedSrcSize <> ZSTD_CONTENTSIZE_UNKNOWN);

    result := ZSTD_copyCCtx_internal(dstCCtx, srcCCtx,
                                fParams, pledgedSrcSize,
                                zbuff);
end;



{not  ZSTD_reduceTable() :
 *  reduce table indexes by `reducerValue`, or squash to zero.
 *  PreserveMark preserves 'unsorted mark' for btlazy2 strategy.
 *  It must be set to a clear 0/1 value, to remove branch during inlining.
 *  Presume table size is a multiple of ZSTD_ROWSIZE
 *  to help auto-vectorization }
procedure ZSTD_reduceTable_internal (table:puint32; size, reducerValue:uint32; preserveMark:int32);
var
  nbRows,cellNb,rowNb,column:int32;
  adder:uint32;
begin
    nbRows := int32(size) div ZSTD_ROWSIZE;
    cellNb := 0;
    assert((size and (ZSTD_ROWSIZE-1)) = 0);  { multiple of ZSTD_ROWSIZE }
    assert(size < (Uint32(1) shl 31));   { can be casted to int }

    for rowNb:=0 to nbRows-1 do
    begin
        for column:=0 to ZSTD_ROWSIZE-1 do
        begin
            if (preserveMark<>0) then
            begin
              if (table[cellNb] = ZSTD_DUBT_UNSORTED_MARK) then
                 adder :=reducerValue
              else
                  adder :=0;
                table[cellNb] :=table[cellNb] + adder;
            end;
            if (table[cellNb] < reducerValue) then
              table[cellNb] := 0
            else 
              table[cellNb] :=table[cellNb] - reducerValue;
            inc(cellNb);
        end;   
    end;
end;

procedure ZSTD_reduceTable(table:puint32; size, reducerValue:uint32);
begin
    ZSTD_reduceTable_internal(table, size, reducerValue, 0);
end;

procedure ZSTD_reduceTable_btlazy2(table:puint32; size, reducerValue:uint32);
begin
    ZSTD_reduceTable_internal(table, size, reducerValue, 1);
end;

{not  ZSTD_reduceIndex() :
*   rescale all indexes to avoid future overflow (indexes are uint32) }
procedure ZSTD_reduceIndex (ms:pZSTD_matchState_t; params:pZSTD_CCtx_params; const reducerValue:uint32);
var
  h3Size,chainSize,hSize:uint32;
begin
    hSize := Uint32(1) shl params^.cParams.hashLog;
    ZSTD_reduceTable(ms^.hashTable, hSize, reducerValue);

    if (params^.cParams.strategy <> ZSTD_fast) then
    begin
        chainSize := Uint32(1) shl params^.cParams.chainLog;
        if (params^.cParams.strategy = ZSTD_btlazy2) then
            ZSTD_reduceTable_btlazy2(ms^.chainTable, chainSize, reducerValue)
        else
            ZSTD_reduceTable(ms^.chainTable, chainSize, reducerValue);
    end;

    if (ms^.hashLog3<>0) then
    begin
        h3Size := Uint32(1) shl ms^.hashLog3;
        ZSTD_reduceTable(ms^.hashTable3, h3Size, reducerValue);
    end;
end;


{-*******************************************************
*  Block entropic compression
********************************************************}

{ See doc/zstd_compression_format.md for detailed format description }

procedure ZSTD_seqToCodes(const seqStorePtr:pseqStore_t);
var
  sequences:pseqDef;
  llCodeTable,ofCodeTable,mlCodeTable:pbyte;
  u,nbSeq,llv,mlv:uint32;
begin
    sequences := seqStorePtr^.sequencesStart;
    llCodeTable := seqStorePtr^.llCode;
    ofCodeTable := seqStorePtr^.ofCode;
    mlCodeTable := seqStorePtr^.mlCode;
    nbSeq := uint32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart);
    assert(nbSeq <= seqStorePtr^.maxNbSeq);
    for u:=0 to nbSeq-1 do 
    begin
        llv := sequences[u].litLength;
        mlv := sequences[u].matchLength;
        llCodeTable[u] := BYTE(ZSTD_LLcode(llv));
        ofCodeTable[u] := BYTE(ZSTD_highbit32(sequences[u].offset));
        mlCodeTable[u] := BYTE(ZSTD_MLcode(mlv));
    end;
    if (seqStorePtr^.longLengthID=1) then
        llCodeTable[seqStorePtr^.longLengthPos] := MaxLL;
    if (seqStorePtr^.longLengthID=2) then
        mlCodeTable[seqStorePtr^.longLengthPos] := MaxML;
end;

{ ZSTD_useTargetCBlockSize():
 * Returns if target compressed block size param is being used.
 * If used, compression will do best effort to make a compressed block size to be around targetCBlockSize.
 * Returns 1 if true, 0 otherwise. }
function ZSTD_useTargetCBlockSize(const cctxParams:pZSTD_CCtx_params):int32;
begin
    ////log(3, 'ZSTD_useTargetCBlockSize (targetCBlockSize:=%zu)', cctxParams^.targetCBlockSize);
    result := ord(cctxParams^.targetCBlockSize <> 0);
end;

{ ZSTD_entropyCompressSequences_internal():
 * actually compresses both literals and sequences }
function
ZSTD_entropyCompressSequences_internal(seqStorePtr:pseqStore_t;
                          const prevEntropy:pZSTD_entropyCTables_t;
                                nextEntropy:pZSTD_entropyCTables_t;
                          const cctxParams:pZSTD_CCtx_params;
                                dst:pbyte;  dstCapacity:int32;
                                entropyWorkspace:pbyte;entropyWkspSize:int32;
                          const bmi2:int32):int32;
var
  bitstreamSize,longOffsets:int32;
  strategy:ZSTD_strategy;
  count:puint32;
  CTable_LitLength,CTable_OffsetBits,CTable_MatchLength:pFSE_CTable;
  LLtype, Offtype, MLtype,max:uint32;   { compressed, raw or rle }
  sequences:pseqDef;
  ofCodeTable,llCodeTable,mlCodeTable:pbyte;
  ostart,oend,op,seqHead,lastNCount:pbyte;
  nbSeq:int32;
  literals:pbyte;
  litSize,cSize:int32;
  mostFrequent,countSize:int32;
  defaultPolicy:ZSTD_defaultPolicy_e;
begin
    longOffsets := ord(cctxParams^.cParams.windowLog > STREAM_ACCUMULATOR_MIN);
    strategy := cctxParams^.cParams.strategy;
    count := puint32(entropyWorkspace);
    CTable_LitLength := nextEntropy^.fse.litlengthCTable;
    CTable_OffsetBits := nextEntropy^.fse.offcodeCTable;
    CTable_MatchLength := nextEntropy^.fse.matchlengthCTable;
    
    sequences := seqStorePtr^.sequencesStart;
    ofCodeTable := seqStorePtr^.ofCode;
    llCodeTable := seqStorePtr^.llCode;
    mlCodeTable := seqStorePtr^.mlCode;
    ostart := dst;
    oend := ostart + dstCapacity;
    op := ostart;
    nbSeq := int32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart);

    lastNCount := nil;

    entropyWorkspace := pbyte(count + (MaxSeq + 1));
    entropyWkspSize  :=entropyWkspSize - (MaxSeq + 1) * sizeof(uint32);

    ////log(3, 'ZSTD_entropyCompressSequences_internal (nbSeq:=%zu)', nbSeq);
    //ZSTD_STATIC_ASSERT(HUF_WORKSPACE_SIZE >= (1shlMAX(MLFSELog,LLFSELog)));
    assert(entropyWkspSize >= HUF_WORKSPACE_SIZE);

    { Compress literals }
    literals := seqStorePtr^.litStart;
    litSize := int32(seqStorePtr^.lit - literals);
    cSize := ZSTD_compressLiterals(@prevEntropy^.huf, @nextEntropy^.huf,cctxParams^.cParams.strategy,ZSTD_disableLiteralsCompression(cctxParams),op, dstCapacity,literals, litSize,entropyWorkspace, entropyWkspSize,bmi2);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);//'ZSTD_compressLiterals failed'
    assert(cSize <= dstCapacity);
    op :=op + cSize;


    { Sequences Header }
    if ((oend-op) < 3 {max nbSeq Size} + 1 {seqHead}) then
       exit(ERROR(dstint32ooSmall));// 'Can''t fit seq hdr in output bufnot ');
    if (nbSeq < 128) then
    begin
        op^ := BYTE(nbSeq);
        inc(op);
    end
    else 
    if (nbSeq < LONGNBSEQ) then
    begin
        op[0] := BYTE((nbSeq shr 8) + $80);
        op[1] := BYTE(nbSeq);
        op :=op+2;
    end
    else 
    begin
        op[0]:=$FF;
        MEM_writeLE16(op+1, Uint16(nbSeq - LONGNBSEQ));
        op :=op+3;
    end;
    assert(op <= oend);
    if (nbSeq=0) then
    begin
        { Copy the old tables over as if we repeated them }
        move(prevEntropy^.fse,nextEntropy^.fse,  sizeof(ZSTD_fseCTables_t));
        exit(int32(op - ostart));
    end;

    { seqHead : flags for FSE encoding type }
    seqHead := op;
    inc(op);
    assert(op <= oend);

    { convert length/distances into codes }
    ZSTD_seqToCodes(seqStorePtr);
    { build CTable for Literal Lengths }
    max := MaxLL;
    
    mostFrequent := HIST_countFast_wksp(count, @max, llCodeTable, nbSeq, entropyWorkspace, entropyWkspSize);   { Can''t fail }
    ////log(3, 'Building LL table');
    nextEntropy^.fse.litlength_repeatMode := prevEntropy^.fse.litlength_repeatMode;
    LLtype := ord(ZSTD_selectEncodingType(@nextEntropy^.fse.litlength_repeatMode,
                                    count, max, mostFrequent, nbSeq,
                                    LLFSELog, prevEntropy^.fse.litlengthCTable,
                                    @LL_defaultNorm[0], LL_defaultNormLog,
                                    ZSTD_defaultAllowed, strategy));
    ////log(stderr, 'LL selectEncoding done, LLtype=', LLtype, ' max=', max, ' nbSeq=', nbSeq);
    assert((set_basic < set_compressed)  and  (set_rle < set_compressed));
    assert(not (LLtype < ord(set_compressed))  and  (nextEntropy^.fse.litlength_repeatMode <> FSE_repeat_none)); { We don't copy tables }
    countSize := ZSTD_buildCTable(
            op, int32(oend - op),
            CTable_LitLength, LLFSELog, symbolEncodingType_e(LLtype),
            count, max, llCodeTable, nbSeq,
            LL_defaultNorm, LL_defaultNormLog, MaxLL,
            prevEntropy^.fse.litlengthCTable,
            sizeof(prevEntropy^.fse.litlengthCTable),
            entropyWorkspace, entropyWkspSize);
    ////log(stderr, 'LL buildCTable done, countSize=', countSize);
    if (ERR_isError(countSize)<>0) then
       exit(countSize);//'ZSTD_buildCTable for LitLens failed'
    if (LLtype = ord(set_compressed)) then
        lastNCount := op;
    op :=op + countSize;
    assert(op <= oend);
    { build CTable for Offsets }
    max := MaxOff;
    mostFrequent := HIST_countFast_wksp(
            count, @max, ofCodeTable, nbSeq, entropyWorkspace, entropyWkspSize);  { Can''t fail }
        { We can only use the basic table if max <= DefaultMaxOff, otherwise the offsets are too large }
    if (max <= DefaultMaxOff) then
       defaultPolicy := ZSTD_defaultAllowed
    else
        defaultPolicy :=ZSTD_defaultDisallowed;
    ////log(3, 'Building OF table');
    nextEntropy^.fse.offcode_repeatMode := prevEntropy^.fse.offcode_repeatMode;
    Offtype := ord(ZSTD_selectEncodingType(@nextEntropy^.fse.offcode_repeatMode,
                                    count, max, mostFrequent, nbSeq,
                                    OffFSELog, prevEntropy^.fse.offcodeCTable,
                                    @OF_defaultNorm[0], OF_defaultNormLog,
                                    defaultPolicy, strategy));
    assert(not (Offtype < ord(set_compressed))  and  (nextEntropy^.fse.offcode_repeatMode <> FSE_repeat_none)); { We don't copy tables }
    countSize := ZSTD_buildCTable(
            op, int32(oend - op),
            CTable_OffsetBits, OffFSELog, symbolEncodingType_e(Offtype),
            count, max, ofCodeTable, nbSeq,
            OF_defaultNorm, OF_defaultNormLog, DefaultMaxOff,
            prevEntropy^.fse.offcodeCTable,
            sizeof(prevEntropy^.fse.offcodeCTable),
            entropyWorkspace, entropyWkspSize);
    if (ERR_isError(countSize)<>0) then
       exit(countSize);// 'ZSTD_buildCTable for Offsets failed'
    if (Offtype = ord(set_compressed)) then
        lastNCount := op;
    op :=op + countSize;
    assert(op <= oend);
    { build CTable for MatchLengths }
    max := MaxML;
    mostFrequent := HIST_countFast_wksp(
            count, @max, mlCodeTable, nbSeq, entropyWorkspace, entropyWkspSize);   { Can''t fail }
    ////log(3, 'Building ML table (remaining space : %i)', (oend-op));
    nextEntropy^.fse.matchlength_repeatMode := prevEntropy^.fse.matchlength_repeatMode;
    MLtype := ord(ZSTD_selectEncodingType(@nextEntropy^.fse.matchlength_repeatMode,
                                    count, max, mostFrequent, nbSeq,
                                    MLFSELog, prevEntropy^.fse.matchlengthCTable,
                                    @ML_defaultNorm[0], ML_defaultNormLog,
                                    ZSTD_defaultAllowed, strategy));
    assert(not (MLtype < ord(set_compressed))  and  (nextEntropy^.fse.matchlength_repeatMode <> FSE_repeat_none)); { We don't copy tables }
    countSize := ZSTD_buildCTable(
            op, int32(oend - op),
            CTable_MatchLength, MLFSELog, symbolEncodingType_e(MLtype),
            count, max, mlCodeTable, nbSeq,
            ML_defaultNorm, ML_defaultNormLog, MaxML,
            prevEntropy^.fse.matchlengthCTable,
            sizeof(prevEntropy^.fse.matchlengthCTable),
            entropyWorkspace, entropyWkspSize);
    if (ERR_isError(countSize)<>0) then
       exit(countSize);//(, 'ZSTD_buildCTable for MatchLengths failed');
    if (MLtype = ord(set_compressed)) then
        lastNCount := op;
    op :=op + countSize;
    assert(op <= oend);

    seqHead^ := BYTE((LLtype shl 6) + (Offtype shl 4) + (MLtype shl 2));

    bitstreamSize := ZSTD_encodeSequences(op, int32(oend - op),
                                        CTable_MatchLength, mlCodeTable,
                                        CTable_OffsetBits, ofCodeTable,
                                        CTable_LitLength, llCodeTable,
                                        sequences, nbSeq,
                                        longOffsets, bmi2);
    if (ERR_isError(bitstreamSize)<>0) then
      exit(bitstreamSize);//(, 'ZSTD_encodeSequences failed');
    op :=op + bitstreamSize;
    assert(op <= oend);
    { zstd versions <= 1.3.4 mistakenly report corruption when
     * FSE_readNCount() receives a buffer < 4 bytes.
     * Fixed by https://github.com/facebook/zstd/pull/1146.
     * This can happen when the last set_compressed table present is 2
     * bytes and the bitstream is only one byte.
     * In this exceedingly rare case, we will simply emit an uncompressed
     * block, since it isn't worth optimizing.
     }
    if (lastNCount<>nil) and ((op - lastNCount) < 4) then
    begin
        { NCountSize >= 2  and  bitstreamSize > 0 => lastCountSize = 3 }
        assert(op - lastNCount = 3);
        ////log(3, 'Avoiding bug in zstd decoder in versions <= 1.3.4 by emitting an uncompressed block.');
        exit(0);
    end;


    ////log(3, 'compressed block size : %u', (op - ostart));
    result := int32(op - ostart);
end;

function
ZSTD_entropyCompressSequences(seqStorePtr:pseqStore_t;
                       const prevEntropy:pZSTD_entropyCTables_t;
                             nextEntropy:pZSTD_entropyCTables_t;
                       const cctxParams:pZSTD_CCtx_params;
                             dst:pbyte;  dstCapacity:int32;
                             srcSize:int32;
                             entropyWorkspace:pbyte;entropyWkspSize:int32;
                             bmi2:int32):int32;
var
  cSize,maxCSize:int32;
begin
    cSize := ZSTD_entropyCompressSequences_internal(seqStorePtr, prevEntropy, nextEntropy, cctxParams,dst, dstCapacity,entropyWorkspace, entropyWkspSize, bmi2);
    if (cSize = 0) then
      exit(0);
    { When srcSize <= dstCapacity, there is enough space to write a raw uncompressed block.
     * Since we ran out of space, block must be not compressible, so fall back to raw uncompressed block.
     }
    if ((cSize = ERROR(dstint32ooSmall)) and (srcSize <= dstCapacity)) then
        exit(0);  { block not compressed }
    if (ERR_isError(cSize)<>0) then
       exit(cSize);//'ZSTD_entropyCompressSequences_internal failed'
    { Check compressibility }
    maxCSize := srcSize - ZSTD_minGain(srcSize, cctxParams^.cParams.strategy);
    if (cSize >= maxCSize) then
      exit(0);  { block not compressed }
    ////log(3, 'ZSTD_entropyCompressSequences() cSize: %zu\n', cSize);
    result := cSize;
end;

{ ZSTD_selectBlockCompressor() :
 * Not static, but internal use only (used by long distance matcher)
 * assumption : strat is a valid strategy }
function ZSTD_selectBlockCompressor(strat:ZSTD_strategy;dictMode:ZSTD_dictMode_e):ZSTD_blockCompressor;
const
  blockCompressor : array[0..3,0..9] of ZSTD_blockCompressor = (
        ( @ZSTD_compressBlock_fast  { default for 0 },
          @ZSTD_compressBlock_fast,
          @ZSTD_compressBlock_doubleFast,
          @ZSTD_compressBlock_greedy,
          @ZSTD_compressBlock_lazy,
          @ZSTD_compressBlock_lazy2,
          @ZSTD_compressBlock_btlazy2,
          @ZSTD_compressBlock_btopt,
          @ZSTD_compressBlock_btultra,
          @ZSTD_compressBlock_btultra2 ),
        ( @ZSTD_compressBlock_fast_extDict  { default for 0 },
          @ZSTD_compressBlock_fast_extDict,
          @ZSTD_compressBlock_doubleFast_extDict,
          @ZSTD_compressBlock_greedy_extDict,
          @ZSTD_compressBlock_lazy_extDict,
          @ZSTD_compressBlock_lazy2_extDict,
          @ZSTD_compressBlock_btlazy2_extDict,
          @ZSTD_compressBlock_btopt_extDict,
          @ZSTD_compressBlock_btultra_extDict,
          @ZSTD_compressBlock_btultra_extDict ),
        ( @ZSTD_compressBlock_fast_dictMatchState  { default for 0 },
          @ZSTD_compressBlock_fast_dictMatchState,
          @ZSTD_compressBlock_doubleFast_dictMatchState,
          @ZSTD_compressBlock_greedy_dictMatchState,
          @ZSTD_compressBlock_lazy_dictMatchState,
          @ZSTD_compressBlock_lazy2_dictMatchState,
          @ZSTD_compressBlock_btlazy2_dictMatchState,
          @ZSTD_compressBlock_btopt_dictMatchState,
          @ZSTD_compressBlock_btultra_dictMatchState,
          @ZSTD_compressBlock_btultra_dictMatchState ),
        ( nil  { default for 0 },
          nil,
          nil,
          @ZSTD_compressBlock_greedy_dedicatedDictSearch,
          @ZSTD_compressBlock_lazy_dedicatedDictSearch,
          @ZSTD_compressBlock_lazy2_dedicatedDictSearch,
          nil,
          nil,
          nil,
          nil )
    );
var
    selectedCompressor:ZSTD_blockCompressor;
begin

    //ZSTD_STATIC_ASSERT((unsigned)ZSTD_fast = 1);

    assert(ZSTD_cParam_withinBounds(ZSTD_c_strategy, ord(strat))<>0);
    selectedCompressor := blockCompressor[int32(dictMode)][int32(strat)];
    assert(selectedCompressor <> nil);
    result := selectedCompressor;
end;

procedure ZSTD_storeLastLiterals(seqStorePtr:pseqStore_t;
                                   const anchor:pbyte;lastLLSize:int32);
begin
  move(anchor^, seqStorePtr^.lit^,  lastLLSize);
  seqStorePtr^.lit :=seqStorePtr^.lit + lastLLSize;
end;

procedure ZSTD_resetSeqStore(ssPtr:pseqStore_t);
begin
  ssPtr^.lit := ssPtr^.litStart;
  ssPtr^.sequences := ssPtr^.sequencesStart;
  ssPtr^.longLengthID := 0;
end;



function ZSTD_buildSeqStore(zc:pZSTD_CCtx; const src:pbyte;srcSize:int32):int32;
var
  ms:pZSTD_matchState_t;
  base,istart,lastLiterals:pbyte;
  curr:uint32;
  dictMode:ZSTD_dictMode_e;
  lastLLSize,i,err:int32;
  blockCompressor:ZSTD_blockCompressor;
  ldmSeqStore:rawSeqStore_t;
begin
    ms := @zc^.blockState.matchState;
    ////log(3, 'ZSTD_buildSeqStore (srcSize:=%zu)', srcSize);
    assert(srcSize <= ZSTD_BLOCKSIZE_MAX);
    { Assert that we have correctly flushed the ctx params into the ms's copy }
    ZSTD_assertEqualCParams(zc^.appliedParams.cParams, ms^.cParams);
    if (srcSize < MIN_CBLOCK_SIZE+ZSTD_blockHeaderSize+1) then
    begin
        if (zc^.appliedParams.cParams.strategy >= ZSTD_btopt) then
        begin
            ZSTD_ldm_skipRawSeqStoreBytes(@zc^.externSeqStore, srcSize);
        end
        else 
        begin
            ZSTD_ldm_skipSequences(@zc^.externSeqStore, srcSize, zc^.appliedParams.cParams.minMatch);
        end;
        exit(ord(ZSTDbss_noCompress)); { don't even attempt compression below a certain srcSize }
    end;
    ZSTD_resetSeqStore(@(zc^.seqStore));
    { required for optimal parser to read stats from dictionary }
    ms^.opt.symbolCosts := @zc^.blockState.prevCBlock^.entropy;
    { tell the optimal parser how we expect to compress literals }
    ms^.opt.literalCompressionMode := zc^.appliedParams.literalCompressionMode;
    { a gap between an attached dict and the current window is not safe,
     * they must remain adjacent,
     * and when that stops being the case, the dict must be unset }
    assert((ms^.dictMatchState = nil) or (ms^.loadedDictEnd = ms^.window.dictLimit));
 
    { limited update after a very long match }
    base := ms^.window.base;
    istart := src;
    curr := uint32(istart-base);
    if (sizeof(pbyte)=8) then
      assert(istart - base < uint32(-1));   { ensure no overflow }
    if (curr > ms^.nextToUpdate + 384) then
      ms^.nextToUpdate := curr - MIN(192, uint32(curr - ms^.nextToUpdate - 384));

    { select and store sequences }
    dictMode := ZSTD_matchState_dictMode(ms);

    for i := 0 to ZSTD_REP_NUM -1 do
        zc^.blockState.nextCBlock^.rep[i] := zc^.blockState.prevCBlock^.rep[i];
    if (zc^.externSeqStore.pos < zc^.externSeqStore.size) then
    begin
        assert( zc^.appliedParams.ldmParams.enableLdm=0);
        { Updates ldmSeqStore.pos }
        lastLLSize :=
            ZSTD_ldm_blockCompress(@zc^.externSeqStore,
                                   ms, @zc^.seqStore,
                                   zc^.blockState.nextCBlock^.rep,
                                   src, srcSize);
        assert(zc^.externSeqStore.pos <= zc^.externSeqStore.size);
    end
    else 
    if (zc^.appliedParams.ldmParams.enableLdm<>0) then
    begin
        ldmSeqStore := knilRawSeqStore;

        ldmSeqStore.seq := zc^.ldmSequences;
        ldmSeqStore.capacity := zc^.maxNbLdmSequences;
        { Updates ldmSeqStore.size }

        err:=ZSTD_ldm_generateSequences(@zc^.ldmState, @ldmSeqStore,@zc^.appliedParams.ldmParams,src, srcSize);
        if (ERR_isError(err)<>0) then
           exit(err);
        { Updates ldmSeqStore.pos }
        lastLLSize :=
            ZSTD_ldm_blockCompress(@ldmSeqStore,
                                   ms, @zc^.seqStore,
                                   zc^.blockState.nextCBlock^.rep,
                                   src, srcSize);
        assert(ldmSeqStore.pos = ldmSeqStore.size);
    end
    else 
    begin   { not long range mode }
        blockCompressor := ZSTD_selectBlockCompressor(zc^.appliedParams.cParams.strategy, dictMode);
        ms^.ldmSeqStore := nil;
        lastLLSize := blockCompressor(ms, @zc^.seqStore, zc^.blockState.nextCBlock^.rep, src, srcSize);
    end;
    lastLiterals := src + srcSize - lastLLSize;
    ZSTD_storeLastLiterals(@zc^.seqStore, lastLiterals, lastLLSize);
    result := ord(ZSTDbss_compress);
end;

procedure ZSTD_copyBlockSequences(zc:pZSTD_CCtx);
var
  seqStore:pseqStore_t;
  seqStoreSeqs:pseqDef;
  seqStoreSeqSize,seqStoreLiteralsSize,literalsRead,lastLLSize:int32;
  outSeqs:pZSTD_Sequence;
  i:int32;
  updatedRepcodes:repcodes_t;
  rawOffset:uint32;
begin
    seqStore := ZSTD_getSeqStore(zc);
    seqStoreSeqs := seqStore^.sequencesStart;
    seqStoreSeqSize := seqStore^.sequences - seqStoreSeqs;
    seqStoreLiteralsSize := int32(seqStore^.lit - seqStore^.litStart);
    literalsRead := 0;
    outSeqs := @zc^.lseqCollector.seqStart[zc^.lseqCollector.seqIndex];
    assert(zc^.lseqCollector.seqIndex + 1 < zc^.lseqCollector.maxSequences);
    { Ensure we have enough space for last literals 'sequence' }
    assert(zc^.lseqCollector.maxSequences >= seqStoreSeqSize + 1);
    move(zc^.blockState.prevCBlock^.rep, updatedRepcodes.rep,  sizeof(repcodes_t));
    for i := 0 to seqStoreSeqSize-1 do
    begin
        rawOffset := seqStoreSeqs[i].offset - ZSTD_REP_NUM;
        outSeqs[i].litLength := seqStoreSeqs[i].litLength;
        outSeqs[i].matchLength := seqStoreSeqs[i].matchLength + MINMATCH;
        outSeqs[i].rep := 0;

        if (i = seqStore^.longLengthPos) then
        begin
            if (seqStore^.longLengthID = 1) then
            begin
                outSeqs[i].litLength :=outSeqs[i].litLength + $10000;
            end
            else 
            if (seqStore^.longLengthID = 2) then
            begin
                outSeqs[i].matchLength :=outSeqs[i].matchLength + $10000;
            end;
        end;

        if (seqStoreSeqs[i].offset <= ZSTD_REP_NUM) then
        begin
            { Derive the correct offset corresponding to a repcode }
            outSeqs[i].rep := seqStoreSeqs[i].offset;
            if (outSeqs[i].litLength <> 0) then
            begin
                rawOffset := updatedRepcodes.rep[outSeqs[i].rep - 1];
            end
            else 
            begin
                if (outSeqs[i].rep = 3) then
                begin
                    rawOffset := updatedRepcodes.rep[0] - 1;
                end
                else 
                begin
                    rawOffset := updatedRepcodes.rep[outSeqs[i].rep];
                end;
            end;
        end;
        outSeqs[i].offset := rawOffset;
        { seqStoreSeqs[i].offset = offCode+1, and ZSTD_updateRep() expects offCode
           so we provide seqStoreSeqs[i].offset - 1 }
        updatedRepcodes := ZSTD_updateRep(updatedRepcodes.rep,
                                         seqStoreSeqs[i].offset - 1,
                                         ord(seqStoreSeqs[i].litLength = 0));
        literalsRead :=literalsRead + outSeqs[i].litLength;
    end;
    { Insert last literals (if any exist) in the block as a sequence with ml = off = 0.
     * If there are no last literals, then we'll emit (of: 0, ml: 0, ll: 0), which is a marker
     * for the block boundary, according to the API.
     }
    assert(seqStoreLiteralsSize >= literalsRead);
    lastLLSize := seqStoreLiteralsSize - literalsRead;
    outSeqs[i].litLength := uint32(lastLLSize);
    outSeqs[i].rep := 0;
    outSeqs[i].offset := 0;
    outSeqs[i].matchLength := 0;
    inc(seqStoreSeqSize);
    zc^.lseqCollector.seqIndex :=zc^.lseqCollector.seqIndex + seqStoreSeqSize;
end;

function ZSTD_generateSequences(zc:pZSTD_CCtx; outSeqs:pZSTD_Sequence;
  outSeqsSize:int32; const src:pbyte;srcSize:int32):int32;
var
  dstCapacity:int32;
  dst:pbyte;
  lseqCollector:SeqCollector;
begin
    dstCapacity := ZSTD_compressBound(srcSize);
    dst := ZSTD_customMalloc(dstCapacity, ZSTD_defaultCMem);
    
    IF(dst = nil) then
    EXIT(ERROR(memory_allocation));//, 'nil pointernot ');

    lseqCollector.collectSequences := 1;
    lseqCollector.seqStart := outSeqs;
    lseqCollector.seqIndex := 0;
    lseqCollector.maxSequences := outSeqsSize;
    zc^.lseqCollector := lseqCollector;

    ZSTD_compress2(zc, dst, dstCapacity, src, srcSize);
    ZSTD_customfree(dst, ZSTD_defaultCMem);
    result := zc^.lseqCollector.seqIndex;
end;

function ZSTD_mergeBlockDelimiters(sequences:pZSTD_Sequence;seqsSize:int32):int32;
var
  lin,lout:int32; 
begin
    lin := 0;
    lout := 0;
    while (lin < seqsSize) do
    begin
        if (sequences[lin].offset = 0)  and  (sequences[lin].matchLength = 0) then
        begin
            if (lin <> seqsSize - 1) then
            begin
                sequences[lin+1].litLength :=sequences[lin+1].litLength + sequences[lin].litLength;
            end;
        end
        else 
        begin
            sequences[lout] := sequences[lin];
            inc(lout);
        end;
        inc(lin);
    end;
    result := lout;
end;

{ Unrolled loop to read four int32s of input at a time. Returns 1 if is RLE, 0 if not. }
function ZSTD_isRLE(const src:pbyte;llength:int32) :int32;
var
  ip:pbyte;
  value:byte;
  valueST,unrollSize,unrollMask,prefixLength,i,u:int32;
begin
    ip := src;
    value := ip[0];
    valueST := int32(Uint64(value) * Uint32($0101010101010101));
    unrollSize := sizeof(int32) * 4;
    unrollMask := unrollSize - 1;
    prefixLength := llength and unrollMask;

    if (llength = 1) then
      exit(1);
    { Check if prefix is RLE first before using unrolled loop }
    if (prefixLength  and  ZSTD_count(ip+1, ip, ip+prefixLength) <> prefixLength-1) then
    begin
        exit(0);
    end;
    i := prefixLength;
    while  (i <> llength) do
    begin
        u := 0;
        while ( u < unrollSize) do
        begin
            if (pint32(ip + i + u)^ <> valueST) then
            begin
                exit(0);
            end;
            u :=u + sizeof(int32);
        end;
        i :=i + unrollSize;
    end;
    result := 1;
end;

{ Returns true if the given block may be RLE.
 * This is just a heuristic based on the compressibility.
 * It may return both false positives and false negatives.
 }
function ZSTD_maybeRLE(seqStore:pseqStore_t ):int32;
var
  nbSeqs,nbLits:int32;
begin
    nbSeqs := int32(seqStore^.sequences - seqStore^.sequencesStart);
    nbLits := int32(seqStore^.lit - seqStore^.litStart);

    result := ord((nbSeqs < 4)  and  (nbLits < 10));
end;

procedure ZSTD_confirmRepcodesAndEntropyTables(zc:pZSTD_CCtx);
var
  tmp:pZSTD_compressedBlockState_t;
begin
    tmp := zc^.blockState.prevCBlock;
    zc^.blockState.prevCBlock := zc^.blockState.nextCBlock;
    zc^.blockState.nextCBlock := tmp;
end;

function ZSTD_compressBlock_internal(zc:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32; frame:uint32 ):int32;
label lout;
var
  rleMaxLength:uint32;
  cSize,bss:int32;
  ip,op:pbyte;
begin
    { This the upper bound for the length of an rle block.
     * This isn't the actual upper bound. Finding the real threshold
     * needs further investigation.
     }
    rleMaxLength := 25;
    ip := src;
    op := dst;
    ////log(3, 'ZSTD_compressBlock_internal (dstCapacity:=%u, dictLimit:=%u, nextToUpdate:=%u)',
    //            dstCapacity, zc^.blockState.matchState.window.dictLimit,
    //            zc^.blockState.matchState.nextToUpdate);

    bss := ZSTD_buildSeqStore(zc, src, srcSize);
    if (ERR_isError(bss)<>0) then
       exit(bss);
    if (bss = ord(ZSTDbss_noCompress)) then
    begin 
      cSize := 0; 
      goto lout; 
    end;
    

    if (zc^.lseqCollector.collectSequences<>0) then
    begin
        ZSTD_copyBlockSequences(zc);
        ZSTD_confirmRepcodesAndEntropyTables(zc);
        exit(0);
    end;

    { encode sequences and literals }
    cSize := ZSTD_entropyCompressSequences(@zc^.seqStore,
            @zc^.blockState.prevCBlock^.entropy, @zc^.blockState.nextCBlock^.entropy,
            @zc^.appliedParams,
            dst, dstCapacity,
            srcSize,
            pbyte(zc^.entropyWorkspace), ENTROPY_WORKSPACE_SIZE { statically allocated in resetCCtx },
            zc^.bmi2);

    if (zc^.lseqCollector.collectSequences<>0) then
    begin
        ZSTD_copyBlockSequences(zc);
        exit(0);
    end;


    if (frame  and 
        { We don't want to emit our first block as a RLE even if it qualifies because
         * doing so will cause the decoder (cli only) to throw a 'should consume all input error.'
         * This is only an issue for zstd <= v1.4.3
         }
        not zc^.isFirstBlock  and 
        cSize < rleMaxLength  and 
        ZSTD_isRLE(ip, srcSize)) then
    begin
        cSize := 1;
        op[0] := ip[0];
    end;

lout:
    if (not ZSTD_isError(cSize)  and  cSize > 1) then 
    begin
        ZSTD_confirmRepcodesAndEntropyTables(zc);
    end;
    { We check that dictionaries have offset codes available for the first
     * block. After the first block, the offcode table might not have large
     * enough codes to represent the offsets in the data.
     }
    if (zc^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode = FSE_repeat_valid) then
        zc^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode := FSE_repeat_check;

    result := cSize;
end;

function ZSTD_compressBlock_targetCBlockSize_body(zc:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;const bss:int32; lastBlock:uint32):int32;
var
  cSize,maxCSize:int32;
begin
    ////log(3, 'Attempting ZSTD_compressSuperBlock()');
    if (bss = ord(ZSTDbss_compress)) then
    begin
        if ({ We don't want to emit our first block as a RLE even if it qualifies because
            * doing so will cause the decoder (cli only) to throw a 'should consume all input error.'
            * This is only an issue for zstd <= v1.4.3
            }
            (zc^.isFirstBlock=0)  and
            (ZSTD_maybeRLE(@zc^.seqStore)<>0)  and 
            (ZSTD_isRLE(src, srcSize)<>0)) then
        begin
            exit(ZSTD_rleCompressBlock(dst, dstCapacity, src^, srcSize, lastBlock));
        end;
        { Attempt superblock compression.
         *
         * Note that compressed size of ZSTD_compressSuperBlock() is not bound by the
         * standard ZSTD_compressBound(). This is a problem, because even if we have
         * space now, taking an extra byte now could cause us to run out of space later
         * and violate ZSTD_compressBound().
         *
         * Define blockBound(blockSize) := blockSize + ZSTD_blockHeaderSize.
         *
         * In order to respect ZSTD_compressBound() we must attempt to emit a raw
         * uncompressed block in these cases:
         *   * cSize = 0: Return code for an uncompressed block.
         *   * cSize = dstint32ooSmall: We may have expanded beyond blockBound(srcSize).
         *     ZSTD_noCompressBlock() will return dstint32ooSmall if we are really out of
         *     output space.
         *   * cSize >= blockBound(srcSize): We have expanded the block too much so
         *     emit an uncompressed block.
         }
        begin
            cSize := ZSTD_compressSuperBlock(zc, dst, dstCapacity, src, srcSize, lastBlock);
            if (cSize <> ERROR(dstint32ooSmall)) then
            begin
                maxCSize := srcSize - ZSTD_minGain(srcSize, zc^.appliedParams.cParams.strategy);
                if (ERR_isError(cSize)<>0) then
                   exit(cSize);//'ZSTD_compressSuperBlock failed'
                if (cSize <> 0)  and  (cSize < maxCSize + ZSTD_blockHeaderSize) then
                begin
                    ZSTD_confirmRepcodesAndEntropyTables(zc);
                    exit(cSize);
                end;
            end;
        end;
    end;

    ////log(3, 'Resorting to ZSTD_noCompressBlock()');
    { Superblock compression failed, attempt to emit a single no compress block.
     * The decoder will be able to stream this block since it is uncompressed.
     }
    result := ZSTD_noCompressBlock(dst, dstCapacity, src, srcSize, lastBlock);
end;

function ZSTD_compressBlock_targetCBlockSize(zc:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;lastBlock:uint32 ):int32;
var
  cSize,bss:int32;
begin
    cSize := 0;
    bss := ZSTD_buildSeqStore(zc, src, srcSize);
    ////log(3, 'ZSTD_compressBlock_targetCBlockSize (dstCapacity:=%u, dictLimit:=%u, nextToUpdate:=%u, srcSize:=%zu)',
    //            dstCapacity, zc^.blockState.matchState.window.dictLimit, zc^.blockState.matchState.nextToUpdate, srcSize);
    //FORWARD_IF_ERROR(bss, 'ZSTD_buildSeqStore failed');
    if (ERR_isError(bss)<>0) then
       exit(bss);
    cSize := ZSTD_compressBlock_targetCBlockSize_body(zc, dst, dstCapacity, src, srcSize, bss, lastBlock);
    //FORWARD_IF_ERROR(cSize, 'ZSTD_compressBlock_targetCBlockSize_body failed');
    if (ERR_isError(cSize)<>0) then
       exit(bss);
    if (zc^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode = FSE_repeat_valid) then
        zc^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode := FSE_repeat_check;

    result := cSize;
end;

procedure ZSTD_overflowCorrectIfNeeded(ms:pZSTD_matchState_t;ws:pZSTD_cwksp;
  params:pZSTD_CCtx_params;ip:pbyte;iend:pbyte);
var
  maxDist,cycleLog,correction:uint32;
begin
    if (ZSTD_window_needOverflowCorrection(ms^.window, iend)<>0) then
    begin
        maxDist := Uint32(1) shl params^.cParams.windowLog;
        cycleLog := ZSTD_cycleLog(params^.cParams.chainLog, params^.cParams.strategy);
        correction := ZSTD_window_correctOverflow(@ms^.window, cycleLog, maxDist, ip);
        //ZSTD_STATIC_ASSERT(ZSTD_CHAINLOG_MAX <= 30);
        //ZSTD_STATIC_ASSERT(ZSTD_WINDOWLOG_MAX_32 <= 30);
        //ZSTD_STATIC_ASSERT(ZSTD_WINDOWLOG_MAX <= 31);
        ZSTD_cwksp_mark_tables_dirty(ws);
        ZSTD_reduceIndex(ms, params, correction);
        ZSTD_cwksp_mark_tables_clean(ws);
        if (ms^.nextToUpdate < correction) then
          ms^.nextToUpdate := 0
        else 
          ms^.nextToUpdate :=ms^.nextToUpdate - correction;
        { invalidate dictionaries on overflow correction }
        ms^.loadedDictEnd := 0;
        ms^.dictMatchState := nil;
    end;
end;

{not  ZSTD_compress_frameChunk() :
*   Compress a chunk of data into one or multiple blocks.
*   All blocks will be terminated, all input will be consumed.
*   Function will issue an error if there is not enough `dstCapacity` to hold the compressed content.
*   Frame is supposed already started (header already produced)
*   @return : compressed size, or an error code
}
function ZSTD_compress_frameChunk (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;lastFrameChunk:uint32 ):int32;
var
  blockSize,remaining,cSize:int32;
  ip,ostart,op:pbyte;
  maxDist,lastBlock,cBlockHeader:uint32;
  ms:pZSTD_matchState_t; 
begin
    blockSize := cctx^.blockSize;
    remaining := srcSize;
    ip := src;
    ostart := dst;
    op := ostart;
    maxDist := Uint32(1) shl cctx^.appliedParams.cParams.windowLog;

    assert(cctx^.appliedParams.cParams.windowLog <= ZSTD_WINDOWLOG_MAX);

    ////log(3, 'ZSTD_compress_frameChunk (blockSize:=%u)', blockSize);
    if (cctx^.appliedParams.fParams.checksumFlag<>0)  and  (srcSize<>0) then
        XXH64_update(@cctx^.xxhState, src, srcSize);

    while (remaining<>0) do
    begin
        ms := @cctx^.blockState.matchState;
        lastBlock := lastFrameChunk and ord(blockSize >= remaining);

        if (dstCapacity < ZSTD_blockHeaderSize + MIN_CBLOCK_SIZE) then
           exit(ERROR(dstint32ooSmall));//'not enough space to store compressed block');
        if (remaining < blockSize) then
          blockSize := remaining;

        ZSTD_overflowCorrectIfNeeded(ms, @cctx^.workspace, @cctx^.appliedParams, ip, ip + blockSize);
        ZSTD_checkDictValidity(@ms^.window, ip + blockSize, maxDist, @ms^.loadedDictEnd, @ms^.dictMatchState);

        { Ensure hash/chain table insertion resumes no sooner than lowlimit }
        if (ms^.nextToUpdate < ms^.window.lowLimit) then
          ms^.nextToUpdate := ms^.window.lowLimit;

        
        if (ZSTD_useTargetCBlockSize(@cctx^.appliedParams)<>0) then
        begin
            cSize := ZSTD_compressBlock_targetCBlockSize(cctx, op, dstCapacity, ip, blockSize, lastBlock);
            //FORWARD_IF_ERROR(cSize, 'ZSTD_compressBlock_targetCBlockSize failed');
            if (ERR_isError(cSize)<>0) then
              exit(cSize);
            assert(cSize > 0);
            assert(cSize <= blockSize + ZSTD_blockHeaderSize);
        end
        else 
        begin
            cSize := ZSTD_compressBlock_internal(cctx,op+ZSTD_blockHeaderSize, dstCapacity-ZSTD_blockHeaderSize,
                                    ip, blockSize, 1 { frame });
            //FORWARD_IF_ERROR(cSize, 'ZSTD_compressBlock_internal failed');
            if (ERR_isError(cSize)<>0) then
              exit(cSize);
            if (cSize = 0) then
            begin  { block is not compressible }
                cSize := ZSTD_noCompressBlock(op, dstCapacity, ip, blockSize, lastBlock);
                //FORWARD_IF_ERROR(cSize, 'ZSTD_noCompressBlock failed');
                if (ERR_isError(cSize)<>0) then
                  exit(cSize);
            end
            else 
            begin
              if cSize = 1 then
                cBlockHeader := lastBlock + ((uint32(bt_rle) shl 1) + uint32(blockSize shl 3))
              else
                cBlockHeader := lastBlock + ((uint32(bt_compressed) shl 1) + uint32(cSize shl 3));
              MEM_writeLE24(op, cBlockHeader);
              cSize :=cSize + ZSTD_blockHeaderSize;
            end;
        end;


        ip :=ip + blockSize;
        assert(remaining >= blockSize);
        remaining :=remaining - blockSize;
        op :=op + cSize;
        assert(dstCapacity >= cSize);
        dstCapacity :=dstCapacity - cSize;
        cctx^.isFirstBlock := 0;
        ////log(3, 'ZSTD_compress_frameChunk: adding a block of size %u',cSize);
    end;

    if ((lastFrameChunk<>0)  and  (op>ostart)) then
      cctx^.stage := ZSTDcs_ending;
    result := int32(op-ostart);
end;


function ZSTD_writeFrameHeader(dst:pbyte;  dstCapacity:int32;
  const params:pZSTD_CCtx_params; pledgedSrcSize:Uint64; dictID:uint32 ):int32;
var
  op:pbyte;
  windowLogByte,frameHeaderDescriptionByte:byte;
  dictIDSizeCodeLength,dictIDSizeCode,checksumFlag,windowSize,singleSegment,fcsCode:uint32;
  pos:int32;
begin
  op := dst;
  dictIDSizeCodeLength := ord(dictID>0) + ord(dictID>=256) + ord(dictID>=65536);   { 0-3 }
  if params^.fParams.noDictIDFlag<>0 then
    dictIDSizeCode :=  0{ 0-3 }
  else
    dictIDSizeCode :=  dictIDSizeCodeLength;   { 0-3 }
  checksumFlag := ord(params^.fParams.checksumFlag>0);
  windowSize := Uint32(1) shl params^.cParams.windowLog;
  singleSegment := params^.fParams.contentSizeFlag  and  ord(windowSize >= pledgedSrcSize);
  windowLogByte := BYTE((params^.cParams.windowLog - ZSTD_WINDOWLOG_ABSOLUTEMIN) shl 3);
  if params^.fParams.contentSizeFlag<>0 then
    fcsCode :=  ord(pledgedSrcSize>=256) + ord(pledgedSrcSize>=65536+256) + ord(pledgedSrcSize>=$FFFFFFFF)  { 0-3 }
  else
    fcsCode :=  0;  { 0-3 }
  frameHeaderDescriptionByte := BYTE(dictIDSizeCode + (checksumFlag shl 2) + (singleSegment shl 5) + (fcsCode shl 6) );
  pos:=0;

  assert(not (params^.fParams.contentSizeFlag  and  pledgedSrcSize = ZSTD_CONTENTSIZE_UNKNOWN));
  IF (dstCapacity < ZSTD_FRAMEHEADERSIZE_MAX) then
    exit(ERROR(dstint32ooSmall));//'dst buf is too small to fit worst-case frame header size.');
  ////log(3, 'ZSTD_writeFrameHeader : dictIDFlag : %u ; dictID : %u ; dictIDSizeCode : %u',
  //            not params^.fParams.noDictIDFlag, dictID, dictIDSizeCode);
  if (params^.format = ZSTD_f_zstd1) then
  begin
      MEM_writeLE32(dst, ZSTD_MAGICNUMBER);
      pos := 4;
  end;
  op[pos] := frameHeaderDescriptionByte;
  inc(pos);
  if (singleSegment=0) then
  begin
   op[pos] := windowLogByte;
   inc(pos);
  end;
  case(dictIDSizeCode) of

      0 :;
      1 : 
      begin
        op[pos] := BYTE(dictID);
        inc(pos);
      end;
      2 : 
      begin
        MEM_writeLE16(op+pos, Uint16(dictID));
        pos:=pos+2;
      end;
      3 : 
      begin
        MEM_writeLE32(op+pos, dictID); 
        pos:=pos+4;
      end;
      else  assert(false); { impossible }
  end;
  case(fcsCode) of

      0 : 
      begin
        if (singleSegment<>0) then
        begin
          op[pos] := BYTE(pledgedSrcSize);
          inc(pos);
        end;
      end;
      1 : 
      begin
        MEM_writeLE16(op+pos, Uint16(pledgedSrcSize-256));
        pos:=pos+2;
      end;
      2 : 
      begin
        MEM_writeLE32(op+pos, uint32(pledgedSrcSize));
        pos:=pos+4;
      end ;
      3 : 
      begin
        MEM_writeLE64(op+pos, Uint64(pledgedSrcSize));
        pos:=pos+8;
      end;
      else  assert(false); { impossible }
  end;
  result := pos;
end;

{ ZSTD_writeSkippableFrame_advanced() :
 * Writes out a skippable frame with the specified magic number variant (16 are supported), 
 * from ZSTD_MAGIC_SKIPPABLE_START to ZSTD_MAGIC_SKIPPABLE_START+15, and the desired source data.
 * 
 * Returns the total number of bytes written, or a ZSTD error code.
 }
function ZSTD_writeSkippableFrame(dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32; magicVariant:uint32 ) :int32;
var
  op:pbyte;
begin
    op := dst;
    IF (dstCapacity < srcSize + ZSTD_SKIPPABLEHEADERSIZE { Skippable frame overhead }) then
      exit(ERROR(dstint32ooSmall));// 'Not enough room for skippable frame');
    if (srcSize > Uint32($FFFFFFFF)) then
      exit(ERROR(srcSize_wrong));// 'Src size too large for skippable frame');
    IF (magicVariant > 15) then
      exit(ERROR(parameter_outOfBound));//, 'Skippable frame magic number variant not supported');

    MEM_writeLE32(op, uint32(ZSTD_MAGIC_SKIPPABLE_START + magicVariant));
    MEM_writeLE32(op+4, uint32(srcSize));
    move(src[0],op[8],  srcSize);
    result := srcSize + ZSTD_SKIPPABLEHEADERSIZE;
end;

{ ZSTD_writeLastEmptyBlock() :
 * output an empty Block with end-of-frame mark to complete a frame
 * @return : size of data written into `dst` (= ZSTD_blockHeaderSize (defined in zstd_internal.h))
 *           or an error code if `dstCapacity` is too small (<ZSTD_blockHeaderSize)
 }
function ZSTD_writeLastEmptyBlock(dst:pbyte;dstCapacity:int32):int32;
var
  cBlockHeader24:uint32;
begin
    IF (dstCapacity < ZSTD_blockHeaderSize) then
      exit(ERROR(dstint32ooSmall));//'dst buf is too small to write frame trailer empty block.');
    cBlockHeader24 := 1 {lastBlock} + ((uint32(bt_raw) shl 1));  { 0 size }
    MEM_writeLE24(dst, cBlockHeader24);
    result := ZSTD_blockHeaderSize;
end;

function ZSTD_referenceExternalSequences(cctx:pZSTD_CCtx;seq:prawSeq;nbSeq:int32):int32;
begin
    IF (cctx^.stage <> ZSTDcs_init) then
      exit(ERROR(stage_wrong)); //'wrong cctx stage');
    IF (cctx^.appliedParams.ldmParams.enableLdm<>0) then
      exit(ERROR(parameter_unsupported));//'incompatible with ldm');
    cctx^.externSeqStore.seq := seq;
    cctx^.externSeqStore.size := nbSeq;
    cctx^.externSeqStore.capacity := nbSeq;
    cctx^.externSeqStore.pos := 0;
    cctx^.externSeqStore.posInSequence := 0;
    exit(0);
end;


function ZSTD_compressContinue_internal (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32; frame,  lastFrameChunk:uint32):int32;
var
  cSize,fhSize:int32;
  ms:pZSTD_matchState_t;
begin
    ms := @cctx^.blockState.matchState;
    fhSize := 0;

    ////log(3, 'ZSTD_compressContinue_internal, stage: %u, srcSize: %u',
    //            cctx^.stage, srcSize);
    IF (cctx^.stage=ZSTDcs_created) then
      exit(ERROR(stage_wrong));//'missing init (ZSTD_compressBegin)');

    if (frame<>0)  and  (cctx^.stage=ZSTDcs_init) then
    begin
        fhSize := ZSTD_writeFrameHeader(dst, dstCapacity, @cctx^.appliedParams,
                                       cctx^.pledgedSrcSizePlusOne-1, cctx^.dictID);
        //FORWARD_IF_ERROR(fhSize, 'ZSTD_writeFrameHeader failed');
        if (ERR_isError(fhSize)<>0) then
         exit(fhSize);
        assert(fhSize <= dstCapacity);
        dstCapacity :=dstCapacity - fhSize;
        dst := dst + fhSize;
        cctx^.stage := ZSTDcs_ongoing;
    end;

    if (srcSize=0) then
      exit(fhSize);  { do not generate an empty block if no input }

    if (ZSTD_window_update(@ms^.window, src, srcSize)=0) then
    begin
        ms^.nextToUpdate := ms^.window.dictLimit;
    end;
    if (cctx^.appliedParams.ldmParams.enableLdm<>0) then
    begin
        ZSTD_window_update(@cctx^.ldmState.window, src, srcSize);
    end;

    if (frame=0) then
    begin
        { overflow check and correction for block mode }
        ZSTD_overflowCorrectIfNeeded(ms, @cctx^.workspace, @cctx^.appliedParams,src, src + srcSize);
    end;

    ////log(3, 'ZSTD_compressContinue_internal (blockSize:=%u)', cctx^.blockSize);
    if frame<>0 then
    begin
      cSize := ZSTD_compress_frameChunk (cctx, dst, dstCapacity, src, srcSize, lastFrameChunk);
      //FORWARD_IF_ERROR(cSize, '%s',  'ZSTD_compressBlock_internal failed');
      if (ERR_isError(cSize)<>0) then
        exit(cSize)
    end
    else
    begin
      cSize := ZSTD_compressBlock_internal (cctx, dst, dstCapacity, src, srcSize, 0 { frame });
      //FORWARD_IF_ERROR(cSize, '%s','ZSTD_compress_frameChunk failed' );
      if (ERR_isError(cSize)<>0) then
        exit(cSize)
    end;
    cctx^.consumedSrcSize :=cctx^.consumedSrcSize + srcSize;
    cctx^.producedCSize   :=cctx^.producedCSize   + (cSize + fhSize);
    assert(not (cctx^.appliedParams.fParams.contentSizeFlag  and  cctx^.pledgedSrcSizePlusOne = 0));
    if (cctx^.pledgedSrcSizePlusOne <> 0) then
    begin  { control src size }
        //ZSTD_STATIC_ASSERT(ZSTD_CONTENTSIZE_UNKNOWN = Uint64(-1) );
        IF (cctx^.consumedSrcSize+1 > cctx^.pledgedSrcSizePlusOne) then
          exit(ERROR(srcSize_wrong));//'error : pledgedSrcSize := %u, while realSrcSize >= %u',(unsigned)cctx^.pledgedSrcSizePlusOne-1,(unsigned)cctx^.consumedSrcSize);
    end;
    result := cSize + fhSize;
end;

function ZSTD_compressContinue (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  const src:pbyte;srcSize:int32):int32;
begin
    ////log(3, 'ZSTD_compressContinue (srcSize:=%u)', srcSize);
    result := ZSTD_compressContinue_internal(cctx, dst, dstCapacity, src, srcSize, 1 { frame mode }, 0 { last chunk });
end;


function ZSTD_getBlockSize(cctx:pZSTD_CCtx):int32;
var
  cParams:ZSTD_compressionParameters;
begin
    cParams := cctx^.appliedParams.cParams;
    assert(ZSTD_checkCParams(cParams)=0);
    result := MIN (ZSTD_BLOCKSIZE_MAX, Uint32(1) shl cParams.windowLog);
end;

function ZSTD_compressBlock(cctx:pZSTD_CCtx; dst:pbyte;  dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
var
  blockSizeMax:int32;
begin
    ////log(3, 'ZSTD_compressBlock: srcSize := %u', srcSize);
    blockSizeMax := ZSTD_getBlockSize(cctx);
    IF (srcSize > blockSizeMax) then
      exit(ERROR(srcSize_wrong));// 'input is larger than a block');

    result := ZSTD_compressContinue_internal(cctx, dst, dstCapacity, src, srcSize, 0 { frame mode }, 0 { last chunk });
end;

{not  ZSTD_loadDictionaryContent() :
 *  @return : 0, or an error code
 }
function ZSTD_loadDictionaryContent(ms:pZSTD_matchState_t;ls:pldmState_t;ws:pZSTD_cwksp;
  params:pZSTD_CCtx_params;src:pbyte;  srcSize:int32;dtlm:ZSTD_dictTableLoadMethod_e ):int32;
var
  remaining,chunk:int32;
  ichunk,ip,iend:pbyte;
begin
    ip := src;
    iend := ip + srcSize;

    ZSTD_window_update(@ms^.window, src, srcSize);
    if params^.forceWindow<>0 then
      ms^.loadedDictEnd :=  0
    else
      ms^.loadedDictEnd :=  uint32(iend - ms^.window.base);

    if (params^.ldmParams.enableLdm<>0)  and  (ls <> nil) then
    begin
        ZSTD_window_update(@ls^.window, src, srcSize);
        if params^.forceWindow<>0 then
          ls^.loadedDictEnd := 0
        else
          ls^.loadedDictEnd := uint32(iend - ls^.window.base);
    end;

    { Assert that we the ms params match the params we're being given }
    ZSTD_assertEqualCParams(params^.cParams, ms^.cParams);

    if (srcSize <= HASH_READ_SIZE) then
      exit(0);

    while (iend - ip > HASH_READ_SIZE) do
    begin
        remaining := int32(iend - ip);
        chunk := MIN(remaining, ZSTD_CHUNKSIZE_MAX);
        ichunk := ip + chunk;

        ZSTD_overflowCorrectIfNeeded(ms, ws, params, ip, ichunk);

        if (params^.ldmParams.enableLdm<>0)  and  (ls <> nil) then
            ZSTD_ldm_fillHashTable(ls, src, src + srcSize, @params^.ldmParams);

        case (params^.cParams.strategy) of
         ZSTD_fast:
            ZSTD_fillHashTable(ms, ichunk, dtlm);
         ZSTD_dfast:
            ZSTD_fillDoubleHashTable(ms, ichunk, dtlm);

         ZSTD_greedy,
         ZSTD_lazy,
         ZSTD_lazy2:
         begin
            if (chunk >= HASH_READ_SIZE  and  ms^.dedicatedDictSearch) then
            begin
                assert(chunk = remaining); { must load everything in one go }
                ZSTD_dedicatedDictSearch_lazy_loadDictionary(ms, ichunk-HASH_READ_SIZE);
            end 
            else 
            if (chunk >= HASH_READ_SIZE) then
            begin
                ZSTD_insertAndFindFirstIndex(ms, ichunk-HASH_READ_SIZE);
            end;
         end;
         ZSTD_btlazy2,   { we want the dictionary table fully sorted }
         ZSTD_btopt,
         ZSTD_btultra,
         ZSTD_btultra2:
         begin
            if (chunk >= HASH_READ_SIZE) then
                ZSTD_updateTree(ms, ichunk-HASH_READ_SIZE, ichunk);
         end;
         else
            assert(false);  { not possible : not a valid strategy id }
        end;

        ip := ichunk;
    end;

    ms^.nextToUpdate := uint32(iend - ms^.window.base);
    exit(0);
end;


{ Dictionaries that assign zero probability to symbols that show up causes problems
 * when FSE encoding. Mark dictionaries with zero probability symbols as FSE_repeat_check
 * and only dictionaries with 100% valid symbols can be assumed valid.
 }
function  ZSTD_dictNCountRepeat(normalizedCounter:pint16;  dictMaxSymbolValue,  maxSymbolValue:uint32):FSE_repeat;
var
  s:uint32;
begin
    if (dictMaxSymbolValue < maxSymbolValue) then
    begin
        exit(FSE_repeat_check);
    end;
    for s := 0 to maxSymbolValue-1 do
    begin
        if (normalizedCounter[s] = 0) then
        begin
            exit(FSE_repeat_check);
        end;
    end;
    result := FSE_repeat_valid;
end;

function ZSTD_loadCEntropy(bs:pZSTD_compressedBlockState_t; workspace:pbyte;
                         dict:pbyte; dictSize:int32):int32;
var
  u,offcodeMax,offcodeMaxValue,maxSymbolValue,hasZeroWeights,offcodeLog,matchlengthMaxValue,matchlengthLog:uint32;
  hufHeaderSize,offcodeHeaderSize,matchlengthHeaderSize:int32;
  litlengthMaxValue,maxOffset,litlengthLog:uint32;
  litlengthHeaderSize,dictContentSize:int32;
  offcodeNCount:array [0..MaxOff] of int16;
  matchlengthNCount:array [0..MaxML] of int16;
  litlengthNCount:array [0..MaxLL] of int16;
  dictPtr,dictEnd:pbyte;
begin
    offcodeMaxValue := MaxOff;
    dictPtr := dict;    { skip magic num and dict ID }
    dictEnd := dictPtr + dictSize;
    dictPtr :=dictPtr + 8;
    bs^.entropy.huf.repeatMode := HUF_repeat_check;

    
      maxSymbolValue := 255;
      hasZeroWeights := 1;
      hufHeaderSize := HUF_readCTable(pHUF_CElt(bs^.entropy.huf.CTable), @maxSymbolValue, dictPtr,
            dictEnd-dictPtr, @hasZeroWeights);

      { We only set the loaded table as valid if it contains all non-zero
       * weights. Otherwise, we set it to check }
      if (hasZeroWeights=0) then
          bs^.entropy.huf.repeatMode := HUF_repeat_valid;

      if (HUF_isError(hufHeaderSize)<>0) then
       exit(ERROR(dictionary_corrupted));
      if (maxSymbolValue < 255) then
       exit(ERROR(dictionary_corrupted));
      dictPtr :=dictPtr + hufHeaderSize;


   
      offcodeHeaderSize := FSE_readNCount(@offcodeNCount[0], @offcodeMaxValue, @offcodeLog, dictPtr, dictEnd-dictPtr);
      if (FSE_isError(offcodeHeaderSize)<>0) then
        exit(ERROR(dictionary_corrupted));
      if (offcodeLog > OffFSELog) then
        exit(ERROR(dictionary_corrupted));
      { fill all offset symbols to avoid garbage at end of table }
      IF (FSE_isError(FSE_buildCTable_wksp(
              bs^.entropy.fse.offcodeCTable,
              @offcodeNCount[0], MaxOff, offcodeLog,
              workspace, HUF_WORKSPACE_SIZE))<>0) then
          exit(ERROR(dictionary_corrupted));
      { Defer checking offcodeMaxValue because we need to know the size of the dictionary content }
      dictPtr :=dictPtr + offcodeHeaderSize;



    matchlengthMaxValue := MaxML;
    matchlengthHeaderSize := FSE_readNCount(@matchlengthNCount[0], @matchlengthMaxValue, @matchlengthLog, dictPtr, dictEnd-dictPtr);
    if (FSE_isError(matchlengthHeaderSize)<>0) then
     exit(ERROR(dictionary_corrupted));
    if (matchlengthLog > MLFSELog) then
     exit(ERROR(dictionary_corrupted));
    if (FSE_isError(FSE_buildCTable_wksp(
            bs^.entropy.fse.matchlengthCTable,
            @matchlengthNCount[0], matchlengthMaxValue, matchlengthLog,
            workspace, HUF_WORKSPACE_SIZE))<>0) then
        exit(ERROR(dictionary_corrupted));
    bs^.entropy.fse.matchlength_repeatMode := ZSTD_dictNCountRepeat(@matchlengthNCount[0], matchlengthMaxValue, MaxML);
    dictPtr :=dictPtr + matchlengthHeaderSize;

   
    litlengthMaxValue := MaxLL;
    litlengthHeaderSize := FSE_readNCount(@litlengthNCount[0], @litlengthMaxValue, @litlengthLog, dictPtr, dictEnd-dictPtr);
    if (FSE_isError(litlengthHeaderSize)<>0) then
     exit(ERROR(dictionary_corrupted));
    if (litlengthLog > LLFSELog) then
     exit(ERROR(dictionary_corrupted));
    if (FSE_isError(FSE_buildCTable_wksp(
            bs^.entropy.fse.litlengthCTable,
            @litlengthNCount[0], litlengthMaxValue, litlengthLog,
            workspace, HUF_WORKSPACE_SIZE))<>0) then
        exit(ERROR(dictionary_corrupted));
    bs^.entropy.fse.litlength_repeatMode := ZSTD_dictNCountRepeat(@litlengthNCount[0], litlengthMaxValue, MaxLL);
    dictPtr :=dictPtr + litlengthHeaderSize;


    if (dictPtr+12 > dictEnd) then
     exit(ERROR(dictionary_corrupted));
    bs^.rep[0] := MEM_readLE32(dictPtr+0);
    bs^.rep[1] := MEM_readLE32(dictPtr+4);
    bs^.rep[2] := MEM_readLE32(dictPtr+8);
    dictPtr :=dictPtr + 12;

    dictContentSize := int32(dictEnd - dictPtr);
    offcodeMax := MaxOff;
    if (dictContentSize <= (uint32(-1) - 128*1024)) then
    begin
        maxOffset := uint32(dictContentSize) + 128*1024; { The maximum offset that must be supported }
        offcodeMax := ZSTD_highbit32(maxOffset); { Calculate minimum offset code required to represent maxOffset }
    end;
    { All offset values <= dictContentSize + 128 KB must be representable for a valid table }
    bs^.entropy.fse.offcode_repeatMode := ZSTD_dictNCountRepeat(offcodeNCount, offcodeMaxValue, MIN(offcodeMax, MaxOff));

    { All repCodes must be <= dictContentSize and <> 0 }
   
    for u:=0 to 2 do
    begin
        if (bs^.rep[u] = 0) then
         exit(ERROR(dictionary_corrupted));
        if (bs^.rep[u] > dictContentSize) then
          exit(ERROR(dictionary_corrupted));
    end;

    result := dictPtr - dict;
end;

{ Dictionary format :
 * See :
 * https://github.com/facebook/zstd/blob/release/doc/zstd_compression_format.md#dictionary-format
 }
{not  ZSTD_loadZstdDictionary() :
 * @return : dictID, or an error code
 *  assumptions : magic number supposed already checked
 *                dictSize supposed >= 8
 }
function ZSTD_loadZstdDictionary(bs:pZSTD_compressedBlockState_t;ms:pZSTD_matchState_t;
  ws:pZSTD_cwksp;params:pZSTD_CCtx_params;dict:pbyte;dictSize:int32;
  dtlm:ZSTD_dictTableLoadMethod_e;workspace:pbyte):int32;
var
  dictContentSize,dictID,eSize,err:int32;
  dictPtr,dictEnd:pbyte;
begin
    dictPtr := dict;
    dictEnd := dictPtr + dictSize;

    //ZSTD_STATIC_ASSERT(HUF_WORKSPACE_SIZE >= (1shlMAX(MLFSELog,LLFSELog)));
    assert(dictSize >= 8);
    assert(MEM_readLE32(dictPtr) = ZSTD_MAGIC_DICTIONARY);
    if params^.fParams.noDictIDFlag<>0 then
      dictID :=  0 
    else
      dictID :=  MEM_readLE32(dictPtr + 4 { skip magic number } );
    eSize := ZSTD_loadCEntropy(bs, workspace, dict, dictSize);
    //FORWARD_IF_ERROR(eSize, 'ZSTD_loadCEntropy failed');
    if (ERR_isError(eSize)<>0) then
      exit(eSize);
    dictPtr :=dictPtr + eSize;


    dictContentSize := int32(dictEnd - dictPtr);
    //FORWARD_IF_ERROR(ZSTD_loadDictionaryContent(ms, nil, ws, params, dictPtr, dictContentSize, dtlm), '');
    err:=ZSTD_loadDictionaryContent(ms, nil, ws, params, dictPtr, dictContentSize, dtlm);
    if (ERR_isError(err)<>0) then
      exit(err);

    result := dictID;
end;

{* ZSTD_compress_insertDictionary() :
*   @return : dictID, or an error code }
function ZSTD_compress_insertDictionary(bs:pZSTD_compressedBlockState_t;
  ms:pZSTD_matchState_t;ls:pldmState_t;ws:pZSTD_cwksp;
  const params:pZSTD_CCtx_params;dict:pbyte;dictSize:int32;
  dictContentType:ZSTD_dictContentType_e;dtlm:ZSTD_dictTableLoadMethod_e;workspace:pbyte):int32;
begin
    //log(3, 'ZSTD_compress_insertDictionary (dictSize:=%u)', dictSize);
    if ((dict=nil) or (dictSize<8)) then
    begin
        IF (dictContentType = ZSTD_dct_fullDict) then
          exit(ERROR(dictionary_wrong));//, '');
        exit(0);
    end;

    ZSTD_reset_compressedBlockState(bs);

    { dict restricted modes }
    if (dictContentType = ZSTD_dct_rawContent) then
        exit(ZSTD_loadDictionaryContent(ms, ls, ws, params, dict, dictSize, dtlm));

    if (MEM_readLE32(dict) <> ZSTD_MAGIC_DICTIONARY) then
    begin
        if (dictContentType = ZSTD_dct_auto) then
        begin
            //log(3, 'raw content dictionary detected');
            exit(ZSTD_loadDictionaryContent(ms, ls, ws, params, dict, dictSize, dtlm));
        end;
        IF (dictContentType = ZSTD_dct_fullDict) then
          exit(ERROR(dictionary_wrong));
        assert(false);   { impossible }
    end;

    { dict as full zstd dictionary }
    result := ZSTD_loadZstdDictionary(
        bs, ms, ws, params, dict, dictSize, dtlm, workspace);
end;



{not  ZSTD_compressBegin_internal() :
 * @return : 0, or an error code }
function ZSTD_compressBegin_internal(cctx:pZSTD_CCtx;dict:pbyte;dictSize:int32;
  dictContentType:ZSTD_dictContentType_e;dtlm:ZSTD_dictTableLoadMethod_e;
  const cdict:pZSTD_CDict;const params:pZSTD_CCtx_params; pledgedSrcSize:Uint64;
  zbuff:ZSTD_buffered_policy_e):int32;
var
  dictID,err:int32;
begin
    //log(3, 'ZSTD_compressBegin_internal: wlog:=%u', params^.cParams.windowLog);
    { params are supposed to be fully validated at this point }
    assert(ZSTD_isError(ZSTD_checkCParams(params^.cParams))=0);
    //assert(not ((dict)  and  (cdict)));  { either dict or cdict, not both }
    if ( (cdict<>nil)
       and  (cdict^.dictContentSize > 0)
       and  ( (pledgedSrcSize < ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF)
        or (pledgedSrcSize < cdict^.dictContentSize * ZSTD_USE_CDICT_PARAMS_DICTSIZE_MULTIPLIER)
        or (pledgedSrcSize = ZSTD_CONTENTSIZE_UNKNOWN)
        or (cdict^.compressionLevel = 0))
       and  (params^.attachDictPref <> ZSTD_dictForceLoad) ) then
    begin
        exit(ZSTD_resetCCtx_usingCDict(cctx, cdict, params, pledgedSrcSize, zbuff));
    end;
  
    err:=ZSTD_resetCCtx_internal(cctx, params^, pledgedSrcSize,ZSTDcrp_makeClean, zbuff);
    if (ERR_isError(err)<>0) then
      exit(err);
    if cdict<>nil then
    dictID := ZSTD_compress_insertDictionary(
                    cctx^.blockState.prevCBlock, @cctx^.blockState.matchState,
                    @cctx^.ldmState, @cctx^.workspace, @cctx^.appliedParams, cdict^.dictContent,
                    cdict^.dictContentSize, cdict^.dictContentType, dtlm,
                    pbyte(cctx^.entropyWorkspace))
    else
    dictID := ZSTD_compress_insertDictionary(
                    cctx^.blockState.prevCBlock, @cctx^.blockState.matchState,
                    @cctx^.ldmState, @cctx^.workspace, @cctx^.appliedParams, dict, dictSize,
                    dictContentType, dtlm, pbyte(cctx^.entropyWorkspace));
    if (ERR_isError(dictID)<>0) then
      exit(dictID);
    assert(dictID <= UINT_MAX);
    cctx^.dictID := uint32(dictID);
    exit(0);
end;

function ZSTD_compressBegin_advanced_internal(cctx:pZSTD_CCtx;dict:pbyte;dictSize:int32;
  dictContentType:ZSTD_dictContentType_e;dtlm:ZSTD_dictTableLoadMethod_e;
    const cdict:pZSTD_CDict;const params:pZSTD_CCtx_params;pledgedSrcSize:uint64):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_compressBegin_advanced_internal: wlog:=%u', params^.cParams.windowLog);
    { compression parameters verification and optimization }
    err:=ZSTD_checkCParams(params^.cParams);
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_compressBegin_internal(cctx,dict, dictSize, dictContentType, dtlm,
                        cdict,params, pledgedSrcSize,ZSTDb_not_buffered);
end;

{not  ZSTD_compressBegin_advanced() :
*   @return : 0, or an error code }
function ZSTD_compressBegin_advanced(cctx:pZSTD_CCtx;dict:pbyte;dictSize:int32;
  params:pZSTD_parameters;pledgedSrcSize:uint64):int32;
var
  cctxParams:ZSTD_CCtx_params;
begin
    cctxParams := ZSTD_assignParamsToCCtxParams(@cctx^.requestedParams, @params);
    result := ZSTD_compressBegin_advanced_internal(cctx,
                                            dict, dictSize, ZSTD_dct_auto, ZSTD_dtlm_fast,
                                            nil {cdict},
                                            @cctxParams, pledgedSrcSize);
end;

function ZSTD_compressBegin_usingDict(cctx:pZSTD_CCtx; dict:pbyte;dictSize:int32; compressionLevel:int32):int32;
var
  params:ZSTD_parameters;
  cctxParams:ZSTD_CCtx_params;
begin
    params := ZSTD_getParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_noAttachDict);
    cctxParams := ZSTD_assignParamsToCCtxParams(@cctx^.requestedParams, @params);
    //log(3, 'ZSTD_compressBegin_usingDict (dictSize:=%u)', dictSize);
    result := ZSTD_compressBegin_internal(cctx, dict, dictSize, ZSTD_dct_auto, ZSTD_dtlm_fast, nil,
                                       @cctxParams, ZSTD_CONTENTSIZE_UNKNOWN, ZSTDb_not_buffered);
end;

function ZSTD_compressBegin(cctx:pZSTD_CCtx; compressionLevel:int32):int32;
begin
    result := ZSTD_compressBegin_usingDict(cctx, nil, 0, compressionLevel);
end;


{not  ZSTD_writeEpilogue() :
*   Ends a frame.
*   @return : nb of bytes written into dst (or an error code) }
function ZSTD_writeEpilogue(cctx:pZSTD_CCtx; dst:pbyte;dstCapacity:int32):int32;
var
  checksum,cBlockHeader24:uint32;
  ostart,op:pbyte;
  fhSize:int32;
begin
    ostart := dst;
    op := ostart;
    fhSize := 0;

    //log(3, 'ZSTD_writeEpilogue');
    IF (cctx^.stage = ZSTDcs_created) then
       exit(ERROR(stage_wrong));// 'init missing');

    { special case : empty frame }
    if (cctx^.stage = ZSTDcs_init) then
    begin
        fhSize := ZSTD_writeFrameHeader(dst, dstCapacity, @cctx^.appliedParams, 0, 0);
        //FORWARD_IF_ERROR(fhSize, 'ZSTD_writeFrameHeader failed');
        if (ERR_isError(fhSize)<>0) then
          exit(fhSize);
        dstCapacity :=dstCapacity - fhSize;
        op :=op + fhSize;
        cctx^.stage := ZSTDcs_ongoing;
    end;

    if (cctx^.stage <> ZSTDcs_ending) then
    begin
        { write one last empty block, make it the 'last' block }
        cBlockHeader24 := 1 { last block } + ((uint32(bt_raw)) shl 1) + 0;
        if (dstCapacity<4) then
          exit(ERROR(dstint32ooSmall));// 'no room for epilogue');
        MEM_writeLE32(op, cBlockHeader24);
        op :=op + ZSTD_blockHeaderSize;
        dstCapacity :=dstCapacity - ZSTD_blockHeaderSize;
    end;

    if (cctx^.appliedParams.fParams.checksumFlag<>0) then
    begin
        checksum := uint32(XXH64_digest(@cctx^.xxhState));
        IF (dstCapacity<4) then
          exit(ERROR(dstint32ooSmall));// 'no room for checksum');
        //log(3, 'ZSTD_writeEpilogue: write checksum : %08X', checksum);
        MEM_writeLE32(op, checksum);
        op :=op + 4;
    end;

    cctx^.stage := ZSTDcs_created;  { return to 'created but no init' status }
    result := op-ostart;
end;

function ZSTD_compressEnd (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  const src:pbyte;srcSize:int32):int32;
var
  endResult,cSize:int32;
begin
    cSize := ZSTD_compressContinue_internal(cctx,
                                dst, dstCapacity, src, srcSize,
                                1 { frame mode }, 1 { last chunk });
    //FORWARD_IF_ERROR(cSize, 'ZSTD_compressContinue_internal failed');
    if (ERR_isError(cSize)<>0) then
      exit(cSize);
    endResult := ZSTD_writeEpilogue(cctx, dst + cSize, dstCapacity-cSize);
    //FORWARD_IF_ERROR(endResult, 'ZSTD_writeEpilogue failed');
    if (ERR_isError(endResult)<>0) then
      exit(endResult);
    assert(not (cctx^.appliedParams.fParams.contentSizeFlag  and  cctx^.pledgedSrcSizePlusOne = 0));
    if (cctx^.pledgedSrcSizePlusOne <> 0) then
    begin  { control src size }
        //ZSTD_STATIC_ASSERT(ZSTD_CONTENTSIZE_UNKNOWN = Uint64(-1) );
        //log(3, 'end of frame : controlling src size');
        if (cctx^.pledgedSrcSizePlusOne <> cctx^.consumedSrcSize+1) then
          exit(ERROR(srcSize_wrong)); //'error : pledgedSrcSize := %u, while realSrcSize := %u',(unsigned)cctx^.pledgedSrcSizePlusOne-1,(unsigned)cctx^.consumedSrcSize);
    end;
    result := cSize + endResult;
end;
{ Internal }
function ZSTD_compress_advanced_internal(cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;dict:pbyte;dictSize:int32;params:pZSTD_CCtx_params):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_compress_advanced_internal (srcSize:%u)', srcSize);
    err:= ZSTD_compressBegin_internal(cctx,
                         dict, dictSize, ZSTD_dct_auto, ZSTD_dtlm_fast, nil,
                         params, srcSize, ZSTDb_not_buffered);
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_compressEnd(cctx, dst, dstCapacity, src, srcSize);
end;
function ZSTD_compress_internal (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;dict:pbyte;dictSize:int32;params:pZSTD_parameters):int32;
var
  cctxParams:ZSTD_CCtx_params;
begin
    cctxParams :=ZSTD_assignParamsToCCtxParams(@cctx^.requestedParams, params);
    //log(3, 'ZSTD_compress_internal');
    result := ZSTD_compress_advanced_internal(cctx,dst, dstCapacity,src, srcSize,dict, dictSize,@cctxParams);
end;

function ZSTD_compress_advanced (cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;dict:pbyte;dictSize:int32;params:ZSTD_parameters):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_compress_advanced');
    err:=ZSTD_checkCParams(params.cParams);
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_compress_internal(cctx,dst, dstCapacity,src, srcSize,dict, dictSize,@params);
end;



function ZSTD_compress_usingDict(cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;dict:pbyte;dictSize:int32;compressionLevel:int32):int32;
var
  params:ZSTD_parameters;
  cctxParams:ZSTD_CCtx_params;
begin
    if dict<>nil then
       params := ZSTD_getParams_internal(compressionLevel, srcSize,  dictSize, ZSTD_cpm_noAttachDict)
    else
       params := ZSTD_getParams_internal(compressionLevel, srcSize,  0, ZSTD_cpm_noAttachDict);
    cctxParams := ZSTD_assignParamsToCCtxParams(@cctx^.requestedParams, @params);
    //log(3, 'ZSTD_compress_usingDict (srcSize:=%u)', srcSize);
    assert(params.fParams.contentSizeFlag = 1);
    result := ZSTD_compress_advanced_internal(cctx, dst, dstCapacity, src, srcSize, dict, dictSize, @cctxParams);
end;

function ZSTD_compressCCtx(cctx:pZSTD_CCtx;dst:pbyte;  dstCapacity:int32;
  src:pbyte;  srcSize:int32;compressionLevel:int32):int32;
begin
    //log(3, 'ZSTD_compressCCtx (srcSize:=%u)', srcSize);
    assert(cctx <> nil);
    result := ZSTD_compress_usingDict(cctx, dst, dstCapacity, src, srcSize, nil, 0, compressionLevel);
end;

function ZSTD_compress(dst:pbyte; dstCapacity:int32;
  src:pbyte;  srcSize:int32;compressionLevel:int32):int32;
var
  cctx:pZSTD_CCtx;
begin
  cctx := ZSTD_createCCtx();
  IF (cctx=nil) then
    exit(ERROR(memory_allocation));// 'ZSTD_createCCtx failed');
  result := ZSTD_compressCCtx(cctx, dst, dstCapacity, src, srcSize, compressionLevel);
  ZSTD_freeCCtx(cctx);
end;


{ ==:=  Dictionary API  ==:= }

{not  ZSTD_estimateCDictSize_advanced() :
 *  Estimate amount of memory that will be needed to create a dictionary with following arguments }
function ZSTD_estimateCDictSize_advanced(
        dictSize:int32; cParams:ZSTD_compressionParameters;
        dictLoadMethod:ZSTD_dictLoadMethod_e ):int32;
begin
    //log(3, 'sizeof(ZSTD_CDict) : %u', sizeof(ZSTD_CDict));
    if dictLoadMethod = ZSTD_dlm_byRef then
    result := ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict))
         + ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE)
         + ZSTD_sizeof_matchState(@cParams, { forCCtx } 0)
         + 0 
    else
    result := ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict))
         + ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE)
         + ZSTD_sizeof_matchState(@cParams, { forCCtx } 0)
          +ZSTD_cwksp_alloc_size(ZSTD_cwksp_align(dictSize, sizeof(pbyte)));    
end;

function ZSTD_estimateCDictSize(dictSize:int32; compressionLevel:int32):int32;
var
cParams:ZSTD_compressionParameters;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_createCDict);
    result := ZSTD_estimateCDictSize_advanced(dictSize, cParams, ZSTD_dlm_byCopy);
end;

function ZSTD_sizeof_CDict(cdict:pZSTD_CDict):int32;
begin
    if (cdict=nil) then
      exit(0);   { support sizeof on nil }
    //log(3, 'sizeof(ZSTD_CDict) : %u', sizeof(ZSTD_CDict));
    { cdict may be in the workspace }
    if cdict^.workspace.workspace = pbyte(cdict) then
      result := 0
    else
      result := sizeof(ZSTD_CDict) + ZSTD_cwksp_sizeof(@cdict^.workspace);
end;

function ZSTD_initCDict_internal(cdict:pZSTD_CDict;
              const dictBuffer:pbyte; dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e;
  params:ZSTD_CCtx_params ):int32;
var
  dictID,err:int32;
  internalBuffer:pbyte;
begin
    //log(3, 'ZSTD_initCDict_internal (dictContentType:%u)', dictContentType);
    assert( ZSTD_checkCParams(params.cParams)=0);
    cdict^.matchState.cParams := params.cParams;
    cdict^.matchState.dedicatedDictSearch := params.enableDedicatedDictSearch;
    if (cdict^.matchState.dedicatedDictSearch  and  dictSize > ZSTD_CHUNKSIZE_MAX) then
    begin
        cdict^.matchState.dedicatedDictSearch := 0;
    end;
    if ((dictLoadMethod = ZSTD_dlm_byRef) or (dictBuffer=nil) or (dictSize=0)) then
    begin
      cdict^.dictContent := dictBuffer;
    end 
    else 
    begin
      internalBuffer := ZSTD_cwksp_reserve_object(@cdict^.workspace, ZSTD_cwksp_align(dictSize, sizeof(pointer)));
      IF (internalBuffer=nil) then
        exit(ERROR(memory_allocation));// 'nil pointernot ');
      cdict^.dictContent := internalBuffer;
      move(dictBuffer^, internalBuffer^,  dictSize);
    end;
    cdict^.dictContentSize := dictSize;
    cdict^.dictContentType := dictContentType;

    cdict^.entropyWorkspace := puint32(ZSTD_cwksp_reserve_object(@cdict^.workspace, HUF_WORKSPACE_SIZE));


    { Reset the state to no dictionary }
    ZSTD_reset_compressedBlockState(@cdict^.cBlockState);
    err:=ZSTD_reset_matchState(
        @cdict^.matchState,
        @cdict^.workspace,
        @params.cParams,
        ZSTDcrp_makeClean,
        ZSTDirp_reset,
        ZSTD_resetTarget_CDict);
    if (ERR_isError(err)<>0) then
      exit(err);
    { (Maybe) load the dictionary
     * Skips loading the dictionary if it is < 8 bytes.
     }
     
      params.compressionLevel := ZSTD_CLEVEL_DEFAULT;
      params.fParams.contentSizeFlag := 1;
      dictID := ZSTD_compress_insertDictionary(@cdict^.cBlockState, @cdict^.matchState, nil, @cdict^.workspace,
        @params, cdict^.dictContent, cdict^.dictContentSize,dictContentType, ZSTD_dtlm_full, pbyte(cdict^.entropyWorkspace));
      //FORWARD_IF_ERROR(dictID, 'ZSTD_compress_insertDictionary failed');
      if (ERR_isError(dictID)<>0) then
        exit(dictID);
      //assert(dictID <= int32(uint32)-1);
      cdict^.dictID := uint32(dictID);

    exit(0);
end;

function ZSTD_createCDict_advanced_internal(dictSize:int32;dictLoadMethod:ZSTD_dictLoadMethod_e;
  cParams:ZSTD_compressionParameters; customMem:ZSTD_customMem):pZSTD_CDict;
var
  workspaceSize:int32;
  workspace:pbyte;
  ws:ZSTD_cwksp;
  cdict:pZSTD_CDict;
begin
  if ((customMem.customAlloc=nil) xor (customMem.customFree=nil)) then
      exit(nil);

  if dictLoadMethod = ZSTD_dlm_byRef then
    workspaceSize :=ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict)) +ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE) +
        ZSTD_sizeof_matchState(@cParams, { forCCtx } 0) + 0
  else
    workspaceSize :=ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict)) +ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE) +
        ZSTD_sizeof_matchState(@cParams, { forCCtx } 0) +
        ZSTD_cwksp_alloc_size(ZSTD_cwksp_align(dictSize, sizeof(pbyte)));
    workspace := ZSTD_customMalloc(workspaceSize, customMem);

    if (workspace=nil) then
    begin
        ZSTD_customfree(workspace, customMem);
        exit(nil);
    end;

    ZSTD_cwksp_init(@ws, workspace, workspaceSize, ZSTD_cwksp_dynamic_alloc);

    cdict := pZSTD_CDict(ZSTD_cwksp_reserve_object(@ws, sizeof(ZSTD_CDict)));
    assert(cdict <> nil);
    ZSTD_cwksp_move(@cdict^.workspace, @ws);
    cdict^.customMem := customMem;
    cdict^.compressionLevel := 0; { signals advanced API usage }

    result := cdict;
end;

function ZSTD_createCDict_advanced(const dictBuffer:pbyte; dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e;
  cParams:ZSTD_compressionParameters;customMem:ZSTD_customMem):pZSTD_CDict;
var
  cctxParams:ZSTD_CCtx_params;
begin
    fillbyte(cctxParams, sizeof(cctxParams), 0);
    ZSTD_CCtxParams_init(@cctxParams, 0);
    cctxParams.cParams := cParams;
    cctxParams.customMem := customMem;
    result := ZSTD_createCDict_advanced2(dictBuffer, dictSize,
        dictLoadMethod, dictContentType,@cctxParams, customMem);
end;
function ZSTD_dedicatedDictSearch_getCParams(compressionLevel:int32; dictSize:int32):ZSTD_compressionParameters;
var
  cParams:ZSTD_compressionParameters;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, 0, dictSize, ZSTD_cpm_createCDict);
    case (cParams.strategy) of
        ZSTD_fast,
        ZSTD_dfast:;
        ZSTD_greedy,
        ZSTD_lazy,
        ZSTD_lazy2:
            cParams.hashLog :=cParams.hashLog + ZSTD_LAZY_DDSS_BUCKET_LOG;
        ZSTD_btlazy2,
        ZSTD_btopt,
        ZSTD_btultra,
        ZSTD_btultra2:;
    end;
    result := cParams;
end;
function ZSTD_dedicatedDictSearch_isSupported(cParams:pZSTD_compressionParameters):int32;
begin
    result := ord(cParams^.strategy >= ZSTD_greedy)  and  ord(cParams^.strategy <= ZSTD_lazy2);
end;

function ZSTD_createCDict_advanced2(
        dict:pbyte;dictSize:int32;
        dictLoadMethod:ZSTD_dictLoadMethod_e;
        dictContentType:ZSTD_dictContentType_e;
        const originalCctxParams:pZSTD_CCtx_params;
        customMem:ZSTD_customMem):pZSTD_CDict;
var
  cctxParams:ZSTD_CCtx_params;
  cParams:ZSTD_compressionParameters;
  cdict:pZSTD_CDict;
begin
    cctxParams := originalCctxParams^;
    //log(3, 'ZSTD_createCDict_advanced2, mode %u', dictContentType);
    if ((customMem.customAlloc=nil) xor (customMem.customFree=nil)) then
      exit(nil);

    if (cctxParams.enableDedicatedDictSearch<>0) then
    begin
        cParams := ZSTD_dedicatedDictSearch_getCParams(cctxParams.compressionLevel, dictSize);
        ZSTD_overrideCParams(@cParams, @cctxParams.cParams);
    end 
    else 
    begin
        cParams := ZSTD_getCParamsFromCCtxParams(@cctxParams, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_createCDict);
    end;

    if (ZSTD_dedicatedDictSearch_isSupported(@cParams)=0) then
    begin
        { Fall back to non-DDSS params }
        cctxParams.enableDedicatedDictSearch := 0;
        cParams := ZSTD_getCParamsFromCCtxParams(@cctxParams, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_createCDict);
    end;

    cctxParams.cParams := cParams;

    cdict := ZSTD_createCDict_advanced_internal(dictSize,dictLoadMethod, cctxParams.cParams,customMem);

    if (ZSTD_isError( ZSTD_initCDict_internal(cdict,dict, dictSize,dictLoadMethod, dictContentType,cctxParams) )<>0) then
    begin
        ZSTD_freeCDict(cdict);
        exit(nil);
    end;

    result := cdict;
end;

function ZSTD_createCDict(dict:pbyte;dictSize:int32; compressionLevel:int32):pZSTD_CDict;
var
  cParams:ZSTD_compressionParameters;
  cdict:pZSTD_CDict;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_createCDict);
    cdict := ZSTD_createCDict_advanced(dict, dictSize,ZSTD_dlm_byCopy, ZSTD_dct_auto,cParams, ZSTD_defaultCMem);
    if (cdict<>nil) then
    begin
      if (compressionLevel = 0) then
        cdict^.compressionLevel :=  ZSTD_CLEVEL_DEFAULT
      else
        cdict^.compressionLevel :=  compressionLevel;
    end;
    result := cdict;
end;

function ZSTD_createCDict_byReference(dict:pbyte;dictSize:int32; compressionLevel:int32):pZSTD_CDict;
var
  cParams:ZSTD_compressionParameters;
  cdict:pZSTD_CDict;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, ZSTD_CONTENTSIZE_UNKNOWN, dictSize, ZSTD_cpm_createCDict);
    cdict := ZSTD_createCDict_advanced(dict, dictSize,ZSTD_dlm_byRef, ZSTD_dct_auto,cParams, ZSTD_defaultCMem);
    if (cdict<>nil) then
    begin
      if (compressionLevel = 0) then
        cdict^.compressionLevel :=  ZSTD_CLEVEL_DEFAULT
      else
        cdict^.compressionLevel :=  compressionLevel;
    end;
    result := cdict;
end;

function ZSTD_freeCDict(cdict:pZSTD_CDict):int32;
var
  cMem:ZSTD_customMem;
  cdictInWorkspace:int32;
begin
    if (cdict=nil) then
      exit(0);   { support free on nil }
    cMem := cdict^.customMem;
    cdictInWorkspace := ZSTD_cwksp_owns_buffer(@cdict^.workspace, pbyte(cdict));
    ZSTD_cwksp_freemem(@cdict^.workspace, cMem);
    if (cdictInWorkspace=0) then
    begin
        ZSTD_customfree(pbyte(cdict), cMem);
    end;
    exit(0);
end;

{not  ZSTD_initStaticCDict_advanced() :
 *  Generate a digested dictionary in provided memory area.
 *  workspace: The memory area to emplace the dictionary into.
 *             Provided pointer must 8-bytes aligned.
 *             It must outlive dictionary usage.
 *  workspaceSize: Use ZSTD_estimateCDictSize()
 *                 to determine how large workspace must be.
 *  cParams : use ZSTD_getCParams() to transform a compression level
 *            into its relevants cParams.
 * @return : pointer to ZSTD_CDict*, or nil if error (size too small)
 *  Note : there is no corresponding 'free' function.
 *         Since workspace was allocated externally, it must be freed externally.
 }
function ZSTD_initStaticCDict(workspace:pbyte; workspaceSize:int32;dict:pbyte;dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e;
  cParams:ZSTD_compressionParameters):pZSTD_CDict;
var
  ws:ZSTD_cwksp;
  cdict:pZSTD_CDict;
  params:ZSTD_CCtx_params;
  matchStateSize,neededSize:int32;
begin
    matchStateSize := ZSTD_sizeof_matchState(@cParams, { forCCtx } 0);
    if dictLoadMethod = ZSTD_dlm_byRef then
      neededSize := ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict)) + 0 + ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE) + matchStateSize
    else
      neededSize := ZSTD_cwksp_alloc_size(sizeof(ZSTD_CDict)) + ZSTD_cwksp_alloc_size(ZSTD_cwksp_align(dictSize, sizeof(pbyte))) + ZSTD_cwksp_alloc_size(HUF_WORKSPACE_SIZE) + matchStateSize;
    
    if (int32(workspace) and 7)<>0 then
      exit(nil);  { 8-aligned }


    
    ZSTD_cwksp_init(@ws, workspace, workspaceSize, ZSTD_cwksp_static_alloc);
    cdict := pZSTD_CDict(ZSTD_cwksp_reserve_object(@ws, sizeof(ZSTD_CDict)));
    if (cdict = nil) then
      exit(nil);
    ZSTD_cwksp_move(@cdict^.workspace, @ws);

    //log(3, '(workspaceSize < neededSize) : (%u < %u) :=> %u',
    //    workspaceSize, neededSize, (workspaceSize < neededSize));
    if (workspaceSize < neededSize) then
      exit(nil);

    ZSTD_CCtxParams_init(@params, 0);
    params.cParams := cParams;

    if (ZSTD_isError( ZSTD_initCDict_internal(cdict,dict, dictSize,dictLoadMethod, dictContentType,params) )<>0) THEN
        exit(nil);

    result := cdict;
end;

function ZSTD_getCParamsFromCDict(cdict:pZSTD_CDict):ZSTD_compressionParameters;
begin
    assert(cdict <> nil);
    result := cdict^.matchState.cParams;
end;

{not  ZSTD_getDictID_fromCDict() :
 *  Provides the dictID of the dictionary loaded into `cdict`.
 *  If @return = 0, the dictionary is not conformant to Zstandard specification, or empty.
 *  Non-conformant dictionaries can still be loaded, but as content-only dictionaries. }
function ZSTD_getDictID_fromCDict(cdict:pZSTD_CDict):uint32;
begin
    if (cdict=nil) then
      exit(0);
    result := cdict^.dictID;
end;


{ ZSTD_compressBegin_usingCDict_advanced() :
 * cdict must be <> nil }
function ZSTD_compressBegin_usingCDict_advanced(
    cctx:pZSTD_CCtx;cdict:pZSTD_CDict;
    fParams:ZSTD_frameParameters;pledgedSrcSize:uint64):int32;
var
  limitedSrcSize,limitedSrcLog:uint32;
  params:ZSTD_CCtx_params;
begin
    //log(3, 'ZSTD_compressBegin_usingCDict_advanced');
    IF (cdict=nil) then
      exit(ERROR(dictionary_wrong));// 'nil pointernot ');
    params := cctx^.requestedParams;
    if ( (pledgedSrcSize < ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF)
                    or (pledgedSrcSize < cdict^.dictContentSize * ZSTD_USE_CDICT_PARAMS_DICTSIZE_MULTIPLIER)
                    or (pledgedSrcSize = ZSTD_CONTENTSIZE_UNKNOWN)
                    or (cdict^.compressionLevel = 0 )) and (params.attachDictPref <> ZSTD_dictForceLoad) then
      params.cParams := ZSTD_getCParamsFromCDict(cdict)
    else
      params.cParams := ZSTD_getCParams(cdict^.compressionLevel, pledgedSrcSize,cdict^.dictContentSize);
    { Increase window log to fit the entire dictionary and source if the
     * source size is known. Limit the increase to 19, which is the
     * window log for compression level 1 with the largest source size.
     }

    if (pledgedSrcSize <> ZSTD_CONTENTSIZE_UNKNOWN) then
    begin
        limitedSrcSize := uint32(MIN(pledgedSrcSize, Uint32(1) shl 19));
        if limitedSrcSize > 1 then
          limitedSrcLog :=  ZSTD_highbit32(limitedSrcSize - 1) + 1
        else
          limitedSrcLog :=  1;
        params.cParams.windowLog := MAX(params.cParams.windowLog, limitedSrcLog);
    end;
    params.fParams := fParams;
    result := ZSTD_compressBegin_internal(cctx,
                                       nil, 0, ZSTD_dct_auto, ZSTD_dtlm_fast,
                                       cdict,
                                       @params, pledgedSrcSize,
                                       ZSTDb_not_buffered);
end;

{ ZSTD_compressBegin_usingCDict() :
 * pledgedSrcSize:=0 means 'unknown'
 * if pledgedSrcSize>0, it will enable contentSizeFlag }
function ZSTD_compressBegin_usingCDict(cctx:pZSTD_CCtx; const cdict:pZSTD_CDict):int32;
var
  fParams:ZSTD_frameParameters;
begin
    //ZSTD_frameParameters const fParams := begin 0 {content}, 0 {checksum}, 0 {noDictID} end;;
    fillbyte(fParams,sizeof(ZSTD_frameParameters),0);
    //log(3, 'ZSTD_compressBegin_usingCDict : dictIDFlag = %u', not fParams.noDictIDFlag);
    result := ZSTD_compressBegin_usingCDict_advanced(cctx, cdict, fParams, ZSTD_CONTENTSIZE_UNKNOWN);
end;

function ZSTD_compress_usingCDict_advanced(cctx:pZSTD_CCtx;
                                dst:pbyte;  dstCapacity:int32;
                                src:pbyte;  srcSize:int32;
                                cdict:pZSTD_CDict;  fParams:ZSTD_frameParameters):int32;
var
  err:int32;
begin
    err:=ZSTD_compressBegin_usingCDict_advanced(cctx, cdict, fParams, srcSize);   { will check if cdict <> nil }
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_compressEnd(cctx, dst, dstCapacity, src, srcSize);
end;

{not  ZSTD_compress_usingCDict() :
 *  Compression using a digested Dictionary.
 *  Faster startup than ZSTD_compress_usingDict(), recommended when same dictionary is used multiple times.
 *  Note that compression parameters are decided at CDict creation time
 *  while frame parameters are hardcoded }
function ZSTD_compress_usingCDict(cctx:pZSTD_CCtx;
                                dst:pbyte;  dstCapacity:int32;
                                src:pbyte;  srcSize:int32;
                                const cdict:pZSTD_CDict):int32;
var
  fParams:ZSTD_frameParameters= (contentSizeFlag:1 {content}; checksumFlag:0 {checksum};noDictIDFlag: 0 {noDictID} );
begin
    result := ZSTD_compress_usingCDict_advanced(cctx, dst, dstCapacity, src, srcSize, cdict, fParams);
end;



{ ******************************************************************
*  Streaming
*******************************************************************}
function ZSTD_initStaticCStream(workspace:pbyte; workspaceSize:int32 ):pZSTD_CStream;
begin
    result := ZSTD_initStaticCCtx(workspace, workspaceSize);
end;

function ZSTD_createCStream_advanced(customMem:ZSTD_customMem):pZSTD_CStream;
begin   { CStream and CCtx are now same object }
    result := ZSTD_createCCtx_advanced(customMem);
end;
function ZSTD_createCStream():pZSTD_CStream;
begin
    //log(3, 'ZSTD_createCStream');
    result := ZSTD_createCStream_advanced(ZSTD_defaultCMem);
end;
function ZSTD_freeCStream(zcs:pZSTD_CStream ):int32;
begin
    result := ZSTD_freeCCtx(zcs);   { same object }
end;



{===   Initialization   ===}

function ZSTD_CStreamInSize():int32;
begin 
  result := ZSTD_BLOCKSIZE_MAX; 
end;

function ZSTD_CStreamOutSize():int32;
begin
    result := ZSTD_compressBound(ZSTD_BLOCKSIZE_MAX) + ZSTD_blockHeaderSize + 4 { 32-bits hash } ;
end;

function  ZSTD_getCParamMode(cdict:pZSTD_CDict; params:pZSTD_CCtx_params; pledgedSrcSize:uint64):ZSTD_cParamMode_e;
begin
    if ((cdict <> nil)  and  (ZSTD_shouldAttachDict(cdict, params, pledgedSrcSize)<>0)) then
        result := ZSTD_cpm_attachDict
    else
        result := ZSTD_cpm_noAttachDict;
end;

{ ZSTD_resetCStream():
 * pledgedSrcSize = 0 means 'unknown' }
function ZSTD_resetCStream(zcs:pZSTD_CStream; pss:uint64):int32;
var
  pledgedSrcSize:uint64;
  err:int32;
begin
    { temporary : 0 interpreted as 'unknown' during transition period.
     * Users willing to specify 'unknown' **must** use ZSTD_CONTENTSIZE_UNKNOWN.
     * 0 will be interpreted as 'empty' in the future.
     }
    if (pss=0) then
      pledgedSrcSize := ZSTD_CONTENTSIZE_UNKNOWN
    else
      pledgedSrcSize :=  pss;
    //log(3, 'ZSTD_resetCStream: pledgedSrcSize := %u', pledgedSrcSize);
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:=ZSTD_CCtx_setPledgedSrcSize(zcs, pledgedSrcSize);
    if (ERR_isError(err)<>0) then
      exit(err);
    exit(0);
end;

{not  ZSTD_initCStream_internal() :
 *  Note : for lib/compress only. Used by zstdmt_compress.c.
 *  Assumption 1 : params are valid
 *  Assumption 2 : either dict, or cdict, is defined, not both }
function ZSTD_initCStream_internal(zcs:pZSTD_CStream;
                    dict:pbyte;dictSize:int32; const cdict:pZSTD_CDict;
                    const params:pZSTD_CCtx_params;
                   pledgedSrcSize:uint64):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_initCStream_internal');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
      exit(err);
    err := ZSTD_CCtx_setPledgedSrcSize(zcs, pledgedSrcSize);
    if (ERR_isError(err)<>0) then
      exit(err);
    assert(ZSTD_isError(ZSTD_checkCParams(params^.cParams))=0);
    zcs^.requestedParams := params^;
    assert(not ((dict<>nil)  and  (cdict<>nil)));  { either dict or cdict, not both }
    if (dict<>nil) then
    begin
        err := ZSTD_CCtx_loadDictionary(zcs, dict, dictSize) ;
        if (ERR_isError(err)<>0) then
          exit(err);
    end
    else
    begin
        { Dictionary is cleared if not cdict }
      err := ZSTD_CCtx_refCDict(zcs, cdict);
      if (ERR_isError(err)<>0) then
        exit(err);
    end;
    exit(0);
end;

{ ZSTD_initCStream_usingCDict_advanced() :
 * same as ZSTD_initCStream_usingCDict(), with control over frame parameters }
function ZSTD_initCStream_usingCDict_advanced(zcs:pZSTD_CStream;
                                            const cdict:pZSTD_CDict;
                                            fParams:ZSTD_frameParameters;
                                           pledgedSrcSize:uint64):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_initCStream_usingCDict_advanced');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:= ZSTD_CCtx_setPledgedSrcSize(zcs, pledgedSrcSize);
    if (ERR_isError(err)<>0) then
      exit(err);
    zcs^.requestedParams.fParams := fParams;
    err:= ZSTD_CCtx_refCDict(zcs, cdict);
    if (ERR_isError(err)<>0) then
      exit(err);
    exit(0);
end;

{ note : cdict must outlive compression session }
function ZSTD_initCStream_usingCDict(zcs:pZSTD_CStream; const cdict:pZSTD_CDict):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_initCStream_usingCDict');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:= ZSTD_CCtx_refCDict(zcs, cdict);
    if (ERR_isError(err)<>0) then
      exit(err);
    exit(0);
end;


{ ZSTD_initCStream_advanced() :
 * pledgedSrcSize must be exact.
 * if srcSize is not known at init time, use value ZSTD_CONTENTSIZE_UNKNOWN.
 * dict is loaded with default parameters ZSTD_dct_auto and ZSTD_dlm_byCopy. }
function ZSTD_initCStream_advanced(zcs:pZSTD_CStream;
                                 dict:pbyte;dictSize:int32;
                                 params:ZSTD_parameters;pss:uint64):int32;
var
  pledgedSrcSize:uint64;
  err:int32;
begin
    { for compatibility with older programs relying on this behavior.
     * Users should now specify ZSTD_CONTENTSIZE_UNKNOWN.
     * This line will be removed in the future.
     }
    if (pss=0)  and  (params.fParams.contentSizeFlag=0) then
      pledgedSrcSize :=  ZSTD_CONTENTSIZE_UNKNOWN
    else
      pledgedSrcSize :=  pss;
    //log(3, 'ZSTD_initCStream_advanced');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_setPledgedSrcSize(zcs, pledgedSrcSize);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_checkCParams(params.cParams);
    if (ERR_isError(err)<>0) then
       exit(err);
    zcs^.requestedParams := ZSTD_assignParamsToCCtxParams(@zcs^.requestedParams, @params);
    err:= ZSTD_CCtx_loadDictionary(zcs, dict, dictSize);
    if (ERR_isError(err)<>0) then
       exit(err);
    exit(0);
end;

function ZSTD_initCStream_usingDict(zcs:pZSTD_CStream; dict:pbyte;dictSize:int32; compressionLevel:int32):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_initCStream_usingDict');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_setParameter(zcs, ZSTD_c_compressionLevel, compressionLevel);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_loadDictionary(zcs, dict, dictSize);
    if (ERR_isError(err)<>0) then
       exit(err);
    exit(0);
end;

function ZSTD_initCStream_srcSize(zcs:pZSTD_CStream; compressionLevel:int32;pss:uint64):int32;
var
  pledgedSrcSize:uint64;
  err:int32;
begin
    { temporary : 0 interpreted as 'unknown' during transition period.
     * Users willing to specify 'unknown' **must** use ZSTD_CONTENTSIZE_UNKNOWN.
     * 0 will be interpreted as 'empty' in the future.
     }
    if (pss=0) then
      pledgedSrcSize :=  ZSTD_CONTENTSIZE_UNKNOWN
    else
      pledgedSrcSize :=  pss;
    //log(3, 'ZSTD_initCStream_srcSize');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_refCDict(zcs, nil);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_setParameter(zcs, ZSTD_c_compressionLevel, compressionLevel);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_setPledgedSrcSize(zcs, pledgedSrcSize);
    if (ERR_isError(err)<>0) then
       exit(err);
    exit(0);
end;

function ZSTD_initCStream(zcs:pZSTD_CStream; compressionLevel:int32):int32;
var
  err:int32;
begin
    //log(3, 'ZSTD_initCStream');
    err:= ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only) ;
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_refCDict(zcs, nil);
    if (ERR_isError(err)<>0) then
       exit(err);
    err:= ZSTD_CCtx_setParameter(zcs, ZSTD_c_compressionLevel, compressionLevel);
    if (ERR_isError(err)<>0) then
       exit(err);
    exit(0);
end;

{===   Compression   ===}

function ZSTD_nextInputSizeHint(cctx:pZSTD_CCtx):int32;
begin
    result := cctx^.inBuffTarget - cctx^.inBuffPos;
    if (result=0) then
      result := cctx^.blockSize;
end;

{* ZSTD_compressStream_generic():
 *  internal function for all *compressStream*() variants
 *  non-static, because can be called from zstdmt_compress.c
 * @return : hint size for next input }
function ZSTD_compressStream_generic(zcs:pZSTD_CStream;
                                          output:pZSTD_outBuffer;
                                          input:pZSTD_inBuffer;
                                          flushMode:ZSTD_EndDirective):int32;
var
  flushed,toFlush,toLoad,loaded:int32;
  lastBlock,someMoreWork:uint32;
  inputBuffered,cSize,oSize,iSize:int32;
  cDst:pbyte;
  istart,iend,ip,ostart,oend,op:pbyte;
begin
    istart := input^.src;
    if input^.size <> 0 then
    begin
      iend := istart + input^.size;
      ip := istart + input^.pos;
    end
    else
    begin
      iend := istart;
      ip := istart;
    end;
    ostart := output^.dst;
    if output^.size <> 0 then
    begin
      oend := ostart + output^.size;
      op := ostart + output^.pos;
    end
    else
    begin
      oend := ostart;
      op := ostart;
    end;
    someMoreWork := 1;

    { check expectations }
    //log(3, 'ZSTD_compressStream_generic, flush:=%u', flushMode);
    if (zcs^.appliedParams.inBufferMode = ZSTD_bm_buffered) then
    begin
        assert(zcs^.inBuff <> nil);
        assert(zcs^.inBuffSize > 0);
    end;
    if (zcs^.appliedParams.outBufferMode = ZSTD_bm_buffered) then
    begin
        assert(zcs^.outBuff <>  nil);
        assert(zcs^.outBuffSize > 0);
    end;
    assert(output^.pos <= output^.size);
    assert(input^.pos <= input^.size);
    assert( flushMode <= ZSTD_e_end);

    while (someMoreWork<>0) do
    begin
      case (zcs^.streamStage) of
         zcss_init:
            exit(ERROR(init_missing));//, 'call ZSTD_initCStream() firstnot ');

         zcss_load,zcss_flush:
         begin
            if zcss_load=zcs^.streamStage then
            begin
              if ( (flushMode = ZSTD_e_end)
                 and  ( (int32(oend-op) >= ZSTD_compressBound(iend-ip))     { Enough output space }
                  or (zcs^.appliedParams.outBufferMode = ZSTD_bm_stable))  { OR we are allowed to return dstSizeTooSmall }
                 and  (zcs^.inBuffPos = 0) ) then
              begin
                  { shortcut to compression pass directly into output buffer }
                  cSize := ZSTD_compressEnd(zcs,op, oend-op, ip, iend-ip);
                  //log(3, 'ZSTD_compressEnd : cSize:=%u', cSize);
                  if (ERR_isError(cSize)<>0) then
                     exit(cSize);
                  ip := iend;
                  op :=op + cSize;
                  zcs^.frameEnded := 1;
                  ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
                  someMoreWork := 0; 
                  break;
              end;
              { complete loading into inBuffer in buffered mode }
              if (zcs^.appliedParams.inBufferMode = ZSTD_bm_buffered) then
              begin 
                  toLoad := zcs^.inBuffTarget - zcs^.inBuffPos;
                  loaded := ZSTD_limitCopy(
                                          zcs^.inBuff + zcs^.inBuffPos, toLoad,
                                          ip, iend-ip);
                  zcs^.inBuffPos :=zcs^.inBuffPos + loaded;
                  if (loaded <> 0) then
                      ip :=ip + loaded;
                  if ( (flushMode = ZSTD_e_continue)
                     and  (zcs^.inBuffPos < zcs^.inBuffTarget) ) then
                  begin
                      { not enough input to fill full block : stop here }
                      someMoreWork := 0; break;
                  end;
                  if ( (flushMode = ZSTD_e_flush)
                     and  (zcs^.inBuffPos = zcs^.inToCompress) ) then
                  begin
                      { empty }
                      someMoreWork := 0; break;
                  end;
              end;
              { compress current block (note : this stage cannot be stopped in the middle) }
              //log(3, 'stream compression stage (flushMode=%u)', flushMode);

              inputBuffered := ord(zcs^.appliedParams.inBufferMode = ZSTD_bm_buffered);
              oSize := oend-op;
              if inputBuffered<>0 then
                iSize := zcs^.inBuffPos - zcs^.inToCompress
              else
                iSize := MIN(int32(iend - ip), zcs^.blockSize);
              if (oSize >= ZSTD_compressBound(iSize)) or (zcs^.appliedParams.outBufferMode = ZSTD_bm_stable) then
                  cDst := op   { compress into output buffer, to skip flush stage }
              else
              begin
                  cDst := zcs^.outBuff;
                  oSize := zcs^.outBuffSize;
              end;
              if (inputBuffered<>0) then
              begin
                  lastBlock := ord((flushMode = ZSTD_e_end)  and  (ip=iend));
                  if lastBlock<>0 then
                    cSize := ZSTD_compressEnd(zcs, cDst, oSize,zcs^.inBuff + zcs^.inToCompress, iSize)
                  else
                    cSize := ZSTD_compressContinue(zcs, cDst, oSize,zcs^.inBuff + zcs^.inToCompress, iSize);
                  //FORWARD_IF_ERROR(cSize, '%s', lastBlock ? 'ZSTD_compressEnd failed' : 'ZSTD_compressContinue failed');
                  zcs^.frameEnded := lastBlock;
                  { prepare next block }
                  zcs^.inBuffTarget := zcs^.inBuffPos + zcs^.blockSize;
                  if (zcs^.inBuffTarget > zcs^.inBuffSize) then
                  begin
                      zcs^.inBuffPos := 0;
                      zcs^.inBuffTarget := zcs^.blockSize;
                  end;
                  //log(3, 'inBuffTarget:%u / inBuffSize:%u',zcs^.inBuffTarget, zcs^.inBuffSize);
                  if (lastBlock=0) then
                      assert(zcs^.inBuffTarget <= zcs^.inBuffSize);
                  zcs^.inToCompress := zcs^.inBuffPos;
              end
              else 
              begin
                  lastBlock := ord(ip + iSize = iend);
                  assert(flushMode = ZSTD_e_end { Already validated });
                  if lastBlock<>0 then
                    cSize := ZSTD_compressEnd(zcs, cDst, oSize, ip, iSize) 
                  else
                    cSize := ZSTD_compressContinue(zcs, cDst, oSize, ip, iSize);
                  { Consume the input prior to error checking to mirror buffered mode. }
                  if (iSize > 0) then
                      ip :=ip + iSize;
                  //FORWARD_IF_ERROR(cSize, '%s', lastBlock ? 'ZSTD_compressEnd failed' : 'ZSTD_compressContinue failed');
                  if (ERR_isError(cSize)<>0) then
                    exit(cSize);
                  zcs^.frameEnded := lastBlock;
                  if (lastBlock<>0) then
                      assert(ip = iend);
              end;
              if (cDst = op) then
              begin  { no need to flush }
                  op :=op + cSize;
                  if (zcs^.frameEnded<>0) then
                  begin
                      //log(3, 'Frame completed directly in outBuffer');
                      someMoreWork := 0;
                      ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
                  end;
                  break;
              end;
              zcs^.outBuffContentSize := cSize;
              zcs^.outBuffFlushedSize := 0;
              zcs^.streamStage := zcss_flush; { pass-through to flush stage }
            end;
	    { fall-through }
            //log(3, 'flush stage');
            
            assert(zcs^.appliedParams.outBufferMode = ZSTD_bm_buffered);
            toFlush := zcs^.outBuffContentSize - zcs^.outBuffFlushedSize;
            flushed := ZSTD_limitCopy(op, int32(oend-op),
                        zcs^.outBuff + zcs^.outBuffFlushedSize, toFlush);
            //log(3, 'toFlush: %u into %u => flushed: %u', toFlush, (oend-op), flushed);
            if (flushed<>0) then
                op :=op + flushed;
            zcs^.outBuffFlushedSize :=zcs^.outBuffFlushedSize + flushed;
            if (toFlush<>flushed) then
            begin
                { flush not fully completed, presumably because dst is too small }
                assert(op=oend);
                someMoreWork := 0;
                break;
            end;
            zcs^.outBuffFlushedSize := 0;
            zcs^.outBuffContentSize := 0;
            if (zcs^.frameEnded<>0) then
            begin
                //log(3, 'Frame completed on flush');
                someMoreWork := 0;
                ZSTD_CCtx_reset(zcs, ZSTD_reset_session_only);
                break;
            end;
            zcs^.streamStage := zcss_load;
            break;
          end;
          
        else { impossible }
            assert(false);
      end;
    end;

    input^.pos := ip - istart;
    output^.pos := op - ostart;
    if (zcs^.frameEnded<>0) then
      exit(0);
    result := ZSTD_nextInputSizeHint(zcs);
end;

function ZSTD_nextInputSizeHint_MTorST(cctx:pZSTD_CCtx):int32;
begin
    result := ZSTD_nextInputSizeHint(cctx);
end;

function ZSTD_compressStream(zcs:pZSTD_CStream; output:pZSTD_outBuffer; input:pZSTD_inBuffer):int32;
var
  err:int32;
begin
    err:= ZSTD_compressStream2(zcs, output, input, ZSTD_e_continue);
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_nextInputSizeHint_MTorST(zcs);
end;

{ After a compression call set the expected input/output buffer.
 * This is validated at the start of the next compression call.
 }
procedure ZSTD_setBufferExpectations(cctx:pZSTD_CCtx;output:pZSTD_outBuffer; input:pZSTD_inBuffer);
begin
    if (cctx^.appliedParams.inBufferMode = ZSTD_bm_stable) then
    begin
        cctx^.expectedInBuffer := input^;
    end;
    if (cctx^.appliedParams.outBufferMode = ZSTD_bm_stable) then
    begin
        cctx^.expectedOutBufferSize := output^.size - output^.pos;
    end;
end;

{ Validate that the input/output buffers match the expectations set by
 * ZSTD_setBufferExpectations.
 }
function ZSTD_checkBufferStability(cctx:pZSTD_CCtx;output:pZSTD_outBuffer;
  input:pZSTD_inBuffer;endOp:ZSTD_EndDirective):int32;
var
  outBufferSize:int32;
  expect:ZSTD_inBuffer;
begin
    if (cctx^.appliedParams.inBufferMode = ZSTD_bm_stable) then
    begin
        expect := cctx^.expectedInBuffer;
        if (expect.src <> input^.src) or (expect.pos <> input^.pos) or (expect.size <> input^.size) then
            exit(ERROR(srcBuffer_wrong));// 'ZSTD_c_stableInBuffer enabled but input differsnot ');
        if (endOp <> ZSTD_e_end) then
            exit(ERROR(srcBuffer_wrong));// 'ZSTD_c_stableInBuffer can only be used with ZSTD_e_endnot ');
    end;
    if (cctx^.appliedParams.outBufferMode = ZSTD_bm_stable) then
    begin
        outBufferSize := output^.size - output^.pos;
        if (cctx^.expectedOutBufferSize <> outBufferSize) then
            exit(ERROR(dstBuffer_wrong));// 'ZSTD_c_stableOutBuffer enabled but output size differsnot ');
    end;
    exit(0);
end;

function ZSTD_CCtx_init_compressStream2(cctx:pZSTD_CCtx;
  endOp:ZSTD_EndDirective;inSize:int32 ):int32;
var
   pledgedSrcSize:Uint64;
   dictSize,err:int32;
   params:ZSTD_CCtx_params;
   prefixDict:ZSTD_prefixDict;
   mode:ZSTD_cParamMode_e;
begin
    params := cctx^.requestedParams;
    prefixDict := cctx^.prefixDict;
    err := ZSTD_initLocalDict(cctx); { Init the local dict if present. }
    if (ERR_isError(err)<>0) then
      exit(err);
    fillbyte(cctx^.prefixDict, sizeof(cctx^.prefixDict), 0);   { single usage }
    assert((prefixDict.dict=nil) or (cctx^.cdict=nil));    { only one can be set }
    if (cctx^.cdict<>nil) then
        params.compressionLevel := cctx^.cdict^.compressionLevel; { let cdict take priority in terms of compression level }
    //log(3, 'ZSTD_compressStream2 : transparent init stage');
    if (endOp = ZSTD_e_end) then
      cctx^.pledgedSrcSizePlusOne := inSize + 1;  { auto-fix pledgedSrcSize }

    if  prefixDict.dict<>nil then
      dictSize :=prefixDict.dictSize
    else
      if cctx^.cdict<>nil then
        dictSize := cctx^.cdict^.dictContentSize
      else
        dictSize := 0;

    mode := ZSTD_getCParamMode(cctx^.cdict, @params, cctx^.pledgedSrcSizePlusOne - 1);
    params.cParams := ZSTD_getCParamsFromCCtxParams(@params, cctx^.pledgedSrcSizePlusOne-1,dictSize, mode);


    if (ZSTD_CParams_shouldEnableLdm(@params.cParams)<>0) then
    begin
        { Enable LDM by default for optimal parser and window size >= 128MB }
        //log(3, 'LDM enabled by default (window size >= 128MB, strategy >= btopt)');
        params.ldmParams.enableLdm := 1;
    end;
 
    pledgedSrcSize := cctx^.pledgedSrcSizePlusOne - 1;
    assert(ZSTD_isError(ZSTD_checkCParams(params.cParams))=0);
    err := ZSTD_compressBegin_internal(cctx,
            prefixDict.dict, prefixDict.dictSize, prefixDict.dictContentType, ZSTD_dtlm_fast,
            cctx^.cdict,
            @params, pledgedSrcSize,
            ZSTDb_buffered);
    if (ERR_isError(err)<>0) then
      exit(err);
    assert(cctx^.appliedParams.nbWorkers = 0);
    cctx^.inToCompress := 0;
    cctx^.inBuffPos := 0;
    if (cctx^.appliedParams.inBufferMode = ZSTD_bm_buffered) then
    begin
        { for small input: avoid automatic flush on reaching end of block, since
        * it would require to add a 3-bytes nil block to end frame
        }
        cctx^.inBuffTarget := cctx^.blockSize + ord(cctx^.blockSize = pledgedSrcSize);
    end
    else 
    begin
        cctx^.inBuffTarget := 0;
    end;
    cctx^.outBuffFlushedSize := 0;
    cctx^.outBuffContentSize := 0;
    cctx^.streamStage := zcss_load;
    cctx^.frameEnded := 0;
    exit(0);
end;

function ZSTD_compressStream2( cctx:pZSTD_CCtx;output:pZSTD_outBuffer;
  input:pZSTD_INBuffer;endOp:ZSTD_EndDirective):int32;
var
   err:int32;
begin
    //log(3, 'ZSTD_compressStream2, endOp:=%u ', endOp);
    { check conditions }
    if (output^.pos > output^.size) then
      exit(ERROR(dstint32ooSmall));// 'invalid output buffer');
    if (input^.pos  > input^.size) then
      exit(ERROR(srcSize_wrong));// 'invalid input buffer');
    if (uint32(endOp) > uint32(ZSTD_e_end)) then
      exit(ERROR(parameter_outOfBound));// 'invalid endDirective');
    assert(cctx <> nil);

    { transparent initialization stage }
    if (cctx^.streamStage = zcss_init) then
    begin
        err :=ZSTD_CCtx_init_compressStream2(cctx, endOp, input^.size);//, 'CompressStream2 initialization failed');
        if (ERR_isError(err)<>0) then
          exit(err);
        ZSTD_setBufferExpectations(cctx, output, input);    { Set initial buffer expectations now that we've initialized }
    end;
    { end of transparent initialization stage }

    err :=ZSTD_checkBufferStability(cctx, output, input, endOp);//, 'invalid buffers');
    if (ERR_isError(err)<>0) then
      exit(err);
    { compression stage }
    err :=ZSTD_compressStream_generic(cctx, output, input, endOp);
    if (ERR_isError(err)<>0) then
      exit(err);
    //log(3, 'completed ZSTD_compressStream2');
    ZSTD_setBufferExpectations(cctx, output, input);
    result := cctx^.outBuffContentSize - cctx^.outBuffFlushedSize; { remaining to flush }
end;

function ZSTD_compressStream2_simpleArgs (cctx:pZSTD_CCtx;
  dst:pbyte;  dstCapacity:int32; dstPos:pint32;
  src:pbyte;  srcSize:int32; srcPos:pint32;
  endOp:ZSTD_EndDirective):int32;
var
  cErr:int32;
  input:ZSTD_inBuffer;
  output:ZSTD_outBuffer;
begin
  output.dst := dst;
  output.size := dstCapacity;
  output.pos := dstPos^ ;
  input.src  := src;
  input.size := srcSize;
  input.pos := srcPos^;
  { ZSTD_compressStream2() will check validity of dstPos and srcPos }
  cErr := ZSTD_compressStream2(cctx, @output, @input, endOp);
  dstPos^ := output.pos;
  srcPos^ := input.pos;
  result := cErr;
end;

function ZSTD_compress2(cctx:pZSTD_CCtx;
                      dst:pbyte;  dstCapacity:int32;
                      const src:pbyte;srcSize:int32):int32;
var
  originalInBufferMode,originalOutBufferMode:ZSTD_bufferMode_e;
  oPos,iPos:int32;
begin
    originalInBufferMode := cctx^.requestedParams.inBufferMode;
    originalOutBufferMode := cctx^.requestedParams.outBufferMode;
    //log(3, 'ZSTD_compress2 (srcSize:=%u)', srcSize);
    ZSTD_CCtx_reset(cctx, ZSTD_reset_session_only);
    { Enable stable input/output buffers. }
    cctx^.requestedParams.inBufferMode := ZSTD_bm_stable;
    cctx^.requestedParams.outBufferMode := ZSTD_bm_stable;
    oPos := 0;
    iPos := 0;
    result := ZSTD_compressStream2_simpleArgs(cctx,
                                        dst, dstCapacity, @oPos,
                                        src, srcSize,@iPos,
                                        ZSTD_e_end);
    { Reset to the original values. }
    cctx^.requestedParams.inBufferMode := originalInBufferMode;
    cctx^.requestedParams.outBufferMode := originalOutBufferMode;
    //FORWARD_IF_ERROR(result, 'ZSTD_compressStream2_simpleArgs failed');
    if (ERR_isError(result)<>0) then
      exit(result);
    if (result <> 0) then
    begin  { compression not completed, due to lack of output space }
        assert(oPos = dstCapacity);
        EXIT(ERROR(dstint32ooSmall));
    end;
    assert(iPos = srcSize);   { all input is expected consumed }
    result := oPos;
end;

{ Returns a ZSTD error code if sequence is not valid }
function ZSTD_validateSequence( offCode,  matchLength,
  posInSrc,  windowLog, dictSize, minMatch:int32 ) :int32;
var
  offsetBound:int32;
  windowSize:uint32;
begin
    windowSize := 1 shl windowLog;
    { posInSrc represents the amount of data the the decoder would decode up to this point.
     * As long as the amount of data decoded is less than or equal to window size, offsets may be
     * larger than the total length of output decoded in order to reference the dict, even larger than
     * window size. After output surpasses windowSize, we're limited to windowSize offsets again.
     }
    if posInSrc > windowSize then
      offsetBound := int32(windowSize)
    else
      offsetBound := posInSrc + int32(dictSize);
    IF (offCode > offsetBound + ZSTD_REP_MOVE) then
      exit(ERROR(corruption_detected));// 'Offset too largenot ');
    IF (matchLength < minMatch) then
      exit(ERROR(corruption_detected));// 'Matchlength too small');
    exit(0);
end;

{ Returns an offset code, given a sequence's raw offset, the ongoing repcode array, and whether litLength = 0 }
function ZSTD_finalizeOffCode(rawOffset:uint32; rep:TREPO;  ll0:uint32):int32;
var
  offCode,repCode:uint32;
begin
    offCode := rawOffset + ZSTD_REP_MOVE;
    repCode := 0;

    if (ll0=0)  and  (rawOffset = rep[0]) then
    begin
        repCode := 1;
    end
    else 
    if (rawOffset = rep[1]) then
    begin
        repCode := 2 - ll0;
    end
    else 
    if (rawOffset = rep[2]) then
    begin
        repCode := 3 - ll0;
    end
    else 
    if (ll0  and  rawOffset = rep[0] - 1) then
    begin
        repCode := 3;
    end;
    if (repCode<>0) then
    begin
        { ZSTD_storeSeq expects a number in the range [0, 2] to represent a repcode }
        offCode := repCode - 1;
    end;
    result := offCode;
end;

{ Returns 0 on success, and a ZSTD_error otherwise. This function scans through an array of
 * ZSTD_Sequence, storing the sequences it finds, until it reaches a block delimiter.
 }
function ZSTD_copySequencesToSeqStoreExplicitBlockDelim(cctx:pZSTD_CCtx; seqPos:pZSTD_sequencePosition;
                                                             inSeqs:pZSTD_Sequence;inSeqsSize:int32;
                                                             src:pbyte;blockSize:int32) :int32;
var
  dictSize,litLength,matchLength,ll0,offCode,idx:uint32;
  updatedRepcodes:repcodes_t;
  ip,iend:pbyte;
  err:int32;
begin
    idx := seqPos^.idx;
    ip := src;
    iend := ip + blockSize;

    if (cctx^.cdict<>nil) then
    begin
        dictSize := uint32(cctx^.cdict^.dictContentSize);
    end
    else 
    if (cctx^.prefixDict.dict<>nil) then
    begin
        dictSize := uint32(cctx^.prefixDict.dictSize);
    end
    else 
    begin
        dictSize := 0;
    end;
    move(cctx^.blockState.prevCBlock^.rep, updatedRepcodes.rep,  sizeof(repcodes_t));
    while ((inSeqs[idx].matchLength <> 0) or (inSeqs[idx].offset <> 0))  and (idx < inSeqsSize) do
    begin
        litLength := inSeqs[idx].litLength;
        matchLength := inSeqs[idx].matchLength;

        ll0 := ord(litLength = 0);
        offCode := ZSTD_finalizeOffCode(inSeqs[idx].offset, updatedRepcodes.rep, ll0);
        updatedRepcodes := ZSTD_updateRep(updatedRepcodes.rep, offCode, ll0);

        //log(3, 'Storing sequence: (of: %u, ml: %u, ll: %u)', offCode, matchLength, litLength);
        if (cctx^.appliedParams.validateSequences<>0) then
        begin
            seqPos^.posInSrc :=seqPos^.posInSrc + litLength + matchLength;
            err:=ZSTD_validateSequence(offCode, matchLength, seqPos^.posInSrc,
                                                cctx^.appliedParams.cParams.windowLog, dictSize,
                                                cctx^.appliedParams.cParams.minMatch);//'Sequence validation failed');
            if (ERR_isError(err)<>0) then
              exit(err);
        end;
        IF (idx - seqPos^.idx > cctx^.seqStore.maxNbSeq) then
         exit(ERROR(memory_allocation));//'Not enough memory allocated. Try adjusting ZSTD_c_minMatch.');
        ZSTD_storeSeq(@cctx^.seqStore, litLength, ip, iend, offCode, matchLength - MINMATCH);
        ip :=ip + matchLength + litLength;
        inc(idx);
    end;
    move(updatedRepcodes.rep, cctx^.blockState.nextCBlock^.rep,  sizeof(repcodes_t));

    if (inSeqs[idx].litLength<>0) then
    begin
        //log(3, 'Storing last literals of size: %u', inSeqs[idx].litLength);
        ZSTD_storeLastLiterals(@cctx^.seqStore, ip, inSeqs[idx].litLength);
        ip :=ip + inSeqs[idx].litLength;
        seqPos^.posInSrc :=seqPos^.posInSrc + inSeqs[idx].litLength;
    end;
    IF (ip <> iend) then
      exit(ERROR(corruption_detected));// 'Blocksize doesn't agree with block delimiternot ');
    seqPos^.idx := idx+1;
    exit(0);
end;

{ Returns the number of bytes to move the current read position back by. Only non-zero
 * if we ended up splitting a sequence. Otherwise, it may return a ZSTD error if something
 * went wrong.
 *
 * This function will attempt to scan through blockSize bytes represented by the sequences
 * in inSeqs, storing any (partial) sequences.
 *
 * Occasionally, we may want to change the actual number of bytes we consumed from inSeqs to
 * avoid splitting a match, or to avoid splitting a match such that it would produce a match
 * smaller than MINMATCH. In this case, we return the number of bytes that we didn't read from this block.
 }
function ZSTD_copySequencesToSeqStoreNoBlockDelim(cctx:pZSTD_CCtx; seqPos:pZSTD_sequencePosition;
                                                       inSeqs:pZSTD_Sequence;inSeqsSize:int32;
                                                       src:pbyte;blockSize:int32) :int32;
var
  lastLLSize,idx,startPosInSequence,endPosInSequence:uint32;
  dictSize,err:int32;
  ip,iend:pbyte;
  updatedRepcodes:repcodes_t;
  bytesAdjustment,finalMatchSplit,litLength,matchLength,rawOffset,offCode:uint32;
  currSeq:ZSTD_Sequence;
  ll0:uint32;
  firstHalfMatchLength:uint32 ;
  secondHalfMatchLength:uint32;
begin
    idx := seqPos^.idx;
    startPosInSequence := seqPos^.posInSequence;
    endPosInSequence := seqPos^.posInSequence + uint32(blockSize);
    ip := (src);
    iend := ip + blockSize;  { May be adjusted if we decide to process fewer than blockSize bytes }
    bytesAdjustment := 0;
    finalMatchSplit := 0;

    if (cctx^.cdict<>nil) then
    begin
        dictSize := cctx^.cdict^.dictContentSize;
    end
    else 
    if (cctx^.prefixDict.dict<>nil) then
    begin
        dictSize := cctx^.prefixDict.dictSize;
    end
    else 
    begin
        dictSize := 0;
    end;
    //log(3, 'ZSTD_copySequencesToSeqStore: idx: %u PIS: %u blockSize: %zu', idx, startPosInSequence, blockSize);
    //log(3, 'Start seq: idx: %u (of: %u ml: %u ll: %u)', idx, inSeqs[idx].offset, inSeqs[idx].matchLength, inSeqs[idx].litLength);
    move( cctx^.blockState.prevCBlock^.rep, updatedRepcodes.rep, sizeof(repcodes_t));
    while (endPosInSequence<>0)  and  (idx < inSeqsSize)  and  (finalMatchSplit=0) do
    begin
        currSeq := inSeqs[idx];
        litLength := currSeq.litLength;
        matchLength := currSeq.matchLength;
        rawOffset := currSeq.offset;

        { Modify the sequence depending on where endPosInSequence lies }
        if (endPosInSequence >= currSeq.litLength + currSeq.matchLength) then
        begin
            if (startPosInSequence >= litLength) then
            begin
                startPosInSequence :=startPosInSequence - litLength;
                litLength := 0;
                matchLength :=matchLength - startPosInSequence;
            end
            else 
            begin
                litLength :=litLength - startPosInSequence;
            end;
            { Move to the next sequence }
            endPosInSequence :=endPosInSequence - currSeq.litLength + currSeq.matchLength;
            startPosInSequence := 0;
            inc(idx);
        end
        else 
        begin
            { This is the final (partial) sequence we're adding from inSeqs, and endPosInSequence
               does not reach the end of the match. So, we have to split the sequence }
            //log(3, 'Require a split: diff: %u, idx: %u PIS: %u',
            //         currSeq.litLength + currSeq.matchLength - endPosInSequence, idx, endPosInSequence);
            if (endPosInSequence > litLength) then
            begin
                if startPosInSequence >= litLength then
                 litLength := 0
                else
                 litLength := litLength - startPosInSequence;
                firstHalfMatchLength := endPosInSequence - startPosInSequence - litLength;
                if (matchLength > blockSize)  and  (firstHalfMatchLength >= cctx^.appliedParams.cParams.minMatch) then
                begin
                    { Only ever split the match if it is larger than the block size }
                    secondHalfMatchLength:= currSeq.matchLength + currSeq.litLength - endPosInSequence;
                    if (secondHalfMatchLength < cctx^.appliedParams.cParams.minMatch) then
                    begin
                        { Move the endPosInSequence backward so that it creates match of minMatch length }
                        endPosInSequence :=endPosInSequence - cctx^.appliedParams.cParams.minMatch - secondHalfMatchLength;
                        bytesAdjustment := cctx^.appliedParams.cParams.minMatch - secondHalfMatchLength;
                        firstHalfMatchLength :=firstHalfMatchLength - bytesAdjustment;
                    end;
                    matchLength := firstHalfMatchLength;
                    { Flag that we split the last match - after storing the sequence, exit the loop,
                       but keep the value of endPosInSequence }
                    finalMatchSplit := 1;
                end
                else 
                begin
                    { Move the position in sequence backwards so that we don't split match, and break to store
                     * the last literals. We use the original currSeq.litLength as a marker for where endPosInSequence
                     * should go. We prefer to do this whenever it is not necessary to split the match, or if doing so
                     * would cause the first half of the match to be too small
                     }
                    bytesAdjustment := endPosInSequence - currSeq.litLength;
                    endPosInSequence := currSeq.litLength;
                    break;
                end;
            end
            else
            begin
                { This sequence ends inside the literals, break to store the last literals }
                break;
            end;
        end;
        { Check if this offset can be represented with a repcode }
       
        ll0 := ord(litLength = 0);
        offCode := ZSTD_finalizeOffCode(rawOffset, updatedRepcodes.rep, ll0);
        updatedRepcodes := ZSTD_updateRep(updatedRepcodes.rep, offCode, ll0);

        if (cctx^.appliedParams.validateSequences<>0) then
        begin
            seqPos^.posInSrc :=seqPos^.posInSrc + litLength + matchLength;
            err:=ZSTD_validateSequence(offCode, matchLength, seqPos^.posInSrc,
                                                   cctx^.appliedParams.cParams.windowLog, dictSize,
                                                   cctx^.appliedParams.cParams.minMatch);//'Sequence validation failed');
            if (ERR_isError(err)<>0) then
              exit(err);
        end;
        //log(3, 'Storing sequence: (of: %u, ml: %u, ll: %u)', offCode, matchLength, litLength);
        IF (idx - seqPos^.idx > cctx^.seqStore.maxNbSeq) then
          exit(ERROR(memory_allocation));//'Not enough memory allocated. Try adjusting ZSTD_c_minMatch.');
        ZSTD_storeSeq(@cctx^.seqStore, litLength, ip, iend, offCode, matchLength - MINMATCH);
        ip :=ip + matchLength + litLength;
    end;
    //log(3, 'Ending seq: idx: %u (of: %u ml: %u ll: %u)', idx, inSeqs[idx].offset, inSeqs[idx].matchLength, inSeqs[idx].litLength);
    assert((idx = inSeqsSize) or (endPosInSequence <= inSeqs[idx].litLength + inSeqs[idx].matchLength));
    seqPos^.idx := idx;
    seqPos^.posInSequence := endPosInSequence;
    move( updatedRepcodes.rep, cctx^.blockState.nextCBlock^.rep,sizeof(repcodes_t));

    iend :=iend - bytesAdjustment;
    if (ip <> iend) then
    begin
        { Store any last literals }
        lastLLSize := uint32(iend - ip);
        assert(ip <= iend);
        //log(3, 'Storing last literals of size: %u', lastLLSize);
        ZSTD_storeLastLiterals(@cctx^.seqStore, ip, lastLLSize);
        seqPos^.posInSrc :=seqPos^.posInSrc +seqPos^.posInSrc + lastLLSize;
    end;

    result := bytesAdjustment;
end;


function ZSTD_selectSequenceCopier(mode:ZSTD_sequenceFormat_e) :ZSTD_sequenceCopier;
begin

    assert(ZSTD_cParam_withinBounds(ZSTD_c_blockDelimiters, ord(mode))<>0);
    if (mode = ZSTD_sf_explicitBlockDelimiters) then
    begin
      exit(@ZSTD_copySequencesToSeqStoreExplicitBlockDelim);
    end
    else 
    if (mode = ZSTD_sf_noBlockDelimiters) then
    begin
        exit(@ZSTD_copySequencesToSeqStoreNoBlockDelim);
    end;
    assert(false);
    result := nil;
end;

{ Compress, block-by-block, all of the sequences given.
 *
 * Returns the cumulative size of all compressed blocks (including their headers), otherwise a ZSTD error.
 }
function ZSTD_compressSequences_internal(cctx:pZSTD_CCtx;
                                              dst:pbyte;  dstCapacity:int32;
                                              const inSeqs:pZSTD_Sequence;inSeqsSize:int32;
                                              const src:pbyte;srcSize:int32) :int32;
var
  cBlockSize,additionalByteAdjustment,cSize,blockSize,compressedSeqsSize,remaining:int32;
  lastBlock,cBlockHeader24:uint32;
  ip,op:pbyte;
  seqPos:ZSTD_sequencePosition;
  sequenceCopier:ZSTD_sequenceCopier;
  cBlockHeader:uint32;
begin
    cSize := 0;
    remaining := srcSize;
    fillbyte(seqPos,sizeof(ZSTD_sequencePosition),0);

    ip := src;
    op := dst;
     sequenceCopier := ZSTD_selectSequenceCopier(cctx^.appliedParams.blockDelimiters);

    //log(3, 'ZSTD_compressSequences_internal srcSize: %zu, inSeqsSize: %zu', srcSize, inSeqsSize);
    { Special case: empty frame }
    if (remaining = 0) then
    begin
        cBlockHeader24 := 1 { last block } + ((uint32(bt_raw) shl 1));
        IF (dstCapacity<4) then
          exit(ERROR(dstint32ooSmall));//, 'No room for empty frame block header');
        MEM_writeLE32(op, cBlockHeader24);
        op :=op + ZSTD_blockHeaderSize;
        dstCapacity :=dstCapacity - ZSTD_blockHeaderSize;
        cSize :=cSize + ZSTD_blockHeaderSize;
    end;

    while (remaining<>0) do
    begin
        lastBlock := ord(remaining <= cctx^.blockSize);
        if lastBlock<>0 then
          blockSize := remaining
        else
          blockSize := uint32(cctx^.blockSize);
        ZSTD_resetSeqStore(@cctx^.seqStore);
        //log(3, 'Working on new block. Blocksize: %zu', blockSize);

        additionalByteAdjustment := sequenceCopier(cctx, @seqPos, inSeqs, inSeqsSize, ip, blockSize);
        //FORWARD_IF_ERROR(additionalByteAdjustment, 'Bad sequence copy');
        if (ERR_isError(additionalByteAdjustment)<>0) then
          exit(additionalByteAdjustment);
        blockSize :=blockSize - additionalByteAdjustment;

        { If blocks are too small, emit as a nocompress block }
        if (blockSize < MIN_CBLOCK_SIZE+ZSTD_blockHeaderSize+1) then
        begin
            cBlockSize := ZSTD_noCompressBlock(op, dstCapacity, ip, blockSize, lastBlock);
            //FORWARD_IF_ERROR(cBlockSize, 'Nocompress block failed');
            if (ERR_isError(cBlockSize)<>0) then
              exit(cBlockSize);
            //log(3, 'Block too small, writing out nocompress block: cSize: %zu', cBlockSize);
            cSize :=cSize + cBlockSize;
            ip :=ip + blockSize;
            op :=op + cBlockSize;
            remaining :=remaining - blockSize;
            dstCapacity :=dstCapacity - cBlockSize;
            continue;
        end;

        compressedSeqsSize := ZSTD_entropyCompressSequences(@cctx^.seqStore,
                                @cctx^.blockState.prevCBlock^.entropy, @cctx^.blockState.nextCBlock^.entropy,
                                @cctx^.appliedParams,
                                op + ZSTD_blockHeaderSize { Leave space for block header }, dstCapacity - ZSTD_blockHeaderSize,
                                blockSize,
                                pbyte(cctx^.entropyWorkspace), ENTROPY_WORKSPACE_SIZE { statically allocated in resetCCtx },
                                cctx^.bmi2);
        //FORWARD_IF_ERROR(compressedSeqsSize, 'Compressing sequences of block failed');
        if (ERR_isError(compressedSeqsSize)<>0) then
          exit(compressedSeqsSize);
        //log(3, 'Compressed sequences size: %zu', compressedSeqsSize);

        if ((cctx^.isFirstBlock=0)  and
            (ZSTD_maybeRLE(@cctx^.seqStore)<>0)  and 
            (ZSTD_isRLE(src, srcSize)<>0)) then
        begin
            { We don't want to emit our first block as a RLE even if it qualifies because
            * doing so will cause the decoder (cli only) to throw a 'should consume all input error.'
            * This is only an issue for zstd <= v1.4.3
            }
            compressedSeqsSize := 1;
        end;

        if (compressedSeqsSize = 0) then
        begin
            { ZSTD_noCompressBlock writes the block header as well }
            cBlockSize := ZSTD_noCompressBlock(op, dstCapacity, ip, blockSize, lastBlock);
            //FORWARD_IF_ERROR(cBlockSize, 'Nocompress block failed');
            if (ERR_isError(cBlockSize)<>0) then
              exit(cBlockSize);
            //log(3, 'Writing out nocompress block, size: %zu', cBlockSize);
        end 
        else 
        if (compressedSeqsSize = 1) then
        begin
            cBlockSize := ZSTD_rleCompressBlock(op, dstCapacity, ip^, blockSize, lastBlock);
            //FORWARD_IF_ERROR(cBlockSize, 'RLE compress block failed');
            if (ERR_isError(cBlockSize)<>0) then
              exit(cBlockSize);
            //log(3, 'Writing out RLE block, size: %zu', cBlockSize);
        end 
        else 
        begin

            { Error checking and repcodes update }
            ZSTD_confirmRepcodesAndEntropyTables(cctx);
            if (cctx^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode = FSE_repeat_valid) then
                cctx^.blockState.prevCBlock^.entropy.fse.offcode_repeatMode := FSE_repeat_check;

            { Write block header into beginning of block}
            cBlockHeader := lastBlock + ((uint32(bt_compressed) shl 1) + uint32(compressedSeqsSize) shl 3);
            MEM_writeLE24(op, cBlockHeader);
            cBlockSize := ZSTD_blockHeaderSize + compressedSeqsSize;
            //log(3, 'Writing out compressed block, size: %zu', cBlockSize);
        end;

        cSize :=cSize + cBlockSize;
        //log(3, 'cSize running total: %zu', cSize);

        if (lastBlock<>0) then
        begin
            break;
        end
        else 
        begin
            ip :=ip + blockSize;
            op :=op + cBlockSize;
            remaining :=remaining - blockSize;
            dstCapacity :=dstCapacity - cBlockSize;
            cctx^.isFirstBlock := 0;
        end;
    end;

    result := cSize;
end;

function ZSTD_compressSequences(cctx:pZSTD_CCtx; dst:pbyte;  dstCapacity:int32;
                              const inSeqs:pZSTD_Sequence;inSeqsSize:int32;
                              const src:pbyte;srcSize:int32) :int32;
var
  op:pbyte;
  cSize,compressedBlocksSize,frameHeaderSize,err:int32;
  checksum:uint32;
begin
    op := dst;
    cSize := 0;
    compressedBlocksSize := 0;
    frameHeaderSize := 0;

    { Transparent initialization stage, same as compressStream2() }
    //log(3, 'ZSTD_compressSequences()');
    assert(cctx <> nil);
    err:=ZSTD_CCtx_init_compressStream2(cctx, ZSTD_e_end, srcSize);//, 'CCtx initialization failed');
    if (ERR_isError(err)<>0) then
      exit(err);
    { Begin writing output, starting with frame header }
    frameHeaderSize := ZSTD_writeFrameHeader(op, dstCapacity, @cctx^.appliedParams, srcSize, cctx^.dictID);
    op :=op + frameHeaderSize;
    dstCapacity :=dstCapacity - frameHeaderSize;
    cSize :=cSize + frameHeaderSize;
    if (cctx^.appliedParams.fParams.checksumFlag<>0)  and  (srcSize<>0) then
    begin
        XXH64_update(@cctx^.xxhState, src, srcSize);
    end;
    { cSize includes block header size and compressed sequences size }
    compressedBlocksSize := ZSTD_compressSequences_internal(cctx,
                                                           op, dstCapacity,
                                                           inSeqs, inSeqsSize,
                                                           src, srcSize);
    err:=compressedBlocksSize;//, 'Compressing blocks failednot ');
    if (ERR_isError(err)<>0) then
      exit(err);
    cSize :=cSize + compressedBlocksSize;
    dstCapacity :=dstCapacity - compressedBlocksSize;

    if (cctx^.appliedParams.fParams.checksumFlag<>0) then
    begin
        checksum := XXH64_digest(@cctx^.xxhState);
        IF (dstCapacity<4) then
          exit(ERROR(dstint32ooSmall));// 'no room for checksum');
        //log(3, 'Write checksum : %08X', checksum);
        MEM_writeLE32(dst + cSize, checksum);
        cSize :=cSize + 4;
    end;

    //log(3, 'Final compressed size: %zu', cSize);
    result := cSize;
end;

{===   Finalize   ===}

{not  ZSTD_flushStream() :
 * @return : amount of data remaining to flush }
function ZSTD_flushStream(zcs:pZSTD_CStream; output:pZSTD_outBuffer):int32;
var
  input:ZSTD_inBuffer;
begin
    fillbyte(input,sizeof(ZSTD_inBuffer),0);
    result := ZSTD_compressStream2(zcs, output, @input, ZSTD_e_flush);
end;


function ZSTD_endStream(zcs:pZSTD_CStream; output:pZSTD_outBuffer):int32;
var
  input:ZSTD_inBuffer;
  remainingToFlush,lastBlockSize,checksumSize,toFlush:int32;
begin
    fillbyte(input,sizeof(ZSTD_inBuffer),0);
    remainingToFlush := ZSTD_compressStream2(zcs, output, @input, ZSTD_e_end);
    //FORWARD_IF_ERROR( remainingToFlush , 'ZSTD_compressStream2 failed');
    if (ERR_isError(remainingToFlush)<>0) then
      exit(remainingToFlush);
    if (zcs^.appliedParams.nbWorkers > 0) then
      exit(remainingToFlush);   { minimal estimation }
    { single thread mode : attempt to calculate remaining to flush more precisely }
    if zcs^.frameEnded<>0 then
    begin
      lastBlockSize := 0;
      checksumSize := 0;
    end
    else
    begin
      lastBlockSize := ZSTD_BLOCKHEADERSIZE;
      checksumSize := int32(zcs^.appliedParams.fParams.checksumFlag * 4);
    end;
    toFlush := remainingToFlush + lastBlockSize + checksumSize;
    //log(3, 'ZSTD_endStream : remaining to flush : %u', uint32(toFlush));
    result := toFlush;
end;
function ZSTD_maxCLevel():int32; 
begin 
  result := ZSTD_MAX_CLEVEL; 
end;
function ZSTD_minCLevel():int32;
begin 
  result := -ZSTD_TARGETLENGTH_MAX; 
end;

{*
 * Reverses the adjustment applied to cparams when enabling dedicated dict
 * search. This is used to recover the params set to be used in the working
 * context. (Otherwise, those tables would also grow.)
 }
procedure ZSTD_dedicatedDictSearch_revertCParams(cParams:pZSTD_compressionParameters); 
begin
    case (cParams^.strategy) of
        ZSTD_fast,
        ZSTD_dfast:;
        ZSTD_greedy,
        ZSTD_lazy,
        ZSTD_lazy2:
            cParams^.hashLog :=cParams^.hashLog - ZSTD_LAZY_DDSS_BUCKET_LOG;
        ZSTD_btlazy2,
        ZSTD_btopt,
        ZSTD_btultra,
        ZSTD_btultra2:;
    end;
end;

function ZSTD_getCParamRowSize(srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):Uint64;
var
  unknown,addedSize:int32;
begin
    case (mode) of
      ZSTD_cpm_unknown,
      ZSTD_cpm_noAttachDict,
      ZSTD_cpm_createCDict:;
      ZSTD_cpm_attachDict:
          dictSize := 0;
      else
      begin
          assert(false);
      end;
    end;
    unknown := ord(srcSizeHint = ZSTD_CONTENTSIZE_UNKNOWN);
    if (unknown<>0)  and  (dictSize > 0) then
      addedSize := 500
    else
      addedSize := 0;
    if (unknown<>0)  and  (dictSize = 0) then
      result :=  ZSTD_CONTENTSIZE_UNKNOWN
    else
      result :=  srcSizeHint+dictSize+addedSize;
end;

{not  ZSTD_getCParams_internal() :
 * @return ZSTD_compressionParameters structure for a selected compression level, srcSize and dictSize.
 *  Note: srcSizeHint 0 means 0, use ZSTD_CONTENTSIZE_UNKNOWN for unknown.
 *        Use dictSize = 0 for unknown or unused.
 *  Note: `mode` controls how we treat the `dictSize`. See docs for `ZSTD_cParamMode_e`. }
function ZSTD_getCParams_internal(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):ZSTD_compressionParameters;
var
  clampedCompressionLevel,row:int32;
  cp:ZSTD_compressionParameters;
  i:integer;
  tableID:uint32;
  rSize:uint64;
begin
    rSize := ZSTD_getCParamRowSize(srcSizeHint, dictSize, mode);
    tableID := ord(rSize <= 256 *1024) + ord(rSize <= 128 *1024) + ord(rSize <= 16 *1024);
    //log(3, 'ZSTD_getCParams_internal (cLevel:=%i)', compressionLevel);

    { row }
    if (compressionLevel = 0) then
      row := ZSTD_CLEVEL_DEFAULT   { 0 = default }
    else 
    if (compressionLevel < 0) then
      row := 0   { entry 0 is baseline for fast mode }
    else if (compressionLevel > ZSTD_MAX_CLEVEL) then
      row := ZSTD_MAX_CLEVEL
    else 
      row := compressionLevel;

    cp := ZSTD_defaultCParameters[tableID][row];
      
    { acceleration factor }
    if (compressionLevel < 0) then
    begin
        clampedCompressionLevel := MAX(ZSTD_minCLevel(), compressionLevel);
        cp.targetLength := uint32(-clampedCompressionLevel);
    end;
    { refine parameters based on srcSize & dictSize }
    result := ZSTD_adjustCParams_internal(cp, srcSizeHint, dictSize, mode);

end;

{not  ZSTD_getCParams() :
 * @return ZSTD_compressionParameters structure for a selected compression level, srcSize and dictSize.
 *  Size values are optional, provide 0 if not known or unused }
function ZSTD_getCParams(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32):ZSTD_compressionParameters;
begin
    if (srcSizeHint = 0) then
      srcSizeHint := ZSTD_CONTENTSIZE_UNKNOWN;
    result := ZSTD_getCParams_internal(compressionLevel, srcSizeHint, dictSize, ZSTD_cpm_unknown);
end;

{not  ZSTD_getParams() :
 *  same idea as ZSTD_getCParams()
 * @return a `ZSTD_parameters` structure (instead of `ZSTD_compressionParameters`).
 *  Fields of `ZSTD_frameParameters` are set to default values }
function ZSTD_getParams_internal(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32; mode:ZSTD_cParamMode_e):ZSTD_parameters;
var
  params:ZSTD_parameters ;
  cParams:ZSTD_compressionParameters;
begin
    cParams := ZSTD_getCParams_internal(compressionLevel, srcSizeHint, dictSize, mode);
    ////log(3, 'ZSTD_getParams (cLevel:=%i)', compressionLevel);
    fillbyte(params, sizeof(params), 0);
    params.cParams := cParams;
    params.fParams.contentSizeFlag := 1;
    result := params;
end;

{not  ZSTD_getParams() :
 *  same idea as ZSTD_getCParams()
 * @return a `ZSTD_parameters` structure (instead of `ZSTD_compressionParameters`).
 *  Fields of `ZSTD_frameParameters` are set to default values }
function ZSTD_getParams(compressionLevel:int32;srcSizeHint:uint64; dictSize:int32):ZSTD_parameters; 
begin
    if (srcSizeHint = 0) then
      srcSizeHint := ZSTD_CONTENTSIZE_UNKNOWN;
    result := ZSTD_getParams_internal(compressionLevel, srcSizeHint, dictSize, ZSTD_cpm_unknown);
end;
end.
