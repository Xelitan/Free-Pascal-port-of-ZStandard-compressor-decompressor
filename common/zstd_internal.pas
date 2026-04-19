unit zstd_internal;
{$mode objfpc}{$H+}
interface
uses xxhash,sysutils,math,                { XXH_reset, update, digest }
      huf,fse,zstd,error_private;

{-*************************************
*  Common constants
**************************************}
const ZSTD_OPT_NUM = (1 shl 12);

  ZSTD_REP_NUM   =   3;                 { number of repcodes }
  ZSTD_REP_MOVE  =   (ZSTD_REP_NUM-1);
  repStartValue:array [0..ZSTD_REP_NUM-1] of Uint32 = (1, 4, 8);

  KB = 1024;//(1  shl 10)
  MB = 1048576;//(1  shl 20)
  GB = 1073741824;//(1U shl 30)

  BIT7 =128;
  BIT6 = 64;
  BIT5 = 32;
  BIT4 = 16;
  BIT1 =  2;
  BIT0 =  1;

  ZSTD_WINDOWLOG_ABSOLUTEMIN = 10;
  ZSTD_fcs_fieldSize:array [0..3] of int32 = (0, 2, 4, 8);
  ZSTD_did_fieldSize:array [0..3] of int32 = (0, 1, 2, 4);

  ZSTD_FRAMEIDSIZE =4;   { magic number size }

  ZSTD_BLOCKHEADERSIZE =3;   { C standard doesn't allow `static const` variable to be init using another `static const` variable }
  ZSTD_FRAMECHECKSUMSIZE =4;

  MIN_SEQUENCES_SIZE =1; { nbSeq==0 }
  MIN_CBLOCK_SIZE =(1 {litCSize} + 1 { RLE or RAW } + MIN_SEQUENCES_SIZE { nbSeq==0 });   { for a non-null block }

  HufLog =12;
  LONGNBSEQ =$7F00;
  MINMATCH  =3;
  Litbits   =8;
  MaxLit    =((1 shl Litbits) - 1);
  MaxML     =52;
  MaxLL     =35;
  DefaultMaxOff =28;
  MaxOff  =31;
  MaxSeq  = MaxML ;//MAX(MaxLL, MaxML);   { Assumption : MaxOff < MaxLL,MaxML }
  MLFSELog    =9;
  LLFSELog    =9;
  OffFSELog   =8;
  MaxFSELog   =9; //MAX(MAX(MLFSELog, LLFSELog), OffFSELog);

  ZSTD_MAX_HUF_HEADER_SIZE = 128; { header + <= 127 byte tree description }
{ Each table cannot take more than #symbols * FSELog bits }
  ZSTD_MAX_FSE_HEADERS_SIZE =(((MaxML + 1) * MLFSELog + (MaxLL + 1) * LLFSELog + (MaxOff + 1) * OffFSELog + 7) / 8);

  LL_bits:array[0..MaxLL]of Uint32 = (
     0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,
     1, 1, 1, 1, 2, 2, 3, 3,
     4, 6, 7, 8, 9,10,11,12,
     13,14,15,16
     );
  LL_defaultNorm:array [0..MaxLL] of int16 = (
     4, 3, 2, 2, 2, 2, 2, 2,
     2, 2, 2, 2, 2, 1, 1, 1,
     2, 2, 2, 2, 2, 2, 2, 2,
     2, 3, 2, 1, 1, 1, 1, 1,
    -1,-1,-1,-1
  );
  LL_DEFAULTNORMLOG = 6;  { for static allocation }

  ML_bits:array [0..MaxML] of Uint32 = (
     0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,
     1, 1, 1, 1, 2, 2, 3, 3,
     4, 4, 5, 7, 8, 9,10,11,
    12,13,14,15,16
  );
  ML_defaultNorm:array [0..MaxML] of int16 = (
     1, 4, 3, 2, 2, 2, 2, 2,
     2, 1, 1, 1, 1, 1, 1, 1,
     1, 1, 1, 1, 1, 1, 1, 1,
     1, 1, 1, 1, 1, 1, 1, 1,
     1, 1, 1, 1, 1, 1, 1, 1,
     1, 1, 1, 1, 1, 1,-1,-1,
    -1,-1,-1,-1,-1
  );
  ML_DEFAULTNORMLOG = 6;  { for static allocation }

  OF_defaultNorm:array [0..DefaultMaxOff] of int16 = (
     1, 1, 1, 1, 1, 1, 2, 2,
     2, 1, 1, 1, 1, 1, 1, 1,
     1, 1, 1, 1, 1, 1, 1, 1,
    -1,-1,-1,-1,-1
  );
  OF_DEFAULTNORMLOG = 5;  { for static allocation }

  WILDCOPY_OVERLENGTH =32;
  WILDCOPY_VECLEN     =16;
{ define 'workspace is too large' as this number of times larger than needed }
  ZSTD_WORKSPACETOOLARGE_FACTOR =3;
  { when workspace is continuously too large
   * during at least this number of times,
   * context's memory usage is considered wasteful,
   * because it's sized to handle a worst case scenario which rarely happens.
   * In which case, resize it down to free some memory }
  ZSTD_WORKSPACETOOLARGE_MAXDURATION =128;
type
  blockType_e =(bt_raw, bt_rle, bt_compressed, bt_reserved);
  symbolEncodingType_e = (set_basic, set_rle, set_compressed, set_repeat);
  ZSTD_overlap_e = (
    ZSTD_no_overlap,
    ZSTD_overlap_src_before_dst
    {  ZSTD_overlap_dst_before_src, }
  );
  
{ Controls whether the input/output buffer is buffered or stable. }
  ZSTD_bufferMode_e=(
    ZSTD_bm_buffered = 0,  { Buffer the input/output }
    ZSTD_bm_stable = 1     { ZSTD_inBuffer/ZSTD_outBuffer is stable }
  );


  pseqDef=^seqDef;
  pseqStore_t=^seqStore_t;
  pZSTD_sequenceLength=^ZSTD_sequenceLength;
  pZSTD_frameSizeInfo=^ZSTD_frameSizeInfo;
  pblockProperties_t=^blockProperties_t;

  seqDef=record
    offset:Uint32;         { Offset code of the sequence }
    litLength  :uint16;
    matchLength:uint16;
  end;
  
  seqStore_t=record
    sequencesStart:pseqDef;
         sequences:pseqDef;      { ptr to end of sequences }
    litStart:pbyte;
         lit:pbyte;              { ptr to end of literals }
      llCode:pbyte;
      mlCode:pbyte;
      ofCode:pbyte;
    maxNbSeq:int32;
    maxNbLit:int32;

    { longLengthPos and longLengthID to allow us to represent either a single litLength or matchLength
     * in the seqStore that has a value larger than U16 (if it exists). To do so, we increment
     * the existing value of the litLength or matchLength by $10000. 
     }
     longLengthID:Uint32;   { 0 == no longLength; 1 == Represent the long literal; 2 == Represent the long match; }
    longLengthPos:Uint32;  { Index of the sequence to apply long length modification to }
  end;

  ZSTD_sequenceLength=record
    litLength:Uint32;
    matchLength:Uint32;
  end;
  {*
   * Contains the compressed frame size and an upper-bound for the decompressed frame size.
   * Note: before using `compressedSize`, check for errors using ZSTD_isError().
   *       similarly, before using `decompressedBound`, check for errors using:
   *          `decompressedBound != ZSTD_CONTENTSIZE_ERROR`
   }
  ZSTD_frameSizeInfo=record
      compressedSize:int32;
      decompressedBound:Uint64;
  end;   { decompress  and  legacy }

  blockProperties_t=record
      blockType:blockType_e;
      lastBlock:Uint32;
       origSize:Uint32;
  end;   { declared here for decompress and fullbench }
{
  #define CHECK_V_F(e, f) size_t const e = f; if (ERR_isError(e)) return e
  #define CHECK_F(f)   { CHECK_V_F(_var_err__, f); }
}
procedure DEBUGLOG(cond:integer;params:array of string);
function ZSTD_highbit32(val:Uint32):Uint32;
function ZSTD_limitCopy(dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
function ZSTD_getSequenceLength(seqStore:pseqStore_t; seq:pseqDef):ZSTD_sequenceLength;
procedure ZSTD_wildcopy(dst, src:pbyte; llength:uint32; ovtype:ZSTD_overlap_e);
procedure ZSTD_copy8(dst, src:pbyte);
procedure ZSTD_copy16(dst, src:pbyte);
implementation

procedure DEBUGLOG(cond:integer;params:array of string);
var
  i:integer;
begin
  exit; //no debug

  write(stderr, Format('DEBUG!: check %d failed', [cond]));
    
  for i := 0 to High(params) do
  begin
    write(stderr, ': ',params[i]);
  end;
    
  write(stderr, '\n');
end;

{-*******************************************
*  Shared functions to include for inlining
********************************************}
procedure ZSTD_copy8(dst, src:pbyte);
begin
  move(src[0],dst[0], 8);
end;

procedure ZSTD_copy16(dst, src:pbyte);
begin
  move(src[0],dst[0], 16);
end;

{! ZSTD_wildcopy() :
 *  Custom version of ZSTD_memcpy(), can over read/write up to WILDCOPY_OVERLENGTH bytes (if length==0)
 *  @param ovtype controls the overlap detection
 *         - ZSTD_no_overlap: The source and destination are guaranteed to be at least WILDCOPY_VECLEN bytes apart.
 *         - ZSTD_overlap_src_before_dst: The src and dst may overlap, but they MUST be at least 8 bytes apart.
 *           The src buffer must be before the dst buffer.
 }

procedure ZSTD_wildcopy(dst, src:pbyte; llength:uint32; ovtype:ZSTD_overlap_e);
var
  diff:uint32;
  ip,op,oend:pbyte;
begin
  diff := dst - src;
  ip := src;
  op := dst;
  oend := op + llength;

  if (ovtype = ZSTD_overlap_src_before_dst)  and  (diff < WILDCOPY_VECLEN) then
  begin
    { Handle short offset copies. }
    repeat
      ZSTD_copy8(op, ip);
      inc(op, 8);
      inc(ip, 8);
    until (op >= oend);
  end 
  else 
  begin
    repeat
      ZSTD_copy16(op, ip);
      inc(op, 16);
      inc(ip, 16);
    until (op >= oend);
  end;
end;

function ZSTD_limitCopy(dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
var
  llength:int32;
begin
    llength := MIN(dstCapacity, srcSize);
    if (llength > 0) then
    begin
      move(src^,dst^,  llength);
    end;
    result := llength;
end;

{*
 * Returns the ZSTD_sequenceLength for the given sequences. It handles the decoding of long sequences
 * indicated by longLengthPos and longLengthID, and adds MINMATCH back to matchLength.
 }
function ZSTD_getSequenceLength(seqStore:pseqStore_t; seq:pseqDef):ZSTD_sequenceLength;
var
  seqLen:ZSTD_sequenceLength;
begin
    seqLen.litLength   := seq^.litLength;
    seqLen.matchLength := seq^.matchLength + MINMATCH;
    if (seqStore^.longLengthPos = Uint32(seq - seqStore^.sequencesStart)) then
    begin
        if (seqStore^.longLengthID = 1) then
        begin
            seqLen.litLength :=seqLen.litLength + $FFFF;
        end;
        if (seqStore^.longLengthID = 2) then
        begin
            seqLen.matchLength :=seqLen.matchLength + $FFFF;
        end;
    end;
    result := seqLen;
end;



//const seqStore_t* ZSTD_getSeqStore(const ZSTD_CCtx* ctx);   { compress  and  dictBuilder }
//void ZSTD_seqToCodes(const seqStore_t* seqStorePtr);   { compress, dictBuilder, decodeCorpus (shouldn't get its definition from here) }
//
//{ custom memory allocation functions }
//void* ZSTD_customMalloc(int32 size, ZSTD_customMem customMem);
//void* ZSTD_customCalloc(int32 size, ZSTD_customMem customMem);
//void ZSTD_customfree(void* ptr, ZSTD_customMem customMem);


function ZSTD_highbit32(val:Uint32):Uint32;   { compress, dictBuilder, decodeCorpus }
  const DeBruijnClz:array[0..31] of Uint32 = ( 0, 9, 1, 10, 13, 21, 2, 29, 11, 14, 16, 18, 22, 25, 3, 30, 8, 12, 20, 28, 15, 17, 24, 7, 19, 27, 23, 6, 26, 5, 4, 31 );
var
  v:Uint32;
begin
  { Software version } 
  v := val;
  v :=v or v  shr  1;
  v :=v or v  shr  2;
  v :=v or v  shr  4;
  v :=v or v  shr  8;
  v :=v or v  shr  16;
  result := DeBruijnClz[(v * Uint32($07C4ACDD))  shr  27];
end;


{ ZSTD_invalidateRepCodes() :
 * ensures next compression will not use repcodes from previous block.
 * Note : only works with regular variant;
 *        do not use with extDict variant ! }
//void ZSTD_invalidateRepCodes(ZSTD_CCtx* cctx);   { zstdmt, adaptive_compression (shouldn't get this definition from here) }


{! ZSTD_getcBlockSize() :
 *  Provides the size of compressed block from block header `src` }
{ Used by: decompress, fullbench (does not get its definition from here) }
//int32 ZSTD_getcBlockSize(const void* src, int32 srcSize,blockProperties_t* bpPtr);

{! ZSTD_decodeSeqHeaders() :
 *  decode sequence header from src }
{ Used by: decompress, fullbench (does not get its definition from here) }
//int32 ZSTD_decodeSeqHeaders(ZSTD_DCtx* dctx, int* nbSeqPtr,const void* src, int32 srcSize);
end.
