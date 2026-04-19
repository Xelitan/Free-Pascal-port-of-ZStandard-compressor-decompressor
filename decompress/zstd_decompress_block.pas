unit zstd_decompress_block;
{$mode objfpc}{$H+}
interface

{-*******************************************************
*  Dependencies
********************************************************}
uses
//zstd_deps,   { ZSTD_memcpy, ZSTD_memmove, ZSTD_memset }
//compiler,    { prefetch }
//cpu,         { bmi2 }
//mem,         { low level memory routines }
fse,
zstd_internal,bitstream,error_private,zstd,
   { ZSTD_DCtx }
zstd_ddict;  { ZSTD_DDictDictContent }
const
ZSTD_BUILD_FSE_TABLE_WKSP_SIZE = 2*53+512+8 ;//(sizeof(int16) * (MaxSeq=52 + 1) + (1 shl MaxFSELog=9) + sizeof(uint64))
{ Default FSE distribution tables.
 * These are pre-calculated FSE decoding tables using default distributions as defined in specification :
 * https://github.com/facebook/zstd/blob/release/doc/zstd_compression_format.md#default-distributions
 * They were generated programmatically with following method :
 * - start from default distributions, present in /lib/common/zstd_internal.h
 * - generate tables normally, using ZSTD_buildFSETable()
 * - printout the content of tables
 * - pretify output, report below, test with fuzzer to ensure it's correct }

{ Default FSE distribution table for Literal Lengths }
  LL_defaultDTable:array [0..64] of ZSTD_seqSymbol = (
  { nextState, nbAddBits, nbBits, baseVal }
     ( nextState: 1; nbAdditionalBits: 1; nbBits:1;baseValue:    6),  { header : fastMode, tableLog }     
     ( nextState: 0; nbAdditionalBits: 0; nbBits:4;baseValue:    0),  ( nextState:16; nbAdditionalBits: 0;  nbBits:4;baseValue:    0),
     ( nextState:32; nbAdditionalBits: 0; nbBits:5;baseValue:    1),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    3),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:    4),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    6),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:    7),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    9),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:   10),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:   12),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:6;baseValue:   14),  ( nextState: 0; nbAdditionalBits: 1;  nbBits:5;baseValue:   16),
     ( nextState: 0; nbAdditionalBits: 1; nbBits:5;baseValue:   20),  ( nextState: 0; nbAdditionalBits: 1;  nbBits:5;baseValue:   22),
     ( nextState: 0; nbAdditionalBits: 2; nbBits:5;baseValue:   28),  ( nextState: 0; nbAdditionalBits: 3;  nbBits:5;baseValue:   32),
     ( nextState: 0; nbAdditionalBits: 4; nbBits:5;baseValue:   48),  ( nextState:32; nbAdditionalBits: 6;  nbBits:5;baseValue:   64),
     ( nextState: 0; nbAdditionalBits: 7; nbBits:5;baseValue:  128),  ( nextState: 0; nbAdditionalBits: 8;  nbBits:6;baseValue:  256),
     ( nextState: 0; nbAdditionalBits:10; nbBits:6;baseValue: 1024),  ( nextState: 0; nbAdditionalBits:12;  nbBits:6;baseValue: 4096),
     ( nextState:32; nbAdditionalBits: 0; nbBits:4;baseValue:    0),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:4;baseValue:    1),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:    2),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    4),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:    5),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    7),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:    8),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:   10),
     ( nextState: 0; nbAdditionalBits: 0; nbBits:5;baseValue:   11),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   13),
     ( nextState:32; nbAdditionalBits: 1; nbBits:5;baseValue:   16),  ( nextState: 0; nbAdditionalBits: 1;  nbBits:5;baseValue:   18),
     ( nextState:32; nbAdditionalBits: 1; nbBits:5;baseValue:   22),  ( nextState: 0; nbAdditionalBits: 2;  nbBits:5;baseValue:   24),
     ( nextState:32; nbAdditionalBits: 3; nbBits:5;baseValue:   32),  ( nextState: 0; nbAdditionalBits: 3;  nbBits:5;baseValue:   40),
     ( nextState: 0; nbAdditionalBits: 6; nbBits:4;baseValue:   64),  ( nextState:16; nbAdditionalBits: 6;  nbBits:4;baseValue:   64),
     ( nextState:32; nbAdditionalBits: 7; nbBits:5;baseValue:  128),  ( nextState: 0; nbAdditionalBits: 9;  nbBits:6;baseValue:  512),
     ( nextState: 0; nbAdditionalBits:11; nbBits:6;baseValue: 2048),  ( nextState:48; nbAdditionalBits: 0;  nbBits:4;baseValue:    0),
     ( nextState:16; nbAdditionalBits: 0; nbBits:4;baseValue:    1),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    2),
     ( nextState:32; nbAdditionalBits: 0; nbBits:5;baseValue:    3),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    5),
     ( nextState:32; nbAdditionalBits: 0; nbBits:5;baseValue:    6),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    8),
     ( nextState:32; nbAdditionalBits: 0; nbBits:5;baseValue:    9),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:   11),
     ( nextState:32; nbAdditionalBits: 0; nbBits:5;baseValue:   12),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   15),
     ( nextState:32; nbAdditionalBits: 1; nbBits:5;baseValue:   18),  ( nextState:32; nbAdditionalBits: 1;  nbBits:5;baseValue:   20),
     ( nextState:32; nbAdditionalBits: 2; nbBits:5;baseValue:   24),  ( nextState:32; nbAdditionalBits: 2;  nbBits:5;baseValue:   28),
     ( nextState:32; nbAdditionalBits: 3; nbBits:5;baseValue:   40),  ( nextState:32; nbAdditionalBits: 4;  nbBits:5;baseValue:   48),
     ( nextState: 0; nbAdditionalBits:16; nbBits:6;baseValue:65536),  ( nextState: 0; nbAdditionalBits:15;  nbBits:6;baseValue:32768),
     ( nextState: 0; nbAdditionalBits:14; nbBits:6;baseValue:16384),  ( nextState: 0; nbAdditionalBits:13;  nbBits:6;baseValue: 8192)
);   { LL_defaultDTable }

{ Default FSE distribution table for Offset Codes }
  OF_defaultDTable:array[0..32] of ZSTD_seqSymbol= (
      { nextState, nbAddBits, nbBits, baseVal }
    ( nextState: 1; nbAdditionalBits: 1;  nbBits:1;baseValue: 5),  { header : fastMode, tableLog }
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    0),     ( nextState: 0; nbAdditionalBits: 6;  nbBits:4;baseValue:   61),
    ( nextState: 0; nbAdditionalBits: 9;  nbBits:5;baseValue:  509),     ( nextState: 0; nbAdditionalBits:15;  nbBits:5;baseValue:32765),
    ( nextState: 0; nbAdditionalBits:21;  nbBits:5;baseValue:2097149),   ( nextState: 0; nbAdditionalBits: 3;  nbBits:5;baseValue:    5),
    ( nextState: 0; nbAdditionalBits: 7;  nbBits:4;baseValue:  125),     ( nextState: 0; nbAdditionalBits:12;  nbBits:5;baseValue: 4093),
    ( nextState: 0; nbAdditionalBits:18;  nbBits:5;baseValue:262141),    ( nextState: 0; nbAdditionalBits:23;  nbBits:5;baseValue:8388605),
    ( nextState: 0; nbAdditionalBits: 5;  nbBits:5;baseValue:   29),     ( nextState: 0; nbAdditionalBits: 8;  nbBits:4;baseValue:  253),
    ( nextState: 0; nbAdditionalBits:14;  nbBits:5;baseValue:16381),     ( nextState: 0; nbAdditionalBits:20;  nbBits:5;baseValue:1048573),
    ( nextState: 0; nbAdditionalBits: 2;  nbBits:5;baseValue:    1),     ( nextState:16; nbAdditionalBits: 7;  nbBits:4;baseValue:  125),
    ( nextState: 0; nbAdditionalBits:11;  nbBits:5;baseValue: 2045),     ( nextState: 0; nbAdditionalBits:17;  nbBits:5;baseValue:131069),
    ( nextState: 0; nbAdditionalBits:22;  nbBits:5;baseValue:4194301),   ( nextState: 0; nbAdditionalBits: 4;  nbBits:5;baseValue:   13),
    ( nextState:16; nbAdditionalBits: 8;  nbBits:4;baseValue:  253),     ( nextState: 0; nbAdditionalBits:13;  nbBits:5;baseValue: 8189),
    ( nextState: 0; nbAdditionalBits:19;  nbBits:5;baseValue:524285),    ( nextState: 0; nbAdditionalBits: 1;  nbBits:5;baseValue:    1),
    ( nextState:16; nbAdditionalBits: 6;  nbBits:4;baseValue:   61),     ( nextState: 0; nbAdditionalBits:10;  nbBits:5;baseValue: 1021),
    ( nextState: 0; nbAdditionalBits:16;  nbBits:5;baseValue:65533),     ( nextState: 0; nbAdditionalBits:28;  nbBits:5;baseValue:268435453),
    ( nextState: 0; nbAdditionalBits:27;  nbBits:5;baseValue:134217725), ( nextState: 0; nbAdditionalBits:26;  nbBits:5;baseValue:67108861),
    ( nextState: 0; nbAdditionalBits:25;  nbBits:5;baseValue:33554429),  ( nextState: 0; nbAdditionalBits:24;  nbBits:5;baseValue:16777213)
);   { OF_defaultDTable }


{ Default FSE distribution table for Match Lengths }
  ML_defaultDTable:array[0..64] of ZSTD_seqSymbol= (
    { nextState, nbAddBits, nbBits, baseVal }
    ( nextState: 1; nbAdditionalBits: 1;  nbBits:1;baseValue: 6),  { header : fastMode, tableLog }
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:    3),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:4;baseValue:    4),
    ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    5),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    6),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    8),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    9),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:   11),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   13),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   16),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   19),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   22),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   25),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   28),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   31),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   34),  ( nextState: 0; nbAdditionalBits: 1;  nbBits:6;baseValue:   37),
    ( nextState: 0; nbAdditionalBits: 1;  nbBits:6;baseValue:   41),  ( nextState: 0; nbAdditionalBits: 2;  nbBits:6;baseValue:   47),
    ( nextState: 0; nbAdditionalBits: 3;  nbBits:6;baseValue:   59),  ( nextState: 0; nbAdditionalBits: 4;  nbBits:6;baseValue:   83),
    ( nextState: 0; nbAdditionalBits: 7;  nbBits:6;baseValue:  131),  ( nextState: 0; nbAdditionalBits: 9;  nbBits:6;baseValue:  515),
    ( nextState:16; nbAdditionalBits: 0;  nbBits:4;baseValue:    4),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:4;baseValue:    5),
    ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    6),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:    7),
    ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    9),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:5;baseValue:   10),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   12),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   15),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   18),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   21),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   24),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   27),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   30),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   33),
    ( nextState: 0; nbAdditionalBits: 1;  nbBits:6;baseValue:   35),  ( nextState: 0; nbAdditionalBits: 1;  nbBits:6;baseValue:   39),
    ( nextState: 0; nbAdditionalBits: 2;  nbBits:6;baseValue:   43),  ( nextState: 0; nbAdditionalBits: 3;  nbBits:6;baseValue:   51),
    ( nextState: 0; nbAdditionalBits: 4;  nbBits:6;baseValue:   67),  ( nextState: 0; nbAdditionalBits: 5;  nbBits:6;baseValue:   99),
    ( nextState: 0; nbAdditionalBits: 8;  nbBits:6;baseValue:  259),  ( nextState:32; nbAdditionalBits: 0;  nbBits:4;baseValue:    4),
    ( nextState:48; nbAdditionalBits: 0;  nbBits:4;baseValue:    4),  ( nextState:16; nbAdditionalBits: 0;  nbBits:4;baseValue:    5),
    ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    7),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:    8),
    ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:   10),  ( nextState:32; nbAdditionalBits: 0;  nbBits:5;baseValue:   11),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   14),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   17),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   20),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   23),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   26),  ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   29),
    ( nextState: 0; nbAdditionalBits: 0;  nbBits:6;baseValue:   32),  ( nextState: 0; nbAdditionalBits:16;  nbBits:6;baseValue:65539),
    ( nextState: 0; nbAdditionalBits:15;  nbBits:6;baseValue:32771),  ( nextState: 0; nbAdditionalBits:14;  nbBits:6;baseValue:16387),
    ( nextState: 0; nbAdditionalBits:13;  nbBits:6;baseValue: 8195),  ( nextState: 0; nbAdditionalBits:12;  nbBits:6;baseValue: 4099),
    ( nextState: 0; nbAdditionalBits:11;  nbBits:6;baseValue: 2051),  ( nextState: 0; nbAdditionalBits:10;  nbBits:6;baseValue: 1027)
);   { ML_defaultDTable }

{_*******************************************************
*  Macros
*********************************************************}

{ These two optional macros force the use one way or another of the two
 * ZSTD_decompressSequences implementations. You can't force in both directions
 * at the same time.
 }
type
  pseq_t=^seq_t;
  pZSTD_fseState=^ZSTD_fseState;
  pseqState_t=^seqState_t;

seq_t=record
    litLength:int32;
    matchLength:int32;
    offset:int32;
    match:pbyte;
end;

ZSTD_fseState=record
    state:int32;
    table:pZSTD_seqSymbol;
end;

seqState_t=record
    DStream:BIT_DStream_t;
    stateLL:ZSTD_fseState;
    stateOffb:ZSTD_fseState;
    stateML:ZSTD_fseState;
    prevOffset:array[0..ZSTD_REP_NUM-1] of int32;
    prefixStart:pbyte;
    dictEnd:pbyte;
    pos:int32;
end;
ZSTD_longOffset_e= ( ZSTD_lo_isRegularOffset, ZSTD_lo_isLongOffset:=1);
ZSTD_prefetch_e= (ZSTD_p_noPrefetch:=0, ZSTD_p_prefetch:=1 );
ZSTD_decompressSequences_t=function (dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
function ZSTD_getcBlockSize(const src:pbyte;srcSize:int32;bpPtr:pblockProperties_t):int32;
procedure ZSTD_checkContinuity(dctx:pZSTD_DCtx;dst:pbyte);
function ZSTD_decompressBlock_internal(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  const src:pbyte;srcSize:int32; frame:int32):int32;
procedure ZSTD_buildFSETable(dt:pZSTD_seqSymbol;
            const normalizedCounter:psmallint;maxSymbolValue:Uint32;
            baseValue,nbAdditionalBits:pUint32;
           tableLog:Uint32;wksp:pbyte;wkspSize,bmi2:int32);
implementation
uses huf_decompress,entropy_common,zstd_common,math;
{_*******************************************************
*  Memory operations
*********************************************************}
procedure ZSTD_copy4(dst,src:pbyte); 
begin 
  move( src^, dst^,4);
end;


{-*************************************************************
 *   Block decoding
 **************************************************************}

{! ZSTD_getcBlockSize() :
 *  Provides the size of compressed block from block header `src` }
function ZSTD_getcBlockSize(const src:pbyte;srcSize:int32;bpPtr:pblockProperties_t):int32;
var
  cBlockHeader,cSize:Uint32;
begin
    if (srcSize < ZSTD_blockHeaderSize) then
       exit(ERROR(srcSize_wrong));

    cBlockHeader := MEM_readLE24(src);
    cSize := cBlockHeader  shr  3;
    bpPtr^.lastBlock := cBlockHeader  and  1;
    bpPtr^.blockType := blockType_e((cBlockHeader  shr  1)  and  3);
    bpPtr^.origSize := cSize;   { only useful for RLE }
    if (bpPtr^.blockType = bt_rle) then
      exit(1);
    IF(bpPtr^.blockType = bt_reserved) then
      exit(ERROR(corruption_detected));
    result := cSize;
end;

{! ZSTD_decodeLiteralsBlock() :
 * @return : nb of bytes read from src (< srcSize )
 *  note : symbol not declared but exposed for fullbench }
function ZSTD_decodeLiteralsBlock(dctx:pZSTD_DCtx;
                          const src:pbyte;srcSize:int32):int32;   { note : srcSize < BLOCKSIZE }
var
  istart:pbyte;
  litEncType:symbolEncodingType_e;
  lhSize, litSize, litCSize,hufSuccess:int32;
  singleStream,lhlCode,lhc:Uint32;
begin
    //log(3,  'ZSTD_decodeLiteralsBlock');
    IF(srcSize < MIN_CBLOCK_SIZE) then
      exit(ERROR(corruption_detected));

    istart := src;
    litEncType := symbolEncodingType_e(istart[0]  and  3);

    case(litEncType) of
      set_repeat,set_compressed:        
      begin
        if litEncType=set_repeat then
        begin
          //log(3,  'set_repeat flag : re-using stats from previous compressed literals block');
          if (dctx^.litEntropy=0) then
           exit(ERROR(dictionary_corrupted));
          { fall-through }
        end;
        IF (srcSize < 5) then
          exit(ERROR(corruption_detected));// 'srcSize >= MIN_CBLOCK_SIZE = 3; here we need up to 5 for case 3');   

        singleStream:=0;
        lhlCode := (istart[0]  shr  2)  and  3;
        lhc := MEM_readLE32(istart);
        case(lhlCode) of 
          0, 1:   { note : default is impossible, since lhlCode into [0..3] }
          begin
            { 2 - 2 - 10 - 10 }
            singleStream := ord(lhlCode = 0);
            lhSize := 3;
            litSize  := (lhc  shr  4)  and  $3FF;
            litCSize := (lhc  shr  14)  and  $3FF;
          end;
          2:
          begin
            { 2 - 2 - 14 - 14 }
            lhSize := 4;
            litSize  := (lhc  shr  4)  and  $3FFF;
            litCSize := lhc  shr  18;
          end;
          3:
          begin
            { 2 - 2 - 18 - 18 }
            lhSize := 5;
            litSize  := (lhc  shr  4)  and  $3FFFF;
            litCSize := (lhc  shr  22) + (int32(istart[4])  shl  10);
          end;
          else
            begin
              { 2 - 2 - 10 - 10 }
              singleStream := ord(lhlCode = 0);
              lhSize := 3;
              litSize  := (lhc  shr  4)  and  $3FF;
              litCSize := (lhc  shr  14)  and  $3FF;
            end;
        end;
        IF (litSize > ZSTD_BLOCKSIZE_MAX) then
          exit(ERROR(corruption_detected));
        IF (litCSize + lhSize > srcSize) then
          exit(ERROR(corruption_detected));

        { prefetch huffman table if cold }
        if (dctx^.ddictIsCold<>0) and (litSize > 768 { heuristic }) then
        begin
            //PREFETCH_AREA(dctx^.HUFptr, sizeof(dctx^.entropy.hufTable));
        end;

        if (litEncType=set_repeat) then
        begin
            if (singleStream<>0) then
            begin
                hufSuccess := HUF_decompress1X_usingDTable_bmi2(
                    dctx^.litBuffer, litSize, istart+lhSize, litCSize,
                    dctx^.HUFptr, dctx^.bmi2);
            end
            else 
            begin
                hufSuccess := HUF_decompress4X_usingDTable_bmi2(
                    dctx^.litBuffer, litSize, istart+lhSize, litCSize,
                    dctx^.HUFptr, dctx^.bmi2);
            end;
        end
        else 
        begin
            if (singleStream<>0) then
            begin
                hufSuccess := HUF_decompress1X1_DCtx_wksp_bmi2(
                    dctx^.entropy.hufTable, dctx^.litBuffer, litSize,
                    istart+lhSize, litCSize, @dctx^.workspace,
                    sizeof(dctx^.workspace), dctx^.bmi2);
            end
            else 
            begin
                hufSuccess := HUF_decompress4X_hufOnly_wksp_bmi2(
                    dctx^.entropy.hufTable, dctx^.litBuffer, litSize,
                    istart+lhSize, litCSize, @dctx^.workspace,
                    sizeof(dctx^.workspace), dctx^.bmi2);
            end;
        end;

        IF (ERR_isError(hufSuccess)<>0) then
        begin
         //log(3,  'DBG HUF decompress failed: hufSuccess=%i', hufSuccess);
         exit(ERROR(corruption_detected));
        end;

        dctx^.litPtr := dctx^.litBuffer;
        dctx^.litSize := litSize;
        dctx^.litEntropy := 1;
        if (litEncType=set_compressed) then
          dctx^.HUFptr := dctx^.entropy.hufTable;
        fillbyte(dctx^.litBuffer [ dctx^.litSize], WILDCOPY_OVERLENGTH, 0);
        exit(litCSize + lhSize);
      end;

      set_basic:
      begin   
        lhlCode := ((istart[0])  shr  2)  and  3;
        case(lhlCode) of
          0,2:   { note : default is impossible, since lhlCode into [0..3] }
          begin
            lhSize := 1;
            litSize := istart[0]  shr  3;
          end;

          1:
          begin
            lhSize := 2;
            litSize := MEM_readLE16(istart)  shr  4;
          end;
          3:
          begin
            lhSize := 3;
            litSize := MEM_readLE24(istart)  shr  4;
          end;
          else
            begin
              lhSize := 1;
              litSize := istart[0]  shr  3;
            end;
        end;

        if (lhSize+litSize+WILDCOPY_OVERLENGTH > srcSize) then
        begin  { risk reading beyond src buffer with wildcopy }
            IF (litSize+lhSize > srcSize) then
             exit(ERROR(corruption_detected));
            move( istart[lhSize], dctx^.litBuffer, litSize);
            dctx^.litPtr := dctx^.litBuffer;
            dctx^.litSize := litSize;
            fillbyte(dctx^.litBuffer [dctx^.litSize], WILDCOPY_OVERLENGTH, 0);
            exit (lhSize+litSize);
        end;
        { direct reference into compressed stream }
        dctx^.litPtr := istart+lhSize;
        dctx^.litSize := litSize;
        exit (lhSize+litSize);
      end;

      set_rle:
      begin 
        lhlCode := ((istart[0])  shr  2)  and  3;
        case(lhlCode) of
          0,2:   { note : default is impossible, since lhlCode into [0..3] }
          begin
            lhSize := 1;
            litSize := istart[0]  shr  3;
          end;
          1:
          begin
            lhSize := 2;
            litSize := MEM_readLE16(istart)  shr  4;
          end;
          3:
          begin
            lhSize := 3;
            litSize := MEM_readLE24(istart)  shr  4;
            IF (srcSize<4) then 
              exit(ERROR(corruption_detected));// 'srcSize >= MIN_CBLOCK_SIZE = 3; here we need lhSize+1 := 4');
          end;
          else   { note : default is impossible, since lhlCode into [0..3] }
            begin
              lhSize := 1;
              litSize := istart[0]  shr  3;
            end;
        end;
        IF (litSize > ZSTD_BLOCKSIZE_MAX) then
          exit(ERROR(corruption_detected));
        fillbyte(dctx^.litBuffer, litSize + WILDCOPY_OVERLENGTH, istart[lhSize]);
        dctx^.litPtr := dctx^.litBuffer;
        dctx^.litSize := litSize;
        exit(lhSize+1);
    end;
    else
        exit(ERROR(corruption_detected));//, 'impossible');
    end;
end;

procedure ZSTD_buildSeqTable_rle(dt:pZSTD_seqSymbol; baseValue,nbAddBits:Uint32);
var
  DTableH:pZSTD_seqSymbol_header;
  cell:pZSTD_seqSymbol;
begin
    DTableH := pZSTD_seqSymbol_header(dt);
    cell := dt + 1;

    DTableH^.tableLog := 0;
    DTableH^.fastMode := 0;

    cell^.nbBits := 0;
    cell^.nextState := 0;
    assert(nbAddBits < 255);
    cell^.nbAdditionalBits := nbAddBits;
    cell^.baseValue := baseValue;
end;


{ ZSTD_buildFSETable() :
 * generate FSE decoding table for one symbol (ll, ml or off)
 * cannot fail if input is valid :=>
 * all inputs are presumed validated at this stage }
procedure ZSTD_buildFSETable_body(dt:pZSTD_seqSymbol;
            const normalizedCounter:psmallint;maxSymbolValue:Uint32;
            baseValue,nbAdditionalBits:pUint32;
           tableLog:Uint32;wksp:pbyte;wkspSize:int32);
var
  tableDecode:pZSTD_seqSymbol;
  maxSV1,tableSize,highThreshold,s:Uint32;
  symbolNext:puint16;
  spread:pbyte;
  DTableH:ZSTD_seqSymbol_header ;
  largeLimit:smallint;
  tableMask,step,pos,i,n:int32;
  add,sv:Uint64;
  position,unroll,u,uPosition:int32;
  symbol,nextState:Uint32;
begin
    tableDecode := dt+1;
    maxSV1 := maxSymbolValue + 1;
    tableSize := 1  shl  tableLog;

    symbolNext := puint16(wksp);
    spread := pbyte(symbolNext + MaxSeq + 1);
    highThreshold := tableSize - 1;


    { Sanity Checks }
    assert(maxSymbolValue <= MaxSeq);
    assert(tableLog <= MaxFSELog);
    assert(wkspSize >= ZSTD_BUILD_FSE_TABLE_WKSP_SIZE);

    { Init, lay down lowprob symbols }

    DTableH.tableLog := tableLog;
    DTableH.fastMode := 1;
    
    largeLimit:= smallint(1  shl  (tableLog-1));
    for s:=0 to maxSV1-1 do 
    begin
        if (normalizedCounter[s]=-1) then
        begin
            tableDecode[highThreshold].baseValue := s;
            dec(highThreshold);
            symbolNext[s] := 1;
        end 
        else 
        begin
            if (normalizedCounter[s] >= largeLimit) then
              DTableH.fastMode:=0;
            assert(normalizedCounter[s]>=0);
            symbolNext[s] := uint16(normalizedCounter[s]);
        end;   
    end;
    move( DTableH, dt^,sizeof(DTableH));

    { Spread symbols }
    assert(tableSize <= 512);
    { Specialized symbol spreading for the case when there are
     * no low probability (-1 count) symbols. When compressing
     * small blocks we avoid low probability symbols to hit this
     * case, since header decoding speed matters more.
     }

    if (highThreshold = tableSize - 1) then
    begin
        tableMask := tableSize-1;
        step := FSE_TABLESTEP(tableSize);
        { First lay down the symbols in order.
         * We use a uint64_t to lay down 8 bytes at a time. This reduces branch
         * misses since small blocks generally have small table logs, so nearly
         * all symbols have counts <= 8. We ensure we have 8 bytes at the end of
         * our buffer to handle the over-write.
         }

        add := Uint64($0101010101010101);
        pos := 0;
        sv := 0;
        for s:=0 to maxSV1-1 do 
        begin
            n := normalizedCounter[s];
            MEM_write64(spread + pos, sv);
            i := 8;
            while ( i < n) do
            begin
                MEM_write64(spread + pos + i, sv);
                i :=i + 8;
            end;
            pos :=pos + n;
            sv :=sv + add
        end;

        { Now we spread those positions across the table.
         * The benefit of doing it in two stages is that we avoid the the
         * variable size inner loop, which caused lots of branch misses.
         * Now we can run through all the positions without any branch misses.
         * We unroll the loop twice, since that is what emperically worked best.
         }
        
        position := 0;
        unroll := 2;
        assert(tableSize mod unroll = 0); { FSE_MIN_TABLELOG is 5 }
        s := 0;
        while  (s < int32(tableSize)) do
        begin
            for u:=0 to unroll-1 do 
            begin
                uPosition := (position + (u * step))  and  tableMask;
                tableDecode[uPosition].baseValue := spread[s + u];
            end;
            position := (position + (unroll * step))  and  tableMask;
            s :=s + unroll
        end;
        assert(position = 0);

    end
    else 
    begin
        tableMask := tableSize-1;
        step := FSE_TABLESTEP(tableSize);
        position := 0;
        for s:=0 to maxSV1-1 do 
        begin
            n := normalizedCounter[s];
            for i:=0 to n-1 do 
            begin
                tableDecode[position].baseValue := s;
                position := (position + step)  and  tableMask;
                while (position > highThreshold) do
                  position := (position + step)  and  tableMask;   { lowprob area }
            end;   
        end;
        assert(position = 0); { position must reach all cells once, otherwise normalizedCounter is incorrect }
    end;

    { Build Decoding table }

    for u:=0 to tableSize-1 do 
    begin
        symbol := tableDecode[u].baseValue;
        nextState := symbolNext[symbol];
        inc(symbolNext[symbol]);
        tableDecode[u].nbBits := BYTE (tableLog - BIT_highbit32(nextState) );
        tableDecode[u].nextState := smallint ( (nextState  shl  tableDecode[u].nbBits) - tableSize);
        assert(nbAdditionalBits[symbol] < 255);
        tableDecode[u].nbAdditionalBits := BYTE(nbAdditionalBits[symbol]);
        tableDecode[u].baseValue := baseValue[symbol];
    end;

end;

{ Avoids the FORCE_INLINE of the _body() function. }
procedure ZSTD_buildFSETable_body_default(dt:pZSTD_seqSymbol;
            const normalizedCounter:psmallint;maxSymbolValue:Uint32;
            baseValue,nbAdditionalBits:pUint32;
           tableLog:Uint32;wksp:pbyte;wkspSize:int32);
begin
    ZSTD_buildFSETable_body(dt, normalizedCounter, maxSymbolValue,
            baseValue, nbAdditionalBits, tableLog, wksp, wkspSize);
end;

procedure ZSTD_buildFSETable_body_bmi2(dt:pZSTD_seqSymbol;
            const normalizedCounter:psmallint;maxSymbolValue:Uint32;
            baseValue,nbAdditionalBits:pUint32;
           tableLog:Uint32;wksp:pbyte;wkspSize:int32);
begin
    ZSTD_buildFSETable_body(dt, normalizedCounter, maxSymbolValue,
            baseValue, nbAdditionalBits, tableLog, wksp, wkspSize);
end;


procedure ZSTD_buildFSETable(dt:pZSTD_seqSymbol;
            const normalizedCounter:psmallint;maxSymbolValue:Uint32;
            baseValue,nbAdditionalBits:pUint32;
           tableLog:Uint32;wksp:pbyte;wkspSize,bmi2:int32);
begin

    if (bmi2<>0) then
    begin
        ZSTD_buildFSETable_body_bmi2(dt, normalizedCounter, maxSymbolValue,
                baseValue, nbAdditionalBits, tableLog, wksp, wkspSize);
        exit;
    end;

    ZSTD_buildFSETable_body_default(dt, normalizedCounter, maxSymbolValue,
            baseValue, nbAdditionalBits, tableLog, wksp, wkspSize);
end;


{! ZSTD_buildSeqTable() :
 * @return : nb bytes read from src,
 *           or an error code if it fails }
function ZSTD_buildSeqTable(DTableSpace:pZSTD_seqSymbol; DTablePtr:ppZSTD_seqSymbol;
  etype:symbolEncodingType_e; max,  maxLog:Uint32;const src:pbyte;srcSize:int32;
  baseValue,nbAdditionalBits:pUint32;defaultTable:pZSTD_seqSymbol;flagRepeatTable:Uint32;
  ddictIsCold,  nbSeq:int32; wksp:pUint32;  wkspSize,bmi2:int32):int32;
var
  symbol,baseline,nbBits:Uint32;
  pStart:pbyte;
  pSize:int32;
  tableLog:uint32;
  norm:array[0..MaxSeq] of smallint;
  headerSize:int32;
begin
    case (etype) of
      set_rle :
      begin
        IF (srcSize=0) then
          exit(ERROR(srcSize_wrong));
        IF (src^ > max) then 
          exit(ERROR(corruption_detected));
        symbol := src^;
        baseline := baseValue[symbol];
        nbBits := nbAdditionalBits[symbol];
        ZSTD_buildSeqTable_rle(DTableSpace, baseline, nbBits);
        
        DTablePtr^ := DTableSpace;
        exit(1);
      end;
      set_basic :
      begin
        DTablePtr^ := defaultTable;
        exit(0);
      end;
      set_repeat:
      begin
        IF (flagRepeatTable=0) then
          exit(ERROR(corruption_detected));
        { prefetch FSE table if used }
        if (ddictIsCold<>0) and (nbSeq > 24 { heuristic }) then
        begin
            //pStart := pbyte(DTablePtr^);
            //pSize := sizeof(ZSTD_seqSymbol) * (SEQSYMBOL_TABLE_SIZE(maxLog));
            //PREFETCH_AREA(pStart, pSize);
        end;
        exit(0);
      end;
      set_compressed :
      begin           
        headerSize := FSE_readNCount(norm,  @max,  @tableLog, src, srcSize);
        IF (FSE_isError(headerSize)<>0) then
          exit(ERROR(corruption_detected));
        IF (tableLog > maxLog) then
          exit(ERROR(corruption_detected));
        ZSTD_buildFSETable(DTableSpace, norm, max, baseValue, nbAdditionalBits, tableLog, pbyte(wksp), wkspSize, bmi2);
        DTablePtr^ := DTableSpace;
        exit(headerSize);
      end;
      else
      begin
        assert(false);
        exit(ERROR(GENERIC_ERROR));// 'impossible');
      end;
    end;
end;

function ZSTD_decodeSeqHeaders(dctx:pZSTD_DCtx; nbSeqPtr:pint32;
  const src:pbyte;srcSize:int32):int32;
var
  istart,iend,ip:pbyte;
  nbSeq:int32;
  LLtype,OFtype,MLtype:symbolEncodingType_e;
  llhSize,ofhSize,mlhSize:int32;
begin
    istart := src;
    iend := istart + srcSize;
    ip := istart;
    //log(3,  'ZSTD_decodeSeqHeaders');

    { check }
    IF (srcSize < MIN_SEQUENCES_SIZE) then
      exit(ERROR(srcSize_wrong));

    { SeqHead }
    nbSeq := ip^;
    inc(ip);
    if (nbSeq=0) then
    begin
        nbSeqPtr^ :=0;
        IF (srcSize <> 1) then
          exit(ERROR(srcSize_wrong));
        exit(1);
    end;
    if (nbSeq > $7F) then
    begin
        if (nbSeq = $FF) then
        begin
            IF (ip+2 > iend) then
             exit(ERROR(srcSize_wrong));
            nbSeq := MEM_readLE16(ip) + LONGNBSEQ;
            ip :=ip+2;
        end
        else 
        begin
            IF (ip >= iend) then 
              exit(ERROR(srcSize_wrong));
            nbSeq := ((nbSeq-$80) shl 8) + ip^;
            inc(ip);
        end;
    end;
    nbSeqPtr^ := nbSeq;

    { FSE table descriptors }
    IF (ip+1 > iend) then
      exit(ERROR(srcSize_wrong)); { minimum possible size: 1 byte for symbol encoding types }
    LLtype := symbolEncodingType_e(   ip^  shr  6);
    OFtype := symbolEncodingType_e((  ip^  shr  4)  and  3);
    MLtype := symbolEncodingType_e((  ip^  shr  2)  and  3);
    inc(ip);

    
    { Build DTables }
    llhSize := ZSTD_buildSeqTable(dctx^.entropy.LLTable,  @dctx^.LLTptr,
                                                  LLtype, MaxLL, LLFSELog,
                                                  ip, iend-ip,
                                                  LL_base, LL_bits,
                                                  LL_defaultDTable, dctx^.fseEntropy,
                                                  dctx^.ddictIsCold, nbSeq,
                                                  dctx^.workspace, sizeof(dctx^.workspace),
                                                  dctx^.bmi2);
    IF (ZSTD_isError(llhSize)<>0) then
      exit(ERROR(corruption_detected));// 'ZSTD_buildSeqTable failed');
    ip :=ip + llhSize;
    

    ofhSize := ZSTD_buildSeqTable(dctx^.entropy.OFTable,  @dctx^.OFTptr,
                                                  OFtype, MaxOff, OffFSELog,
                                                  ip, iend-ip,
                                                  OF_base, OF_bits,
                                                  OF_defaultDTable, dctx^.fseEntropy,
                                                  dctx^.ddictIsCold, nbSeq,
                                                  dctx^.workspace, sizeof(dctx^.workspace),
                                                  dctx^.bmi2);
    IF (ZSTD_isError(ofhSize)<>0) then 
      exit(ERROR(corruption_detected));// 'ZSTD_buildSeqTable failed');
    ip :=ip + ofhSize;

    mlhSize := ZSTD_buildSeqTable(dctx^.entropy.MLTable,  @dctx^.MLTptr,
                                                  MLtype, MaxML, MLFSELog,
                                                  ip, iend-ip,
                                                  ML_base, ML_bits,
                                                  ML_defaultDTable, dctx^.fseEntropy,
                                                  dctx^.ddictIsCold, nbSeq,
                                                  dctx^.workspace, sizeof(dctx^.workspace),
                                                  dctx^.bmi2);
    IF (ZSTD_isError(mlhSize)<>0) then 
      exit(ERROR(corruption_detected));// 'ZSTD_buildSeqTable failed');
    ip :=ip + mlhSize;

    result := ip-istart;
end;

{! ZSTD_overlapCopy8() :
 *  Copies 8 bytes from ip to op and updates op and ip where ip <= op.
 *  If the offset is < 8 then the offset is spread to at least 8 bytes.
 *
 *  Precondition: *ip <= *op
 *  Postcondition: *op - *op >= 8
 }
procedure ZSTD_overlapCopy8(op,ip:ppBYTE;offset:int32);
const
  dec32table:array[0..7] of Uint32=(0, 1, 2, 1, 4, 4, 4, 4);{ added }
  dec64table:array[0..7] of int32=(8, 8, 8, 7, 8, 9,10,11); { subtracted }
var
  sub2:int32;
begin
    assert( ip^ <= op^);
    if (offset < 8) then
    begin
        { close range match, overlap } 
        sub2 := dec64table[offset];
        op^[0] := ip^[0];
        op^[1] := ip^[1];
        op^[2] := ip^[2];
        op^[3] := ip^[3];
        ip^ :=ip^ + dec32table[offset];
        ZSTD_copy4( op^ + 4, ip^);
        ip^ :=ip^ - sub2;
    end
    else 
    begin
        ZSTD_copy8(op^, ip^);
    end;
    ip^ :=ip^ + 8;
    op^ :=op^ + 8;
    assert( op^ - ip^ >= 8);
end;

{! ZSTD_safecopy() :
 *  Specialized version of memcpy() that is allowed to READ up to WILDCOPY_OVERLENGTH past the input buffer
 *  and write up to 16 bytes past oend_w (op >= oend_w is allowed).
 *  This function is only called in the uncommon case where the sequence is near the end of the block. It
 *  should be fast for a single long sequence, but can be slow for several short sequences.
 *
 *  @param ovtype controls the overlap detection
 *         - ZSTD_no_overlap: The source and destination are guaranteed to be at least WILDCOPY_VECLEN bytes apart.
 *         - ZSTD_overlap_src_before_dst: The src and dst may overlap and may be any distance apart.
 *           The src buffer must be before the dst buffer.
 }
procedure ZSTD_safecopy(op, oend_w, ip:pbyte; length:int32; ovtype:ZSTD_overlap_e);
var
  diff:int32;
  oend:pbyte;
begin
    diff := op - ip;
    oend := op + length;

    assert(((ovtype = ZSTD_no_overlap) and ((diff <= -8)  or  (diff >= 8)  or  (op >= oend_w)))  or 
           ((ovtype = ZSTD_overlap_src_before_dst) and (diff >= 0)));

    if (length < 8) then
    begin
        { Handle short lengths. }
        while (op < oend) do
        begin
           op^ := ip^;
           inc(op);
           inc(ip);
        end;
        exit;
    end;
    if (ovtype = ZSTD_overlap_src_before_dst) then
    begin
        { Copy 8 bytes and ensure the offset >= 8 when there can be overlap. }
        assert(length >= 8);
        ZSTD_overlapCopy8( @op,  @ip, diff);
        assert(op - ip >= 8);
        assert(op <= oend);
    end;

    if (oend <= oend_w) then
    begin
        { No risk of overwrite. }
        ZSTD_wildcopy(op, ip, length, ovtype);
        exit;
    end;
    if (op <= oend_w) then
    begin
        { Wildcopy until we get close to the end. }
        assert(oend > oend_w);
        ZSTD_wildcopy(op, ip, oend_w - op, ovtype);
        ip :=ip + (oend_w - op);
        op := oend_w;
    end;
    { Handle the leftovers. }
    while (op < oend) do
    begin 
      op^ := ip^;
      inc(op);
      inc(ip);
    end;
end;

{ ZSTD_execSequenceEnd():
 * This version handles cases that are near the end of the output buffer. It requires
 * more careful checks to make sure there is no overflow. By separating out these hard
 * and unlikely cases, we can speed up the common cases.
 *
 * NOTE: This function needs to be fast for a single long sequence, but doesn't need
 * to be optimized for many small sequences, since those fall into ZSTD_execSequence().
 }

function ZSTD_execSequenceEnd(op,oend:pbyte;  sequence:seq_t;litPtr:ppbyte; litLimit:pbyte;
  prefixStart, virtualStart, dictEnd:pbyte):int32;
var
  oLitEnd,iLitEnd,match,oend_w:pbyte;
  sequenceLength,length1:int32;
begin
    oLitEnd := op + sequence.litLength;
    sequenceLength := sequence.litLength + sequence.matchLength;
    iLitEnd := litPtr^ + sequence.litLength;
    match := oLitEnd - sequence.offset;
    oend_w := oend - WILDCOPY_OVERLENGTH;

    { bounds checks : careful of address space overflow in 32-bit mode }
    IF (sequenceLength > int32(oend - op)) then
      exit(ERROR(dstint32ooSmall));// 'last match must fit within dstBuffer');
    IF (sequence.litLength > int32(litLimit - litPtr^)) then 
      exit(ERROR(corruption_detected));//  'try to read beyond literal buffer');
    assert(op < op + sequenceLength);
    assert(oLitEnd < op + sequenceLength);

    { copy literals }
    ZSTD_safecopy(op, oend_w, litPtr^, sequence.litLength, ZSTD_no_overlap);
    op := oLitEnd;
    litPtr^ := iLitEnd;

    { copy Match }
    if (sequence.offset > int32(oLitEnd - prefixStart)) then
    begin
        { offset beyond prefix }
        IF (sequence.offset > int32(oLitEnd - virtualStart)) then
          exit(ERROR(corruption_detected));
        match := dictEnd - (prefixStart-match);
        if (match + sequence.matchLength <= dictEnd) then
        begin
            move( match^, oLitEnd^,sequence.matchLength);
            exit(sequenceLength);
        end;
        { span extDict  and  currentPrefixSegment }
        length1 := dictEnd - match;
        move( match^, oLitEnd^,length1);
        op := oLitEnd + length1;
        sequence.matchLength :=sequence.matchLength - length1;
        match := prefixStart;
    end;
    ZSTD_safecopy(op, oend_w, match, sequence.matchLength, ZSTD_overlap_src_before_dst);
    result := sequenceLength;
end;

function ZSTD_execSequence(op,oend:pbyte;  sequence:seq_t;litPtr:ppBYTE; litLimit:pbyte;
  prefixStart, virtualStart, dictEnd:pbyte):int32;
var
  oLitEnd,oMatchEnd,oend_w,iLitEnd,match:pbyte;
  sequenceLength,length1:int32;
begin
    oLitEnd := op + sequence.litLength;
    sequenceLength := sequence.litLength + sequence.matchLength;
    oMatchEnd := op + sequenceLength;   { risk : address space overflow (32-bits) }
    oend_w := oend - WILDCOPY_OVERLENGTH;   { risk : address space underflow on oend:=nil }
    iLitEnd := litPtr^ + sequence.litLength;
    match := oLitEnd - sequence.offset;

    assert(op <> nil { Precondition });
    assert(oend_w < oend { No underflow });
    { Handle edge cases in a slow path:
     *   - Read beyond end of literals
     *   - Match end is within WILDCOPY_OVERLIMIT of oend
     *   - 32-bit mode and the match length overflows
     }
    
    if ((iLitEnd > litLimit)  or (oMatchEnd > oend_w)  {$IFDEF CPU32} or
             (int32(oend - op) < sequenceLength + WILDCOPY_OVERLENGTH){$ENDIF}) then
        exit(ZSTD_execSequenceEnd(op, oend, sequence, litPtr, litLimit, prefixStart, virtualStart, dictEnd));

    { Assumptions (everything else goes into ZSTD_execSequenceEnd()) }
    assert(op <= oLitEnd { No overflow });
    assert(oLitEnd < oMatchEnd { Non-zero match  and  no overflow });
    assert(oMatchEnd <= oend { No underflow });
    assert(iLitEnd <= litLimit { Literal length is in bounds });
    assert(oLitEnd <= oend_w { Can wildcopy literals });
    assert(oMatchEnd <= oend_w { Can wildcopy matches });

    { Copy Literals:
     * Split out litLength <= 16 since it is nearly always true. +1.6% on gcc-9.
     * We likely don't need the full 32-byte wildcopy.
     }
    assert(WILDCOPY_OVERLENGTH >= 16);
    ZSTD_copy16(op, litPtr^);
    if ((sequence.litLength > 16)) then
    begin
        ZSTD_wildcopy(op+16, litPtr^+16, sequence.litLength-16, ZSTD_no_overlap);
    end;
    op := oLitEnd;
    litPtr^ := iLitEnd;   { update for next sequence }

    { Copy Match }
    if (sequence.offset > int32(oLitEnd - prefixStart)) then
    begin
        { offset beyond prefix ^. go into extDict }
        IF (sequence.offset > int32(oLitEnd - virtualStart)) then
          exit(ERROR(corruption_detected));
        match := dictEnd + (match - prefixStart);
        if (match + sequence.matchLength <= dictEnd) then
        begin
            move( match^, oLitEnd^,sequence.matchLength);
            exit(sequenceLength);
        end;
        { span extDict  and  currentPrefixSegment }
        length1 := dictEnd - match;
        move(match^, oLitEnd^,  length1);
        op := oLitEnd + length1;
        sequence.matchLength :=sequence.matchLength - length1;
        match := prefixStart;
    end;
    { Match within prefix of 1 or more bytes }
    assert(op <= oMatchEnd);
    assert(oMatchEnd <= oend_w);
    assert(match >= prefixStart);
    assert(sequence.matchLength >= 1);

    { Nearly all offsets are >= WILDCOPY_VECLEN bytes, which means we can use wildcopy
     * without overlap checking.
     }
    if (sequence.offset >= WILDCOPY_VECLEN) then 
    begin
        { We bet on a full wildcopy for matches, since we expect matches to be
         * longer than literals (in general). In silesia, ~10% of matches are longer
         * than 16 bytes.
         }
        ZSTD_wildcopy(op, match, sequence.matchLength, ZSTD_no_overlap);
        exit(sequenceLength);
    end;
    assert(sequence.offset < WILDCOPY_VECLEN);

    { Copy 8 bytes and spread the offset to be >= 8. }
    ZSTD_overlapCopy8( @op,  @match, sequence.offset);

    { If the match length is > 8 bytes, then continue with the wildcopy. }
    if (sequence.matchLength > 8) then
    begin
        assert(op < oMatchEnd);
        ZSTD_wildcopy(op, match, sequence.matchLength-8, ZSTD_overlap_src_before_dst);
    end;
    result := sequenceLength;
end;

procedure ZSTD_initFseState(DStatePtr:pZSTD_fseState; bitD:pBIT_DStream_t; dt:pZSTD_seqSymbol);
var
  ptr:pbyte;
  DTableH:pZSTD_seqSymbol_header;
begin
    ptr := pbyte(dt);
    DTableH := pZSTD_seqSymbol_header(ptr);
    DStatePtr^.state := BIT_readBits(bitD, DTableH^.tableLog);
    //log(3,  'ZSTD_initFseState : val:=%u using %u bits',
    //            Uint32(DStatePtr^.state), DTableH^.tableLog);
    BIT_reloadDStream(bitD);
    DStatePtr^.table := dt + 1;
end;

procedure ZSTD_updateFseState(DStatePtr:pZSTD_fseState; bitD:pBIT_DStream_t);
var
  DInfo:ZSTD_seqSymbol;
  nbBits:Uint32;
  lowBits:int32;
begin
  DInfo := DStatePtr^.table[DStatePtr^.state];
  nbBits := DInfo.nbBits;
  lowBits := BIT_readBits(bitD, nbBits);
  DStatePtr^.state := DInfo.nextState + lowBits;
end;

procedure ZSTD_updateFseStateWithDInfo(DStatePtr:pZSTD_fseState; bitD:pBIT_DStream_t; DInfo:ZSTD_seqSymbol);
var
  nbBits:Uint32;
  lowBits:int32;
begin
    nbBits := DInfo.nbBits;
    lowBits := BIT_readBits(bitD, nbBits);
    DStatePtr^.state := DInfo.nextState + lowBits;
end;

{ We need to add at most (ZSTD_WINDOWLOG_MAX_32 - 1) bits to read the maximum
 * offset bits. But we can only read at most (STREAM_ACCUMULATOR_MIN_32 - 1)
 * bits before reloading. This value is the maximum number of bytes we read
 * after reloading when we are decoding long offsets.
 }

function ZSTD_decodeSequence(seqState:pseqState_t;longOffsets:ZSTD_longOffset_e;prefetch:ZSTD_prefetch_e):seq_t;
var
  seq:seq_t;
  llDInfo,mlDInfo,ofDInfo:ZSTD_seqSymbol;
  llBase,mlBase,ofBase,ll0,extraBits:Uint32;
  llBits,mlBits,ofBits,totalBits:byte;
  matchBase:pbyte;
  offset,temp,pos,kUseUpdateFseState:int32;
begin
    llDInfo := seqState^.stateLL.table[seqState^.stateLL.state];
    mlDInfo := seqState^.stateML.table[seqState^.stateML.state];
    ofDInfo := seqState^.stateOffb.table[seqState^.stateOffb.state];
    llBase := llDInfo.baseValue;
    mlBase := mlDInfo.baseValue;
    ofBase := ofDInfo.baseValue;
    llBits := llDInfo.nbAdditionalBits;
    mlBits := mlDInfo.nbAdditionalBits;
    ofBits := ofDInfo.nbAdditionalBits;
    totalBits := llBits+mlBits+ofBits;

    { sequence }
    
    if (ofBits > 1) then
    begin
        ASSERT(ord(ZSTD_lo_isLongOffset) = 1);
        //ASSERT(LONG_OFFSETS_MAX_EXTRA_BITS_32 = 5);
        assert(ofBits <= MaxOff);
        temp:=0;
        {$ifdef CPU32}
        temp:=1;
        {$endif}
        if (temp=1) and (ord(longOffsets)<>0) and (ofBits >= STREAM_ACCUMULATOR_MIN_32) then
        begin
            extraBits := ofBits - MIN(ofBits, 32 - seqState^.DStream.bitsConsumed);
            offset := ofBase + (BIT_readBitsFast( @seqState^.DStream, ofBits - extraBits)  shl  extraBits);
            BIT_reloadDStream( @seqState^.DStream);
            if (extraBits<>0) then
              offset :=offset + BIT_readBitsFast( @seqState^.DStream, extraBits);
            //assert(extraBits <= LONG_OFFSETS_MAX_EXTRA_BITS_32);   { to avoid another reload }
        end
        else 
        begin
            offset := ofBase + BIT_readBitsFast( @seqState^.DStream, ofBits{>0});   { <=  (ZSTD_WINDOWLOG_MAX-1) bits }
            if (temp=1) then
              BIT_reloadDStream( @seqState^.DStream);
        end;
        seqState^.prevOffset[2] := seqState^.prevOffset[1];
        seqState^.prevOffset[1] := seqState^.prevOffset[0];
        seqState^.prevOffset[0] := offset;
    end
    else 
    begin
        ll0 := ord(llBase = 0);
        if (ofBits = 0) then
        begin
            if ll0=0 then
                offset := seqState^.prevOffset[0]
            else 
            begin
                offset := seqState^.prevOffset[1];
                seqState^.prevOffset[1] := seqState^.prevOffset[0];
                seqState^.prevOffset[0] := offset;
            end;
        end
        else 
        begin
            offset := ofBase + ll0 + BIT_readBitsFast( @seqState^.DStream, 1);
            if (offset=3) then
              temp := seqState^.prevOffset[0] - 1
            else
              temp := seqState^.prevOffset[offset];
            temp :=temp + ord(temp=0);   { 0 is not valid; input is corrupted; force offset to 1 }
            if (offset <> 1) then
              seqState^.prevOffset[2] := seqState^.prevOffset[1];
            seqState^.prevOffset[1] := seqState^.prevOffset[0];
            offset := temp;
            seqState^.prevOffset[0] := offset;
        end;   
    end;
    seq.offset := offset;

    seq.matchLength := mlBase;
    if (mlBits > 0) then
        seq.matchLength :=seq.matchLength + BIT_readBitsFast( @seqState^.DStream, mlBits{>0});
    {$ifdef CPU32}
    if ((mlBits+llBits >= STREAM_ACCUMULATOR_MIN_32-5)) then
        BIT_reloadDStream( @seqState^.DStream);
    {$endif}
    {$ifdef CPU64}
    if ((totalBits >= STREAM_ACCUMULATOR_MIN_64-(LLFSELog+MLFSELog+OffFSELog))) then
        BIT_reloadDStream( @seqState^.DStream);
    {$endif}
    { Ensure there are enough bits to read the rest of data in 64-bit mode. }
    ASSERT(16+LLFSELog+MLFSELog+OffFSELog < STREAM_ACCUMULATOR_MIN_64);

    seq.litLength := llBase;
    if (llBits > 0) then
        seq.litLength :=seq.litLength + BIT_readBitsFast( @seqState^.DStream, llBits{>0});

    {$ifdef CPU32}
        BIT_reloadDStream( @seqState^.DStream);
    {$endif}
    //log(3,  'seq: litL:=%u, matchL:=%u, offset:=%u',
    //            seq.litLength, seq.matchLength, seq.offset);

    if (prefetch = ZSTD_p_prefetch) then
    begin
        pos := seqState^.pos + seq.litLength;
        if (seq.offset > pos) then
          matchBase := seqState^.dictEnd
        else
          matchBase := seqState^.prefixStart;
        seq.match := matchBase + pos - seq.offset;  { note : this operation can overflow when seq.offset is really too large, which can only happen when input is corrupted.
                                                    * No consequence though : no memory access will occur, offset is only used for prefetching }
        seqState^.pos := pos + seq.matchLength;
    end;

    { ANS state update
     * gcc-9.0.0 does 2.5% worse with ZSTD_updateFseStateWithDInfo().
     * clang-9.2.0 does 7% worse with ZSTD_updateFseState().
     * Naturally it seems like ZSTD_updateFseStateWithDInfo() should be the
     * better option, so it is the default for other compilers. But, if you
     * measure that it is worse, please put up a pull request.
     }
    begin
        kUseUpdateFseState := 0;
        if (kUseUpdateFseState<>0) then
        begin
            ZSTD_updateFseState( @seqState^.stateLL,  @seqState^.DStream);    { <=  9 bits }
            ZSTD_updateFseState( @seqState^.stateML,  @seqState^.DStream);    { <=  9 bits }
            {$ifdef CPU32}
              BIT_reloadDStream( @seqState^.DStream);    { <= 18 bits }
            {$endif}
            ZSTD_updateFseState( @seqState^.stateOffb,  @seqState^.DStream);  { <=  8 bits }
        end
        else 
        begin
            ZSTD_updateFseStateWithDInfo( @seqState^.stateLL,  @seqState^.DStream, llDInfo);    { <=  9 bits }
            ZSTD_updateFseStateWithDInfo( @seqState^.stateML,  @seqState^.DStream, mlDInfo);    { <=  9 bits }
            {$ifdef CPU32}
              BIT_reloadDStream( @seqState^.DStream);    { <= 18 bits }
            {$endif}
            ZSTD_updateFseStateWithDInfo( @seqState^.stateOffb,  @seqState^.DStream, ofDInfo);  { <=  8 bits }
        end;
    end;

    result := seq;
end;

function ZSTD_decompressSequences_body( dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
var
  ip,iend,ostart,oend,op:pbyte;
  litPtr,litEnd,prefixStart,vBase,dictEnd:pbyte;
  seqState:seqState_t;
  lerror:int32;
  i:uint32;
  sequence:seq_t;
  oneSeqSize,lastLLSize:int32;
begin
    ip := seqStart;
    iend := ip + seqSize;
    ostart := dst;
    oend := ostart + maxDstSize;
    op := ostart;
    litPtr := dctx^.litPtr;
    litEnd := litPtr + dctx^.litSize;
    prefixStart := (dctx^.prefixStart);
    vBase := (dctx^.virtualStart);
    dictEnd := (dctx^.dictEnd);
    //log(3,  'ZSTD_decompressSequences_body');

    { Regen sequences }
    if (nbSeq<>0) then
    begin
        lerror := 0;
        dctx^.fseEntropy := 1;
 
        for i:=0 to ZSTD_REP_NUM-1 do 
          seqState.prevOffset[i] := dctx^.entropy.rep[i]; 

        IF (ERR_isError(BIT_initDStream(@seqState.DStream, ip, iend-ip))<>0) then
          exit(ERROR(corruption_detected));
        ZSTD_initFseState( @seqState.stateLL,  @seqState.DStream, dctx^.LLTptr);
        ZSTD_initFseState( @seqState.stateOffb,  @seqState.DStream, dctx^.OFTptr);
        ZSTD_initFseState( @seqState.stateML,  @seqState.DStream, dctx^.MLTptr);
        assert(dst <> nil);

        ASSERT(
                (BIT_DStream_unfinished < BIT_DStream_completed) and
                (BIT_DStream_endOfBuffer < BIT_DStream_completed) and
                (BIT_DStream_completed < BIT_DStream_overflow));
        while (true) do
        begin
            sequence := ZSTD_decodeSequence( @seqState, isLongOffset, ZSTD_prefetch_e.ZSTD_p_noPrefetch);
            oneSeqSize := ZSTD_execSequence(op, oend, sequence,  @litPtr, litEnd, prefixStart, vBase, dictEnd);
            //log(3,  'regenerated sequence size : %u', Uint32(oneSeqSize));
            BIT_reloadDStream( @seqState.DStream);
            op :=op + oneSeqSize;
            { gcc and clang both don't like early returns in this loop.
             * Instead break and check for an error at the end of the loop.
             }
            if (ZSTD_isError(oneSeqSize)<>0) then
            begin
              lerror := oneSeqSize;
              break;
            end;
            dec(nbSeq);
            if (nbSeq=0) then
              break;
        end;

        { check if reached exact end }
        //log(3,  'ZSTD_decompressSequences_body: after decode loop, remaining nbSeq : %i', nbSeq);
        if (ZSTD_isError(lerror)<>0) then
          exit(lerror);
        IF (nbSeq<>0) then
          exit(ERROR(corruption_detected));
        IF(BIT_reloadDStream( @seqState.DStream) < BIT_DStream_completed) then
          exit(ERROR(corruption_detected));
        { save reps for next block }
        for i:=0 to ZSTD_REP_NUM-1 do
          dctx^.entropy.rep[i] := Uint32(seqState.prevOffset[i]); 
    end;

    { last literal segment }
 
    lastLLSize := litEnd - litPtr;
    IF (lastLLSize > int32(oend-op)) then
      exit(ERROR(dstint32ooSmall));
    if (op <> nil) then
    begin
        move(litPtr^, op^,  lastLLSize);
        op :=op + lastLLSize;
    end;

    result := op-ostart;
end;
function ZSTD_decompressSequencesLong_body(dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
const
	STORED_SEQS =4;
	STORED_SEQS_MASK =(STORED_SEQS-1);
	ADVANCED_SEQS =4;
VAR
  ip,iend,ostart,oend,op,dictStart:pbyte;
  litPtr,litEnd,prefixStart,vBase,dictEnd:pbyte;
  seqState:seqState_t;
  lerror,seqAdvance,seqNb:int32;
  i:int32;
  sequence:seq_t;
  oneSeqSize,lastLLSize:int32; 
  sequences:array[0..3] of seq_t; 
begin
    ip := seqStart;
    iend := ip + seqSize;
    ostart := dst;
    oend := ostart + maxDstSize;
    op := ostart;
    litPtr := dctx^.litPtr;
    litEnd := litPtr + dctx^.litSize;
    prefixStart := (dctx^.prefixStart);
    dictStart := (dctx^.virtualStart);
    dictEnd := (dctx^.dictEnd);

    { Regen sequences }
    if (nbSeq<>0) then
    begin 
        seqAdvance := MIN(nbSeq, ADVANCED_SEQS);
        dctx^.fseEntropy := 1;

        for i:=0 to ZSTD_REP_NUM-1 do 
          seqState.prevOffset[i] := dctx^.entropy.rep[i]; 

        seqState.prefixStart := prefixStart;
        seqState.pos := int32(op-prefixStart);
        seqState.dictEnd := dictEnd;
        assert(dst <> nil);
        assert(iend >= ip);
        IF(ERR_isError(BIT_initDStream(@seqState.DStream, ip, iend-ip))<>0) then
            exit(ERROR(corruption_detected));
        ZSTD_initFseState(@seqState.stateLL, @seqState.DStream, dctx^.LLTptr);
        ZSTD_initFseState(@seqState.stateOffb, @seqState.DStream, dctx^.OFTptr);
        ZSTD_initFseState(@seqState.stateML, @seqState.DStream, dctx^.MLTptr);

        { prepare in advance }
        seqNb:=0;
        while ( (BIT_reloadDStream(@seqState.DStream) <= BIT_DStream_completed) and (seqNb<seqAdvance)) do
        begin
            sequences[seqNb] := ZSTD_decodeSequence(@seqState, isLongOffset, ZSTD_p_prefetch);
            inc(seqNb);
        end;
        IF (seqNb<seqAdvance) then
          exit(ERROR(corruption_detected));

        { decode and decompress }
        while ((BIT_reloadDStream(@(seqState.DStream)) <= BIT_DStream_completed) and (seqNb<nbSeq) ) do
        begin
            sequence := ZSTD_decodeSequence(@seqState, isLongOffset, ZSTD_p_prefetch);
            oneSeqSize := ZSTD_execSequence(op, oend, sequences[(seqNb-ADVANCED_SEQS) and STORED_SEQS_MASK], @litPtr, litEnd, prefixStart, dictStart, dictEnd);
            if (ZSTD_isError(oneSeqSize)<>0) then
              exit(oneSeqSize);
            
            sequences[seqNb and STORED_SEQS_MASK] := sequence;
            op :=op + oneSeqSize;
            inc(seqNb);
        end;
        IF (seqNb<nbSeq) then 
          exit(ERROR(corruption_detected));

        { finish queue }
        seqNb :=seqNb - seqAdvance;
        while ( seqNb<nbSeq ) do
        begin
            oneSeqSize := ZSTD_execSequence(op, oend, sequences[seqNb and STORED_SEQS_MASK], @litPtr, litEnd, prefixStart, dictStart, dictEnd);
            if (ZSTD_isError(oneSeqSize)<>0) then
              exit(oneSeqSize);
            op :=op + oneSeqSize;
            inc(seqNb);
        end;

        { save reps for next block }
        for i:=0 to ZSTD_REP_NUM-1 do 
          dctx^.entropy.rep[i] := Uint32(seqState.prevOffset[i]);
    end;

    { last literal segment }
    lastLLSize := litEnd - litPtr;
    IF (lastLLSize > int32(oend-op)) then
      exit(ERROR(dstint32ooSmall));
    if (op <> nil) then
    begin
        move( litPtr^, op^,lastLLSize);
        op :=op + lastLLSize;
    end;
    

    result := op-ostart;
end;
function ZSTD_decompressSequencesLong_default(dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
begin
    result := ZSTD_decompressSequencesLong_body(dctx, dst, maxDstSize, seqStart, seqSize, nbSeq, isLongOffset, frame);
end;
function ZSTD_decompressSequences_default(dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
begin
    result := ZSTD_decompressSequences_body(dctx, dst, maxDstSize, seqStart, seqSize, nbSeq, isLongOffset, frame);
end;

function ZSTD_decompressSequencesLong_bmi2(dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
begin
    result := ZSTD_decompressSequencesLong_body(dctx, dst, maxDstSize, seqStart, seqSize, nbSeq, isLongOffset, frame);
end;

{ ZSTD_decompressSequencesLong() :
 * decompression function triggered when a minimum share of offsets is considered 'long',
 * aka out of cache.
 * note : 'long' definition seems overloaded here, sometimes meaning 'wider than bitstream register', and sometimes meaning 'farther than memory cache distance'.
 * This function will try to mitigate main memory latency through the use of prefetching }
function ZSTD_decompressSequencesLong(dctx:pZSTD_DCtx;dst:pbyte;maxDstSize:int32;
  seqStart:pbyte;seqSize,nbSeq:int32;isLongOffset:ZSTD_longOffset_e;frame:int32):int32;
begin
    //log(3,  'ZSTD_decompressSequencesLong');

    if (dctx^.bmi2<>0) then
    begin
        exit(ZSTD_decompressSequencesLong_bmi2(dctx, dst, maxDstSize, seqStart, seqSize, nbSeq, isLongOffset, frame));
    end;

  result := ZSTD_decompressSequencesLong_default(dctx, dst, maxDstSize, seqStart, seqSize, nbSeq, isLongOffset, frame);
end;




{ ZSTD_getLongOffsetsShare() :
 * condition : offTable must be valid
 * @return : 'share' of long offsets (arbitrarily defined as > (1 shl 23))
 *           compared to maximum possible of (1 shl OffFSELog) }
function ZSTD_getLongOffsetsShare(const offTable:pZSTD_seqSymbol):uint32;
var
  ptr:pbyte;
  tableLog,max,u,total:Uint32;
  table:pZSTD_seqSymbol;
begin
    ptr := pbyte(offTable);
    tableLog := pZSTD_seqSymbol_header(ptr)[0].tableLog;
    table := offTable + 1;
    max := 1  shl  tableLog;
    total := 0;
    //log(3,  'ZSTD_getLongOffsetsShare: (tableLog:=%u)', tableLog);

    assert(max <= (1  shl  OffFSELog));  { max not too large }
    for u:=0 to max-1 do
    begin
      if (table[u].nbAdditionalBits > 22) then
        total :=total + 1;
    end;

    assert(tableLog <= OffFSELog);
    total :=total  shl (OffFSELog - tableLog);  { scale to OffFSELog }

    result := total;
end;


function ZSTD_decompressBlock_internal(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  const src:pbyte;srcSize:int32; frame:int32):int32;
var
  ip:pbyte;
  isLongOffset:ZSTD_longOffset_e;
  litCSize:int32;
  nbSeq,seqHSize:int32;
begin   { blockType = blockCompressed }
    ip := src;
    { isLongOffset must be true if there are long offsets.
     * Offsets are long if they are larger than 2^STREAM_ACCUMULATOR_MIN.
     * We don't expect that to be the case in 64-bit mode.
     * In block mode, window size is not known, so we have to be conservative.
     * (note: but it could be evaluated from current-lowLimit)
     }
    litCSize:=0;
    {$IFDEF CPU32}
    litCSize:=1;
    {$ENDIF}
    isLongOffset := ZSTD_longOffset_e((litCSize=1) and ((frame=0)  or  (dctx^.fParams.windowSize > (Uint32(1)  shl  STREAM_ACCUMULATOR_MIN))));
    //log(3,  'ZSTD_decompressBlock_internal (size : %u)', srcSize);

    IF (srcSize >= ZSTD_BLOCKSIZE_MAX) then 
      exit(ERROR(srcSize_wrong));

    { Decode literals section }
     
    litCSize := ZSTD_decodeLiteralsBlock(dctx, src, srcSize);
    //log(3,  'ZSTD_decodeLiteralsBlock : %u', litCSize);
    if (ZSTD_isError(litCSize)<>0) then
      exit(litCSize);
    ip :=ip + litCSize;
    srcSize :=srcSize - litCSize;
    

    { Build Decoding Tables }

    { These macros control at build-time which decompressor implementation
     * we use. If neither is defined, we do some inspection and dispatch at
     * runtime.
     }

    seqHSize := ZSTD_decodeSeqHeaders(dctx,  @nbSeq, ip, srcSize);
    if (ZSTD_isError(seqHSize)<>0) then
      exit(seqHSize);
    ip :=ip + seqHSize;
    srcSize :=srcSize - seqHSize;
    IF(dst = nil) and (nbSeq > 0) then 
      exit(ERROR(dstint32ooSmall));// 'nil not handled');
    dctx^.ddictIsCold := 0;
    result := ZSTD_decompressSequencesLong(dctx, dst, dstCapacity, ip, srcSize, nbSeq, isLongOffset, frame);
end;


procedure ZSTD_checkContinuity(dctx:pZSTD_DCtx;dst:pbyte);
begin
    if (dst <> dctx^.previousDstEnd) then
    begin   { not contiguous }
        dctx^.dictEnd := dctx^.previousDstEnd;
        dctx^.virtualStart := dst - ((dctx^.previousDstEnd) -(dctx^.prefixStart));
        dctx^.prefixStart := dst;
        dctx^.previousDstEnd := dst;
    end;
end;


function ZSTD_decompressBlock(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  const src:pbyte;srcSize:int32):int32;
var
  dSize:int32;
begin
    ZSTD_checkContinuity(dctx, dst);
    dSize := ZSTD_decompressBlock_internal(dctx, dst, dstCapacity, src, srcSize, { frame } 0);
    dctx^.previousDstEnd := dst + dSize;
    result := dSize;
end;
end.
