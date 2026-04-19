unit ZSTD_DDICT;
{$mode objfpc}{$H+}
interface
{ zstd_ddict.c :
 * concentrates all logic that needs to know the internals of ZSTD_DDict object }

{-*******************************************************
*  Dependencies
********************************************************}
uses
//zstd_deps,   { ZSTD_memcpy, ZSTD_memmove, ZSTD_memset }
//cpu,         { bmi2 }
//mem,         { low level memory routines }
xxHash,
huf,zstd_internal,zstd;
//zstd_legacy;


const
  ZSTD_REP_NUM   =   3;
{-*******************************************************
 *  Constants
 ********************************************************}
  LL_base:array[0..MaxLL] of uint32 = (
                 0,    1,    2,     3,     4,     5,     6,      7,
                 8,    9,   10,    11,    12,    13,    14,     15,
                16,   18,   20,    22,    24,    28,    32,     40,
                48,   64, $80, $100, $200, $400, $800, $1000,
                $2000, $4000, $8000, $10000 );

  OF_base:array[0..MaxOff] of uint32 = (
                 0,        1,       1,       5,     $D,     $1D,     $3D,     $7D,
                 $FD,   $1FD,   $3FD,   $7FD,   $FFD,   $1FFD,   $3FFD,   $7FFD,
                 $FFFD, $1FFFD, $3FFFD, $7FFFD, $FFFFD, $1FFFFD, $3FFFFD, $7FFFFD,
                 $FFFFFD, $1FFFFFD, $3FFFFFD, $7FFFFFD, $FFFFFFD, $1FFFFFFD, $3FFFFFFD, $7FFFFFFD );

  OF_bits:array[0..MaxOff] of uint32 = (
                     0,  1,  2,  3,  4,  5,  6,  7,
                     8,  9, 10, 11, 12, 13, 14, 15,
                    16, 17, 18, 19, 20, 21, 22, 23,
                    24, 25, 26, 27, 28, 29, 30, 31 );

  ML_base:array[0..MaxML] of uint32 = (
                     3,  4,  5,    6,     7,     8,     9,    10,
                    11, 12, 13,   14,    15,    16,    17,    18,
                    19, 20, 21,   22,    23,    24,    25,    26,
                    27, 28, 29,   30,    31,    32,    33,    34,
                    35, 37, 39,   41,    43,    47,    51,    59,
                    67, 83, 99, $83, $103, $203, $403, $803,
                    $1003, $2003, $4003, $8003, $10003 );
type
{-*******************************************************
*  Types
********************************************************}
pZSTD_entropyDTables_t=^ZSTD_entropyDTables_t;
pZSTD_seqSymbol_header=^ZSTD_seqSymbol_header;
ppZSTD_seqSymbol=^pZSTD_seqSymbol;
pZSTD_seqSymbol=^ZSTD_seqSymbol;



{-*******************************************************
 *  Decompression types
 ********************************************************}
 ZSTD_seqSymbol_header=record
     fastMode:Uint32;
     tableLog:Uint32;
 end;

 ZSTD_seqSymbol=record
     nextState:smallint  ;
     nbAdditionalBits:BYTE ;
     nbBits:BYTE ;
     baseValue:Uint32  ;
 end;
ZSTD_entropyDTables_t=record
    LLTable:array[0..512] of ZSTD_seqSymbol;    { Note : Space reserved for FSE Tables }
    OFTable:array[0..256] of ZSTD_seqSymbol;   { is also used as temporary workspace while building hufTable during DDict creation }
    MLTable:array[0..512] of ZSTD_seqSymbol;    { and therefore must be at least HUF_DECOMPRESS_WORKSPACE_SIZE large }
    hufTable:array[0..4096] of Uint32;  { can accommodate HUF_decompress4X }
    rep:array[0..ZSTD_REP_NUM-1] of Uint32;
    workspace:array[0..511] of Uint32;  { HUF_DECOMPRESS_WORKSPACE_SIZE_U32 = 512 = 2048 bytes, matches C zstd }
end;
pZSTD_DDict=^ZSTD_DDict_s;
ZSTD_DDict_s=record
    dictBuffer:pbyte;
    dictContent:pbyte;
    dictSize:int32 ;
    entropy:ZSTD_entropyDTables_t ;
    dictID:Uint32 ;
    entropyPresent:Uint32 ;
    //cMem:ZSTD_customMem ;
end;  { typedef'd to ZSTD_DDict within 'zstd.h' }
pZSTD_DCtx=^ZSTD_DCtx_s;
ZSTD_dStage=( ZSTDds_getFrameHeaderSize, ZSTDds_decodeFrameHeader,
               ZSTDds_decodeBlockHeader, ZSTDds_decompressBlock,
               ZSTDds_decompressLastBlock, ZSTDds_checkChecksum,
               ZSTDds_decodeSkippableHeader, ZSTDds_skipFrame);

ZSTD_dStreamStage=( zdss_init:=0, zdss_loadHeader,
               zdss_read, zdss_load, zdss_flush);

ZSTD_dictUses_e=(
    ZSTD_use_indefinitely := -1,  { Use the dictionary indefinitely }
    ZSTD_dont_use := 0,           { Do not use the dictionary (if one exists free it) }
    ZSTD_use_once := 1            { Use the dictionary once and set to ZSTD_dont_use }
);


ZSTD_DCtx_s=record
    LLTptr:pZSTD_seqSymbol;
    MLTptr:pZSTD_seqSymbol;
    OFTptr:pZSTD_seqSymbol;
    HUFptr:puint32;
    entropy:ZSTD_entropyDTables_t;
    workspace:array [0..511] of Uint32;   { space needed when building huffman tables }
    previousDstEnd:pbyte;   { detect continuity }
    prefixStart:pbyte;      { start of current segment }
    virtualStart:pbyte;     { virtual start of previous segment if it was just before current one }
    dictEnd:pbyte;          { end of previous segment }
    expected:int32 ;
    fParams:ZSTD_frameHeader ;
    decodedSize:Uint64 ;
    bType:blockType_e ;            { used in ZSTD_decompressContinue(), store blockType between block header decoding and block decompression stages }
    stage:ZSTD_dStage ;
    litEntropy:Uint32;
    fseEntropy:Uint32;
    xxhState:XXH64_state_t;
     headerSize:int32;
    format:ZSTD_format_e;
    forceIgnoreChecksum:ZSTD_forceIgnoreChecksum_e;   { User specified: if = 1, will ignore checksums in compressed frame. Default = 0 }
     validateChecksum:Uint32;         { if = 1, will validate checksum. Is = 1 if (fParams.checksumFlag = 1) and (forceIgnoreChecksum = 0). }
    litPtr:pbyte;
    customMem:ZSTD_customMem;
    litSize:int32;
    rleSize:int32;
    staticSize:int32;
     bmi2:int32;                     { = 1 if the CPU supports BMI2 and 0 otherwise. CPU support is determined dynamically once per context lifetime. }

    { dictionary }
    ddictLocal:pZSTD_DDict;
    ddict:pZSTD_DDict;     { set by ZSTD_initDStream_usingDDict(), or ZSTD_DCtx_refDDict() }
     dictID:Uint32;
     ddictIsCold:int32;             { if = 1 : dictionary is 'new' for working context, and presumed 'cold' (not in cpu cache) }
    dictUses:ZSTD_dictUses_e;

    { streaming }
    streamStage:ZSTD_dStreamStage;
    inBuff:pbyte;
    inBuffSize:int32;
    inPos:int32;
    maxWindowSize:int32;
    outBuff:pbyte;
    outBuffSize:int32;
    outStart:int32;
    outEnd:int32;
    lhSize:int32;
    legacyContext:pbyte;
    previousLegacyVersion:Uint32;
    legacyVersion:Uint32;
    hostageByte:Uint32;
     noForwardProgress:int32;
    outBufferMode:ZSTD_bufferMode_e;
     expectedOutBuffer:ZSTD_outBuffer;

    { workspace }
    litBuffer:array[0..ZSTD_BLOCKSIZE_MAX + WILDCOPY_OVERLENGTH-1] of byte;
    headerBuffer:array[0..ZSTD_FRAMEHEADERSIZE_MAX-1] of byte;

     oversizedDuration:int32;
end;  { typedef'd to ZSTD_DCtx within 'zstd.h' }
ZSTD_DCtx=ZSTD_DCtx_s;
ZSTD_DStream=ZSTD_DCtx;
pZSTD_DStream=^ZSTD_DCtx; 
function ZSTD_sizeof_DDict(const ddict:pZSTD_DDict):int32;
function ZSTD_freeDDict(ddict:pZSTD_DDict):int32;
function ZSTD_DDict_dictContent(const ddict:pZSTD_DDict):pbyte;
function ZSTD_DDict_dictSize(const ddict:pZSTD_DDict):int32;
procedure ZSTD_copyDDictParameters(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict);
function ZSTD_createDDict_advanced(dict:pbyte;dictSize:int32;dictLoadMethod:ZSTD_dictLoadMethod_e;
  dictContentType:ZSTD_dictContentType_e;customMem:ZSTD_customMem):pZSTD_DDict;
implementation
uses error_private,zstd_common,ZSTD_DECOMPRESSf;
function ZSTD_DDict_dictContent(const ddict:pZSTD_DDict):pbyte;
begin
    assert(ddict <> nil);
    result := ddict^.dictContent;
end;

function ZSTD_DDict_dictSize(const ddict:pZSTD_DDict):int32;
begin
    assert(ddict <> nil);
    result := ddict^.dictSize;
end;

procedure ZSTD_copyDDictParameters(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict);
begin
    //log(3,  'ZSTD_copyDDictParameters');
    assert(dctx <> nil);
    assert(ddict <> nil);
    dctx^.dictID := ddict^.dictID;
    dctx^.prefixStart := ddict^.dictContent;
    dctx^.virtualStart := ddict^.dictContent;
    dctx^.dictEnd := ddict^.dictContent + ddict^.dictSize;
    dctx^.previousDstEnd := dctx^.dictEnd;
    if (ddict^.entropyPresent<>0) then
    begin
        dctx^.litEntropy := 1;
        dctx^.fseEntropy := 1;
        dctx^.LLTptr := ddict^.entropy.LLTable;
        dctx^.MLTptr := ddict^.entropy.MLTable;
        dctx^.OFTptr := ddict^.entropy.OFTable;
        dctx^.HUFptr := ddict^.entropy.hufTable;
        dctx^.entropy.rep[0] := ddict^.entropy.rep[0];
        dctx^.entropy.rep[1] := ddict^.entropy.rep[1];
        dctx^.entropy.rep[2] := ddict^.entropy.rep[2];
    end
    else 
    begin
        dctx^.litEntropy := 0;
        dctx^.fseEntropy := 0;
    end;
end;


function ZSTD_loadEntropy_intoDDict(ddict:pZSTD_DDict;dictContentType:ZSTD_dictContentType_e):int32;
var
  magic:Uint32;
begin
    ddict^.dictID := 0;
    ddict^.entropyPresent := 0;
    if (dictContentType = ZSTD_dct_rawContent) then
      exit(0);

    if (ddict^.dictSize < 8) then
    begin
        if (dictContentType = ZSTD_dct_fullDict) then
            exit(ERROR(dictionary_corrupted));   { only accept specified dictionaries }
        exit(0);   { pure content mode }
    end;
    magic := MEM_readLE32(ddict^.dictContent);
    if (magic <> ZSTD_MAGIC_DICTIONARY) then
    begin
        if (dictContentType = ZSTD_dct_fullDict) then
            exit(ERROR(dictionary_corrupted));   { only accept specified dictionaries }
        exit(0);   { pure content mode }
    end;
    
    ddict^.dictID := MEM_readLE32(ddict^.dictContent + ZSTD_FRAMEIDSIZE);

    { load entropy tables }
    if(ZSTD_isError(ZSTD_loadDEntropy(
             @ddict^.entropy, ddict^.dictContent, ddict^.dictSize))<>0) then
    begin
        exit(ERROR(dictionary_corrupted));
    end;
    ddict^.entropyPresent := 1;
    exit(0);
end;


function ZSTD_initDDict_internal(ddict:pZSTD_DDict;dict:pbyte;dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e):int32;
var
  internalBuffer:pbyte;
  err:int32;
begin
    if ((dictLoadMethod = ZSTD_dlm_byRef)  or  ((dict=nil)  or  (dictSize=0))) then
    begin
        ddict^.dictBuffer := nil;
        ddict^.dictContent := dict;
        if (dict=nil) then
          dictSize := 0;
    end
    else 
    begin
        internalBuffer := allocmem(dictSize);
        ddict^.dictBuffer := internalBuffer;
        ddict^.dictContent := internalBuffer;
        if (internalBuffer=nil) then
          exit(ERROR(memory_allocation));
        move(dict^, internalBuffer^,  dictSize);
    end;
    ddict^.dictSize := dictSize;
    ddict^.entropy.hufTable[0] := HUF_DTable((HufLog)*$1000001);  { cover both little and big endian }

    { parse dictionary content }
    err:=ZSTD_loadEntropy_intoDDict(ddict, dictContentType);
    if (ERR_isError(err)<>0) then
			exit(err);

    exit(0);
end;

function ZSTD_createDDict_advanced(dict:pbyte;dictSize:int32;dictLoadMethod:ZSTD_dictLoadMethod_e;
  dictContentType:ZSTD_dictContentType_e;customMem:ZSTD_customMem):pZSTD_DDict;
var
  ddict:pZSTD_DDict;
  initResult:int32;
begin
    if ord((customMem.customAlloc=nil) xor (customMem.customFree=nil))<>0 then
      exit(nil);

    ddict := allocmem(sizeof(pZSTD_DDict^));
    if (ddict = nil) then
      exit(nil);
    //ddict^.cMem := customMem;
    initResult := ZSTD_initDDict_internal(ddict,dict, dictSize,dictLoadMethod, dictContentType);
    if (ZSTD_isError(initResult)<>0) then
    begin
        ZSTD_freeDDict(ddict);
        exit(nil);
    end;
    exit(ddict);
end;

{! ZSTD_createDDict() :
*   Create a digested dictionary, to start decompression without startup delay.
*   `dict` content is copied inside DDict.
*   Consequently, `dict` can be released after `ZSTD_DDict` creation }
function ZSTD_createDDict(const dict:pbyte;dictSize:int32):pZSTD_DDict;
var
  allocator:ZSTD_customMem;
begin
    fillbyte(allocator,sizeof(ZSTD_customMem),0);
    result := ZSTD_createDDict_advanced(dict, dictSize, ZSTD_dlm_byCopy, ZSTD_dct_auto, allocator);
end;

{! ZSTD_createDDict_byReference() :
 *  Create a digested dictionary, to start decompression without startup delay.
 *  Dictionary content is simply referenced, it will be accessed during decompression.
 *  Warning : dictBuffer must outlive DDict (DDict must be freed before dictBuffer) }
function ZSTD_createDDict_byReference(const dictBuffer:pbyte;dictSize:int32):pZSTD_DDict;
var
  allocator:ZSTD_customMem;
begin
    fillbyte(allocator,sizeof(ZSTD_customMem),0);
    result := ZSTD_createDDict_advanced(dictBuffer, dictSize, ZSTD_dlm_byRef, ZSTD_dct_auto, allocator);
end;


function ZSTD_initStaticDDict(sBuffer:pbyte;sBufferSize:int32;dict:pbyte;dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e):pZSTD_DDict;
var
  neededSpace:int32;
  ddict:pZSTD_DDict;
begin
  if dictLoadMethod = ZSTD_dlm_byRef then
    neededSpace := sizeof(pZSTD_DDict^)
  else
    neededSpace := sizeof(pZSTD_DDict^)+dictSize ;
    
  ddict := pZSTD_DDict(sBuffer);
  assert(sBuffer <> nil);
  assert(dict <> nil);
  if (int32(sBuffer)  and  7)<>0 then
    exit(nil);   { 8-aligned }
  if (sBufferSize < neededSpace) then
    exit(nil);
  if (dictLoadMethod = ZSTD_dlm_byCopy) then
  begin
      move( dict^, ddict[1],dictSize);  { local copy }
      dict := pbyte(ddict+1);
  end;
  if (ZSTD_isError( ZSTD_initDDict_internal(ddict,dict, dictSize,ZSTD_dlm_byRef, dictContentType) )<>0) then
    exit(nil);
  exit(ddict);
end;


function ZSTD_freeDDict(ddict:pZSTD_DDict):int32;
var
  cMem:ZSTD_customMem; 
begin
    if (ddict=nil) then
      exit(0);   { support free on nil }
    //cMem := ddict^.cMem;
    ZSTD_customfree(ddict^.dictBuffer, cMem);
    ZSTD_customfree(pbyte(ddict), cMem);
    exit(0);
end;

{! ZSTD_estimateDDictSize() :
 *  Estimate amount of memory that will be needed to create a dictionary for decompression.
 *  Note : dictionary created by reference using ZSTD_dlm_byRef are smaller }
function ZSTD_estimateDDictSize(dictSize:int32; dictLoadMethod:ZSTD_dictLoadMethod_e):int32;
begin
  if dictLoadMethod = ZSTD_dlm_byRef then
    result := sizeof(pZSTD_DDict^)
  else
    result := sizeof(pZSTD_DDict^) + dictSize;
end;

function ZSTD_sizeof_DDict(const ddict:pZSTD_DDict):int32;
begin
    if (ddict=nil) then
      exit(0);   { support sizeof on nil }
    if ddict^.dictBuffer<>nil then
      result := sizeof(pZSTD_DDict^) + ddict^.dictSize
    else
      result := sizeof(pZSTD_DDict^);
end;

{! ZSTD_getDictID_fromDDict() :
 *  Provides the dictID of the dictionary loaded into `ddict`.
 *  If @return = 0, the dictionary is not conformant to Zstandard specification, or empty.
 *  Non-conformant dictionaries can still be loaded, but as content-only dictionaries. }
function ZSTD_getDictID_fromDDict(const ddict:pZSTD_DDict):uint32;
begin
    if (ddict=nil) then
      exit(0);
    result := ZSTD_getDictID_fromDict(ddict^.dictContent, ddict^.dictSize);
end;
end.
