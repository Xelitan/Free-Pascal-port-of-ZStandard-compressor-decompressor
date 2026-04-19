unit ZSTD_DECOMPRESSf;
{$mode objfpc}{$H+}
interface
{-*******************************************************
*  Dependencies
********************************************************}
uses
//zstd_deps,   { ZSTD_memcpy, ZSTD_memmove, ZSTD_memset }
//cpu,         { bmi2 }
//mem,         { low level memory routines }
math,xxHash,huf_decompress,entropy_common,
huf,zstd_common,error_private, zstd,
zstd_internal,  { blockProperties_t }
   { ZSTD_DCtx }
zstd_ddict,  { ZSTD_DDictDictContent }
zstd_decompress_block;   { ZSTD_decompressBlock_internal }
//zstd_legacy;


{ ***************************************************************
*  Tuning parameters
****************************************************************}
{!
 * HEAPMODE :
 * Select how default decompression function ZSTD_decompress() allocates its context,
 * on stack (0), or into heap (1, default; requires malloc()).
 * Note that functions with explicit context such as ZSTD_decompressDCtx() are unaffected.
 }
const
  ZSTD_HEAPMODE = 1;
  ZSTD_WINDOWLOG_LIMIT_DEFAULT = 27;   { by default, the streaming decoder will refuse any frame
                                             * requiring larger than (1<<ZSTD_WINDOWLOG_LIMIT_DEFAULT) window size,
                                             * to preserve host's memory from unreasonable requirements.
                                             * This limit can be overridden using ZSTD_DCtx_setParameter(,ZSTD_d_windowLogMax,).
                                             * The limit does not apply for one-pass decoders (such as ZSTD_decompress()), since no additional memory is allocated }

{!
*  LEGACY_SUPPORT :
*  if set to 1+, ZSTD_decompress() can decode older formats (v0.1+)
}

  ZSTD_LEGACY_SUPPORT = 0;


{!
 *  MAXWINDOWSIZE_DEFAULT :
 *  maximum window size accepted by DStream __by default__.
 *  Frames requiring more memory will be rejected.
 *  It's possible to set a different limit using ZSTD_DCtx_setMaxWindowSize().
 }

  ZSTD_MAXWINDOWSIZE_DEFAULT = ((Uint32(1)  shl  ZSTD_WINDOWLOG_LIMIT_DEFAULT) + 1);


{!
 *  NO_FORWARD_PROGRESS_MAX :
 *  maximum allowed nb of calls to ZSTD_decompressStream()
 *  without any forward progress
 *  (defined as: no byte read from input, and no byte flushed to output)
 *  before triggering an error.
 }
 ZSTD_NO_FORWARD_PROGRESS_MAX = 16;
function ZSTD_getFrameContentSize(const src:pbyte;srcSize:int32):Uint64;
function ZSTD_loadDEntropy(entropy:pZSTD_entropyDTables_t;dict:pbyte; dictSize:int32):int32;
function ZSTD_findFrameCompressedSize(const src:pbyte;srcSize:int32):int32;
function ZSTD_decompressBegin_usingDDict(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict):int32;
function ZSTD_decompressBegin_usingDict(dctx:pZSTD_DCtx; const dict:pbyte;dictSize:int32):int32;
function ZSTD_decompress_usingDDict(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  src:pbyte;srcSize:int32;const ddict:pZSTD_DDict):int32;
function ZSTD_createDStream_advanced(customMem:ZSTD_customMem):pZSTD_DStream;
function ZSTD_DCtx_reset(dctx:pZSTD_DCtx; reset:ZSTD_ResetDirective):int32;
function ZSTD_initDStream_usingDDict(dctx:pZSTD_DStream; const ddict:pZSTD_DDict):int32;
function ZSTD_DCtx_refDDict(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict):int32;
function ZSTD_dParam_getBounds(dParam:ZSTD_dParameter):ZSTD_bounds;
function ZSTD_DCtx_setParameter(dctx:pZSTD_DCtx; dParam:ZSTD_dParameter;value: int32 ):int32;
function ZSTD_getDictID_fromDict(const dict:pbyte;dictSize:int32):uint32;
function ZSTD_decompress(dst:pbyte;dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
implementation
{-*************************************************************
*   Context management
**************************************************************}
function ZSTD_sizeof_DCtx (const dctx:pZSTD_DCtx):int32;
begin
    if (dctx=nil) then
      exit(0);   { support sizeof nil }
    result := sizeof(ZSTD_DCtx)
           + ZSTD_sizeof_DDict(dctx^.ddictLocal)
           + dctx^.inBuffSize + dctx^.outBuffSize;
end;

function ZSTD_estimateDCtxSize():int32; 
begin 
  result := sizeof(ZSTD_DCtx); 
end;


function ZSTD_startingInputLength(format:ZSTD_format_e):int32;
var
  startingInputLength:int32;
begin
    startingInputLength := ZSTD_FRAMEHEADERSIZE_PREFIX(format);
    { only supports formats ZSTD_f_zstd1 and ZSTD_f_zstd1_magicless }
    assert( (format = ZSTD_f_zstd1)  or  (format = ZSTD_f_zstd1_magicless) );
    result := startingInputLength;
end;

procedure ZSTD_DCtx_resetParameters(dctx:pZSTD_DCtx);
begin
    assert(dctx^.streamStage = zdss_init);
    dctx^.format := ZSTD_f_zstd1;
    dctx^.maxWindowSize := ZSTD_MAXWINDOWSIZE_DEFAULT;
    dctx^.outBufferMode := ZSTD_bm_buffered;
    dctx^.forceIgnoreChecksum := ZSTD_d_validateChecksum;
end;

procedure ZSTD_initDCtx_internal(dctx:pZSTD_DCtx);
begin
    dctx^.staticSize  := 0;
    dctx^.ddict       := nil;
    dctx^.ddictLocal  := nil;
    dctx^.dictEnd     := nil;
    dctx^.ddictIsCold := 0;
    dctx^.dictUses := ZSTD_dont_use;
    dctx^.inBuff      := nil;
    dctx^.inBuffSize  := 0;
    dctx^.outBuffSize := 0;
    dctx^.streamStage := zdss_init;
    dctx^.legacyContext := nil;
    dctx^.previousLegacyVersion := 0;
    dctx^.noForwardProgress := 0;
    dctx^.oversizedDuration := 0;
    //dctx^.bmi2 := ZSTD_cpuid_bmi2(ZSTD_cpuid());
    ZSTD_DCtx_resetParameters(dctx);
    dctx^.validateChecksum := 1;
end;

function ZSTD_initStaticDCtx(workspace:pbyte;workspaceSize:int32):pZSTD_DCtx;
var
  dctx:pZSTD_DCtx;
begin
    dctx := pZSTD_DCtx(workspace);

    if (int32(workspace)  and  7)<>0 then
      exit(nil);  { 8-aligned }
    if (workspaceSize < sizeof(ZSTD_DCtx)) then
      exit(nil);  { minimum size }

    ZSTD_initDCtx_internal(dctx);
    dctx^.staticSize := workspaceSize;
    dctx^.inBuff := pbyte(dctx+1);
    result := dctx;
end;

function ZSTD_createDCtx_advanced(customMem:ZSTD_customMem):pZSTD_DCtx;
var
  dctx:pZSTD_DCtx;
begin
    if ((customMem.customAlloc=nil) xor (customMem.customFree=nil)) then
      exit(nil);

    dctx := allocmem(sizeof(ZSTD_DCtx));
    if (dctx=nil) then
      exit(nil);
    dctx^.customMem := customMem;
    ZSTD_initDCtx_internal(dctx);
    result := dctx;
    
end;

function ZSTD_createDCtx():pZSTD_DCtx;
begin
    //log(3,  'ZSTD_createDCtx');
    result := ZSTD_createDCtx_advanced(ZSTD_defaultCMem);
end;

procedure ZSTD_clearDict(dctx:pZSTD_DCtx);
begin
    ZSTD_freeDDict(dctx^.ddictLocal);
    dctx^.ddictLocal := nil;
    dctx^.ddict := nil;
    dctx^.dictUses := ZSTD_dont_use;
end;

function ZSTD_freeDCtx(dctx:pZSTD_DCtx):int32;
var
  cMem:ZSTD_customMem;
begin
    if (dctx=nil) then
      exit(0);   { support free on nil }
    IF (dctx^.staticSize<>0) then
     exit(ERROR(memory_allocation));// 'not compatible with static DCtx');
    cMem := dctx^.customMem;
    ZSTD_clearDict(dctx);
    ZSTD_customFree(dctx^.inBuff, cMem);
    dctx^.inBuff := nil;

    //if (dctx^.legacyContext<>nil) then 不SUPPORT
    //    ZSTD_freeLegacyStreamContext(dctx^.legacyContext, dctx^.previousLegacyVersion);

    ZSTD_customFree(pbyte(dctx), cMem);
    exit(0);

end;

{ no longer useful }
procedure ZSTD_copyDCtx(dstDCtx:pZSTD_DCtx;srcDCtx:pZSTD_DCtx);
var
  toCopy:int32;
begin
    toCopy := int32(( @dstDCtx^.inBuff) - dstDCtx);
    move( srcDCtx^, dstDCtx^, toCopy);  { no need to copy workspace }
end;


{-*************************************************************
 *   Frame header decoding
 **************************************************************}

{! ZSTD_isFrame() :
 *  Tells if the content of `buffer` starts with a valid Frame Identifier.
 *  Note : Frame Identifier is 4 bytes. If `size < 4`, @return will always be 0.
 *  Note 2 : Legacy Frame Identifiers are considered valid only if Legacy Support is enabled.
 *  Note 3 : Skippable Frame Identifiers are considered valid. }
function ZSTD_isFrame(const buffer:pbyte;size:int32):uint32;
var
  magic:Uint32;
begin
  if (size < ZSTD_FRAMEIDSIZE) then
    exit(0);
  magic := MEM_readLE32(buffer);
  if (magic = ZSTD_MAGICNUMBER) then
    exit(1);
  if ((magic  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
    exit(1);
    
  //if (ZSTD_isLegacy(buffer, size)) then
  //  exit(1);

  exit(0);
end;

{* ZSTD_frameHeaderSize_internal() :
 *  srcSize must be large enough to reach header size fields.
 *  note : only works for formats ZSTD_f_zstd1 and ZSTD_f_zstd1_magicless.
 * @return : size of the Frame Header
 *           or an error code, which can be tested with ZSTD_isError() }
function ZSTD_frameHeaderSize_internal(const src:pbyte;srcSize:int32; format:ZSTD_format_e):int32;
var
  minInputSize:int32;
  fhd:byte;
  dictID,singleSegment,fcsId:Uint32;
begin
    minInputSize := ZSTD_startingInputLength(format);
    IF (srcSize < minInputSize) then
       exit(ERROR(srcSize_wrong));

    fhd := src[minInputSize-1];
    dictID:= fhd  and  3;
    singleSegment := (fhd  shr  5)  and  1;
    fcsId := fhd  shr  6;
    result := minInputSize + ord(singleSegment = 0)
         + ZSTD_did_fieldSize[dictID] + ZSTD_fcs_fieldSize[fcsId]
         + ord((singleSegment <> 0) and (fcsId = 0));
end;

{* ZSTD_frameHeaderSize() :
 *  srcSize must be >= ZSTD_frameHeaderSize_prefix.
 * @return : size of the Frame Header,
 *           or an error code (if srcSize is too small) }
function ZSTD_frameHeaderSize(const src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_frameHeaderSize_internal(src, srcSize, ZSTD_f_zstd1);
end;


{* ZSTD_getFrameHeader_advanced() :
 *  decode Frame Header, or require larger `srcSize`.
 *  note : only works for formats ZSTD_f_zstd1 and ZSTD_f_zstd1_magicless
 * @return : 0, `zfhPtr` is correctly filled,
 *          >0, `srcSize` is too small, value is wanted `srcSize` amount,
 *           or an error code, which can be tested using ZSTD_isError() }
function ZSTD_getFrameHeader_advanced(zfhPtr:pZSTD_frameHeader; const src:pbyte;srcSize:int32; format:ZSTD_format_e):int32;
var
  ip:pbyte;
  minInputSize:int32;
  fhsize,pos:int32;
  fhdByte:byte;
  dictIDSizeCode,checksumFlag,singleSegment,fcsID,dictID:Uint32;
  windowSize,frameContentSize:Uint64;
  wlByte:BYTE;
  windowLog:Uint32;
begin
    ip := src;
    minInputSize := ZSTD_startingInputLength(format);

    fillbyte(zfhPtr^, sizeof(ZSTD_frameHeader), 0);   { not strictly necessary, but static analyzer do not understand that zfhPtr is only going to be read only if return value is zero, since they are 2 different signals }
    if (srcSize < minInputSize) then
      exit(minInputSize);
    IF (src=nil) then
       exit(ERROR(GENERIC_ERROR));// 'invalid parameter');

    if ( (format <> ZSTD_f_zstd1_magicless)
      and (MEM_readLE32(src) <> ZSTD_MAGICNUMBER) ) then
    begin
        if ((MEM_readLE32(src)  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
        begin
            { skippable frame }
            if (srcSize < ZSTD_SKIPPABLEHEADERSIZE) then
                exit(ZSTD_SKIPPABLEHEADERSIZE); { magic number + frame length }
            fillbyte(zfhPtr^, sizeof(ZSTD_frameHeader), 0);
            zfhPtr^.frameContentSize := MEM_readLE32(src + ZSTD_FRAMEIDSIZE);
            zfhPtr^.frameType := ZSTD_skippableFrame;
            exit(0);
        end;
        exit(ERROR(prefix_unknown));
    end;

    { ensure there is enough `srcSize` to fully read/decode frame header }
    fhsize := ZSTD_frameHeaderSize_internal(src, srcSize, format);
    if (srcSize < fhsize) then
      exit(fhsize);
    zfhPtr^.headerSize := Uint32(fhsize);

    fhdByte := ip[minInputSize-1];
    pos := minInputSize;
    dictIDSizeCode := fhdByte and 3;
    checksumFlag := (fhdByte shr 2) and 1;
    singleSegment := (fhdByte shr 5) and 1;
    fcsID := fhdByte shr 6;
    windowSize := 0;
    dictID := 0;
    frameContentSize := ZSTD_CONTENTSIZE_UNKNOWN;
    IF ((fhdByte  and  $08) <> 0) then 
      exit(ERROR(frameParameter_unsupported));//'reserved bits, must be zero');

    if (singleSegment=0) then
    begin
        wlByte := ip[pos];
        inc(pos);
        windowLog := (wlByte  shr  3) + ZSTD_WINDOWLOG_ABSOLUTEMIN;
        IF (windowLog > ZSTD_WINDOWLOG_MAX) then
        exit(ERROR(frameParameter_windowTooLarge));
        windowSize := (1  shl  windowLog);
        windowSize :=windowSize + (windowSize  shr  3) * (wlByte and 7);
    end;
    case(dictIDSizeCode) of
        0 : ;
        1 : 
        begin
          dictID := ip[pos]; 
          inc(pos);
        end;
        2 : 
        begin
          dictID := MEM_readLE16(ip+pos); 
          pos:=pos+2;
        end;
        3 : 
        begin
          dictID := MEM_readLE32(ip+pos); 
          pos:=pos+4;
        end;

    end;
    case(fcsID) of
         0 : 
         begin
           if (singleSegment<>0) then
            frameContentSize := ip[pos];
         end;
         1 : 
         begin
           frameContentSize := MEM_readLE16(ip+pos)+256;
         end;
         2 : 
         begin
           frameContentSize := MEM_readLE32(ip+pos);
         end;
         3 : 
         begin
           frameContentSize := MEM_readLE64(ip+pos);
         end;
         else assert(false);  { impossible }
    end;
    if (singleSegment<>0) then
      windowSize := frameContentSize;

    zfhPtr^.frameType := ZSTD_frame;
    zfhPtr^.frameContentSize := frameContentSize;
    zfhPtr^.windowSize := windowSize;
    zfhPtr^.blockSizeMax :=  MIN(windowSize, UInt64(ZSTD_BLOCKSIZE_MAX));
    zfhPtr^.dictID := dictID;
    zfhPtr^.checksumFlag := checksumFlag;

    exit(0);
end;

{* ZSTD_getFrameHeader() :
 *  decode Frame Header, or require larger `srcSize`.
 *  note : this function does not consume input, it only reads it.
 * @return : 0, `zfhPtr` is correctly filled,
 *          >0, `srcSize` is too small, value is wanted `srcSize` amount,
 *           or an error code, which can be tested using ZSTD_isError() }
function ZSTD_getFrameHeader(zfhPtr:pZSTD_frameHeader; const src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_getFrameHeader_advanced(zfhPtr, src, srcSize, ZSTD_f_zstd1);
end;


{* ZSTD_getFrameContentSize() :
 *  compatible with legacy mode
 * @return : decompressed size of the single frame pointed to be `src` if known, otherwise
 *         - ZSTD_CONTENTSIZE_UNKNOWN if the size cannot be determined
 *         - ZSTD_CONTENTSIZE_ERROR if an error occurred (e.g. invalid magic number, srcSize too small) }
function ZSTD_getFrameContentSize(const src:pbyte;srcSize:int32):Uint64;
var
  ret:Uint64;
  zfh:ZSTD_frameHeader;
begin
    //if (ZSTD_isLegacy(src, srcSize)) then
    //begin
    //  ret := ZSTD_getDecompressedSize_legacy(src, srcSize);
    //  if ret = 0 then
    //    exit(ZSTD_CONTENTSIZE_UNKNOWN)
    //  else
    //    exit(ret);
    //end;


    if (ZSTD_getFrameHeader( @zfh, src, srcSize) <> 0) then
        exit(ZSTD_CONTENTSIZE_ERROR);
    if (zfh.frameType = ZSTD_skippableFrame) then
    begin
        exit(0);
    end
    else 
    begin
        result := zfh.frameContentSize;
    end;
end;

function readSkippableFrameSize(src:pbyte;srcSize:int32):int32;
var
  skippableHeaderSize,skippableSize:int32;
  sizeUint32:Uint32;
begin
    skippableHeaderSize := ZSTD_SKIPPABLEHEADERSIZE;

    if (srcSize < ZSTD_SKIPPABLEHEADERSIZE) then
      exit(ERROR(srcSize_wrong));

    sizeUint32 := MEM_readLE32(src + ZSTD_FRAMEIDSIZE);
    if (Uint32(sizeUint32 + ZSTD_SKIPPABLEHEADERSIZE) < sizeUint32) then
    exit(ERROR(frameParameter_unsupported));
    
    skippableSize := skippableHeaderSize + sizeUint32;
    if (skippableSize > srcSize) then
      exit(ERROR(srcSize_wrong));
    result := skippableSize;    
end;

{* ZSTD_findDecompressedSize() :
 *  compatible with legacy mode
 *  `srcSize` must be the exact length of some number of ZSTD compressed and/or
 *      skippable frames
 *  @return : decompressed size of the frames contained }
function ZSTD_findDecompressedSize(src:pbyte;srcSize:int32):Uint64;
var
  totalDstSize,ret:Uint64;
  magicNumber:Uint32;
  skippableSize,frameSrcSize:int32;
begin
    totalDstSize := 0;

    while (srcSize >= ZSTD_startingInputLength(ZSTD_f_zstd1)) do
    begin
        magicNumber := MEM_readLE32(src);

        if ((magicNumber  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
        begin
            skippableSize := readSkippableFrameSize(src, srcSize);
            if (ZSTD_isError(skippableSize)<>0) then
            begin
                exit(ZSTD_CONTENTSIZE_ERROR);
            end;
            assert(skippableSize <= srcSize);

            src := src + skippableSize;
            srcSize :=srcSize - skippableSize;
            continue;
        end;

        ret := ZSTD_getFrameContentSize(src, srcSize);
        if (ret >= ZSTD_CONTENTSIZE_ERROR) then
          exit(ret);

        { check for overflow }
        if (totalDstSize + ret < totalDstSize) then
          exit(ZSTD_CONTENTSIZE_ERROR);
        totalDstSize :=totalDstSize + ret;
        
        frameSrcSize := ZSTD_findFrameCompressedSize(src, srcSize);
        if (ZSTD_isError(frameSrcSize)<>0) then
        begin
            exit(ZSTD_CONTENTSIZE_ERROR);
        end;

        src := src + frameSrcSize;
        srcSize :=srcSize - frameSrcSize;
    end;  { while (srcSize >= ZSTD_frameHeaderSize_prefix) }

    if (srcSize<>0) then
      exit(ZSTD_CONTENTSIZE_ERROR);

    result := totalDstSize;
end;

{* ZSTD_getDecompressedSize() :
 *  compatible with legacy mode
 * @return : decompressed size if known, 0 otherwise
             note : 0 can mean any of the following :
                   - frame content is empty
                   - decompressed size field is not present in frame header
                   - frame header unknown / not supported
                   - frame header not complete (`srcSize` too small) }
function ZSTD_getDecompressedSize(const src:pbyte;srcSize:int32):Uint64;
var
  ret:Uint64;
begin
    ret := ZSTD_getFrameContentSize(src, srcSize);
    ASSERT(ZSTD_CONTENTSIZE_ERROR < ZSTD_CONTENTSIZE_UNKNOWN);
    if (ret >= ZSTD_CONTENTSIZE_ERROR) then
      result :=  0
    else
      result := ret;
end;


{* ZSTD_decodeFrameHeader() :
 * `headerSize` must be the size provided by ZSTD_frameHeaderSize().
 * @return : 0 if success, or an error code, which can be tested using ZSTD_isError() }
function ZSTD_decodeFrameHeader(dctx:pZSTD_DCtx; const src:pbyte;headerSize:int32):int32;
begin
    result := ZSTD_getFrameHeader_advanced( @(dctx^.fParams), src, headerSize, dctx^.format);
    if (ZSTD_isError(result)<>0) then
      exit(result);    { invalid header }
    if (result>0) then
      exit(ERROR(srcSize_wrong));// 'headerSize too small');
    if (dctx^.fParams.checksumFlag<>0) and (ord(dctx^.forceIgnoreChecksum)=0) then
      dctx^.validateChecksum :=  1
    ELSE
      dctx^.validateChecksum :=  0;
    if (dctx^.validateChecksum<>0) then
      XXH64_reset( @dctx^.xxhState, 0);
    exit(0);
end;

function ZSTD_errorFrameSizeInfo(ret:int32):ZSTD_frameSizeInfo;
var
  frameSizeInfo:ZSTD_frameSizeInfo;
begin
    frameSizeInfo.compressedSize := ret;
    frameSizeInfo.decompressedBound := ZSTD_CONTENTSIZE_ERROR;
    result := frameSizeInfo;
end;

function ZSTD_findFrameSizeInfo(const src:pbyte;srcSize:int32):ZSTD_frameSizeInfo;
var
  frameSizeInfo:ZSTD_frameSizeInfo;
  ip,ipstart:pbyte;
  remainingSize,nbBlocks,ret:int32;
  zfh:ZSTD_frameHeader;
  blockProperties:blockProperties_t;
  cBlockSize:int32;
begin
    fillbyte( frameSizeInfo, sizeof(ZSTD_frameSizeInfo), 0);
    //if (ZSTD_isLegacy(src, srcSize)) then
    //    exit(ZSTD_findFrameSizeInfoLegacy(src, srcSize));

    if ((srcSize >= ZSTD_SKIPPABLEHEADERSIZE) 
        and ((MEM_readLE32(src)<>0)  and  (ZSTD_MAGIC_SKIPPABLE_MASK = ZSTD_MAGIC_SKIPPABLE_START))) then
    begin
        frameSizeInfo.compressedSize := readSkippableFrameSize(src, srcSize);
        assert((ZSTD_isError(frameSizeInfo.compressedSize)<>0)  or 
               (frameSizeInfo.compressedSize <= srcSize));
        exit(frameSizeInfo);
    end
    else 
    begin
        ip := src;
        ipstart := ip;
        remainingSize := srcSize;
        nbBlocks := 0;
        

        { Extract Frame Header }
        ret := ZSTD_getFrameHeader( @zfh, src, srcSize);
        if (ZSTD_isError(ret)<>0) then
            exit(ZSTD_errorFrameSizeInfo(ret));
        if (ret > 0) then
            exit(ZSTD_errorFrameSizeInfo(ERROR(srcSize_wrong)));
        

        ip :=ip + zfh.headerSize;
        remainingSize :=remainingSize - zfh.headerSize;

        { Iterate over each block }
        while (true) do
        begin
            cBlockSize := ZSTD_getcBlockSize(ip, remainingSize,  @blockProperties);
            if (ZSTD_isError(cBlockSize)<>0) then
                exit(ZSTD_errorFrameSizeInfo(cBlockSize));

            if (ZSTD_blockHeaderSize + cBlockSize > remainingSize) then
                exit(ZSTD_errorFrameSizeInfo(ERROR(srcSize_wrong)));

            ip :=ip + ZSTD_blockHeaderSize + cBlockSize;
            remainingSize :=remainingSize - ZSTD_blockHeaderSize + cBlockSize;
            inc(nbBlocks);

            if (blockProperties.lastBlock<>0) then
              break;
        end;

        { Final frame content checksum }
        if (zfh.checksumFlag<>0) then
        begin
            if (remainingSize < 4) then
                exit(ZSTD_errorFrameSizeInfo(ERROR(srcSize_wrong)));
            ip :=ip + 4;
        end;

        frameSizeInfo.compressedSize := int32(ip - ipstart);
        if (zfh.frameContentSize <> ZSTD_CONTENTSIZE_UNKNOWN) then
          frameSizeInfo.decompressedBound := zfh.frameContentSize
        else
          frameSizeInfo.decompressedBound := nbBlocks * zfh.blockSizeMax;
        result := frameSizeInfo;
    end;
end;

{* ZSTD_findFrameCompressedSize() :
 *  compatible with legacy mode
 *  `src` must point to the start of a ZSTD frame, ZSTD legacy frame, or skippable frame
 *  `srcSize` must be at least as large as the frame contained
 *  @return : the compressed size of the frame starting at `src` }
function ZSTD_findFrameCompressedSize(const src:pbyte;srcSize:int32):int32;
var
  frameSizeInfo:ZSTD_frameSizeInfo;
begin
  frameSizeInfo := ZSTD_findFrameSizeInfo(src, srcSize);
  result := frameSizeInfo.compressedSize;
end;

{* ZSTD_decompressBound() :
 *  compatible with legacy mode
 *  `src` must point to the start of a ZSTD frame or a skippeable frame
 *  `srcSize` must be at least as large as the frame contained
 *  @return : the maximum decompressed size of the compressed source
 }
function ZSTD_decompressBound(src:pbyte;srcSize:int32):Uint64;
var
  bound,decompressedBound:Uint64;
  frameSizeInfo:ZSTD_frameSizeInfo;
  compressedSize:int32;
begin
    bound := 0;
    { Iterate over each frame }
    while (srcSize > 0) do
    begin
        frameSizeInfo := ZSTD_findFrameSizeInfo(src, srcSize);
        compressedSize := frameSizeInfo.compressedSize;
        decompressedBound := frameSizeInfo.decompressedBound;
        if (ZSTD_isError(compressedSize)<>0)  or  (decompressedBound = ZSTD_CONTENTSIZE_ERROR) then
            exit(ZSTD_CONTENTSIZE_ERROR);
        assert(srcSize >= compressedSize);
        src := src + compressedSize;
        srcSize :=srcSize - compressedSize;
        bound :=bound + decompressedBound;
    end;
    result := bound;
end;


{-*************************************************************
 *   Frame decoding
 **************************************************************}

{* ZSTD_insertBlock() :
 *  insert `src` block into `dctx` history. Useful to track uncompressed blocks. }
function ZSTD_insertBlock(dctx:pZSTD_DCtx; const blockStart:pbyte;blockSize:int32):int32;
begin
    //log(3,  'ZSTD_insertBlock: %u bytes', blockSize);
    ZSTD_checkContinuity(dctx, blockStart);
    dctx^.previousDstEnd := blockStart + blockSize;
    result := blockSize;
end;


function ZSTD_copyRawBlock(dst:pbyte;dstCapacity:int32
                          ;src:pbyte;srcSize:int32):int32;
begin
    //log(3,  'ZSTD_copyRawBlock');
    IF (srcSize > dstCapacity) then 
      exit(ERROR(dstint32ooSmall));
    if (dst = nil) then
    begin
        if (srcSize = 0) then
          exit(0);
        exit(ERROR(dstBuffer_nil));
    end;
    move(src^,dst^,  srcSize);
    result := srcSize;
end;

function ZSTD_setRleBlock(dst:pbyte;dstCapacity:int32;b:BYTE;regenSize:int32 ):int32;
begin
    IF (regenSize > dstCapacity) then
      exit(ERROR(dstint32ooSmall));
    if (dst = nil) then
    begin
        if (regenSize = 0) then
          exit(0);
        exit(ERROR(dstBuffer_nil));
    end;
    fillbyte(dst^, regenSize, b);
    result := regenSize;
end;


{! ZSTD_decompressFrame() :
 * @dctx must be properly initialized
 *  will update *srcPtr and *srcSizePtr,
 *  to make *srcPtr progress by one frame. }
function ZSTD_decompressFrame(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
                             const srcPtr:ppbyte;srcSizePtr:pint32):int32;
var
  ip,ostart,oend,op:pbyte;
  remainingSrcSize,frameHeaderSize:int32;
  decodedSize,cBlockSize,err:int32;
  blockProperties:blockProperties_t;
  checkCalc,checkRead:Uint32;
begin
    ip := srcPtr^;
    ostart := dst;
    if dstCapacity <> 0 then
      oend :=  ostart + dstCapacity
    else
      oend :=  ostart;
    op := ostart;
    remainingSrcSize := srcSizePtr^;

    //log(3,  'ZSTD_decompressFrame (srcSize:%i)', srcSizePtr^);

    { check }
    IF (remainingSrcSize < ZSTD_FRAMEHEADERSIZE_MIN(dctx^.format)+ZSTD_blockHeaderSize) then
        exit(ERROR(srcSize_wrong));

    { Frame Header }
    frameHeaderSize := ZSTD_frameHeaderSize_internal(
                ip, ZSTD_FRAMEHEADERSIZE_PREFIX(dctx^.format), dctx^.format);
    if (ZSTD_isError(frameHeaderSize)<>0) then
      exit(frameHeaderSize);
    IF (remainingSrcSize < frameHeaderSize+ZSTD_blockHeaderSize) then
      exit(ERROR(srcSize_wrong));
    err:=ZSTD_decodeFrameHeader(dctx, ip, frameHeaderSize);
    if (ERR_isError(err)<>0) then
      exit(err);
    ip :=ip + frameHeaderSize;
    remainingSrcSize :=remainingSrcSize - frameHeaderSize;

    { Loop on each block }
    while (true) do
    begin
        cBlockSize := ZSTD_getcBlockSize(ip, remainingSrcSize,  @blockProperties);
        if (ZSTD_isError(cBlockSize)<>0) then
          exit(cBlockSize);

        ip :=ip + ZSTD_blockHeaderSize;
        remainingSrcSize :=remainingSrcSize - ZSTD_blockHeaderSize;
        IF (cBlockSize > remainingSrcSize) then
         exit(ERROR(srcSize_wrong));

        case(blockProperties.blockType) of
          bt_compressed:
          begin
            decodedSize := ZSTD_decompressBlock_internal(dctx, op, int32(oend-op), ip, cBlockSize, { frame } 1);
          end;
          bt_raw :
            decodedSize := ZSTD_copyRawBlock(op, int32(oend-op), ip, cBlockSize);

          bt_rle :
            decodedSize := ZSTD_setRleBlock(op, int32(oend-op), ip^, blockProperties.origSize);

          bt_reserved :
          else
            exit(ERROR(corruption_detected));//, 'invalid block type');
        end;

        if (ZSTD_isError(decodedSize)<>0) then
          exit(decodedSize);
        if (dctx^.validateChecksum<>0) then
            XXH64_update( @dctx^.xxhState, op, decodedSize);
        if (decodedSize <> 0) then
            op :=op + decodedSize;
        assert(ip <> nil);
        ip :=ip + cBlockSize;
        remainingSrcSize :=remainingSrcSize - cBlockSize;
        if (blockProperties.lastBlock<>0) then
          break;
    end;

    if (dctx^.fParams.frameContentSize <> ZSTD_CONTENTSIZE_UNKNOWN) then
    begin
        IF( Uint64(op-ostart) <> dctx^.fParams.frameContentSize) then
          exit(ERROR(corruption_detected));
    end;
    if (dctx^.fParams.checksumFlag<>0) then
    begin { Frame content checksum verification }
        IF (remainingSrcSize<4) then
          exit(ERROR(checksum_wrong));
        if (ord(dctx^.forceIgnoreChecksum)=0) then
        begin
            checkCalc := Uint32(XXH64_digest(@dctx^.xxhState));
            checkRead := MEM_readLE32(ip);
            IF (checkRead <> checkCalc) then 
              exit(ERROR(checksum_wrong));
        end;
        ip :=ip + 4;
        remainingSrcSize :=remainingSrcSize - 4;
    end;

    { Allow caller to get size read }
    srcPtr^ := ip;
    srcSizePtr^ := remainingSrcSize;
    result := int32(op-ostart);
end;

function ZSTD_decompressMultiFrame(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  src:pbyte;srcSize:int32;dict:pbyte;dictSize:int32;const ddict:pZSTD_DDict):int32;
var
  dststart:pbyte;
  moreThan1Frame:int32;
  decodedSize,frameSize,skippableSize:int32;
  magicNumber:Uint32;
  res,err:int32;
begin
    dststart := dst;
    moreThan1Frame := 0;

    //log(3,  'ZSTD_decompressMultiFrame');
    assert((dict=nil)  or  (ddict=nil));  { either dict or ddict set, not both }

    if (ddict<>nil) then
    begin
        dict := ZSTD_DDict_dictContent(ddict);
        dictSize := ZSTD_DDict_dictSize(ddict);
    end;

    while (srcSize >= ZSTD_startingInputLength(dctx^.format)) do
    begin

        //if (ZSTD_isLegacy(src, srcSize)) then
        //begin
        //    frameSize := ZSTD_findFrameCompressedSizeLegacy(src, srcSize);
        //    if (ZSTD_isError(frameSize)<>0) then
        //      exit(frameSize);
        //    IF (dctx^.staticSize<>0) then
        //      exit(ERROR(memory_allocation));//'legacy support is not compatible with static dctx');
        //
        //    decodedSize := ZSTD_decompressLegacy(dst, dstCapacity, src, frameSize, dict, dictSize);
        //    if (ZSTD_isError(decodedSize)<>0) then
        //      exit(decodedSize);
        //
        //    assert(decodedSize <= dstCapacity);
        //    dst := dst + decodedSize;
        //    dstCapacity :=dstCapacity - decodedSize;
        //
        //    src := src + frameSize;
        //    srcSize :=srcSize - frameSize;
        //
        //    continue;
        //end;

        magicNumber := MEM_readLE32(src);
        //log(3,  'reading magic number %08X (expecting %08X)',
        //            magicNumber, ZSTD_MAGICNUMBER);
        if ((magicNumber  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
        begin
            skippableSize := readSkippableFrameSize(src, srcSize);
            //FORWARD_IF_ERROR(skippableSize, 'readSkippableFrameSize failed');
            if (ERR_isError(skippableSize)<>0) then
        			exit(err);
            assert(skippableSize <= srcSize);

            src := src + skippableSize;
            srcSize :=srcSize - skippableSize;
            continue;
        end;

        if (ddict<>nil) then
        begin
            { we were called from ZSTD_decompress_usingDDict }
            err:=ZSTD_decompressBegin_usingDDict(dctx, ddict);
            if (ERR_isError(err)<>0) then
        			exit(err);
        end
        else 
        begin
            { this will initialize correctly with no dict if dict = nil, so
             * use this in all cases but ddict }
            err:=ZSTD_decompressBegin_usingDict(dctx, dict, dictSize);
            if (ERR_isError(err)<>0) then
        			exit(err);
        end;
        ZSTD_checkContinuity(dctx, dst);

        res := ZSTD_decompressFrame(dctx, dst, dstCapacity,
                                                     @src,  @srcSize);
        IF( (ZSTD_getErrorCode(res) = ZSTD_ErrorCode.prefix_unknown) and (moreThan1Frame=1)) then
            exit(ERROR(srcSize_wrong));
            {
            'At least one frame successfully completed, '
            'but following bytes are garbage: '
            'it's more likely to be a srcSize error, '
            'specifying more input bytes than size of frame(s). '
            'Note: one could be unlucky, it might be a corruption error instead, '
            'happening right at the place where we expect zstd magic bytes. '
            'But this is _much_ less likely than a srcSize field error.');
            }
        if (ZSTD_isError(res)<>0) then
          exit(res);
        assert(res <= dstCapacity);
        if (res <> 0) then
            dst := dst + res;
        dstCapacity :=dstCapacity - res;
        
        moreThan1Frame := 1;
    end;  { while (srcSize >= ZSTD_frameHeaderSize_prefix) }

    IF (srcSize<>0) then 
      exit(ERROR(srcSize_wrong));// 'input not entirely consumed');

    result := int32(dst - dststart);
end;

function ZSTD_decompress_usingDict(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;
  const src:pbyte;srcSize:int32;const dict:pbyte;dictSize:int32):int32;
begin
    result := ZSTD_decompressMultiFrame(dctx, dst, dstCapacity, src, srcSize, dict, dictSize, nil);
end;


function ZSTD_getDDict(dctx:pZSTD_DCtx):pZSTD_DDict;
begin
    case (dctx^.dictUses) of

        { fall-through }
      ZSTD_dont_use:
      begin
        ZSTD_clearDict(dctx);
        exit(nil);
      end;
      ZSTD_use_indefinitely:
        exit(dctx^.ddict);
      ZSTD_use_once:
      begin
        dctx^.dictUses := ZSTD_dont_use;
        exit(dctx^.ddict);
      end;
    end;
end;

function ZSTD_decompressDCtx(dctx:pZSTD_DCtx; dst:pbyte;dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_decompress_usingDDict(dctx, dst, dstCapacity, src, srcSize, ZSTD_getDDict(dctx));
end;


function ZSTD_decompress(dst:pbyte;dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
var
  regenSize:int32;
  dctx:pZSTD_DCtx;
begin
    dctx := ZSTD_createDCtx();
    IF (dctx=nil) then 
      exit(ERROR(memory_allocation));// 'nil pointer!');
    regenSize := ZSTD_decompressDCtx(dctx, dst, dstCapacity, src, srcSize);
    ZSTD_freeDCtx(dctx);
    result := regenSize;
end;


{-**************************************
*   Advanced Streaming Decompression API
*   Bufferless and synchronous
***************************************}
function ZSTD_nextSrcSizeToDecompress(dctx:pZSTD_DCtx):int32; 
begin 
  result := dctx^.expected; 
end;

{*
 * Similar to ZSTD_nextSrcSizeToDecompress(), but when when a block input can be streamed,
 * we allow taking a partial block as the input. Currently only raw uncompressed blocks can
 * be streamed.
 *
 * For blocks that can be streamed, this allows us to reduce the latency until we produce
 * output, and avoid copying the input.
 *
 * @param inputSize - The total amount of input that the caller currently has.
 }
function ZSTD_nextSrcSizeToDecompressWithInputSize(dctx:pZSTD_DCtx; inputSize:int32 ) :int32; 
begin
    if (not ((dctx^.stage = ZSTDds_decompressBlock)  or  (dctx^.stage = ZSTDds_decompressLastBlock))) then
        exit(dctx^.expected);
    if (dctx^.bType <> bt_raw) then
        exit(dctx^.expected);
    result := MIN(MAX(inputSize, 1), dctx^.expected);
end;

function ZSTD_nextInputType(dctx:pZSTD_DCtx):ZSTD_nextInputType_e; 
begin
    case(dctx^.stage) of
      //else:   { should not happen }
      //  assert(false);
      ZSTDds_getFrameHeaderSize,
      ZSTDds_decodeFrameHeader:
        exit(ZSTDnit_frameHeader);
      ZSTDds_decodeBlockHeader:
        exit(ZSTDnit_blockHeader);
      ZSTDds_decompressBlock:
        exit(ZSTDnit_block);
      ZSTDds_decompressLastBlock:
        exit(ZSTDnit_lastBlock);
      ZSTDds_checkChecksum:
        exit(ZSTDnit_checksum);
      ZSTDds_decodeSkippableHeader,
      ZSTDds_skipFrame:
        exit(ZSTDnit_skippableFrame);
    end;
end;

function ZSTD_isSkipFrame(dctx:pZSTD_DCtx) :int32;
begin 
  result := ord(dctx^.stage = ZSTDds_skipFrame);
end;

{* ZSTD_decompressContinue() :
 *  srcSize : must be the exact nb of bytes expected (see ZSTD_nextSrcSizeToDecompress())
 *  @return : nb of bytes generated into `dst` (necessarily <= `dstCapacity)
 *            or an error code, which can be tested using ZSTD_isError() }
function ZSTD_decompressContinue(dctx:pZSTD_DCtx; dst:pbyte;dstCapacity:int32; const src:pbyte;srcSize:int32):int32;
var
  bp:blockProperties_t;
  cBlockSize,rSize,err:int32;
  h32,check32:uint32;
begin
    //log(3,  'ZSTD_decompressContinue (srcSize:%u)', srcSize);
    { Sanity check }
    IF (srcSize <> ZSTD_nextSrcSizeToDecompressWithInputSize(dctx, srcSize)) then 
      exit(ERROR(srcSize_wrong));// 'not allowed');
    if (dstCapacity<>0) then
      ZSTD_checkContinuity(dctx, dst);

    case (dctx^.stage) of
      ZSTDds_getFrameHeaderSize :
      begin
        assert(src <> nil);
        if (dctx^.format = ZSTD_f_zstd1) then
        begin  { allows header }
            assert(srcSize >= ZSTD_FRAMEIDSIZE);  { to read skippable magic number }
            if ((MEM_readLE32(src)  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
            begin        { skippable frame }
                move(src^,dctx^.headerBuffer,  srcSize);
                dctx^.expected := ZSTD_SKIPPABLEHEADERSIZE - srcSize;  { remaining to load to get full skippable frame header }
                dctx^.stage := ZSTDds_decodeSkippableHeader;
                exit(0);
            end;   
        end;
        dctx^.headerSize := ZSTD_frameHeaderSize_internal(src, srcSize, dctx^.format);
        if (ZSTD_isError(dctx^.headerSize)<>0) then
          exit(dctx^.headerSize);
        move( src^, dctx^.headerBuffer,srcSize);
        dctx^.expected := dctx^.headerSize - srcSize;
        dctx^.stage := ZSTDds_decodeFrameHeader;
        exit(0);
      end;
      ZSTDds_decodeFrameHeader:
      begin
        assert(src <> nil);
        move( src^, dctx^.headerBuffer [dctx^.headerSize - srcSize],srcSize);
        err:=ZSTD_decodeFrameHeader(dctx, dctx^.headerBuffer, dctx^.headerSize);
        if (ERR_isError(err)<>0) then
    			exit(err);
        dctx^.expected := ZSTD_blockHeaderSize;
        dctx^.stage := ZSTDds_decodeBlockHeader;
        exit(0);
      end;
      ZSTDds_decodeBlockHeader:
      begin   
          cBlockSize := ZSTD_getcBlockSize(src, ZSTD_blockHeaderSize,  @bp);
          if (ZSTD_isError(cBlockSize)<>0) then
            exit(cBlockSize);
          IF (cBlockSize > dctx^.fParams.blockSizeMax) then
            exit(ERROR(corruption_detected));// 'Block Size Exceeds Maximum');
          dctx^.expected := cBlockSize;
          dctx^.bType := bp.blockType;
          dctx^.rleSize := bp.origSize;
          if (cBlockSize<>0) then
          begin
              if bp.lastBlock<>0 then
                dctx^.stage := ZSTDds_decompressLastBlock
              else
                dctx^.stage := ZSTDds_decompressBlock;
              exit(0);
          end;
          { empty block }
          if (bp.lastBlock<>0) then
          begin
              if (dctx^.fParams.checksumFlag<>0) then
              begin
                  dctx^.expected := 4;
                  dctx^.stage := ZSTDds_checkChecksum;
              end
              else
              begin
                  dctx^.expected := 0; { end of frame }
                  dctx^.stage := ZSTDds_getFrameHeaderSize;
              end;
          end
          else
          begin
              dctx^.expected := ZSTD_blockHeaderSize;  { jump to next header }
              dctx^.stage := ZSTDds_decodeBlockHeader;
          end;
          exit(0);
      end;

      ZSTDds_decompressLastBlock,
      ZSTDds_decompressBlock:
      begin
          //log(3,  'ZSTD_decompressContinue: case ZSTDds_decompressBlock');
          
          case(dctx^.bType) of
            bt_compressed:
            begin
              //log(3,  'ZSTD_decompressContinue: case bt_compressed');
              rSize := ZSTD_decompressBlock_internal(dctx, dst, dstCapacity, src, srcSize, { frame } 1);
              dctx^.expected := 0;  { Streaming not supported }
            end;
            bt_raw :
            begin
              assert(srcSize <= dctx^.expected);
              rSize := ZSTD_copyRawBlock(dst, dstCapacity, src, srcSize);
              //FORWARD_IF_ERROR(rSize, 'ZSTD_copyRawBlock failed');
              if (ERR_isError(rSize)<>0) then
          			exit(rSize);
              assert(rSize = srcSize);
              dctx^.expected :=dctx^.expected - rSize;
            end;
            bt_rle :
            begin
              rSize := ZSTD_setRleBlock(dst, dstCapacity, src^, dctx^.rleSize);
              dctx^.expected := 0;  { Streaming not supported }
            end;
            //bt_reserved;   { should never happen }
            //else
            //  exit(ERROR(corruption_detected));//, 'invalid block type');
          end;
          if (ERR_isError(rSize)<>0) then
            exit(rSize);
          IF (rSize > dctx^.fParams.blockSizeMax) then
           exit(ERROR(corruption_detected));// 'Decompressed Block Size Exceeds Maximum');
          //log(3,  'ZSTD_decompressContinue: decoded size from block : %u', rSize);
          dctx^.decodedSize :=dctx^.decodedSize + rSize;
          if (dctx^.validateChecksum<>0) then
            XXH64_update( @dctx^.xxhState, dst, rSize);
          dctx^.previousDstEnd := dst + rSize;

          { Stay on the same stage until we are finished streaming the block. }
          if (dctx^.expected > 0) then
          begin
              exit(rSize);
          end;

          if (dctx^.stage = ZSTDds_decompressLastBlock) then
          begin   { end of frame }
              //log(3,  'ZSTD_decompressContinue: decoded size from frame : %u', dctx^.decodedSize);
              IF (dctx^.fParams.frameContentSize <> ZSTD_CONTENTSIZE_UNKNOWN)
               and (dctx^.decodedSize <> dctx^.fParams.frameContentSize) then
                exit(ERROR(corruption_detected));
              if (dctx^.fParams.checksumFlag<>0) then
              begin  { another round for frame checksum }
                  dctx^.expected := 4;
                  dctx^.stage := ZSTDds_checkChecksum;
              end
              else 
              begin
                  dctx^.expected := 0;   { ends here }
                  dctx^.stage := ZSTDds_getFrameHeaderSize;
              end;
          end
          else 
          begin
              dctx^.stage := ZSTDds_decodeBlockHeader;
              dctx^.expected := ZSTD_blockHeaderSize;
          end;
          exit(rSize);
      end;

      ZSTDds_checkChecksum:
        begin
            assert(srcSize = 4);  { guaranteed by dctx^.expected }
            if (dctx^.validateChecksum<>0) then
            begin
                h32 := XXH64_digest( @dctx^.xxhState);
                check32 := MEM_readLE32(src);
                //log(3,  'ZSTD_decompressContinue: checksum : calculated %08X :: %08X read', h32, check32);
                IF (check32 <> h32) then 
                  exit(ERROR(checksum_wrong));
            end;
            dctx^.expected := 0;
            dctx^.stage := ZSTDds_getFrameHeaderSize;
            exit(0);
        end;

      ZSTDds_decodeSkippableHeader:
      begin
        assert(src <> nil);
        assert(srcSize <= ZSTD_SKIPPABLEHEADERSIZE);
        move( src, dctx^.headerBuffer [(ZSTD_SKIPPABLEHEADERSIZE - srcSize)],srcSize);   { complete skippable header }
        dctx^.expected := MEM_readLE32(@dctx^.headerBuffer[ZSTD_FRAMEIDSIZE]);   { note : dctx^.expected can grow seriously large, beyond local buffer size }
        dctx^.stage := ZSTDds_skipFrame;
        exit(0);
      end;
      ZSTDds_skipFrame:
      begin
        dctx^.expected := 0;
        dctx^.stage := ZSTDds_getFrameHeaderSize;
        exit(0);
      end;
      else
      begin
        assert(false);   { impossible }
        exit(ERROR(GENERIC_ERROR));// 'impossible to reach');   { some compiler require default to do something }
      end;
    end;
end;


function ZSTD_refDictContent(dctx:pZSTD_DCtx; const dict:pbyte;dictSize:int32):int32;
begin
    dctx^.dictEnd := dctx^.previousDstEnd;
    dctx^.virtualStart := dict - ((dctx^.previousDstEnd) - (dctx^.prefixStart));
    dctx^.prefixStart := dict;
    dctx^.previousDstEnd := dict + dictSize;
    exit(0);
end;

{! ZSTD_loadDEntropy() :
 *  dict : must point at beginning of a valid zstd dictionary.
 * @return : size of entropy tables read }
function ZSTD_loadDEntropy(entropy:pZSTD_entropyDTables_t;dict:pbyte; dictSize:int32):int32;
var
  dictPtr,dictEnd,workspace:pbyte;
  workspaceSize,hSize:int32;
  offcodeNCount:array[0..MaxOff] of smallint;
  offcodeMaxValue,offcodeLog:uint32;
  offcodeHeaderSize:int32;
  matchlengthNCount:array[0..MaxML] of smallint;
  matchlengthMaxValue,matchlengthLog:uint32;
  matchlengthHeaderSize:int32;
  litlengthNCount:array[0..MaxLL] of smallint;
  litlengthHeaderSize,rep,litlengthLog,litlengthMaxValue:uint32;
  i,dictContentSize:int32;
begin
    dictPtr := dict;
    dictEnd := dictPtr + dictSize;

    IF(dictSize <= 8) then 
    exit(ERROR(dictionary_corrupted));// 'dict is too small');
    assert(MEM_readLE32(dict) = ZSTD_MAGIC_DICTIONARY);   { dict must be valid }
    dictPtr :=dictPtr + 8;   { skip header := magic + dictID }

    //ASSERT(offsetof(ZSTD_entropyDTables_t, OFTable) = offsetof(ZSTD_entropyDTables_t, LLTable) + sizeof(entropy^.LLTable));
    //ASSERT(offsetof(ZSTD_entropyDTables_t, MLTable) = offsetof(ZSTD_entropyDTables_t, OFTable) + sizeof(entropy^.OFTable));
    //ASSERT(sizeof(entropy^.LLTable) + sizeof(entropy^.OFTable) + sizeof(entropy^.MLTable) >= HUF_DECOMPRESS_WORKSPACE_SIZE);
    workspace :=  @entropy^.LLTable;   { use fse tables as temporary workspace; implies fse tables are grouped together }
    workspaceSize := sizeof(entropy^.LLTable) + sizeof(entropy^.OFTable) + sizeof(entropy^.MLTable);
    hSize := HUF_readDTableX2_wksp(entropy^.hufTable,dictPtr, int32(dictEnd - dictPtr),workspace, workspaceSize);

    IF (ERR_isError(hSize)<>0) then
      exit(ERROR(dictionary_corrupted));
    dictPtr :=dictPtr + hSize;
    
    offcodeMaxValue := MaxOff;
    offcodeHeaderSize := FSE_readNCount(offcodeNCount,  @offcodeMaxValue,  @offcodeLog, dictPtr, int32(dictEnd-dictPtr));
    IF (FSE_isError(offcodeHeaderSize)<>0) then
      exit(ERROR(dictionary_corrupted));
    IF (offcodeMaxValue > MaxOff) then
      exit(ERROR(dictionary_corrupted));
    IF (offcodeLog > OffFSELog) then
      exit(ERROR(dictionary_corrupted));
    ZSTD_buildFSETable( entropy^.OFTable,
                        offcodeNCount, offcodeMaxValue,
                        OF_base, OF_bits,
                        offcodeLog,
                        @entropy^.workspace, sizeof(entropy^.workspace),
                        { bmi2 }0);
    dictPtr :=dictPtr + offcodeHeaderSize;
    
    matchlengthMaxValue := MaxML;
    matchlengthHeaderSize := FSE_readNCount(matchlengthNCount,  @matchlengthMaxValue,  @matchlengthLog, dictPtr, int32(dictEnd-dictPtr));
    IF (FSE_isError(matchlengthHeaderSize)<>0) then
      exit(ERROR(dictionary_corrupted));
    IF (matchlengthMaxValue > MaxML) then
      exit(ERROR(dictionary_corrupted));
    IF (matchlengthLog > MLFSELog) then
      exit(ERROR(dictionary_corrupted));
    ZSTD_buildFSETable( entropy^.MLTable,
                        matchlengthNCount, matchlengthMaxValue,
                        ML_base, ML_bits,
                        matchlengthLog,
                        @entropy^.workspace, sizeof(entropy^.workspace),
                        { bmi2 } 0);
    dictPtr :=dictPtr + matchlengthHeaderSize;
    
    litlengthMaxValue := MaxLL;
    litlengthHeaderSize := FSE_readNCount(litlengthNCount,  @litlengthMaxValue,  @litlengthLog, dictPtr, int32(dictEnd-dictPtr));
    IF (FSE_isError(litlengthHeaderSize)<>0) then
      exit(ERROR(dictionary_corrupted));
    IF (litlengthMaxValue > MaxLL) then
      exit(ERROR(dictionary_corrupted));
    IF (litlengthLog > LLFSELog) then
      exit(ERROR(dictionary_corrupted));
    ZSTD_buildFSETable( entropy^.LLTable,
                        litlengthNCount, litlengthMaxValue,
                        LL_base, LL_bits,
                        litlengthLog,
                        @entropy^.workspace, sizeof(entropy^.workspace),
                        { bmi2 } 0);
    dictPtr :=dictPtr + litlengthHeaderSize;

    IF (dictPtr+12 > dictEnd) then
      exit(ERROR(dictionary_corrupted));

    dictContentSize := int32(dictEnd - (dictPtr+12));
    for i:=0 to 2 do
    begin
        rep := MEM_readLE32(dictPtr); 
        dictPtr :=dictPtr + 4;
        IF (rep=0)  or  (rep > dictContentSize) then
          exit(ERROR(dictionary_corrupted));
        entropy^.rep[i] := rep;
    end;

    result := int32(dictPtr - dict);
end;

function ZSTD_decompress_insertDictionary(dctx:pZSTD_DCtx; dict:pbyte;dictSize:int32):int32;
var
  magic:Uint32;
  eSize:int32;
begin
    if (dictSize < 8) then
      exit(ZSTD_refDictContent(dctx, dict, dictSize));
     
    magic := MEM_readLE32(dict);
    if (magic <> ZSTD_MAGIC_DICTIONARY) then
    begin
      exit(ZSTD_refDictContent(dctx, dict, dictSize));   { pure content mode }
    end;
    dctx^.dictID := MEM_readLE32(dict + ZSTD_FRAMEIDSIZE);

    { load entropy tables }
    eSize := ZSTD_loadDEntropy( @dctx^.entropy, dict, dictSize);
    IF (ZSTD_isError(eSize)<>0) then
      exit(ERROR(dictionary_corrupted));
    dict := dict + eSize;
    dictSize :=dictSize - eSize;
    dctx^.fseEntropy := 1;
    dctx^.litEntropy := 1;

    { reference dictionary content }
    result := ZSTD_refDictContent(dctx, dict, dictSize);
end;

function ZSTD_decompressBegin(dctx:pZSTD_DCtx):int32;
begin
    assert(dctx <> nil);
    dctx^.expected := ZSTD_startingInputLength(dctx^.format);  { dctx^.format must be properly set }
    dctx^.stage := ZSTDds_getFrameHeaderSize;
    dctx^.decodedSize := 0;
    dctx^.previousDstEnd := nil;
    dctx^.prefixStart := nil;
    dctx^.virtualStart := nil;
    dctx^.dictEnd := nil;
    dctx^.entropy.hufTable[0] := HUF_DTable((HufLog)*$1000001);  { cover both little and big endian }
    dctx^.fseEntropy := 0;
    dctx^.litEntropy := 0;
    dctx^.dictID := 0;
    dctx^.bType := bt_reserved;
    ASSERT(sizeof(dctx^.entropy.rep) = sizeof(repStartValue));
    move(repStartValue[0], dctx^.entropy.rep[0], sizeof(repStartValue));  { initial repcodes }
    dctx^.LLTptr := dctx^.entropy.LLTable;
    dctx^.MLTptr := dctx^.entropy.MLTable;
    dctx^.OFTptr := dctx^.entropy.OFTable;
    dctx^.HUFptr := dctx^.entropy.hufTable;
    exit(0);
end;

function ZSTD_decompressBegin_usingDict(dctx:pZSTD_DCtx; const dict:pbyte;dictSize:int32):int32;
var
  err:int32;
begin
    err:=ZSTD_decompressBegin(dctx);
    if (ERR_isError(err)<>0) then
			exit(err);
    if (dict<>nil) and (dictSize<>0) then
        IF (ZSTD_isError(ZSTD_decompress_insertDictionary(dctx, dict, dictSize))<>0) then
          exit(ERROR(dictionary_corrupted));
    exit(0);
end;


{ ===   ZSTD_DDict   === }

function ZSTD_decompressBegin_usingDDict(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict):int32;
var
  dictStart,dictEnd:pbyte;
  dictSize,err:int32;
begin
    //log(3,  'ZSTD_decompressBegin_usingDDict');
    assert(dctx <> nil);
    if (ddict<>nil) then
    begin
        dictStart := ZSTD_DDict_dictContent(ddict);
        dictSize := ZSTD_DDict_dictSize(ddict);
        dictEnd := dictStart + dictSize;
        dctx^.ddictIsCold := ord(dctx^.dictEnd <> dictEnd);
        if dctx^.ddictIsCold<>0 then
          //log(3,  'DDict is %s','~cold~')
        else
          //log(3,  'DDict is %s', 'hot!');
    end;
    err:= ZSTD_decompressBegin(dctx);
    if (ERR_isError(err)<>0) then
			exit(err);
    if (ddict<>nil) then
    begin   { nil ddict is equivalent to no dictionary }
        ZSTD_copyDDictParameters(dctx, ddict);
    end;
    exit(0);
end;

{! ZSTD_getDictID_fromDict() :
 *  Provides the dictID stored within dictionary.
 *  if @return = 0, the dictionary is not conformant with Zstandard specification.
 *  It can still be loaded, but as a content-only dictionary. }
function ZSTD_getDictID_fromDict(const dict:pbyte;dictSize:int32):uint32;
begin
    if (dictSize < 8) then
      exit(0);
    if (MEM_readLE32(dict) <> ZSTD_MAGIC_DICTIONARY) then
      exit(0);
    result := MEM_readLE32(dict + ZSTD_FRAMEIDSIZE);
end;

{! ZSTD_getDictID_fromFrame() :
 *  Provides the dictID required to decompress frame stored within `src`.
 *  If @return = 0, the dictID could not be decoded.
 *  This could for one of the following reasons :
 *  - The frame does not require a dictionary (most common case).
 *  - The frame was built with dictID intentionally removed.
 *    Needed dictionary is a hidden information.
 *    Note : this use case also happens when using a non-conformant dictionary.
 *  - `srcSize` is too small, and as a result, frame header could not be decoded.
 *    Note : possible if `srcSize < ZSTD_FRAMEHEADERSIZE_MAX`.
 *  - This is not a Zstandard frame.
 *  When identifying the exact failure cause, it's possible to use
 *  ZSTD_getFrameHeader(), which will provide a more precise error code. }
function ZSTD_getDictID_fromFrame(const src:pbyte;srcSize:int32):uint32;
var
  zfp:ZSTD_frameHeader;
  hError:int32;
begin
    fillbyte(zfp,sizeof(ZSTD_frameHeader),0);
    hError := ZSTD_getFrameHeader( @zfp, src, srcSize);
    if (ZSTD_isError(hError)<>0) then
      exit(0);
    result := zfp.dictID;
end;


{! ZSTD_decompress_usingDDict() :
*   Decompression using a pre-digested Dictionary
*   Use dictionary without significant overhead. }
function ZSTD_decompress_usingDDict(dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32
  ;src:pbyte;srcSize:int32;const ddict:pZSTD_DDict):int32;
begin
    { pass content and size in case legacy frames are encountered }
    result := ZSTD_decompressMultiFrame(dctx, dst, dstCapacity, src, srcSize,
                                     nil, 0,
                                     ddict);
end;


{==================:=
*   Streaming decompression
*==================}

function ZSTD_createDStream():pZSTD_DStream;
begin
    //log(3,  'ZSTD_createDStream');
    result := ZSTD_createDStream_advanced(ZSTD_defaultCMem);
end;

function ZSTD_initStaticDStream(workspace:pbyte;workspaceSize:int32):pZSTD_DStream;
begin
    result := ZSTD_initStaticDCtx(workspace, workspaceSize);
end;

function ZSTD_createDStream_advanced(customMem:ZSTD_customMem):pZSTD_DStream;
begin
    result := ZSTD_createDCtx_advanced(customMem);
end;

function ZSTD_freeDStream(zds:pZSTD_DStream):int32;
begin
    result := ZSTD_freeDCtx(zds);
end;


{ ***  Initialization  *** }

function ZSTD_DStreamInSize():int32;
begin 
  result := ZSTD_BLOCKSIZE_MAX + ZSTD_blockHeaderSize; 
end;
function ZSTD_DStreamOutSize():int32;
begin 
  result := ZSTD_BLOCKSIZE_MAX; 
end;

function ZSTD_DCtx_loadDictionary_advanced(dctx:pZSTD_DCtx;dict:pbyte;dictSize:int32;
  dictLoadMethod:ZSTD_dictLoadMethod_e;dictContentType:ZSTD_dictContentType_e):int32;
begin
    IF (dctx^.streamStage <> zdss_init) then
      exit(ERROR(stage_wrong));
    ZSTD_clearDict(dctx);
    if (dict<>nil) and (dictSize <> 0) then
    begin
        dctx^.ddictLocal := ZSTD_createDDict_advanced(dict, dictSize, dictLoadMethod, dictContentType, dctx^.customMem);
        if (dctx^.ddictLocal = nil) then 
          exit(ERROR(memory_allocation));// 'nil pointer!');
        dctx^.ddict := dctx^.ddictLocal;
        dctx^.dictUses := ZSTD_use_indefinitely;
    end;
    exit(0);
end;

function ZSTD_DCtx_loadDictionary_byReference(dctx:pZSTD_DCtx; const dict:pbyte;dictSize:int32):int32;
begin
    result := ZSTD_DCtx_loadDictionary_advanced(dctx, dict, dictSize, ZSTD_dlm_byRef, ZSTD_dct_auto);
end;

function ZSTD_DCtx_loadDictionary(dctx:pZSTD_DCtx; const dict:pbyte;dictSize:int32):int32;
begin
    result := ZSTD_DCtx_loadDictionary_advanced(dctx, dict, dictSize, ZSTD_dlm_byCopy, ZSTD_dct_auto);
end;

function ZSTD_DCtx_refPrefix_advanced(dctx:pZSTD_DCtx; prefix:pbyte; prefixSize:int32; dictContentType:ZSTD_dictContentType_e):int32;
var
  err:int32;
begin
    err:= ZSTD_DCtx_loadDictionary_advanced(dctx, prefix, prefixSize, ZSTD_dlm_byRef, dictContentType);
    if (ERR_isError(err)<>0) then
			exit(err);
    dctx^.dictUses := ZSTD_use_once;
    exit(0);
end;

function ZSTD_DCtx_refPrefix(dctx:pZSTD_DCtx; prefix:pbyte; prefixSize:int32 ):int32;
begin
    result := ZSTD_DCtx_refPrefix_advanced(dctx, prefix, prefixSize, ZSTD_dct_rawContent);
end;


{ ZSTD_initDStream_usingDict() :
 * return : expected size, aka ZSTD_startingInputLength().
 * this function cannot fail }
function ZSTD_initDStream_usingDict(zds:pZSTD_DStream; const dict:pbyte;dictSize:int32):int32;
var
  err:int32;
begin
    //log(3,  'ZSTD_initDStream_usingDict');
    err:=ZSTD_DCtx_reset(zds, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
			exit(err);    
    err:=ZSTD_DCtx_loadDictionary(zds, dict, dictSize);
    if (ERR_isError(err)<>0) then
			exit(err);
    result := ZSTD_startingInputLength(zds^.format);
end;

{ note : this variant can't fail }
function ZSTD_initDStream(zds:pZSTD_DStream):int32;
begin
    //log(3,  'ZSTD_initDStream');
    result := ZSTD_initDStream_usingDDict(zds, nil);
end;

{ ZSTD_initDStream_usingDDict() :
 * ddict will just be referenced, and must outlive decompression session
 * this function cannot fail }
function ZSTD_initDStream_usingDDict(dctx:pZSTD_DStream; const ddict:pZSTD_DDict):int32;
var
  err:int32;
begin
    err:=ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
			exit(err);
    err:=ZSTD_DCtx_refDDict(dctx, ddict);
    if (ERR_isError(err)<>0) then
			exit(err);
    result := ZSTD_startingInputLength(dctx^.format);
end;

{ ZSTD_resetDStream() :
 * return : expected size, aka ZSTD_startingInputLength().
 * this function cannot fail }
function ZSTD_resetDStream(dctx:pZSTD_DStream):int32;
var
  err:int32;
begin
    err:=ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only);
    if (ERR_isError(err)<>0) then
			exit(err);
    result := ZSTD_startingInputLength(dctx^.format);
end;


function ZSTD_DCtx_refDDict(dctx:pZSTD_DCtx; const ddict:pZSTD_DDict):int32;
begin
    IF (dctx^.streamStage <> zdss_init) then 
      exit(ERROR(stage_wrong));
    ZSTD_clearDict(dctx);
    if (ddict<>nil) then
    begin
        dctx^.ddict := ddict;
        dctx^.dictUses := ZSTD_use_indefinitely;
    end;
    exit(0);
end;

{ ZSTD_DCtx_setMaxWindowSize() :
 * note : no direct equivalence in ZSTD_DCtx_setParameter,
 * since this version sets windowSize, and the other sets windowLog }
function ZSTD_DCtx_setMaxWindowSize(dctx:pZSTD_DCtx; maxWindowSize:int32):int32;
var
  bounds:ZSTD_bounds;
  lmin,lmax:int32;
begin
    bounds := ZSTD_dParam_getBounds(ZSTD_d_windowLogMax);
    lmin := 1  shl  bounds.lowerBound;
    lmax := 1  shl  bounds.upperBound;
    if (dctx^.streamStage <> zdss_init) then 
    exit(ERROR(stage_wrong));
    if (maxWindowSize < lmin) then 
    exit(ERROR(parameter_outOfBound));
    if (maxWindowSize > lmax) then 
    exit(ERROR(parameter_outOfBound));
    dctx^.maxWindowSize := maxWindowSize;
    exit(0);
end;

function ZSTD_DCtx_setFormat(dctx:pZSTD_DCtx; format:ZSTD_format_e):int32;
begin
    result := ZSTD_DCtx_setParameter(dctx, ZSTD_d_format, ord(format));
end;

function ZSTD_dParam_getBounds(dParam:ZSTD_dParameter):ZSTD_bounds;
var
  bounds:ZSTD_bounds;
begin
    fillbyte(bounds,sizeof(ZSTD_bounds),0);
    case (dParam) of
        ZSTD_d_windowLogMax:
        begin
            bounds.lowerBound := ZSTD_WINDOWLOG_ABSOLUTEMIN;
            bounds.upperBound := ZSTD_WINDOWLOG_MAX;
            exit(bounds);
        end;
        ZSTD_d_format:
        begin
            bounds.lowerBound := int32(ZSTD_f_zstd1);
            bounds.upperBound := int32(ZSTD_f_zstd1_magicless);
            ASSERT(ZSTD_f_zstd1 < ZSTD_f_zstd1_magicless);
            exit(bounds);
        end;
        ZSTD_d_stableOutBuffer:
        begin
            bounds.lowerBound := int32(ZSTD_bm_buffered);
            bounds.upperBound := int32(ZSTD_bm_stable);
            exit(bounds);
        end;
        ZSTD_d_forceIgnoreChecksum:
        begin
            bounds.lowerBound := int32(ZSTD_d_validateChecksum);
            bounds.upperBound := int32(ZSTD_d_ignoreChecksum);
            exit(bounds);
        end;
        else;
    end;
    bounds.error := ERROR(parameter_unsupported);
    result := bounds;
end;

{ ZSTD_dParam_withinBounds:
 * @return 1 if value is within dParam bounds,
 * 0 otherwise }
function ZSTD_dParam_withinBounds(dParam:ZSTD_dParameter; value:int32):int32;
var
  bounds:ZSTD_bounds;
begin
    bounds := ZSTD_dParam_getBounds(dParam);
    if (ZSTD_isError(bounds.error)<>0) then
      exit(0);
    if (value < bounds.lowerBound) then
      exit(0);
    if (value > bounds.upperBound) then
      exit(0);
    result := 1;
end;


function ZSTD_DCtx_getParameter(dctx:pZSTD_DCtx; param:ZSTD_dParameter; value:pint32):int32;
begin
    case (param) of
        ZSTD_d_windowLogMax:
        begin
            value^ := int32(ZSTD_highbit32(Uint32(dctx^.maxWindowSize)));
            exit(0);
        end;
        ZSTD_d_format:
        begin
            value^ := int32(dctx^.format);
            exit(0);
        end;
        ZSTD_d_stableOutBuffer:
        begin
            value^ := int32(dctx^.outBufferMode);
            exit(0);
        end;
        ZSTD_d_forceIgnoreChecksum:
        begin
            value^ := int32(dctx^.forceIgnoreChecksum);
            exit(0);
        end;
        else;
    end;
    exit(ERROR(parameter_unsupported));
end;

function ZSTD_DCtx_setParameter(dctx:pZSTD_DCtx; dParam:ZSTD_dParameter;value: int32 ):int32;
var
  err:int32;
begin
    if (dctx^.streamStage <> zdss_init) then 
    exit(ERROR(stage_wrong));
    case(dParam) of
        ZSTD_d_windowLogMax:
        begin
            if (value = 0) then
              value := ZSTD_WINDOWLOG_LIMIT_DEFAULT;
            err:=ZSTD_dParam_withinBounds(ZSTD_d_windowLogMax, value);
            if (ERR_isError(err)<>0) then
        			exit(err);
            dctx^.maxWindowSize := int32(1)  shl  value;
            exit(0);
        end;
        ZSTD_d_format:
        begin
            err:=ZSTD_dParam_withinBounds(ZSTD_d_format, value);
            if (ERR_isError(err)<>0) then
        			exit(err);
            dctx^.format := ZSTD_format_e(value);
            exit(0);
        end;
        ZSTD_d_stableOutBuffer:
        begin
            err:=ZSTD_dParam_withinBounds(ZSTD_d_stableOutBuffer, value);
            if (ERR_isError(err)<>0) then
        			exit(err);
            dctx^.outBufferMode := ZSTD_bufferMode_e(value);
            exit(0);
        end;
        ZSTD_d_forceIgnoreChecksum:
        begin
            err:=ZSTD_dParam_withinBounds(ZSTD_d_forceIgnoreChecksum, value);
            if (ERR_isError(err)<>0) then
        			exit(err);
            dctx^.forceIgnoreChecksum := ZSTD_forceIgnoreChecksum_e(value);
            exit(0);
        end;
        else;
    end;
    exit(ERROR(parameter_unsupported));//, '');
end;

function ZSTD_DCtx_reset(dctx:pZSTD_DCtx; reset:ZSTD_ResetDirective):int32;
begin
    if ( (reset = ZSTD_reset_session_only)
       or  (reset = ZSTD_reset_session_and_parameters) ) then
    begin
        dctx^.streamStage := zdss_init;
        dctx^.noForwardProgress := 0;
    end;
    if ( (reset = ZSTD_reset_parameters)
       or  (reset = ZSTD_reset_session_and_parameters) ) then
    begin
        if (dctx^.streamStage <> zdss_init) then 
          exit(ERROR(stage_wrong));
        ZSTD_clearDict(dctx);
        ZSTD_DCtx_resetParameters(dctx);
    end;
    exit(0);
end;


function ZSTD_sizeof_DStream(const dctx:pZSTD_DStream):int32;
begin
    result := ZSTD_sizeof_DCtx(dctx);
end;
function Max(a, b: Uint64): Uint64;inline;
begin
  if a > b then
    Result := a
  else
    Result := b;
end;
function Min(a, b: Uint64): Uint64;inline;
begin
  if a < b then
    Result := a
  else
    Result := b;
end;
function ZSTD_decodingBufferSize_min(windowSize, frameContentSize:Uint64):int32;
var
  blockSize,minRBSize:int32;
  neededRBSize,neededSize:Uint64;
begin
    blockSize := int32(MIN(windowSize, ZSTD_BLOCKSIZE_MAX));
    neededRBSize := windowSize + blockSize + (WILDCOPY_OVERLENGTH * 2);
    neededSize := MIN(frameContentSize, neededRBSize);
    minRBSize := int32(neededSize);
    IF (Uint64(minRBSize) <> neededSize) then
      exit(ERROR(frameParameter_windowTooLarge));
    result := minRBSize;
end;

function ZSTD_estimateDStreamSize(windowSize:int32):int32;
var
  blockSize,inBuffSize,outBuffSize:int32;
begin
    blockSize := MIN(windowSize, ZSTD_BLOCKSIZE_MAX);
    inBuffSize := blockSize;  { no block can be larger }
    outBuffSize := ZSTD_decodingBufferSize_min(windowSize, ZSTD_CONTENTSIZE_UNKNOWN);
    result := ZSTD_estimateDCtxSize() + inBuffSize + outBuffSize;
end;

function ZSTD_estimateDStreamSize_fromFrame(const src:pbyte;srcSize:int32):int32;
var
  windowSizeMax:Uint32;
  zfh:ZSTD_frameHeader;
  err:int32;
begin
    windowSizeMax := uint32(1)  shl  ZSTD_WINDOWLOG_MAX;   { note : should be user-selectable, but requires an additional parameter (or a dctx) }
    
    err := ZSTD_getFrameHeader( @zfh, src, srcSize);
    if (ZSTD_isError(err)<>0) then
      exit(err);
    if (err>0) then 
      exit(ERROR(srcSize_wrong));
    if (zfh.windowSize > windowSizeMax) then
      exit(ERROR(frameParameter_windowTooLarge));
    result := ZSTD_estimateDStreamSize(int32(zfh.windowSize));
end;


{ *****   Decompression   ***** }

function ZSTD_DCtx_isOverflow(zds:pZSTD_DStream; neededInBuffSize, neededOutBuffSize:int32):int32;
begin
    result := ord((zds^.inBuffSize + zds^.outBuffSize) >= (neededInBuffSize + neededOutBuffSize) * ZSTD_WORKSPACETOOLARGE_FACTOR);
end;

procedure ZSTD_DCtx_updateOversizedDuration(zds:pZSTD_DStream; neededInBuffSize, neededOutBuffSize:int32);
begin
    if (ZSTD_DCtx_isOverflow(zds, neededInBuffSize, neededOutBuffSize)<>0) then
        inc(zds^.oversizedDuration)
    else
        zds^.oversizedDuration := 0;
end;

function ZSTD_DCtx_isOversizedTooLong(zds:pZSTD_DStream):int32;
begin
    result := ord(zds^.oversizedDuration >= ZSTD_WORKSPACETOOLARGE_MAXDURATION);
end;

{ Checks that the output buffer hasn't changed if ZSTD_obm_stable is used. }
function ZSTD_checkOutBuffer( zds:pZSTD_DStream; output:pZSTD_outBuffer):int32;
var
  expect:ZSTD_outBuffer;
begin
    expect := zds^.expectedOutBuffer;
    { No requirement when ZSTD_obm_stable is not enabled. }
    if (zds^.outBufferMode <> ZSTD_bm_stable) then
        exit(0);
    { Any buffer is allowed in zdss_init, this must be the same for every other call until
     * the context is reset.
     }
    if (zds^.streamStage = zdss_init) then
        exit(0);
    { The buffer must match our expectation exactly. }
    if (expect.dst = output^.dst) and (expect.pos = output^.pos) and (expect.size = output^.size) then
        exit(0);
    exit(ERROR(dstBuffer_wrong));//, 'ZSTD_d_stableOutBuffer enabled but output differs!');
end;

{ Calls ZSTD_decompressContinue() with the right parameters for ZSTD_decompressStream()
 * and updates the stage and the output buffer state. This call is extracted so it can be
 * used both when reading directly from the ZSTD_inBuffer, and in buffered input mode.
 * NOTE: You must break after calling this function since the streamStage is modified.
 }
function ZSTD_decompressContinueStream(zds:pZSTD_DStream; op:ppbyte; oend:pbyte;src:pbyte;srcSize:int32):int32;
var
   isSkipFrame,dstSize,decodedSize:int32;
begin
    isSkipFrame := ZSTD_isSkipFrame(zds);
    if (zds^.outBufferMode = ZSTD_bm_buffered) then
    begin
        if isSkipFrame<>0 then
        dstSize := 0 
        else
        dstSize := zds^.outBuffSize - zds^.outStart;
        decodedSize := ZSTD_decompressContinue(zds,zds^.outBuff + zds^.outStart, dstSize, src, srcSize);
        if (ERR_isError(decodedSize)<>0) then
    			exit(decodedSize);
        if (decodedSize=0) and (isSkipFrame=0) then
        begin
            zds^.streamStage := zdss_read;
        end
        else 
        begin
            zds^.outEnd := zds^.outStart + decodedSize;
            zds^.streamStage := zdss_flush;
        end;
    end
    else 
    begin
        { Write directly into the output buffer }
        if isSkipFrame<>0 then
          dstSize := 0
        else
          dstSize := int32(oend - op^);
        decodedSize := ZSTD_decompressContinue(zds, op^, dstSize, src, srcSize);
        if (ERR_isError(decodedSize)<>0) then
    			exit(decodedSize);
        op^ :=op^ + decodedSize;
        { Flushing is not needed. }
        zds^.streamStage := zdss_read;
        assert(op^ <= oend);
        assert(zds^.outBufferMode = ZSTD_bm_stable);
    end;
    exit(0);
end;

function ZSTD_decompressStream(zds:pZSTD_DStream; output:pZSTD_outBuffer; input:pZSTD_inBuffer):int32;
var
  src,istart,iend,ip,dst,ostart,oend,op:pbyte;
  someMoreWork:Uint32;
  hint,hSize,dictSize,toLoad,remainingInput,cSize,decompressedSize,neededInBuffSize,neededOutBuffSize:int32;
  legacyVersion:Uint32;
  ddict:pZSTD_DDict;
  dict:pbyte;
  tooSmall,tooLarge,bufferSize,neededInSize,isSkipFrame,loadedSize:int32;
  toFlushSize,nextSrcSizeHint,flushedSize,err:int32;
begin
    src := input^.src;
    if input^.pos <> 0 then
      istart :=  src + input^.pos
    else
      istart := src;
    if input^.size <> 0 then
      iend := src + input^.size
    else
      iend := src;
    ip := istart;
    dst := output^.dst;
    if output^.pos <> 0 then
      ostart :=  dst + output^.pos
    else
      ostart :=  dst;
    if output^.size <> 0 then
      oend := dst + output^.size
    else
      oend := dst;
    op := ostart;
    someMoreWork := 1;

    //log(3,  'ZSTD_decompressStream');
    IF(input^.pos > input^.size) then
        exit(ERROR(srcSize_wrong));//        'forbidden. in: pos: %u   vs size: %u',input^.pos, input^.size);
    IF(output^.pos > output^.size) then
        exit(ERROR(dstint32ooSmall));//        'forbidden. out: pos: %u   vs size: %u',output^.pos, output^.size);
    //log(3,  'input size : %u', (input^.size - input^.pos));
    err:=ZSTD_checkOutBuffer(zds, output);
    if (ERR_isError(err)<>0) then
      exit(err);

    while (someMoreWork<>0) do
    begin
        case(zds^.streamStage) of
          zdss_init :
          begin
            //log(3,  'stage zdss_init :=> transparent reset ');
            zds^.streamStage := zdss_loadHeader;
            zds^.outEnd := 0;
            zds^.outStart := 0;
            zds^.inPos := 0;
            zds^.lhSize := 0;
            zds^.legacyVersion := 0;
            zds^.hostageByte := 0;
            zds^.expectedOutBuffer := output^;
            { fall-through }
          end;
          zdss_loadHeader,zdss_read,zdss_load :
          begin
            if zdss_loadHeader=zds^.streamStage then
            begin
              //log(3,  'stage zdss_loadHeader (srcSize : %u)', (iend - ip));

              //if (zds^.legacyVersion<>0) then
              //begin
              //    IF (zds^.staticSize<>0) then
              //      exit(ERROR(memory_allocation));//'legacy support is incompatible with static dctx');
              //    hint := ZSTD_decompressLegacyStream(zds^.legacyContext, zds^.legacyVersion, output, input);
              //    if (hint=0) then
              //      zds^.streamStage := zdss_init;
              //    exit(hint);
              //end;

              hSize := ZSTD_getFrameHeader_advanced( @zds^.fParams, zds^.headerBuffer, zds^.lhSize, zds^.format);
              //log(3,  'header size : %u', hSize);
              if (ZSTD_isError(hSize)<>0) then
              begin
                  //legacyVersion := ZSTD_isLegacy(istart, iend-istart);
                  //if (legacyVersion<>0) then
                  //begin
                  //    ddict := ZSTD_getDDict(zds);
                  //    if ddict<>nil then
                  //    begin
                  //      dict := ZSTD_DDict_dictContent(ddict);
                  //      dictSize := ZSTD_DDict_dictSize(ddict)
                  //    end
                  //    else
                  //    begin
                  //      dict := nil;
                  //      dictSize:=0;
                  //    end;
                  //    //log(3,  'ZSTD_decompressStream: detected legacy version v0.%u', legacyVersion);
                  //    IF (zds^.staticSize) then 
                  //      exit(ERROR(memory_allocation));//'legacy support is incompatible with static dctx');
                  //    err:=ZSTD_initLegacyStream( and zds^.legacyContext,
                  //                zds^.previousLegacyVersion, legacyVersion,
                  //                dict, dictSize);
                  //    if (ERR_isError(err)<>0) then
                  //      exit(err);
                  //    zds^.legacyVersion := zds^.previousLegacyVersion := legacyVersion;
                  //    hint := ZSTD_decompressLegacyStream(zds^.legacyContext, legacyVersion, output, input);
                  //    if (hint=0) then
                  //      zds^.streamStage := zdss_init;   { or stay in stage zdss_loadHeader }
                  //    exit(hint);
                  //end;

                  exit(hSize);   { error }
              end;

              if (hSize <> 0) then
              begin   { need more input }
                  toLoad := hSize - zds^.lhSize;   { if hSize<>0, hSize > zds^.lhSize }
                  remainingInput := int32(iend-ip);
                  assert(iend >= ip);
                  if (toLoad > remainingInput) then
                  begin   { not enough input to load full header }
                      if (remainingInput > 0) then
                      begin
                          move( ip^, zds^.headerBuffer [zds^.lhSize],remainingInput);
                          zds^.lhSize :=zds^.lhSize + remainingInput;
                      end;
                      input^.pos := input^.size;
                      exit((MAX(ZSTD_FRAMEHEADERSIZE_MIN(zds^.format), hSize) - zds^.lhSize) + ZSTD_blockHeaderSize);   { remaining header bytes + next block header }
                  end;
                  assert(ip <> nil);
                  move( ip^, zds^.headerBuffer[zds^.lhSize],toLoad); 
                  zds^.lhSize := hSize; 
                  ip :=ip + toLoad;
                  break;
              end;
              { check for single-pass mode opportunity }
              if (zds^.fParams.frameContentSize <> ZSTD_CONTENTSIZE_UNKNOWN)
                  and (zds^.fParams.frameType <> ZSTD_skippableFrame)
                  and (int32(oend-op) >= zds^.fParams.frameContentSize) then
              begin
                  cSize := ZSTD_findFrameCompressedSize(istart, (iend-istart));
                  if (cSize <= int32(iend-istart)) then
                  begin
                      { shortcut : using single-pass mode }
                      decompressedSize := ZSTD_decompress_usingDDict(zds, op, (oend-op), istart, cSize, ZSTD_getDDict(zds));
                      if (ZSTD_isError(decompressedSize)<>0) then
                        exit(decompressedSize);
                      //log(3,  'shortcut to single-pass ZSTD_decompress_usingDDict()');
                      ip := istart + cSize;
                      op :=op + decompressedSize;
                      zds^.expected := 0;
                      zds^.streamStage := zdss_init;
                      someMoreWork := 0;
                      break;
                  end;
              end;

              { Check output buffer is large enough for ZSTD_odm_stable. }
              if (zds^.outBufferMode = ZSTD_bm_stable)
                  and (zds^.fParams.frameType <> ZSTD_skippableFrame)
                  and (zds^.fParams.frameContentSize <> ZSTD_CONTENTSIZE_UNKNOWN)
                  and (int32(oend-op) < zds^.fParams.frameContentSize) then
              begin
                  exit(ERROR(dstint32ooSmall));//, 'ZSTD_obm_stable passed but ZSTD_outBuffer is too small');
              end;

              { Consume header (see ZSTDds_decodeFrameHeader) }
              //log(3,  'Consume header');
              err:=ZSTD_decompressBegin_usingDDict(zds, ZSTD_getDDict(zds));
              if (ERR_isError(err)<>0) then
                exit(err);

              if ((MEM_readLE32(zds^.headerBuffer)  and  ZSTD_MAGIC_SKIPPABLE_MASK) = ZSTD_MAGIC_SKIPPABLE_START) then
              begin  { skippable frame }
                  zds^.expected := MEM_readLE32(@zds^.headerBuffer [ ZSTD_FRAMEIDSIZE]);
                  zds^.stage := ZSTDds_skipFrame;
              end
              else 
              begin
                  err:=ZSTD_decodeFrameHeader(zds, zds^.headerBuffer, zds^.lhSize);
                  if (ERR_isError(err)<>0) then
                    exit(err);
                  zds^.expected := ZSTD_blockHeaderSize;
                  zds^.stage := ZSTDds_decodeBlockHeader;
              end;

              { control buffer memory usage }
              //log(3,  'Control max memory usage (%u KB <= max %u KB)',
              //            (zds^.fParams.windowSize  shr 10),
              //            (zds^.maxWindowSize  shr  10) );
              zds^.fParams.windowSize := MAX(zds^.fParams.windowSize, Uint32(1)  shl  ZSTD_WINDOWLOG_ABSOLUTEMIN);
              IF (zds^.fParams.windowSize > zds^.maxWindowSize) then
                exit(ERROR(frameParameter_windowTooLarge));

              { Adapt buffer sizes to frame header instructions }
              neededInBuffSize := MAX(zds^.fParams.blockSizeMax, 4 { frame checksum });
              if zds^.outBufferMode = ZSTD_bm_buffered then
                neededOutBuffSize := ZSTD_decodingBufferSize_min(zds^.fParams.windowSize, zds^.fParams.frameContentSize) 
              else
                neededOutBuffSize := 0;

              ZSTD_DCtx_updateOversizedDuration(zds, neededInBuffSize, neededOutBuffSize);

              tooSmall := ord((zds^.inBuffSize < neededInBuffSize)  or  (zds^.outBuffSize < neededOutBuffSize));
              tooLarge := ZSTD_DCtx_isOversizedTooLong(zds);

              if (tooSmall<>0)  or  (tooLarge<>0) then
              begin
                  bufferSize := neededInBuffSize + neededOutBuffSize;
                  //log(3,  'inBuff  : from %u to %u',
                  //            zds^.inBuffSize, neededInBuffSize);
                  //log(3,  'outBuff : from %u to %u',
                  //            zds^.outBuffSize, neededOutBuffSize);
                  if (zds^.staticSize<>0) then
                  begin  { static DCtx }
                      //log(3,  'staticSize : %u', zds^.staticSize);
                      assert(zds^.staticSize >= sizeof(ZSTD_DCtx));  { controlled at init }
                      IF (bufferSize > zds^.staticSize - sizeof(ZSTD_DCtx)) then
                        exit(ERROR(memory_allocation));
                  end
                  else 
                  begin
                      ZSTD_customFree(zds^.inBuff, zds^.customMem);
                      zds^.inBuffSize := 0;
                      zds^.outBuffSize := 0;
                      zds^.inBuff := allocmem(bufferSize);
                      IF (zds^.inBuff = nil) then 
                        exit(ERROR(memory_allocation));
                  end;
                  zds^.inBuffSize := neededInBuffSize;
                  zds^.outBuff := zds^.inBuff + zds^.inBuffSize;
                  zds^.outBuffSize := neededOutBuffSize;
              end;
              zds^.streamStage := zdss_read;
              { fall-through }
            end;

          if zds^.streamStage=zdss_read then
          begin
            //log(3,  'stage zdss_read');
            neededInSize := ZSTD_nextSrcSizeToDecompressWithInputSize(zds, (iend - ip));
            //log(3,  'neededInSize := %u', neededInSize);
            if (neededInSize=0) then
            begin  { end of frame }
                zds^.streamStage := zdss_init;
                someMoreWork := 0;
                break;
            end;
            if (int32(iend-ip) >= neededInSize) then
            begin  { decode directly from src }
                err:=ZSTD_decompressContinueStream(zds,  @op, oend, ip, neededInSize);
                if (ERR_isError(err)<>0) then
                  exit(err);
                ip :=ip + neededInSize;
                { Function modifies the stage so we must break }
                break;
            end;
            if (ip=iend) then
            begin 
              someMoreWork := 0; 
              break; 
            end;   { no more input }
            zds^.streamStage := zdss_load;
            { fall-through }
          end;
          if zds^.streamStage = zdss_load then
          begin
            neededInSize := ZSTD_nextSrcSizeToDecompress(zds);
            toLoad := neededInSize - zds^.inPos;
            isSkipFrame := ZSTD_isSkipFrame(zds);

            { At this point we shouldn't be decompressing a block that we can stream. }
            assert(neededInSize = ZSTD_nextSrcSizeToDecompressWithInputSize(zds, iend - ip));
            if (isSkipFrame<>0) then
            begin
                loadedSize := MIN(toLoad, (iend-ip));
            end
            else 
            begin
                IF(toLoad > zds^.inBuffSize - zds^.inPos) then
                  exit(ERROR(corruption_detected));//'should never happen');
                loadedSize := ZSTD_limitCopy(zds^.inBuff + zds^.inPos, toLoad, ip, int32(iend-ip));
            end;
            ip :=ip + loadedSize;
            zds^.inPos :=zds^.inPos + loadedSize;
            if (loadedSize < toLoad) then
            begin 
              someMoreWork := 0; 
              break; 
            end;   { not enough input, wait for more }

            { decode loaded input }
            zds^.inPos := 0;   { input is consumed }
            err:=ZSTD_decompressContinueStream(zds,  @op, oend, zds^.inBuff, neededInSize);
            if (ERR_isError(err)<>0) then
              exit(err);
            { Function modifies the stage so we must break }
            break;

          end;
          end;
          zdss_flush:
          begin
            toFlushSize := zds^.outEnd - zds^.outStart;
            flushedSize := ZSTD_limitCopy(op, int32(oend-op), zds^.outBuff + zds^.outStart, toFlushSize);
            op :=op + flushedSize;
            zds^.outStart :=zds^.outStart + flushedSize;
            if (flushedSize = toFlushSize) then
            begin  { flush completed }
                zds^.streamStage := zdss_read;
                if ( (zds^.outBuffSize < zds^.fParams.frameContentSize)
                  and (zds^.outStart + zds^.fParams.blockSizeMax > zds^.outBuffSize) ) then
                begin
                    //log(3,  'restart filling outBuff from beginning (left:%i, needed:%u)',
                    //        (zds^.outBuffSize - zds^.outStart),
                    //        zds^.fParams.blockSizeMax);
                    zds^.outEnd := 0;
                    zds^.outStart := 0;
                end;
                break;
            end;
            { cannot complete flush }
            someMoreWork := 0;
            break;
          end;
          else
          begin
            assert(false);    { impossible }
            exit(ERROR(GENERIC_ERROR));//, 'impossible to reach'));   { some compiler require default to do something }
          end;   
        end;
    end;
    { result }
    input^.pos := int32(ip - (input^.src));
    output^.pos := int32(op - (output^.dst));

    { Update the expected output buffer for ZSTD_obm_stable. }
    zds^.expectedOutBuffer := output^;

    if ((ip=istart) and (op=ostart)) then
    begin  { no forward progress }
        inc(zds^.noForwardProgress);
        if (zds^.noForwardProgress >= ZSTD_NO_FORWARD_PROGRESS_MAX) then
        begin
            IF (op=oend) then
            exit(ERROR(dstint32ooSmall));
            IF (ip=iend) then
            exit(ERROR(srcSize_wrong));
            assert(false);
        end;
    end
    else 
    begin
        zds^.noForwardProgress := 0;
    end;

    nextSrcSizeHint:= ZSTD_nextSrcSizeToDecompress(zds);
    if (nextSrcSizeHint=0) then
    begin   { frame fully decoded }
        if (zds^.outEnd = zds^.outStart) then
        begin  { output fully flushed }
            if (zds^.hostageByte<>0) then
            begin
                if (input^.pos >= input^.size) then
                begin
                    { can't release hostage (not present) }
                    zds^.streamStage := zdss_read;
                    exit(1);
                end;
                inc(input^.pos);  { release hostage }
            end;   { zds^.hostageByte }
            exit(0);
        end;  { zds^.outEnd = zds^.outStart }
        if (zds^.hostageByte=0) then
        begin { output not fully flushed; keep last byte as hostage; will be released when all output is flushed }
            dec(input^.pos);   { note : pos > 0, otherwise, impossible to finish reading last block }
            zds^.hostageByte:=1;
        end;
        exit(1);
    end;  { nextSrcSizeHint=0 }
    nextSrcSizeHint :=nextSrcSizeHint + ZSTD_blockHeaderSize * ord(ZSTD_nextInputType(zds) = ZSTDnit_block);   { preload header of next block }
    assert(zds^.inPos <= nextSrcSizeHint);
    nextSrcSizeHint :=nextSrcSizeHint - zds^.inPos;   { part already loaded}
    result := nextSrcSizeHint;
end;

function ZSTD_decompressStream_simpleArgs (dctx:pZSTD_DCtx;dst:pbyte;dstCapacity:int32;dstPos:pint32;
  const src:pbyte;srcSize:int32; srcPos:pint32):int32;
var
  output:ZSTD_outBuffer;
  input:ZSTD_inBuffer;
  cErr:int32;
begin
  output.dst := dst;
  output.size := dstCapacity;
  output.pos:= dstPos^ ;
  input.src  :=  src;
  input.size := srcSize;
  input.pos :=srcPos^ ;
    { ZSTD_compress_generic() will check validity of dstPos and srcPos }
  cErr := ZSTD_decompressStream(dctx,  @output,  @input);
  dstPos^ := output.pos;
  srcPos^ := input.pos;
  result := cErr;
end;
end.
