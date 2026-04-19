unit ZSTD_COMPRESS_internal;
{$mode objfpc}{$H+}
interface
uses zstd,zstd_internal,ZSTD_CWKSPF,huf,fse,xxHash,zstd_common,error_private;

{-*************************************
*  Constants
**************************************}
const
  kSearchStrength         =8;
  HASH_READ_SIZE          =8;
  ZSTD_DUBT_UNSORTED_MARK =1;   { For btlazy2 strategy, index ZSTD_DUBT_UNSORTED_MARK=1 means 'unsorted'.
                                       It could be confused for a real successor at index '1', if sorted as larger than its predecessor.
                                       It's not a big deal though : candidate will just be sorted again.
                                       Additionally, candidate position 1 will be lost.
                                       But candidate 1 cannot hide a large tree of candidates, so it's a minimal loss.
                                       The benefit is that ZSTD_DUBT_UNSORTED_MARK cannot be mishandled after table re-use with a different strategy.
                                       This constant is required by ZSTD_compressBlock_btlazy2() and ZSTD_reduceTable_internal() }

  prime3bytes :Uint32 = Uint32(506832829);
  prime4bytes :Uint32 = Uint32(2654435761);
  prime5bytes :Uint64 = Uint64(889523592379);
  prime6bytes :Uint64 = Uint64(227718039650203);
  prime7bytes :Uint64 = Uint64(58295818150454627);
  prime8bytes :Uint64 = Uint64($CF1BBCDCB7A56463);
  ZSTD_ROLL_HASH_CHAR_OFFSET =10;
  
  COMPRESS_SEQUENCES_WORKSPACE_SIZE = (4 * (MaxSeq + 2));
  ENTROPY_WORKSPACE_SIZE = (HUF_WORKSPACE_SIZE + COMPRESS_SEQUENCES_WORKSPACE_SIZE);
  {-*************************************
  *  Round buffer management
  **************************************}
  { Max current allowed }
  ZSTD_CURRENT_MAX = ((3  shl  29) + (Uint32(1)  shl  ZSTD_WINDOWLOG_MAX));
  { Maximum chunk size before overflow correction needs to be called again }
  ZSTD_CHUNKSIZE_MAX =
      ( (-1)                  { Maximum ending current index }
      - ZSTD_CURRENT_MAX) ;         { Maximum beginning lowLimit }

type
{-*************************************
*  Context memory management
**************************************}
ZSTD_sequencePosition=record
    idx:Uint32;             { Index in array of ZSTD_Sequence }
    posInSequence:Uint32;   { Position within sequence at idx }
    posInSrc:int32;        { Number of bytes given by sequences provided so far }
end;
ZSTD_compressionStage_e= ( ZSTDcs_created:=0, ZSTDcs_init, ZSTDcs_ongoing, ZSTDcs_ending);
ZSTD_cStreamStage= (zcss_init:=0, zcss_load, zcss_flush);
pZSTD_prefixDict=^ZSTD_prefixDict;
pZSTD_localDict=^ZSTD_localDict;
pZSTD_hufCTables_t=^ZSTD_hufCTables_t;
pZSTD_fseCTables_t=^ZSTD_fseCTables_t;
pZSTD_entropyCTables_t=^ZSTD_entropyCTables_t;
pZSTD_match_t=^ZSTD_match_t;
prawSeq=^rawSeq;
prawSeqStore_t=^rawSeqStore_t;
pZSTD_optimal_t=^ZSTD_optimal_t;
poptState_t=^optState_t;
pZSTD_compressedBlockState_t=^ZSTD_compressedBlockState_t;
pZSTD_window_t=^ZSTD_window_t;
ppZSTD_matchState_t=^pZSTD_matchState_t;
pZSTD_matchState_t=^ZSTD_matchState_t;
pZSTD_blockState_t=^ZSTD_blockState_t;
pldmEntry_t=^ldmEntry_t;
pldmState_t=^ldmState_t;
pldmParams_t=^ldmParams_t;
pSeqCollector=^SeqCollector;
pZSTD_CCtx_params=^ZSTD_CCtx_params;

ZSTD_prefixDict=record
    dict:pbyte;
    dictSize:int32;
    dictContentType:ZSTD_dictContentType_e;
end;

ZSTD_hufCTables_t=record
    CTable:array[0..25] of HUF_CElt;
    repeatMode:HUF_repeat;
end;

ZSTD_fseCTables_t=record
    offcodeCTable:array [0..(1 + (1 shl ((OffFSELog)-1)) + (((MaxOff)+1)*2)) -1]   of FSE_CTable;
    matchlengthCTable:array [0..(1 + (1 shl ((MLFSELog)-1)) + (((MaxML)+1)*2))-1] of FSE_CTable;
    litlengthCTable:array [0..(1 + (1 shl ((LLFSELog)-1)) + (((MaxLL)+1)*2))-1]   of FSE_CTable;
    offcode_repeatMode:    FSE_repeat;
    matchlength_repeatMode:FSE_repeat;
    litlength_repeatMode:  FSE_repeat;
end;

ZSTD_entropyCTables_t=record
    huf:ZSTD_hufCTables_t;
    fse:ZSTD_fseCTables_t;
end;

ZSTD_match_t=record
    off:UINT32;            { Offset code (offset + ZSTD_REP_MOVE) for the match }
    len:UINT32;            { Raw length of match }
end;

rawSeq=record
    offset:Uint32;         { Offset of sequence }
    litLength:Uint32 ;      { Length of literals prior to match }
    matchLength:Uint32;    { Raw length of match }
end;

rawSeqStore_t=record
  seq:prawSeq;          { The start of the sequences }
  pos:int32;           { The index in seq where reading stopped. pos <= size. }
  posInSequence:int32; { The position within the sequence at seq[pos] where reading
                           stopped. posInSequence <= seq[pos].litLength + seq[pos].matchLength }
  size:int32;          { The number of sequences. <= capacity. }
  capacity:int32;      { The capacity starting from `seq` pointer }
end;

TREPO=array [0..ZSTD_REP_NUM-1] of Uint32;
ZSTD_optimal_t=record
    price:int32;
    off:Uint32;
    mlen:Uint32;
    litlen:Uint32;
    rep:TREPO;
end;

ZSTD_OptPrice_e = (zop_dynamic:=0, zop_predef);

optState_t=record
    { All tables are allocated inside cctx^.workspace by ZSTD_resetCCtx_internal() }
    litFreq:puint32;           { table of literals statistics, of size 256 }
    litLengthFreq:puint32;     { table of litLength statistics, of size (MaxLL+1) }
    matchLengthFreq:puint32;   { table of matchLength statistics, of size (MaxML+1) }
    offCodeFreq:puint32;       { table of offCode statistics, of size (MaxOff+1) }
    matchTable:pZSTD_match_t;    { list of found matches, of size ZSTD_OPT_NUM+1 }
    priceTable:pZSTD_optimal_t;  { All positions tracked by optimal parser, of size ZSTD_OPT_NUM+1 }

    litSum:Uint32;                 { nb of literals }
    litLengthSum:Uint32;           { nb of litLength codes }
    matchLengthSum:Uint32;         { nb of matchLength codes }
    offCodeSum:Uint32;             { nb of offset codes }
    litSumBasePrice:Uint32;        { to compare to log2(litfreq) }
    litLengthSumBasePrice:Uint32;  { to compare to log2(llfreq)  }
    matchLengthSumBasePrice:Uint32;{ to compare to log2(mlfreq)  }
    offCodeSumBasePrice:Uint32;    { to compare to log2(offreq)  }
    priceType:ZSTD_OptPrice_e;   { prices can be determined dynamically, or follow a pre-defined cost structure }
    symbolCosts:pZSTD_entropyCTables_t;  { pre-calculated dictionary statistics }
    literalCompressionMode:ZSTD_literalCompressionMode_e;
end;

ZSTD_compressedBlockState_t=record
  entropy:ZSTD_entropyCTables_t;
  rep:TREPO;
end;

ZSTD_window_t=record
    nextSrc:pbyte;    { next block here to continue on current prefix }
    base:pbyte;       { All regular indexes relative to this position }
    dictBase:pbyte;   { extDict indexes relative to this position }
    dictLimit:Uint32;          { below that point, need extDict }
    lowLimit:Uint32;           { below that point, no more valid data }
end;
ZSTD_matchState_t=record
    window:ZSTD_window_t;   { State for window round buffer management }
    loadedDictEnd:Uint32;      { index of end of dictionary, within context's referential.
                             * When loadedDictEnd <> 0, a dictionary is in use, and still valid.
                             * This relies on a mechanism to set loadedDictEnd:=0 when dictionary is no longer within distance.
                             * Such mechanism is provided within ZSTD_window_enforceMaxDist() and ZSTD_checkDictValidity().
                             * When dict referential is copied into active context (i.e. not attached),
                             * loadedDictEnd = dictSize, since referential starts from zero.
                             }
    nextToUpdate:Uint32;       { index from which to continue table update }
    hashLog3:Uint32;           { dispatch table for matches of len=3 : larger = faster, more memory }
    hashTable:pUint32;
    hashTable3:pUint32;
    chainTable:pUint32;
    dedicatedDictSearch:int32;  { Indicates whether this matchState is using the
                               * dedicated dictionary search structure.
                               }
    opt:optState_t ;         { optimal parser state }
    dictMatchState:pZSTD_matchState_t;
    cParams:ZSTD_compressionParameters;
    ldmSeqStore:prawSeqStore_t;
end;

ZSTD_blockState_t=record
    prevCBlock:pZSTD_compressedBlockState_t;
    nextCBlock:pZSTD_compressedBlockState_t;
    matchState:ZSTD_matchState_t;
end;

pZSTD_CDict_s=^ZSTD_CDict_s;
pZSTD_sequencePosition=^ZSTD_sequencePosition;
ZSTD_CDict_s=record
    dictContent:pbyte;
    dictContentSize:int32;
    dictContentType:ZSTD_dictContentType_e; { The dictContentType the CDict was created with }
    entropyWorkspace:pUint32; { entropy workspace of HUF_WORKSPACE_SIZE bytes }
    workspace:ZSTD_cwksp ;
    matchState:ZSTD_matchState_t ;
    cBlockState:ZSTD_compressedBlockState_t ;
    customMem:ZSTD_customMem ;
    dictID:Uint32 ;
    compressionLevel:int32 ; { 0 indicates that advanced API was used to select CDict params }
end;  { typedef'd to ZSTD_CDict within 'zstd.h' }
pZSTD_CDict=^ZSTD_CDict;
ZSTD_CDict=ZSTD_CDict_s;
ZSTD_localDict=record
    dictBuffer:pbyte;
    dict:pbyte;
    dictSize:int32;
    dictContentType:ZSTD_dictContentType_e;
    cdict:pZSTD_CDict;
end;
ldmEntry_t=record
    offset:Uint32;
    checksum:Uint32;
end;

ldmState_t=record
    window:ZSTD_window_t;   { State for the window round buffer management }
    hashTable:pldmEntry_t;
    loadedDictEnd:Uint32;
    bucketOffsets:pBYTE;    { Next position in bucket to insert entry }
    hashPower:Uint64;          { Used to compute the rolling hash.
                             * Depends on ldmParams.minMatchLength }
end;

ldmParams_t=record
    enableLdm:Uint32;          { 1 if enable long distance matching }
    hashLog:Uint32;            { Log size of hashTable }
    bucketSizeLog:Uint32;      { Log bucket size for collision resolution, at most 8 }
    minMatchLength:Uint32;     { Minimum match length }
    hashRateLog:Uint32;       { Log number of entries to skip }
    windowLog:Uint32;          { Window log for the LDM }
end;

SeqCollector=record
    collectSequences:int32;
    seqStart:pZSTD_Sequence;
    seqIndex:int32;
    maxSequences:int32;
end;

ZSTD_CCtx_params=record
    format:ZSTD_format_e;
    cParams:ZSTD_compressionParameters;
    fParams:ZSTD_frameParameters;

    compressionLevel:int32;
    forceWindow:int32;           { force back-references to respect limit of
                                * 1 shl wLog, even for dictionary }
    targetCBlockSize:int32;   { Tries to fit compressed block size to be around targetCBlockSize.
                                * No target when targetCBlockSize = 0.
                                * There is no guarantee on compressed block size }
    srcSizeHint:int32;           { User's best guess of source size.
                                * Hint is not valid when srcSizeHint = 0.
                                * There is no guarantee that hint is close to actual source size }

    attachDictPref:ZSTD_dictAttachPref_e;
    literalCompressionMode:ZSTD_literalCompressionMode_e;

    { Multithreading: used to pass parameters to mtctx }
    nbWorkers:int32;
    jobSize:int32;
    overlapLog:int32;
    rsyncable:int32;

    { Long distance matching parameters }
    ldmParams:ldmParams_t;

    { Dedicated dict search algorithm trigger }
    enableDedicatedDictSearch:int32;

    { Input/output buffer modes }
    inBufferMode:ZSTD_bufferMode_e;
    outBufferMode:ZSTD_bufferMode_e;

    { Sequence compression API }
    blockDelimiters:ZSTD_sequenceFormat_e;
    validateSequences:int32;

    { Internal use, for createCCtxParams() and freeCCtxParams() only }
    customMem:ZSTD_customMem;
end;  { typedef'd to ZSTD_CCtx_params within 'zstd.h' }



{*
 * Indicates whether this compression proceeds directly from user-provided
 * source buffer to user-provided destination buffer (ZSTDb_not_buffered), or
 * whether the context needs to buffer the input/output (ZSTDb_buffered).
 }
ZSTD_buffered_policy_e = (
    ZSTDb_not_buffered,
    ZSTDb_buffered
);


pZSTD_CCtx=^ZSTD_CCtx;
pZSTD_CStream=pZSTD_CCtx;
ZSTD_CCtx=record
    stage:ZSTD_compressionStage_e;
    cParamsChanged:int32;                  { = 1 if cParams(except wlog) or compression level are changed in requestedParams. Triggers transmission of new params to ZSTDMT (if available) then reset to 0. }
    bmi2:int32;                            { = 1 if the CPU supports BMI2 and 0 otherwise. CPU support is determined dynamically once per context lifetime. }
    requestedParams:ZSTD_CCtx_params;
    appliedParams:ZSTD_CCtx_params;
    dictID:Uint32;

    workspace:ZSTD_cwksp; { manages buffer for dynamic allocations }
    blockSize:int32;
    pledgedSrcSizePlusOne:uint64;  { this way, 0 (default) = unknown }
    consumedSrcSize:uint64;
    producedCSize:uint64;
    xxhState:XXH64_state_t;
    customMem:ZSTD_customMem;
    //pool:pZSTD_threadPool;
    staticSize:int32;
    lseqCollector:SeqCollector;
    isFirstBlock:int32;
    initialized:int32;

    seqStore:seqStore_t;      { sequences storage ptrs }
    ldmState:ldmState_t;      { long distance matching state }
    ldmSequences:prawSeq;     { Storage for the ldm output sequences }
    maxNbLdmSequences:int32;
    externSeqStore:rawSeqStore_t; { Mutable reference to external sequences }
    blockState:ZSTD_blockState_t;
    entropyWorkspace:pUint32;  { entropy workspace of ENTROPY_WORKSPACE_SIZE bytes }

    { Wether we are streaming or not }
    bufferedPolicy:ZSTD_buffered_policy_e;

    { streaming }
    inBuff:pbyte;
    inBuffSize:int32;
    inToCompress:int32;
    inBuffPos:int32;
    inBuffTarget:int32;
    outBuff:pbyte;
    outBuffSize:int32;
    outBuffContentSize:int32;
    outBuffFlushedSize:int32;
    streamStage:ZSTD_cStreamStage;
    frameEnded:uint32;

    { Stable in/out buffer verification }
    expectedInBuffer:ZSTD_inBuffer;
    expectedOutBufferSize:int32;

    { Dictionary }
    localDict:ZSTD_localDict;
    cdict:pZSTD_CDict;
    prefixDict:ZSTD_prefixDict;   { single-usage dictionary }

    { Multi-threading }
    //mtctx:pZSTDMT_CCtx;
end;

ZSTD_dictTableLoadMethod_e= ( ZSTD_dtlm_fast, ZSTD_dtlm_full );

ZSTD_dictMode_e = (
    ZSTD_noDict = 0,
    ZSTD_extDict = 1,
    ZSTD_dictMatchState = 2,
    ZSTD_dedicatedDictSearch = 3
);

ZSTD_cParamMode_e = (
    ZSTD_cpm_noAttachDict = 0,  { Compression with ZSTD_noDict or ZSTD_extDict.
                                 * In this mode we use both the srcSize and the dictSize
                                 * when selecting and adjusting parameters.
                                 }
    ZSTD_cpm_attachDict = 1,    { Compression with ZSTD_dictMatchState or ZSTD_dedicatedDictSearch.
                                 * In this mode we only take the srcSize into account when selecting
                                 * and adjusting parameters.
                                 }
    ZSTD_cpm_createCDict = 2,   { Creating a CDict.
                                 * In this mode we take both the source size and the dictionary size
                                 * into account when selecting and adjusting the parameters.
                                 }
    ZSTD_cpm_unknown = 3       { ZSTD_getCParams, ZSTD_getParams, ZSTD_adjustParams.
                                 * We don't know what these parameters are for. We default to the legacy
                                 * behavior of taking both the source size and the dict size into account
                                 * when selecting and adjusting parameters.
                                 }
);

ZSTD_blockCompressor= function(
        bs:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte; srcSize:int32):int32;
TREPO3=array [0..2] of Uint32;
repcodes_t = record
    rep:TREPO3;
end;
const knilRawSeqStore:rawSeqStore_t = (seq:nil;   pos:0; posInSequence:0; size:0; capacity:0);
//function ZSTD_selectBlockCompressor(strat:ZSTD_strategy;dictMode:ZSTD_dictMode_e):ZSTD_blockCompressor;
function ZSTD_hashPtr(p:pbyte; hBits, mls:Uint32):int32;
function ZSTD_getLowestPrefixIndex(ms:pZSTD_matchState_t; curr,windowLog:Uint32):Uint32;
function ZSTD_count(pIn, pMatch,pInLimit:pbyte):int32;
procedure ZSTD_storeSeq(seqStorePtr:pseqStore_t; litLength:int32; literals,litLimit:pbyte; offCode:Uint32; mlBase:int32);
function ZSTD_count_2segments(ip,   match, iEnd, mEnd, iStart:pbyte):int32;
function ZSTD_getLowestMatchIndex(ms:pZSTD_matchState_t;  curr, windowLog:uint32):Uint32;
function ZSTD_rollingHash_rotate(hash:Uint64;  toRemove,  toAdd:BYTE; primePower:Uint64):Uint64;
function ZSTD_rollingHash_compute(buf:pbyte; size:int32):Uint64;
function ZSTD_window_hasExtDict(window:ZSTD_window_t):Uint32;
function ZSTD_window_needOverflowCorrection(window:ZSTD_window_t;srcEnd:pbyte):Uint32;
function ZSTD_window_correctOverflow(window:pZSTD_window_t; cycleLog,maxDist:Uint32; src:pbyte):Uint32;
procedure ZSTD_window_enforceMaxDist(window:pZSTD_window_t;blockEnd:pbyte;maxDist:Uint32;
  loadedDictEndPtr:pUint32;dictMatchStatePtr:ppZSTD_matchState_t);
function ZSTD_matchState_dictMode(ms:pZSTD_matchState_t):ZSTD_dictMode_e;
function ZSTD_cParam_withinBounds(cParam:ZSTD_cParameter; value:int32):int32;
procedure ZSTD_window_clear(window:pZSTD_window_t);
procedure ZSTD_window_init(window:pZSTD_window_t);
function ZSTD_rollingHash_primePower(length:Uint32):Uint64;
function ZSTD_LLcode(litLength:Uint32 ):Uint32;
function ZSTD_MLcode(mlBase:Uint32):Uint32;
function  ZSTD_minGain(srcSize:int32; strat:ZSTD_strategy):int32;
function ZSTD_disableLiteralsCompression(cctxParams:pZSTD_CCtx_params):int32;
function ZSTD_hash3Ptr(ptr:pbyte;  h:Uint32):int32; 
function ZSTD_updateRep(rep:TREPO3; offset:Uint32; ll0:Uint32):repcodes_t;
function ZSTD_rleCompressBlock(dst:pbyte; dstCapacity:int32; src:byte; srcSize:int32; lastBlock:Uint32):int32;
function ZSTD_noCompressBlock(dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32; lastBlock:Uint32):int32;
procedure ZSTD_checkDictValidity(const window:pZSTD_window_t;
  blockEnd:pbyte;maxDist:Uint32;loadedDictEndPtr:pUint32;dictMatchStatePtr:ppZSTD_matchState_t);
function ZSTD_window_update(window:pZSTD_window_t;src:pbyte; srcSize:int32):Uint32;
function ZSTD_hash6Ptr(p:pbyte;  h:Uint32) :int32;
function ZSTD_hash8Ptr(p:pbyte;  h:Uint32) :int32;
implementation
 uses zstd_compressf;


function ZSTD_LLcode(litLength:Uint32 ):Uint32;
const
    LL_Code:array [0..63] of BYTE = (  0,  1,  2,  3,  4,  5,  6,  7,
                                       8,  9, 10, 11, 12, 13, 14, 15,
                                      16, 16, 17, 17, 18, 18, 19, 19,
                                      20, 20, 20, 20, 21, 21, 21, 21,
                                      22, 22, 22, 22, 22, 22, 22, 22,
                                      23, 23, 23, 23, 23, 23, 23, 23,
                                      24, 24, 24, 24, 24, 24, 24, 24,
                                      24, 24, 24, 24, 24, 24, 24, 24 );
    LL_deltaCode:Uint32 = 19;
begin
  if (litLength > 63) then
    result := ZSTD_highbit32(litLength) + LL_deltaCode
  else
    result := LL_Code[litLength];
end;

{ ZSTD_MLcode() :
 * note : mlBase := matchLength - MINMATCH;
 *        because it's the format it's stored in seqStore^.sequences }
function ZSTD_MLcode(mlBase:Uint32):Uint32;
const
    ML_Code:array [0..127] of BYTE = ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
                                      16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
                                      32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37,
                                      38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39,
                                      40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
                                      41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41,
                                      42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
                                      42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42);
    ML_deltaCode:Uint32 = 36;
begin
  if (mlBase > 127) then
    result := ZSTD_highbit32(mlBase) + ML_deltaCode
  else
    result := ML_Code[mlBase];
end;

function ZSTD_updateRep(rep:TREPO3; offset:Uint32; ll0:Uint32):repcodes_t;
var
  newReps:repcodes_t;
  repCode,currentOffset:Uint32;
begin
    if (offset >= ZSTD_REP_NUM) then
    begin  { full offset }
        newReps.rep[2] := rep[1];
        newReps.rep[1] := rep[0];
        newReps.rep[0] := offset - ZSTD_REP_MOVE;
    end
    else 
    begin   { repcode }
        repCode:= offset + ll0;
        if (repCode > 0) then
        begin  { note : if repCode=0, no change }
          if (repCode=ZSTD_REP_NUM) then
            currentOffset :=  (rep[0] - 1)
          else
            currentOffset :=  rep[repCode];
          if (repCode >= 2) then
            newReps.rep[2] := rep[1]
          else
            newReps.rep[2] :=  rep[2];
            newReps.rep[1] := rep[0];
            newReps.rep[0] := currentOffset;
        end
        else 
        begin   { repCode = 0 }
            move(rep[0],newReps,  sizeof(newReps));
        end;
    end;
    result := newReps;
end;

{ ZSTD_cParam_withinBounds:
 * @return 1 if value is within cParam bounds,
 * 0 otherwise }
function ZSTD_cParam_withinBounds(cParam:ZSTD_cParameter; value:int32):int32;
var
  bounds:ZSTD_bounds;
begin
  bounds := ZSTD_cParam_getBounds(cParam);
    if (ZSTD_isError(bounds.error)<>0) then exit(0);
    if (value < bounds.lowerBound)  then exit(0);
    if (value > bounds.upperBound)  then exit(0);
    result := 1;
end;

{ ZSTD_noCompressBlock() :
 * Writes uncompressed block to dst buffer from given src.
 * Returns the size of the block }
function ZSTD_noCompressBlock (dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32; lastBlock:Uint32):int32;
var
  cBlockHeader24:Uint32;
begin
  cBlockHeader24 := lastBlock + ((Uint32(bt_raw) shl 1) + Uint32(srcSize  shl  3));
  IF(srcSize + ZSTD_blockHeaderSize > dstCapacity) then
    exit(ERROR(dstint32ooSmall));// 'dst buf too small for uncompressed block');
  MEM_writeLE24(dst, cBlockHeader24);
  move(src^, (dst + ZSTD_blockHeaderSize)^, srcSize);
  result := ZSTD_blockHeaderSize + srcSize;
end;

function ZSTD_rleCompressBlock (dst:pbyte; dstCapacity:int32; src:byte; srcSize:int32; lastBlock:Uint32):int32;
var
  op:pbyte;
  cBlockHeader:Uint32;
begin
    op := dst;
    cBlockHeader := lastBlock + ((Uint32(bt_rle) shl 1) + Uint32(srcSize  shl  3));
    IF (dstCapacity < 4) then
     exit(ERROR(dstint32ooSmall));
    MEM_writeLE24(op, cBlockHeader);
    op[3] := src;
    result :=  4;
end;


{ ZSTD_minGain() :
 * minimum compression required
 * to generate a compress block or a compressed literals section.
 * note : use same formula for both situations }
function  ZSTD_minGain(srcSize:int32; strat:ZSTD_strategy):int32;
var
  minlog:Uint32;
begin
  if (strat>=ZSTD_btultra) then
    minlog :=  Uint32(strat) - 1
  else
    minlog :=  6;
  //ASSERT(ZSTD_btultra = 8);
  assert(ZSTD_cParam_withinBounds(ZSTD_c_strategy, ord(strat))<>0);
  result := (srcSize  shr  minlog) + 2;
end;

function ZSTD_disableLiteralsCompression(cctxParams:pZSTD_CCtx_params):int32;
begin
    case (cctxParams^.literalCompressionMode) of
     ZSTD_lcm_huffman: exit(0);
     ZSTD_lcm_uncompressed: exit(1);
     ZSTD_lcm_auto: exit(ord((cctxParams^.cParams.strategy = ZSTD_fast)  and  (cctxParams^.cParams.targetLength > 0)));
     else
      begin
        assert(false { impossible: pre-validated });
        exit(ord((cctxParams^.cParams.strategy = ZSTD_fast)  and  (cctxParams^.cParams.targetLength > 0)));
      end;
    end;
end;

{! ZSTD_safecopyLiterals() :
 *  memcpy() function that won't read beyond more than WILDCOPY_OVERLENGTH bytes past ilimit_w.
 *  Only called when the sequence ends past ilimit_w, so it only needs to be optimized for single
 *  large copies.
 }
procedure ZSTD_safecopyLiterals(op,ip, iend, ilimit_w:pbyte);
begin
    assert(iend > ilimit_w);
    if (ip <= ilimit_w) then
    begin
        move(ip^, op^, ilimit_w - ip);
        op := op + (ptruint(ilimit_w) - ptruint(ip));
        ip := ilimit_w;
    end;
    while (ip < iend) do
    begin
      op^ := ip^;
      inc(op);
      inc(ip);
    end;
end;

{! ZSTD_storeSeq() :
 *  Store a sequence (litlen, litPtr, offCode and mlBase) into seqStore_t.
 *  `offCode` : distance to match + ZSTD_REP_MOVE (values <= ZSTD_REP_MOVE are repCodes).
 *  `mlBase` : matchLength - MINMATCH
 *  Allowed to overread literals up to litLimit.
}
procedure ZSTD_storeSeq(seqStorePtr:pseqStore_t; litLength:int32; literals,litLimit:pbyte; offCode:Uint32; mlBase:int32);
var
  litLimit_w,litEnd,g_start:pbyte;
  pos :Uint32;
begin
    litLimit_w := litLimit - WILDCOPY_OVERLENGTH;
    litEnd := literals + litLength;

    g_start := nil;
    if (g_start=nil) then
      g_start := literals;  { note : index only works for compression within a single segment }
    
    pos := Uint32(literals - g_start);
    //log(3, 'Cpos%7u :%3u literals, match%4u bytes at offCode%7u',pos, litLength, mlBase+MINMATCH, offCode);
    

    assert(int32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart) < seqStorePtr^.maxNbSeq);
    { copy Literals }
    assert(seqStorePtr^.maxNbLit <= 128 *1024);
    assert(seqStorePtr^.lit + litLength <= seqStorePtr^.litStart + seqStorePtr^.maxNbLit);
    assert(literals + litLength <= litLimit);
    if (litEnd <= litLimit_w) then
    begin
        { Common case we can use wildcopy.
	        * First copy 16 bytes, because literals are likely short.
	      }
        assert(WILDCOPY_OVERLENGTH >= 16);
        move(literals^,seqStorePtr^.lit^,16);
        if (litLength > 16) then
        begin
            //ZSTD_wildcopy(seqStorePtr^.lit+16, literals+16, (ptrdiff_t)litLength-16, ZSTD_no_overlap);
            move(literals[16],seqStorePtr^.lit[16],litLength-16);
        end;
    end
    else 
    begin
        ZSTD_safecopyLiterals(seqStorePtr^.lit, literals, litEnd, litLimit_w);
    end;
    seqStorePtr^.lit :=seqStorePtr^.lit + litLength;

    { literal Length }
    if (litLength>$FFFF) then
    begin
        assert(seqStorePtr^.longLengthID = 0); { there can only be a single long length }
        seqStorePtr^.longLengthID := 1;
        seqStorePtr^.longLengthPos := Uint32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart);
    end;
    seqStorePtr^.sequences[0].litLength := word(litLength);

    { match offset }
    seqStorePtr^.sequences[0].offset := offCode + 1;

    { match Length }
    if (mlBase>$FFFF) then
    begin
        assert(seqStorePtr^.longLengthID = 0); { there can only be a single long length }
        seqStorePtr^.longLengthID := 2;
        seqStorePtr^.longLengthPos := Uint32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart);
    end;
    seqStorePtr^.sequences[0].matchLength := word(mlBase);

    inc(seqStorePtr^.sequences);
end;


{-*************************************
*  Match length counter
**************************************}
function ZSTD_NbCommonBytes (val:int32):uint32;
const
  {$ifdef CPU64}
    DeBruijnBytePos:array [0..63] of int32 = ( 0, 0, 0, 0, 0, 1, 1, 2,
      0, 3, 1, 3, 1, 4, 2, 7,
      0, 2, 3, 6, 1, 5, 3, 5,
      1, 3, 4, 4, 2, 5, 6, 7,
      7, 0, 1, 2, 3, 3, 4, 6,
      2, 6, 5, 5, 3, 4, 5, 6,
      7, 1, 2, 4, 6, 4, 4, 5,
      7, 2, 6, 5, 7, 6, 7, 7 );
  {$endif}
  {$ifdef CPU32}
    DeBruijnBytePos:array [0..31] of int32 = ( 0, 0, 3, 0, 3, 1, 3, 0,
      3, 2, 2, 1, 3, 2, 0, 1,
      3, 3, 1, 2, 2, 2, 2, 0,
      3, 1, 2, 0, 1, 0, 1, 1 );
  {$endif}
var
  r:uint32;
begin
    {$ifdef ENDIAN_LITTLE}
        {$ifdef CPU64}
          exit(DeBruijnBytePos[(Uint64((val and  -Int64(val)) * Uint64($0218A392CDABBD3F)))  shr  58]);
        {$endif}
        {$ifdef CPU32} { 32 bits }

          exit(DeBruijnBytePos[(Uint32((val and -Int32(val)) * Uint32($077CB531)))  shr  27]);
        {$endif}
    {$endif}  { Big Endian CPU }
    {$ifdef ENDIAN_BIG}
        {$ifdef CPU64}

            const unsigned n32 := sizeof(int32)*4;   { calculate this way due to compiler complaining in 32-bits mode }
            if ((val shr n32)=0) then
            begin 
              r:=4; 
            end
            else 
            begin 
              r:=0; 
              val :=val shr n32; 
            end;
            
            if ((val shr 16)=0) then
            begin 
              r:=r+2; 
              val :=val shr 8; 
            end
            else 
            begin 
              val :=val shr 24; 
            end;
            r :=r + (not val);
            result := r;

        {$endif}
         {$ifdef CPU32}{ 32 bits }

            if ((val shr 16)=0) then
            begin 
              r:=2; 
              val :=val shr 8; 
            end
            else 
            begin 
              r:=0; 
              val :=val shr 24; 
            end;
            r :=r + (not val);
            result := r;
        {$endif}
    {$endif}
end;


function ZSTD_count(pIn, pMatch,pInLimit:pbyte):int32;
var
  pStart,pInLoopLimit:pbyte;
  diff:int32;
begin
    pStart := pIn;
    pInLoopLimit := pInLimit - (sizeof(int32)-1);

    if (pIn < pInLoopLimit) then
    begin
        diff := MEM_readST(pMatch) xor MEM_readST(pIn);
        if (diff<>0) then
          exit(ZSTD_NbCommonBytes(diff)); 
        pIn:=pIn+sizeof(int32); 
        pMatch:=pMatch+sizeof(int32);
        while (pIn < pInLoopLimit) do
        begin 
            diff := MEM_readST(pMatch) xor MEM_readST(pIn);
            if (diff=0) then
            begin 
              pIn:=pIn+sizeof(int32); 
              pMatch:=pMatch+sizeof(int32); 
              continue; 
            end;
            pIn :=pIn + ZSTD_NbCommonBytes(diff);
            exit(int32(pIn - pStart));
        end;   
    end;
    {$ifdef CPU64}
    if (pIn<(pInLimit-3))  and  (MEM_read32(pMatch) = MEM_read32(pIn)) then
    begin 
      pIn:=pIn+4; 
      pMatch:=pMatch+4; 
    end;
    {$endif}
    if ((pIn<(pInLimit-1))  and  (MEM_read16(pMatch) = MEM_read16(pIn))) then
    begin 
      pIn:=pIn+2; 
      pMatch:=pMatch+2; 
    end;
    if ((pIn<pInLimit)  and  ( pMatch^ = pIn^)) then
      inc(pIn);
    result := int32(pIn - pStart);
end;

{* ZSTD_count_2segments() :
 *  can count match length with `ip` & `match` in 2 different segments.
 *  convention : on reaching mEnd, match count continue starting from iStart
 }
function MINpbyte(a,b:pbyte):pbyte;
begin
   if (ptruint(a)<ptruint(b)) then
      result:=a
   else
     result:=b;
end;

function ZSTD_count_2segments(ip,   match, iEnd, mEnd, iStart:pbyte):int32;
var
  vEnd:pbyte;
  matchLength:int32;
begin
    vEnd := MINpbyte( ip + (ptruint(mEnd) - ptruint(match)), iEnd);
    matchLength := ZSTD_count(ip, match, vEnd);
    if (match + matchLength <> mEnd) then
      exit(matchLength);
    //log(3, 'ZSTD_count_2segments: found a 2-parts match (current length=%zu)', matchLength);
    //log(3, 'distance from match beginning to end dictionary := %zi', mEnd - match);
    //log(3, 'distance from current pos to end buffer := %zi', iEnd - ip);
    //log(3, 'next byte : ip=%02X, istart=%02X', ip[matchLength], iStart^);
    //log(3, 'final match length := %zu', matchLength + ZSTD_count(ip+matchLength, iStart, iEnd));
    result := matchLength + ZSTD_count(ip+matchLength, iStart, iEnd);
end;


{-*************************************
 *  Hashes
 **************************************}

function  ZSTD_hash3( u,  h:Uint32):Uint32; 
begin 
  result := ((u  shl  (32-24)) * prime3bytes)   shr  (32-h) ; 
end;
function ZSTD_hash3Ptr(ptr:pbyte;  h:Uint32):int32; 
begin 
  result := ZSTD_hash3(MEM_readLE32(ptr), h); 
end; { only in zstd_opt.h }


function  ZSTD_hash4( u,  h:Uint32) :Uint32; 
begin 
  result := (u * prime4bytes)  shr  (32-h) ; 
end;
function ZSTD_hash4Ptr(ptr:pbyte;  h:Uint32):int32;
begin 
  result := ZSTD_hash4(MEM_read32(ptr), h); 
end;


function ZSTD_hash5( u:Uint64;  h:Uint32) :int32;
begin 
  result := int32(((u   shl  (64-40)) * prime5bytes)  shr  (64-h)) ; 
end;
function ZSTD_hash5Ptr(p:pbyte;  h:Uint32) :int32;
begin 
  result := ZSTD_hash5(MEM_readLE64(p), h); 
end;


function ZSTD_hash6( u:Uint64;  h:Uint32) :int32;
begin 
  result := int32(((u   shl  (64-48)) * prime6bytes)  shr  (64-h)) ; 
end;
function ZSTD_hash6Ptr(p:pbyte;  h:Uint32) :int32;
begin 
  result := ZSTD_hash6(MEM_readLE64(p), h); 
end;


function ZSTD_hash7( u:Uint64;  h:Uint32) :int32;
begin 
  result := int32(((u   shl  (64-56)) * prime7bytes)  shr  (64-h)) ; 
end;
function ZSTD_hash7Ptr(p:pbyte;  h:Uint32) :int32;
begin 
  result := ZSTD_hash7(MEM_readLE64(p), h); 
end;

function ZSTD_hash8( u:Uint64;  h:Uint32) :int32;
begin 
  result := int32(((u) * prime8bytes)  shr  (64-h)) ; 
end;
function ZSTD_hash8Ptr(p:pbyte;  h:Uint32) :int32;
begin 
  result := ZSTD_hash8(MEM_readLE64(p), h); 
end;

function ZSTD_hashPtr(p:pbyte; hBits, mls:Uint32):int32;
begin
    case(mls) of
      4: exit(ZSTD_hash4Ptr(p, hBits));
      5: exit(ZSTD_hash5Ptr(p, hBits));
      6: exit(ZSTD_hash6Ptr(p, hBits));
      7: exit(ZSTD_hash7Ptr(p, hBits));
      8: exit(ZSTD_hash8Ptr(p, hBits));
      else exit(ZSTD_hash4Ptr(p, hBits));
    end;
end;

{* ZSTD_ipow() :
 * Return base^exponent.
 }
function ZSTD_ipow( base,  exponent:Uint64):Uint64;
var
  power:Uint64;
begin
  power := 1;
  while (exponent<>0) do
  begin
    if (exponent and 1)<>0 then
      power :=power * base;
    exponent  :=exponent  shr  1;
    base :=base * base;
  end;
  result := power;
end;



{* ZSTD_rollingHash_append() :
 * Add the buffer to the hash value.
 }
function ZSTD_rollingHash_append(hash:Uint64; buf:pbyte; size:int32):Uint64;
var
  istart:pbyte;
  pos:int32;
begin
    istart := buf;
    for pos := 0 to size-1 do
    begin
        hash :=hash * prime8bytes;
        hash :=hash + istart[pos] + ZSTD_ROLL_HASH_CHAR_OFFSET;
    end;
    result := hash;
end;

{* ZSTD_rollingHash_compute() :
 * Compute the rolling hash value of the buffer.
 }
function ZSTD_rollingHash_compute(buf:pbyte; size:int32):Uint64;
begin
    result := ZSTD_rollingHash_append(0, buf, size);
end;

{* ZSTD_rollingHash_primePower() :
 * Compute the primePower to be passed to ZSTD_rollingHash_rotate() for a hash
 * over a window of length bytes.
 }
function ZSTD_rollingHash_primePower(length:Uint32):Uint64;
begin
    result := ZSTD_ipow(prime8bytes, length - 1);
end;

{* ZSTD_rollingHash_rotate() :
 * Rotate the rolling hash by one byte.
 }
function ZSTD_rollingHash_rotate(hash:Uint64;  toRemove,  toAdd:BYTE; primePower:Uint64):Uint64;
begin
    hash :=hash - (toRemove + ZSTD_ROLL_HASH_CHAR_OFFSET) * primePower;
    hash :=hash * prime8bytes;
    hash :=hash + toAdd + ZSTD_ROLL_HASH_CHAR_OFFSET;
    result := hash;
end;


{*
 * ZSTD_window_clear():
 * Clears the window containing the history by simply setting it to empty.
 }
procedure ZSTD_window_clear(window:pZSTD_window_t);
var
  endT:int32;
  lend:Uint32;
begin
    endT := int32(window^.nextSrc - window^.base);
    lend := Uint32(endT);

    window^.lowLimit := lend;
    window^.dictLimit := lend;
end;

{*
 * ZSTD_window_hasExtDict():
 * Returns non-zero if the window has a non-empty extDict.
 }
function ZSTD_window_hasExtDict(window:ZSTD_window_t):Uint32;
begin
    result :=  ord(window.lowLimit < window.dictLimit);
end;

{*
 * ZSTD_matchState_dictMode():
 * Inspects the provided matchState and figures out what dictMode should be
 * passed to the compressor.
 }
function ZSTD_matchState_dictMode(ms:pZSTD_matchState_t):ZSTD_dictMode_e;
begin
  if ZSTD_window_hasExtDict(ms^.window)<>0 then
    result := ZSTD_extDict
  else
    if ms^.dictMatchState <> nil then
      if (ms^.dictMatchState^.dedicatedDictSearch<>0) then
       result := ZSTD_dedicatedDictSearch
      else
       result := ZSTD_dictMatchState
    else
      result := ZSTD_noDict;
end;

{*
 * ZSTD_window_needOverflowCorrection():
 * Returns non-zero if the indices are getting too large and need overflow
 * protection.
 }
function ZSTD_window_needOverflowCorrection(window:ZSTD_window_t;srcEnd:pbyte):Uint32;
begin
    result := Uint32(srcEnd - window.base);
    result := ord(result > ZSTD_CURRENT_MAX);
end;

{*
 * ZSTD_window_correctOverflow():
 * Reduces the indices to protect from index overflow.
 * Returns the correction made to the indices, which must be applied to every
 * stored index.
 *
 * The least significant cycleLog bits of the indices must remain the same,
 * which may be 0. Every index up to maxDist in the past must be valid.
 * NOTE: (maxDist & cycleMask) must be zero.
 }
function ZSTD_window_correctOverflow(window:pZSTD_window_t; cycleLog,maxDist:Uint32; src:pbyte):Uint32;
var
  cycleMask,curr,currentCycle0,currentCycle1,newCurrent,correction:Uint32;
begin
    { preemptive overflow correction:
     * 1. correction is large enough:
     *    lowLimit > (3 shl 29) => current > 3 shl 29 + 1 shl windowLog
     *    1 shl windowLog <= newCurrent < 1 shl chainLog + 1 shl windowLog
     *
     *    current - newCurrent
     *    > (3 shl 29 + 1 shl windowLog) - (1 shl windowLog + 1 shl chainLog)
     *    > (3 shl 29) - (1 shl chainLog)
     *    > (3 shl 29) - (1 shl 30)             (NOTE: chainLog <= 30)
     *    > 1 shl 29
     *
     * 2. (ip+ZSTD_CHUNKSIZE_MAX - cctx^.base) doesn't overflow:
     *    After correction, current is less than (1 shl chainLog + 1 shl windowLog).
     *    In 64-bit mode we are safe, because we have 64-bit ptrdiff_t.
     *    In 32-bit mode we are safe, because (chainLog <= 29), so
     *    ip+ZSTD_CHUNKSIZE_MAX - cctx^.base < 1 shl 32.
     * 3. (cctx^.lowLimit + 1 shl windowLog) < 1 shl 32:
     *    windowLog <= 31 => 3 shl 29 + 1 shl windowLog < 7 shl 29 < 1 shl 32.
     }
    
    cycleMask := (Uint32(1)  shl  cycleLog) - 1;
    curr := Uint32(src - window^.base);
    currentCycle0 := curr and cycleMask;
    { Exclude zero so that newCurrent - maxDist >= 1. }
    if currentCycle0 = 0 then
      currentCycle1 :=  (Uint32(1)  shl  cycleLog)
    else
      currentCycle1 :=  currentCycle0;
    newCurrent := currentCycle1 + maxDist;
    correction := curr - newCurrent;
    assert((maxDist and cycleMask) = 0);
    assert(curr > newCurrent);
    { Loose bound, should be around 1 shl 29 (see above) }
    assert(correction > 1 shl 28);

    window^.base :=window^.base + correction;
    window^.dictBase := window^.dictBase + correction;
    if (window^.lowLimit <= correction) then
      window^.lowLimit := 1
    else 
      window^.lowLimit :=window^.lowLimit - correction;
    if (window^.dictLimit <= correction) then
      window^.dictLimit := 1
    else 
      window^.dictLimit :=window^.dictLimit - correction;

    { Ensure we can still reference the full window. }
    assert(newCurrent >= maxDist);
    assert(newCurrent - maxDist >= 1);
    { Ensure that lowLimit and dictLimit didn't underflow. }
    assert(window^.lowLimit <= newCurrent);
    assert(window^.dictLimit <= newCurrent);

    //log(3, 'Correction of $%x bytes to lowLimit:=$%x', correction,
    //         window^.lowLimit);
    result := correction;
end;

{*
 * ZSTD_window_enforceMaxDist():
 * Updates lowLimit so that:
 *    (srcEnd - base) - lowLimit = maxDist + loadedDictEnd
 *
 * It ensures index is valid as long as index >= lowLimit.
 * This must be called before a block compression call.
 *
 * loadedDictEnd is only defined if a dictionary is in use for current compression.
 * As the name implies, loadedDictEnd represents the index at end of dictionary.
 * The value lies within context's referential, it can be directly compared to blockEndIdx.
 *
 * If loadedDictEndPtr is nil, no dictionary is in use, and we use loadedDictEnd = 0.
 * If loadedDictEndPtr is not nil, we set it to zero after updating lowLimit.
 * This is because dictionaries are allowed to be referenced fully
 * as long as the last byte of the dictionary is in the window.
 * Once input has progressed beyond window size, dictionary cannot be referenced anymore.
 *
 * In normal dict mode, the dictionary lies between lowLimit and dictLimit.
 * In dictMatchState mode, lowLimit and dictLimit are the same,
 * and the dictionary is below them.
 * forceWindow and dictMatchState are therefore incompatible.
 }
procedure ZSTD_window_enforceMaxDist(window:pZSTD_window_t;blockEnd:pbyte;maxDist:Uint32;
  loadedDictEndPtr:pUint32;dictMatchStatePtr:ppZSTD_matchState_t);
var
  blockEndIdx,loadedDictEnd,newLowLimit:Uint32;
begin
    blockEndIdx := Uint32(blockEnd - window^.base);
    if  (loadedDictEndPtr <> nil)  then
      loadedDictEnd :=loadedDictEndPtr^
    else
      loadedDictEnd :=0;
    //log(3, 'ZSTD_window_enforceMaxDist: blockEndIdx:=%u, maxDist:=%u, loadedDictEnd:=%u',
    //            blockEndIdx, maxDist, loadedDictEnd);

    { - When there is no dictionary : loadedDictEnd = 0.
         In which case, the test (blockEndIdx > maxDist) is merely to avoid
         overflowing next operation `newLowLimit := blockEndIdx - maxDist`.
       - When there is a standard dictionary :
         Index referential is copied from the dictionary,
         which means it starts from 0.
         In which case, loadedDictEnd = dictSize,
         and it makes sense to compare `blockEndIdx > maxDist + dictSize`
         since `blockEndIdx` also starts from zero.
       - When there is an attached dictionary :
         loadedDictEnd is expressed within the referential of the context,
         so it can be directly compared against blockEndIdx.
    }
    if (blockEndIdx > maxDist + loadedDictEnd) then
    begin
        newLowLimit := blockEndIdx - maxDist;
        if (window^.lowLimit < newLowLimit) then
          window^.lowLimit := newLowLimit;
        if (window^.dictLimit < window^.lowLimit) then
        begin
            //log(3, 'Update dictLimit to match lowLimit, from %u to %u',
            //            window^.dictLimit, window^.lowLimit);
            window^.dictLimit := window^.lowLimit;
        end;
        { On reaching window size, dictionaries are invalidated }
        if (loadedDictEndPtr<>nil) then
          loadedDictEndPtr^ := 0;
        if (dictMatchStatePtr<>nil) then
          dictMatchStatePtr^ := nil;
    end;
end;

{ Similar to ZSTD_window_enforceMaxDist(),
 * but only invalidates dictionary
 * when input progresses beyond window size.
 * assumption : loadedDictEndPtr and dictMatchStatePtr are valid (non nil)
 *              loadedDictEnd uses same referential as window^.base
 *              maxDist is the window size }
procedure ZSTD_checkDictValidity(const window:pZSTD_window_t;
  blockEnd:pbyte;maxDist:Uint32;loadedDictEndPtr:pUint32;dictMatchStatePtr:ppZSTD_matchState_t);
var
  blockEndIdx,loadedDictEnd:Uint32;
begin
    assert(loadedDictEndPtr <> nil);
    assert(dictMatchStatePtr <> nil); 
    blockEndIdx := Uint32(blockEnd - window^.base);
    loadedDictEnd := loadedDictEndPtr^;
    //log(3, 'ZSTD_checkDictValidity: blockEndIdx:=%u, maxDist:=%u, loadedDictEnd:=%u',
    //            blockEndIdx, maxDist, loadedDictEnd);
    assert(blockEndIdx >= loadedDictEnd);

    if (blockEndIdx > loadedDictEnd + maxDist) then
    begin
        { On reaching window size, dictionaries are invalidated.
         * For simplification, if window size is reached anywhere within next block,
         * the dictionary is invalidated for the full block.
         }
        //log(3, 'invalidating dictionary for current block (distance > windowSize)');
        loadedDictEndPtr^ := 0;
        dictMatchStatePtr^ := nil;
    end 
    else 
    begin
        if (loadedDictEndPtr^ <> 0) then
        begin
            //log(3, 'dictionary considered valid for current block');
        end;   
    end;
end;

procedure ZSTD_window_init(window:pZSTD_window_t);
begin
    fillbyte(window^, sizeof(ZSTD_window_t), 0);
    window^.base := nil;
    window^.dictBase := nil;
    window^.dictLimit := 1;    { start from 1, so that 1st position is valid }
    window^.lowLimit := 1;     { it ensures first and later CCtx usages compress the same }
    window^.nextSrc := window^.base + 1;   { see issue #1241 }
end;

{*
 * ZSTD_window_update():
 * Updates the window by appending [src, src + srcSize) to the window.
 * If it is not contiguous, the current prefix becomes the extDict, and we
 * forget about the extDict. Handles overlap of the prefix and extDict.
 * Returns non-zero if the segment is contiguous.
 }
function ZSTD_window_update(window:pZSTD_window_t;src:pbyte; srcSize:int32):Uint32;
var
  ip:pbyte;
  distanceFromBase:int32;
  contiguous,highInputIdx,lowLimitMax:Uint32;
begin
    ip := src;
    contiguous := 1;
    //log(3, 'ZSTD_window_update');
    if (srcSize = 0) then
        exit(contiguous);
    assert(window^.base <> nil);
    assert(window^.dictBase <> nil);
    { Check if blocks follow each other }
    if (src <> window^.nextSrc) then
    begin
        { not contiguous }
        distanceFromBase := int32(window^.nextSrc - window^.base);
        //log(3, 'Non contiguous blocks, new segment starts at %u', window^.dictLimit);
        window^.lowLimit := window^.dictLimit;
        assert(distanceFromBase = distanceFromBase);  { should never overflow }
        window^.dictLimit := Uint32(distanceFromBase);
        window^.dictBase := window^.base;
        window^.base := ip - distanceFromBase;
        { ms^.nextToUpdate := window^.dictLimit; }
        if (window^.dictLimit - window^.lowLimit < HASH_READ_SIZE) then
          window^.lowLimit := window^.dictLimit;   { too small extDict }
        contiguous := 0;
    end;
    window^.nextSrc := ip + srcSize;
    { if input and dictionary overlap : reduce dictionary (area presumed modified by input) }
    if ( (ip+srcSize > window^.dictBase + window^.lowLimit)
       and (ip < window^.dictBase + window^.dictLimit)) then
    begin 
        highInputIdx := (ip + srcSize) - window^.dictBase;
        if (highInputIdx > uint32(window^.dictLimit)) then
          lowLimitMax := window^.dictLimit
        else
          lowLimitMax := Uint32(highInputIdx);
        window^.lowLimit := lowLimitMax;
        //log(3, 'Overlapping extDict and input : new lowLimit := %u', window^.lowLimit);
    end;
    result := contiguous;
end;

{*
 * Returns the lowest allowed match index. It may either be in the ext-dict or the prefix.
 }
function ZSTD_getLowestMatchIndex(ms:pZSTD_matchState_t;  curr, windowLog:uint32):Uint32;
var
  maxDistance,lowestValid,withinWindow,isDictionary,matchLowest:Uint32;
begin
    maxDistance := Uint32(1)  shl  windowLog;
    lowestValid := ms^.window.lowLimit;
    if (curr - lowestValid > maxDistance) then
      withinWindow :=  curr - maxDistance
    else
      withinWindow :=  lowestValid;
    isDictionary := ord(ms^.loadedDictEnd <> 0);
    { When using a dictionary the entire dictionary is valid if a single byte of the dictionary
     * is within the window. We invalidate the dictionary (and set loadedDictEnd to 0) when it isn't
     * valid for the entire block. So this check is sufficient to find the lowest valid match index.
     }
     if isDictionary<>0 then
      matchLowest := lowestValid
     else
      matchLowest := withinWindow;
    result := matchLowest;
end;

{*
 * Returns the lowest allowed match index in the prefix.
 }
function ZSTD_getLowestPrefixIndex(ms:pZSTD_matchState_t; curr,windowLog:Uint32):Uint32;
var
  maxDistance,lowestValid,withinWindow,isDictionary,matchLowest:Uint32;
begin
    maxDistance := Uint32(1)  shl  windowLog;
    lowestValid := ms^.window.dictLimit;
    if (curr - lowestValid > maxDistance) then
       withinWindow :=  curr - maxDistance
    else
        withinWindow :=  lowestValid;
    isDictionary := ord(ms^.loadedDictEnd <> 0);
    { When computing the lowest prefix index we need to take the dictionary into account to handle
     * the edge case where the dictionary and the source are contiguous in memory.
     }
     if isDictionary<>0 then
      matchLowest := lowestValid
     else
      matchLowest := withinWindow;
    result := matchLowest;
end;



{ debug functions }

function ZSTD_fWeight(rawStat:Uint32):double;
var
  fp_accuracy,fp_multiplier,newStat,hb,BWeight,FWeight,weight:Uint32;
begin
  fp_accuracy := 8;
  fp_multiplier := (1  shl  fp_accuracy);
  newStat := rawStat + 1;
  hb := ZSTD_highbit32(newStat);
  BWeight := hb * fp_multiplier;
  FWeight := (newStat  shl  fp_accuracy)  shr  hb;
  weight := BWeight + FWeight;
  assert(hb + fp_accuracy < 31);
  result := double(weight) / fp_multiplier;
end;

{ display a table content,
 * listing each element, its frequency, and its predicted bit cost }
procedure ZSTD_debugTable(table:pUint32; max:Uint32);
var
  u, sum:Uint32;
begin
  u:=0; 
  sum:=0;
  while (u<=max) do
  begin
    sum :=sum + table[u];
    inc(u)
  end;
  //log(3, 'total nb elts: %u', sum);
  for u:=0 to max do
  begin
      //log(3, '%2u: %5u  (%.2f)',u, table[u], ZSTD_fWeight(sum) - ZSTD_fWeight(table[u]) );
  end;
end;
end.
