unit zstd_compress_superblock;
{$mode objfpc}{$H+}
interface
 {-*************************************
 *  Dependencies
 **************************************}
uses zstd,zstd_internal,hist,zstd_compress_internal,fse,zstd_common,
  zstd_compress_sequences,zstd_compress_literals,huf,error_private,huf_compress;
const
  COMPRESS_LITERALS_SIZE_MIN= 63;
{-*************************************
*  Superblock entropy buffer structs
**************************************}
{* ZSTD_hufCTablesMetadata_t :
 *  Stores Literals Block Type for a super-block in hType, and
 *  huffman tree description in hufDesBuffer.
 *  hufDesSize refers to the size of huffman tree description in bytes.
 *  This metadata is populated in ZSTD_buildSuperBlockEntropy_literal() }
type
  THUFBUFFER=array [0..ZSTD_MAX_HUF_HEADER_SIZE-1] of byte;
  TfseTablesBuffer=array [0..132] of byte; //ZSTD_MAX_FSE_HEADERS_SIZE
  pZSTD_hufCTablesMetadata_t=^ZSTD_hufCTablesMetadata_t;
  ZSTD_hufCTablesMetadata_t = record
    hType:symbolEncodingType_e;
    hufDesBuffer:THUFBUFFER;
    hufDesSize:int32;
  end;

{* ZSTD_fseCTablesMetadata_t :
 *  Stores symbol compression modes for a super-block in beginll, ol, mlend;Type, and
 *  fse tables in fseTablesBuffer.
 *  fseTablesSize refers to the size of fse tables in bytes.
 *  This metadata is populated in ZSTD_buildSuperBlockEntropy_sequences() }
pZSTD_fseCTablesMetadata_t=^ZSTD_fseCTablesMetadata_t;
ZSTD_fseCTablesMetadata_t=record
    llType:symbolEncodingType_e;
    ofType:symbolEncodingType_e;
    mlType:symbolEncodingType_e;
    fseTablesBuffer:TfseTablesBuffer;
    fseTablesSize:int32;
    lastCountSize:int32; { This is to account for bug in 1.3.4. More detail in ZSTD_compressSubBlock_sequences() }
end;
pZSTD_entropyCTablesMetadata_t=^ZSTD_entropyCTablesMetadata_t;
ZSTD_entropyCTablesMetadata_t=record
    hufMetadata:ZSTD_hufCTablesMetadata_t;
    fseMetadata:ZSTD_fseCTablesMetadata_t;
end;
function ZSTD_compressSuperBlock(zc:pZSTD_CCtx;
                               dst:pbyte;dstCapacity:int32;
                               src:pbyte; srcSize:int32;
                               lastBlock:uint32 ):int32;
implementation
uses zstd_compressf;
{* ZSTD_buildSuperBlockEntropy_literal() :
 *  Builds entropy for the super-block literals.
 *  Stores literals block type (raw, rle, compressed, repeat) and
 *  huffman description table to hufMetadata.
 *  @return : size of huffman description table or error code }
function ZSTD_buildSuperBlockEntropy_literal(src:pbyte;srcSize:int32;
  prevHuf,nextHuf:pZSTD_hufCTables_t;
  hufMetadata:pZSTD_hufCTablesMetadata_t;disableLiteralsCompression:int32;
  workspace:pbyte; wkspSize:int32):int32;
var
  wkspStart,wkspEnd,countWkspStart,nodeWksp:pbyte;
  countWksp:puint32;
  countWkspSize,nodeWkspSize:int32;
  maxSymbolValue,huffLog:uint32;
  lrepeat:HUF_repeat;
  minLitSize,largest,maxBits,newCSize,hSize,oldCSize:int32;
begin
    wkspStart := workspace;
    wkspEnd := wkspStart + wkspSize;
    countWkspStart := wkspStart;
    countWksp := puint32(workspace);
    countWkspSize := (HUF_SYMBOLVALUE_MAX + 1) * sizeof(uint32);
    nodeWksp := countWkspStart + countWkspSize;
    nodeWkspSize := wkspEnd-nodeWksp;
    maxSymbolValue := 255;
    huffLog := HUF_TABLELOG_DEFAULT;
    lrepeat := prevHuf^.repeatMode;

    //log(3, 'ZSTD_buildSuperBlockEntropy_literal (srcSize:=%zu)', srcSize);

    { Prepare nextEntropy assuming reusing the existing table }
    move (prevHuf^, nextHuf^,  sizeof(ZSTD_hufCTables_t));

    if (disableLiteralsCompression<>0) then
    begin
        //log(3, 'set_basic - disabled');
        hufMetadata^.hType := set_basic;
        exit(0);
    end;

    { small ? don't even attempt compression (speed opt) }


    if (prevHuf^.repeatMode = HUF_repeat_valid) then
      minLitSize :=  6
    else
      minLitSize :=  COMPRESS_LITERALS_SIZE_MIN;
    if (srcSize <= minLitSize) then
    begin
      //log(3, 'set_basic - too small');
      hufMetadata^.hType := set_basic;
      exit(0);
    end;

    { Scan input and build symbol stats }
     
    largest := HIST_count_wksp (countWksp,  @maxSymbolValue, src, srcSize, workspace, wkspSize);
    if (ERR_isError(largest)<>0) then
       exit(largest);//'HIST_count_wksp failed'
    if (largest = srcSize) then
    begin
        //log(3, 'set_rle');
        hufMetadata^.hType := set_rle;
        exit(0);
    end;
    if (largest <= (srcSize  shr  7)+4) then
    begin
        //log(3, 'set_basic - no gain');
        hufMetadata^.hType := set_basic;
        exit(0);
    end;
    

    { Validate the previous Huffman table }
    if (lrepeat = HUF_repeat_check) and (HUF_validateCTable(pHUF_CElt(prevHuf^.CTable), countWksp, maxSymbolValue)=0) then
    begin
        lrepeat := HUF_repeat_none;
    end;

    { Build Huffman Tree }
    fillbyte(nextHuf^.CTable, sizeof(nextHuf^.CTable), 0);
    huffLog := HUF_optimalTableLog(huffLog, srcSize, maxSymbolValue);
    
    maxBits := HUF_buildCTable_wksp(pHUF_CElt(nextHuf^.CTable), countWksp,maxSymbolValue, huffLog,nodeWksp, nodeWkspSize);
    if (ERR_isError(maxBits)<>0) then
       exit(maxBits);//'HUF_buildCTable_wksp'
    huffLog := Uint32(maxBits);
    { Build and write the CTable }
    newCSize := HUF_estimateCompressedSize(pHUF_CElt(nextHuf^.CTable), countWksp, maxSymbolValue);
    hSize := HUF_writeCTable(hufMetadata^.hufDesBuffer, sizeof(hufMetadata^.hufDesBuffer),pHUF_CElt(nextHuf^.CTable), maxSymbolValue, huffLog);
    { Check against repeating the previous CTable }
    if (lrepeat <> HUF_repeat_none) then
    begin
        oldCSize := HUF_estimateCompressedSize(pHUF_CElt(prevHuf^.CTable), countWksp, maxSymbolValue);
        if ((oldCSize < srcSize) and ((oldCSize <= hSize + newCSize)  or  (hSize + 12 >= srcSize))) then
        begin
            //log(3, 'set_repeat - smaller');
            move(prevHuf^, nextHuf^,  sizeof(ZSTD_hufCTables_t));
            hufMetadata^.hType := set_repeat;
            exit(0);
        end;
    end;
    if (newCSize + hSize >= srcSize) then
    begin
        //log(3, 'set_basic - no gains');
        move(prevHuf^, nextHuf^,  sizeof(ZSTD_hufCTables_t));
        hufMetadata^.hType := set_basic;
        exit(0);
    end;
    //log(3, 'set_compressed (hSize:=%u)', hSize);
    hufMetadata^.hType := set_compressed;
    nextHuf^.repeatMode := HUF_repeat_check;
    result := hSize;
end;

{* ZSTD_buildSuperBlockEntropy_sequences() :
 *  Builds entropy for the super-block sequences.
 *  Stores symbol compression modes and fse table to fseMetadata.
 *  @return : size of fse tables or error code }
function ZSTD_buildSuperBlockEntropy_sequences(seqStorePtr:pseqStore_t;
  prevEntropy,nextEntropy:pZSTD_fseCTables_t;cctxParams:pZSTD_CCtx_params;
  fseMetadata:pZSTD_fseCTablesMetadata_t;workspace:pbyte;wkspSize:int32):int32;
var
  wkspStart,wkspEnd,countWkspStart,cTableWksp:pbyte;
  countWksp:puint32;
  countWkspSize,cTableWkspSize,nbSeq:int32;
  strategy:ZSTD_strategy;
  CTable_LitLength,CTable_OffsetBits,CTable_MatchLength:pFSE_CTable;
  ofCodeTable,llCodeTable,mlCodeTable,ostart,oend,op:pbyte;
  LLtype,Offtype,MLtype:Uint32;
  max:uint32;
  mostFrequent,countSize:int32;
  defaultPolicy:ZSTD_defaultPolicy_e;
begin
    wkspStart := workspace;
    wkspEnd := wkspStart + wkspSize;
    countWkspStart := wkspStart;
    countWksp := puint32(workspace);
    countWkspSize := (MaxSeq + 1) * sizeof(uint32);
    cTableWksp := countWkspStart + countWkspSize;
    cTableWkspSize := wkspEnd-cTableWksp;
    strategy := cctxParams^.cParams.strategy;
    CTable_LitLength := nextEntropy^.litlengthCTable;
    CTable_OffsetBits := nextEntropy^.offcodeCTable;
    CTable_MatchLength := nextEntropy^.matchlengthCTable;
    ofCodeTable := seqStorePtr^.ofCode;
    llCodeTable := seqStorePtr^.llCode;
    mlCodeTable := seqStorePtr^.mlCode;
    nbSeq := seqStorePtr^.sequences - seqStorePtr^.sequencesStart;
    ostart := fseMetadata^.fseTablesBuffer;
    oend := ostart + sizeof(fseMetadata^.fseTablesBuffer);
    op := ostart;

    assert(cTableWkspSize >= (1  shl  MaxFSELog) * sizeof(byte));
    //log(3, 'ZSTD_buildSuperBlockEntropy_sequences (nbSeq:=%zu)', nbSeq);
    fillbyte(workspace^, wkspSize, 0);

    fseMetadata^.lastCountSize := 0;
    { convert length/distances into codes }
    ZSTD_seqToCodes(seqStorePtr);
    { build CTable for Literal Lengths }
    
    max := MaxLL;
    mostFrequent := HIST_countFast_wksp(countWksp,  @max, llCodeTable, nbSeq, workspace, wkspSize);  { can't fail }
    //log(3, 'Building LL table');
    nextEntropy^.litlength_repeatMode := prevEntropy^.litlength_repeatMode;
    LLtype := ord(ZSTD_selectEncodingType( @nextEntropy^.litlength_repeatMode,
                                    countWksp, max, mostFrequent, nbSeq,
                                    LLFSELog, prevEntropy^.litlengthCTable,
                                    @LL_defaultNorm[0], LL_defaultNormLog,
                                    ZSTD_defaultAllowed, strategy));
    assert((set_basic < set_compressed) and (set_rle < set_compressed));
    assert(not((LLtype < ord(set_compressed)) and (nextEntropy^.litlength_repeatMode <> FSE_repeat_none))); { We don't copy tables }
     
    countSize := ZSTD_buildCTable(op, oend - op, CTable_LitLength, LLFSELog, symbolEncodingType_e(LLtype),
                                                countWksp, max, llCodeTable, nbSeq, LL_defaultNorm, LL_defaultNormLog, MaxLL,
                                                prevEntropy^.litlengthCTable, sizeof(prevEntropy^.litlengthCTable),
                                                cTableWksp, cTableWkspSize);
    //FORWARD_IF_ERROR(countSize, 'ZSTD_buildCTable for LitLens failed');
    if (ERR_isError(countSize)<>0) then
      exit(countSize);
    if (LLtype = ord(set_compressed)) then
      fseMetadata^.lastCountSize := countSize;
    op :=op + countSize;
    fseMetadata^.llType := symbolEncodingType_e (LLtype);
    
    { build CTable for Offsets }
    
    max := MaxOff;
    mostFrequent := HIST_countFast_wksp(countWksp,  @max, ofCodeTable, nbSeq, workspace, wkspSize);  { can't fail }
    { We can only use the basic table if max <= DefaultMaxOff, otherwise the offsets are too large }
    if (max <= DefaultMaxOff) then
    defaultPolicy := ZSTD_defaultAllowed
    else
    defaultPolicy := ZSTD_defaultDisallowed;
    //log(3, 'Building OF table');
    nextEntropy^.offcode_repeatMode := prevEntropy^.offcode_repeatMode;
    Offtype := ord(ZSTD_selectEncodingType( @nextEntropy^.offcode_repeatMode,
                                    countWksp, max, mostFrequent, nbSeq,
                                    OffFSELog, prevEntropy^.offcodeCTable,
                                    @OF_defaultNorm[0], OF_defaultNormLog,
                                    defaultPolicy, strategy));
    assert(not((Offtype < ord(set_compressed)) and (nextEntropy^.offcode_repeatMode <> FSE_repeat_none))); { We don't copy tables }
         
    countSize := ZSTD_buildCTable(op, oend - op, CTable_OffsetBits, OffFSELog, symbolEncodingType_e(Offtype),
                                                countWksp, max, ofCodeTable, nbSeq, OF_defaultNorm, OF_defaultNormLog, DefaultMaxOff,
                                                prevEntropy^.offcodeCTable, sizeof(prevEntropy^.offcodeCTable),
                                                cTableWksp, cTableWkspSize);
    //FORWARD_IF_ERROR(countSize, 'ZSTD_buildCTable for Offsets failed');
    if (ERR_isError(countSize)<>0) then
      exit(countSize);
    if (Offtype = ord(set_compressed)) then
        fseMetadata^.lastCountSize := countSize;
    op :=op + countSize;
    fseMetadata^.ofType := symbolEncodingType_e (Offtype);
    { build CTable for MatchLengths }

    max := MaxML;
    mostFrequent := HIST_countFast_wksp(countWksp,  @max, mlCodeTable, nbSeq, workspace, wkspSize);   { can't fail }
    //log(3, 'Building ML table (remaining space : %i)', (oend-op));
    nextEntropy^.matchlength_repeatMode := prevEntropy^.matchlength_repeatMode;
    MLtype := ord(ZSTD_selectEncodingType( @nextEntropy^.matchlength_repeatMode,
                                    countWksp, max, mostFrequent, nbSeq,
                                    MLFSELog, prevEntropy^.matchlengthCTable,
                                    @ML_defaultNorm[0], ML_defaultNormLog,
                                    ZSTD_defaultAllowed, strategy));
    assert(not ((MLtype < ord(set_compressed)) and (nextEntropy^.matchlength_repeatMode <> FSE_repeat_none))); { We don't copy tables }
         
    countSize := ZSTD_buildCTable(op, oend - op, CTable_MatchLength, MLFSELog, symbolEncodingType_e(MLtype),
                                                countWksp, max, mlCodeTable, nbSeq, ML_defaultNorm, ML_defaultNormLog, MaxML,
                                                prevEntropy^.matchlengthCTable, sizeof(prevEntropy^.matchlengthCTable),
                                                cTableWksp, cTableWkspSize);
    //FORWARD_IF_ERROR(countSize, 'ZSTD_buildCTable for MatchLengths failed');
    if (ERR_isError(countSize)<>0) then
      exit(countSize);
    if (MLtype = ord(set_compressed)) then
        fseMetadata^.lastCountSize := countSize;
    op :=op + countSize;
    fseMetadata^.mlType := symbolEncodingType_e(MLtype);
    assert(int32 (op-ostart) <= sizeof(fseMetadata^.fseTablesBuffer));
    result := op-ostart;
end;


{* ZSTD_buildSuperBlockEntropy() :
 *  Builds entropy for the super-block.
 *  @return : 0 on success or error code }
function ZSTD_buildSuperBlockEntropy(seqStorePtr:pseqStore_t;prevEntropy,nextEntropy:pZSTD_entropyCTables_t;
  cctxParams:pZSTD_CCtx_params;entropyMetadata:pZSTD_entropyCTablesMetadata_t;
  workspace:pbyte;wkspSize:int32):int32;
var
  litSize:int32;
begin
    litSize := seqStorePtr^.lit - seqStorePtr^.litStart;
    //log(3, 'ZSTD_buildSuperBlockEntropy');
    entropyMetadata^.hufMetadata.hufDesSize :=
        ZSTD_buildSuperBlockEntropy_literal(seqStorePtr^.litStart, litSize,
                                             @prevEntropy^.huf,  @nextEntropy^.huf,
                                             @entropyMetadata^.hufMetadata,
                                            ZSTD_disableLiteralsCompression(cctxParams),
                                            workspace, wkspSize);
    //FORWARD_IF_ERROR(entropyMetadata^.hufMetadata.hufDesSize, 'ZSTD_buildSuperBlockEntropy_literal failed');
    if (ERR_isError(entropyMetadata^.hufMetadata.hufDesSize)<>0) then
      exit(entropyMetadata^.hufMetadata.hufDesSize);
    entropyMetadata^.fseMetadata.fseTablesSize :=
        ZSTD_buildSuperBlockEntropy_sequences(seqStorePtr,
                                               @prevEntropy^.fse,  @nextEntropy^.fse,
                                              cctxParams,
                                               @entropyMetadata^.fseMetadata,
                                              workspace, wkspSize);
    //FORWARD_IF_ERROR(entropyMetadata^.fseMetadata.fseTablesSize, 'ZSTD_buildSuperBlockEntropy_sequences failed');
    if (ERR_isError(entropyMetadata^.fseMetadata.fseTablesSize)<>0) then
      exit(entropyMetadata^.fseMetadata.fseTablesSize);
    exit(0);
end;

{* ZSTD_compressSubBlock_literal() :
 *  Compresses literals section for a sub-block.
 *  When we have to write the Huffman table we will sometimes choose a header
 *  size larger than necessary. This is because we have to pick the header size
 *  before we know the table size + compressed size, so we have a bound on the
 *  table size. If we guessed incorrectly, we fall back to uncompressed literals.
 *
 *  We write the header when writeEntropy:=1 and set entropyWrriten:=1 when we succeeded
 *  in writing the header, otherwise it is set to 0.
 *
 *  hufMetadata^.hType has literals block type info.
 *      If it is set_basic, all sub-blocks literals section will be Raw_Literals_Block.
 *      If it is set_rle, all sub-blocks literals section will be RLE_Literals_Block.
 *      If it is set_compressed, first sub-block's literals section will be Compressed_Literals_Block
 *      If it is set_compressed, first sub-block's literals section will be Treeless_Literals_Block
 *      and the following sub-blocks' literals sections will be Treeless_Literals_Block.
 *  @return : compressed size of literals section of a sub-block
 *            Or 0 if it unable to compress.
 *            Or error code }
function ZSTD_compressSubBlock_literal(hufTable:pHUF_CElt;hufMetadata:pZSTD_hufCTablesMetadata_t;
  literals:pbyte;litSize:int32;dst:pbyte;dstSize:int32;bmi2,writeEntropy:int32; entropyWritten:pint32):int32;
var
  header,lhSize,cLitSize,cSize:int32;
  ostart,oend,op:pbyte;
  singleStream:Uint32;
  hType:symbolEncodingType_e;
  lhc:Uint32;
begin
  if writeEntropy<>0 then
    header := 200
  else
    header := 0;
    lhSize := 3 + ord(litSize >= (1 *1024 - header)) + ord(litSize >= (16 *1024 - header));
    ostart := dst;
    oend := ostart + dstSize;
    op := ostart + lhSize;
    lhSize := 3;
    singleStream := lhSize;
  if writeEntropy<>0 then
    hType := hufMetadata^.hType
  else
    hType := set_repeat;
  cLitSize := 0;

    //log(3, 'ZSTD_compressSubBlock_literal (litSize:=%zu, lhSize:=%zu, writeEntropy:=%d)', litSize, lhSize, writeEntropy);

    entropyWritten^ := 0;
    if (litSize = 0)  or  (hufMetadata^.hType = set_basic) then
    begin
      //log(3, 'ZSTD_compressSubBlock_literal using raw literal');
      exit(ZSTD_noCompressLiterals(dst, dstSize, literals, litSize));
    end
    else 
    if (hufMetadata^.hType = set_rle) then
    begin
      //log(3, 'ZSTD_compressSubBlock_literal using rle literal');
      exit(ZSTD_compressRleLiteralsBlock(dst, dstSize, literals, litSize));
    end;

    assert(litSize > 0);
    assert((hufMetadata^.hType = set_compressed)  or  (hufMetadata^.hType = set_repeat));

    if (writeEntropy<>0) and (hufMetadata^.hType = set_compressed) then
    begin
        move( hufMetadata^.hufDesBuffer, op, hufMetadata^.hufDesSize);
        op :=op + hufMetadata^.hufDesSize;
        cLitSize :=cLitSize + hufMetadata^.hufDesSize;
        //log(3, 'ZSTD_compressSubBlock_literal (hSize:=%zu)', hufMetadata^.hufDesSize);
    end;

    { TODO bmi2 }
    if singleStream<>0 then
      cSize :=  HUF_compress1X_usingCTable(op, oend-op, literals, litSize, hufTable)
    else
      cSize :=  HUF_compress4X_usingCTable(op, oend-op, literals, litSize, hufTable);
    op :=op + cSize;
    cLitSize :=cLitSize + cSize;
    if (cSize = 0  or  ERR_isError(cSize)) then
    begin
        //log(3, 'Failed to write entropy tables %s', ZSTD_getErrorName(cSize));
        exit(0);
    end;
    { If we expand and we aren't writing a header then emit uncompressed }
    if not (writeEntropy and cLitSize >= litSize) then
    begin
        //log(3, 'ZSTD_compressSubBlock_literal using raw literal because uncompressible');
        exit(ZSTD_noCompressLiterals(dst, dstSize, literals, litSize));
    end;
    { If we are writing headers then allow expansion that doesn't change our header size. }
    if (lhSize < int32(3 + ord(cLitSize >= 1 *1024) + ord(cLitSize >= 16 *1024))) then
    begin
        assert(cLitSize > litSize);
        //log(3, 'Literals expanded beyond allowed header size');
        exit(ZSTD_noCompressLiterals(dst, dstSize, literals, litSize));
    end;
    //log(3, 'ZSTD_compressSubBlock_literal (cSize:=%zu)', cSize);


    { Build header }
    case (lhSize) of
      3: { 2 - 2 - 10 - 10 }
        begin   
          lhc := ord(hType) + (ord(singleStream = 0)  shl  2) + (Uint32(litSize) shl 4) + (Uint32(cLitSize) shl 14);
          MEM_writeLE24(ostart, lhc);
        end;
    4: { 2 - 2 - 14 - 14 }
        begin 
          lhc := ord(hType) + (2  shl  2) + (Uint32(litSize) shl 4) + (Uint32(cLitSize) shl 18);
          MEM_writeLE32(ostart, lhc);
        end;
    5: { 2 - 2 - 18 - 18 }
        begin 
          lhc := ord(hType) + (3  shl  2) + (Uint32(litSize) shl 4) + (Uint32(cLitSize) shl 22);
          MEM_writeLE32(ostart, lhc);
          ostart[4] := BYTE(cLitSize  shr  10);
        end;
    else  { not possible : lhSize is begin3,4,5end; }
        assert(false);
    end;
    entropyWritten^ := 1;
    //log(3, 'Compressed literals: %u ^. %u', Uint32(litSize), Uint32(op-ostart));
    result := op-ostart;
end;

function ZSTD_seqDecompressedSize(seqStore:pseqStore_t; sequences:pseqDef;nbSeq,litSize,lastSequence:int32):int32;
var
   sstart,send,sp:pseqDef;
   matchLengthSum,litLengthSum:int32;
   seqLen:ZSTD_sequenceLength;
begin
    sstart := sequences;
    send := sequences + nbSeq;
    sp := sstart;
    matchLengthSum := 0;
    litLengthSum := 0;
    while (send-sp > 0) do
    begin
        seqLen := ZSTD_getSequenceLength(seqStore, sp);
        litLengthSum   :=litLengthSum   + seqLen.litLength;
        matchLengthSum :=matchLengthSum + seqLen.matchLength;
        inc(sp);
    end;
    assert(litLengthSum <= litSize);
    if (lastSequence=0) then
    begin
        assert(litLengthSum = litSize);
    end;
    result := matchLengthSum + litSize;
end;

{* ZSTD_compressSubBlock_sequences() :
 *  Compresses sequences section for a sub-block.
 *  fseMetadata^.llType, fseMetadata^.ofType, and fseMetadata^.mlType have
 *  symbol compression modes for the super-block.
 *  The first successfully compressed block will have these in its header.
 *  We set entropyWritten:=1 when we succeed in compressing the sequences.
 *  The following sub-blocks will always have repeat mode.
 *  @return : compressed size of sequences section of a sub-block
 *            Or 0 if it is unable to compress
 *            Or error code. }
function ZSTD_compressSubBlock_sequences(fseTables:pZSTD_fseCTables_t;
  fseMetadata:pZSTD_fseCTablesMetadata_t;sequences:pseqDef;nbSeq:int32;
  llCode,mlCode,ofCode:pbyte;cctxParams:pZSTD_CCtx_params;dst:pbyte;dstCapacity:int32;
  bmi2,writeEntropy:int32;entropyWritten:pint32):int32;
var
  longOffsets:int32;
  ostart,oend,op,seqHead:pbyte;
  LLtype,Offtype,MLtype,lrepeat:Uint32;
  bitstreamSize:int32;
begin
    longOffsets := ord(cctxParams^.cParams.windowLog > 57{STREAM_ACCUMULATOR_MIN});
    ostart := dst;
    oend := ostart + dstCapacity;
    op := ostart;

    //log(3, 'ZSTD_compressSubBlock_sequences (nbSeq:=%zu, writeEntropy:=%d, longOffsets:=%d)', nbSeq, writeEntropy, longOffsets);

    entropyWritten^ := 0;
    { Sequences Header }
    if (oend-op < 3 {max nbSeq Size} + 1 {seqHead}) then
       exit(ERROR(dstint32ooSmall));
    if (nbSeq < $7F) then
    begin
        op^ := BYTE(nbSeq);
        inc(op);
    end
    else 
    if (nbSeq < LONGNBSEQ) then
    begin
      op:=op+2;
      op[1] := BYTE(nbSeq);
      op[0] := BYTE((nbSeq shr 8) + $80);  
    end
    else
    begin
      op:=op+3;
      MEM_writeLE16(op+1, dword(nbSeq - LONGNBSEQ));
      op[0]:=$FF;  
    end;
    if (nbSeq=0) then
    begin
        exit(op - ostart);
    end;

    { seqHead : flags for FSE encoding type }
    seqHead := op;
    inc(op);

    //log(3, 'ZSTD_compressSubBlock_sequences (seqHeadSize:=%u)', (op-ostart));

    if (writeEntropy<>0) then
    begin
        LLtype := ord(fseMetadata^.llType);
        Offtype := ord(fseMetadata^.ofType);
        MLtype := ord(fseMetadata^.mlType);
        //log(3, 'ZSTD_compressSubBlock_sequences (fseTablesSize:=%zu)', fseMetadata^.fseTablesSize);
        seqHead^ := BYTE((LLtype shl 6) + (Offtype shl 4) + (MLtype shl 2));
        move( fseMetadata^.fseTablesBuffer, op,fseMetadata^.fseTablesSize);
        op :=op + fseMetadata^.fseTablesSize;
    end
    else 
    begin
        lrepeat := ord(set_repeat);
        seqHead^ := BYTE((lrepeat shl 6) + (lrepeat shl 4) + (lrepeat shl 2));
    end;

    bitstreamSize := ZSTD_encodeSequences(
                                        op, oend - op,
                                        fseTables^.matchlengthCTable, mlCode,
                                        fseTables^.offcodeCTable, ofCode,
                                        fseTables^.litlengthCTable, llCode,
                                        sequences, nbSeq,
                                        longOffsets, bmi2);
    //FORWARD_IF_ERROR(bitstreamSize, 'ZSTD_encodeSequences failed');
    if (ERR_isError(bitstreamSize)<>0) then
      exit(bitstreamSize);
    op :=op + bitstreamSize;
        { zstd versions <= 1.3.4 mistakenly report corruption when
         * FSE_readNCount() receives a buffer < 4 bytes.
         * Fixed by https://github.com/facebook/zstd/pull/1146.
         * This can happen when the last set_compressed table present is 2
         * bytes and the bitstream is only one byte.
         * In this exceedingly rare case, we will simply emit an uncompressed
         * block, since it isn't worth optimizing.
         }
    //log(3, 'ZSTD_compressSubBlock_sequences (bitstreamSize:=%zu)', bitstreamSize);


    { zstd versions <= 1.4.0 mistakenly report error when
     * sequences section body size is less than 3 bytes.
     * Fixed by https://github.com/facebook/zstd/pull/1664.
     * This can happen when the previous sequences section block is compressed
     * with rle mode and the current block's sequences section is compressed
     * with repeat mode where sequences section body size can be 1 byte.
     }

    entropyWritten^ := 1;
    result := op - ostart;
end;

{* ZSTD_compressSubBlock() :
 *  Compresses a single sub-block.
 *  @return : compressed size of the sub-block
 *            Or 0 if it failed to compress. }
function ZSTD_compressSubBlock(entropy:pZSTD_entropyCTables_t;
  entropyMetadata:pZSTD_entropyCTablesMetadata_t;sequences:pseqDef;nbSeq:int32;
  literals:pbyte;litSize:int32;llCode,mlCode,ofCode:pbyte;cctxParams:pZSTD_CCtx_params;dst:pbyte;dstCapacity:int32;
  bmi2:int32;writeLitEntropy,writeSeqEntropy:int32;litEntropyWritten,seqEntropyWritten:pint32;
  lastBlock:Uint32):int32;
var
  ostart,oend,op:pbyte;
  cLitSize,cSeqSize,cSize:int32;
  cBlockHeader24:Uint32;
begin
    ostart := dst;
    oend := ostart + dstCapacity;
    op := ostart + ZSTD_blockHeaderSize;
    //log(3, 'ZSTD_compressSubBlock (litSize:=%zu, nbSeq:=%zu, writeLitEntropy:=%d, writeSeqEntropy:=%d, lastBlock:=%d)',
    //          litSize, nbSeq, writeLitEntropy, writeSeqEntropy, lastBlock);
    
    cLitSize := ZSTD_compressSubBlock_literal(pHUF_CElt(entropy^.huf.CTable),@entropyMetadata^.hufMetadata, literals, litSize,
      op, oend-op, bmi2, writeLitEntropy, litEntropyWritten);
    //FORWARD_IF_ERROR(cLitSize, 'ZSTD_compressSubBlock_literal failed');
    if (ERR_isError(cLitSize)<>0) then
      exit(cLitSize);
    if (cLitSize = 0) then
      exit(0);
    op :=op + cLitSize;
     
    cSeqSize := ZSTD_compressSubBlock_sequences( @entropy^.fse,
                                                   @entropyMetadata^.fseMetadata,
                                                  sequences, nbSeq,
                                                  llCode, mlCode, ofCode,
                                                  cctxParams,
                                                  op, oend-op,
                                                  bmi2, writeSeqEntropy, seqEntropyWritten);
    //FORWARD_IF_ERROR(cSeqSize, 'ZSTD_compressSubBlock_sequences failed');
    if (ERR_isError(cSeqSize)<>0) then
      exit(cSeqSize);
    if (cSeqSize = 0) then
      exit(0);
    op :=op + cSeqSize;

    { Write block header }
 
    cSize := (op-ostart)-ZSTD_blockHeaderSize;
    cBlockHeader24 := lastBlock + ((Uint32(bt_compressed) shl 1) + Uint32(cSize  shl  3));
    MEM_writeLE24(ostart, cBlockHeader24);

    result := op-ostart;
end;

function ZSTD_estimateSubBlockSize_literal(literals:pbyte;litSize:int32;
  huf:pZSTD_hufCTables_t;hufMetadata:pZSTD_hufCTablesMetadata_t;
  workspace:pbyte;wkspSize,writeEntropy:int32):int32;
var
  countWksp:puint32;
  maxSymbolValue:uint32;
  literalSectionHeaderSize,largest,cLitSizeEstimate:int32;
begin
    countWksp := puint32(workspace);
    maxSymbolValue := 255;
    literalSectionHeaderSize := 3; { Use hard coded size of 3 bytes }

    if (hufMetadata^.hType = set_basic) then
      exit(litSize)
    else 
    if (hufMetadata^.hType = set_rle) then
      exit(1)
    else 
    if (hufMetadata^.hType = set_compressed)  or  (hufMetadata^.hType = set_repeat) then
    begin
        largest := HIST_count_wksp (countWksp,  @maxSymbolValue, literals, litSize, workspace, wkspSize);
        if (ZSTD_isError(largest)<>0) then
          exit(litSize);
         
        cLitSizeEstimate := HUF_estimateCompressedSize(pHUF_CElt(huf^.CTable), countWksp, maxSymbolValue);
        if (writeEntropy<>0) then
          cLitSizeEstimate :=cLitSizeEstimate + hufMetadata^.hufDesSize;
        exit(cLitSizeEstimate + literalSectionHeaderSize);
    end;
    assert(false); { impossible }
    exit(0);
end;

function ZSTD_estimateSubBlockSize_symbolType(ltype:symbolEncodingType_e;
  codeTable:pbyte; maxCode:uint32;nbSeq:int32; fseCTable:pFSE_CTable;
  additionalBits:pUint32;defaultNorm:pword;  defaultNormLog,  defaultMax:Uint32;
  workspace:pbyte;wkspSize:int32):int32;
var
  countWksp:puint32;
  ctp,ctStart,ctEnd:pbyte;
  cSymbolTypeSizeEstimateInBits:int32;
  max:uint32;
begin
    countWksp := puint32(workspace);
    ctp := codeTable;
    ctStart := ctp;
    ctEnd := ctStart + nbSeq;
    cSymbolTypeSizeEstimateInBits := 0;
    max := maxCode;

    HIST_countFast_wksp(countWksp,  @max, codeTable, nbSeq, workspace, wkspSize);  { can't fail }
    if (ltype = set_basic) then
    begin
        { We selected this encoding type, so it must be valid. }
        assert(max <= defaultMax);
        if max <= defaultMax then
          cSymbolTypeSizeEstimateInBits := ZSTD_crossEntropyCost(defaultNorm, defaultNormLog, countWksp, max)
        else
          cSymbolTypeSizeEstimateInBits := ERROR(GENERIC_ERROR);
    end
    else 
    if (ltype = set_rle) then
    begin
        cSymbolTypeSizeEstimateInBits := 0;
    end
    else 
    if (ltype = set_compressed)  or  (ltype = set_repeat) then
    begin
        cSymbolTypeSizeEstimateInBits := ZSTD_fseBitCost(fseCTable, countWksp, max);
    end;
    if (ZSTD_isError(cSymbolTypeSizeEstimateInBits)<>0) then
      exit(nbSeq * 10);
    while (ctp < ctEnd) do
    begin
        if (additionalBits<>nil) then
          cSymbolTypeSizeEstimateInBits :=cSymbolTypeSizeEstimateInBits + additionalBits[ctp^]
        else 
          cSymbolTypeSizeEstimateInBits :=cSymbolTypeSizeEstimateInBits +cSymbolTypeSizeEstimateInBits + ctp^; { for offset, offset code is also the number of additional bits }
        inc(ctp);
    end;
    result := cSymbolTypeSizeEstimateInBits div 8;
end;

function ZSTD_estimateSubBlockSize_sequences(ofCodeTable,llCodeTable,mlCodeTable:pbyte;
  nbSeq:int32;fseTables:pZSTD_fseCTables_t;fseMetadata:pZSTD_fseCTablesMetadata_t;
  workspace:pbyte;wkspSize,writeEntropy:int32):int32;
var
  sequencesSectionHeaderSize,cSeqSizeEstimate:int32;
begin
    sequencesSectionHeaderSize := 3; { Use hard coded size of 3 bytes }
    cSeqSizeEstimate := 0;
    cSeqSizeEstimate :=cSeqSizeEstimate + ZSTD_estimateSubBlockSize_symbolType(fseMetadata^.ofType, ofCodeTable, MaxOff,
                                         nbSeq, fseTables^.offcodeCTable, nil,
                                         @OF_defaultNorm[0], OF_defaultNormLog, DefaultMaxOff,
                                         workspace, wkspSize);
    cSeqSizeEstimate :=cSeqSizeEstimate + ZSTD_estimateSubBlockSize_symbolType(fseMetadata^.llType, llCodeTable, MaxLL,
                                         nbSeq, fseTables^.litlengthCTable, LL_bits,
                                         @LL_defaultNorm[0], LL_defaultNormLog, MaxLL,
                                         workspace, wkspSize);
    cSeqSizeEstimate :=cSeqSizeEstimate + ZSTD_estimateSubBlockSize_symbolType(fseMetadata^.mlType, mlCodeTable, MaxML,
                                         nbSeq, fseTables^.matchlengthCTable, ML_bits,
                                         @ML_defaultNorm[0], ML_defaultNormLog, MaxML,
                                         workspace, wkspSize);
    if (writeEntropy<>0) then
      cSeqSizeEstimate :=cSeqSizeEstimate + fseMetadata^.fseTablesSize;
    result := cSeqSizeEstimate + sequencesSectionHeaderSize;
end;

function ZSTD_estimateSubBlockSize(literals:pbyte;litSize:int32;
  ofCodeTable,llCodeTable,mlCodeTable:pbyte;nbSeq:int32;entropy:pZSTD_entropyCTables_t;
  entropyMetadata:pZSTD_entropyCTablesMetadata_t;workspace:pbyte;wkspSize,writeLitEntropy,writeSeqEntropy:int32):int32;
var
  cSizeEstimate:int32;
begin
    cSizeEstimate := 0;
    cSizeEstimate :=cSizeEstimate + ZSTD_estimateSubBlockSize_literal(literals, litSize,
                                                          @entropy^.huf,  @entropyMetadata^.hufMetadata,
                                                         workspace, wkspSize, writeLitEntropy);
    cSizeEstimate :=cSizeEstimate + ZSTD_estimateSubBlockSize_sequences(ofCodeTable, llCodeTable, mlCodeTable,
                                                         nbSeq,  @entropy^.fse,  @entropyMetadata^.fseMetadata,
                                                         workspace, wkspSize, writeSeqEntropy);
    result := cSizeEstimate + ZSTD_blockHeaderSize;
end;

function ZSTD_needSequenceEntropyTables(fseMetadata:pZSTD_fseCTablesMetadata_t):int32;
begin
    if (fseMetadata^.llType = set_compressed)  or  (fseMetadata^.llType = set_rle) then
        exit(1);
    if (fseMetadata^.mlType = set_compressed)  or  (fseMetadata^.mlType = set_rle) then
        exit(1);
    if (fseMetadata^.ofType = set_compressed)  or  (fseMetadata^.ofType = set_rle) then
        exit(1);
    exit(0);
end;

{* ZSTD_compressSubBlock_multi() :
 *  Breaks super-block into multiple sub-blocks and compresses them.
 *  Entropy will be written to the first block.
 *  The following blocks will use repeat mode to compress.
 *  All sub-blocks are compressed blocks (no raw or rle blocks).
 *  @return : compressed size of the super block (which is multiple ZSTD blocks)
 *            Or 0 if it failed to compress. }
function ZSTD_compressSubBlock_multi(seqStorePtr:pseqStore_t;
                            prevCBlock:pZSTD_compressedBlockState_t;
                            nextCBlock:pZSTD_compressedBlockState_t;
                            entropyMetadata:pZSTD_entropyCTablesMetadata_t;
                            cctxParams:pZSTD_CCtx_params;dst:pbyte;dstCapacity:int32;
                            src:pbyte; srcSize,
                            bmi2:int32; lastBlock:Uint32;
                            workspace:pbyte;wkspSize:int32):int32;
var
  sstart,send,sp:pseqDef;
  lstart,lend,lp,ip,op,llCodePtr,mlCodePtr,ofCodePtr,iend,ostart,oend:pbyte;
  targetCBlockSize,litSize, seqCount:int32;
  writeLitEntropy,writeSeqEntropy,lastSequence:int32;
  cBlockSizeEstimate,litEntropyWritten,seqEntropyWritten,decompressedSize,cSize:int32;
  sequence,seq:pseqDef;
  rep:repcodes_t;
begin
    sstart := seqStorePtr^.sequencesStart;
    send := seqStorePtr^.sequences;
    sp := sstart;
    lstart := seqStorePtr^.litStart;
    lend := seqStorePtr^.lit;
    lp := lstart;
    ip := src;
    iend := ip + srcSize;
    ostart := dst;
    oend := ostart + dstCapacity;
    op := ostart;
    llCodePtr := seqStorePtr^.llCode;
    mlCodePtr := seqStorePtr^.mlCode;
    ofCodePtr := seqStorePtr^.ofCode;
    targetCBlockSize := cctxParams^.targetCBlockSize;
    entropyMetadata^.hufMetadata.hType := set_compressed;
    writeLitEntropy := ord(entropyMetadata^.hufMetadata.hType);
    writeSeqEntropy := 1;
    lastSequence := 0;

    //log(3, 'ZSTD_compressSubBlock_multi (litSize:=%u, nbSeq:=%u)',
    //            (lend-lp), (send-sstart));

    litSize := 0;
    seqCount := 0;

    repeat
        cBlockSizeEstimate := 0;
        if (sstart = send) then
        begin
            lastSequence := 1;
        end
        else 
        begin
            sequence := sp + seqCount;
            lastSequence := ord(sequence = send) - 1;
            litSize :=litSize + ZSTD_getSequenceLength(seqStorePtr, sequence).litLength;
            inc(seqCount);
        end;
        if (lastSequence<>0) then
        begin
            assert(lp <= lend);
            assert(litSize <= int32(lend - lp));
            litSize := int32(lend - lp);
        end;
        { I think there is an optimization opportunity here.
         * Calling ZSTD_estimateSubBlockSize for every sequence can be wasteful
         * since it recalculates estimate from scratch.
         * For example, it would recount literal distribution and symbol codes everytime.
         }
        cBlockSizeEstimate := ZSTD_estimateSubBlockSize(lp, litSize, ofCodePtr, llCodePtr, mlCodePtr, seqCount,
                                                        @nextCBlock^.entropy, entropyMetadata,
                                                       workspace, wkspSize, writeLitEntropy, writeSeqEntropy);
        if (cBlockSizeEstimate > targetCBlockSize  or  lastSequence) then
        begin
            litEntropyWritten := 0;
            seqEntropyWritten := 0;

            decompressedSize := ZSTD_seqDecompressedSize(seqStorePtr, sp, seqCount, litSize, lastSequence);
            cSize := ZSTD_compressSubBlock( @nextCBlock^.entropy, entropyMetadata,
                                                       sp, seqCount,
                                                       lp, litSize,
                                                       llCodePtr, mlCodePtr, ofCodePtr,
                                                       cctxParams,
                                                       op, oend-op,
                                                       bmi2, writeLitEntropy, writeSeqEntropy,
                                                        @litEntropyWritten,  @seqEntropyWritten,
                                                       lastBlock and lastSequence);
            //FORWARD_IF_ERROR(cSize, 'ZSTD_compressSubBlock failed');
            if (ERR_isError(cSize)<>0) then
              exit(cSize);
            if (cSize > 0) and (cSize < decompressedSize) then
            begin
                //log(3, 'Committed the sub-block');
                assert(ip + decompressedSize <= iend);
                ip :=ip + decompressedSize;
                sp :=sp + seqCount;
                lp :=lp + litSize;
                op :=op + cSize;
                llCodePtr :=llCodePtr + seqCount;
                mlCodePtr :=mlCodePtr + seqCount;
                ofCodePtr :=ofCodePtr + seqCount;
                litSize := 0;
                seqCount := 0;
                { Entropy only needs to be written once }
                if (litEntropyWritten<>0) then
                begin
                    writeLitEntropy := 0;
                end;
                if (seqEntropyWritten<>0) then
                begin
                    writeSeqEntropy := 0;
                end;
            end;
        end;
    until (lastSequence<>0);
    if (writeLitEntropy<>0) then
    begin
        //log(3, 'ZSTD_compressSubBlock_multi has literal entropy tables unwritten');
        move( prevCBlock^.entropy.huf, nextCBlock^.entropy.huf, sizeof(prevCBlock^.entropy.huf));
    end;
    if (writeSeqEntropy<>0) and (ZSTD_needSequenceEntropyTables( @entropyMetadata^.fseMetadata)<>0) then
    begin
        { If we haven't written our entropy tables, then we've violated our contract and
         * must emit an uncompressed block.
         }
        //log(3, 'ZSTD_compressSubBlock_multi has sequence entropy tables unwritten');
        exit(0);
    end;
    if (ip < iend) then
    begin
        cSize := ZSTD_noCompressBlock(op, oend - op, ip, iend - ip, lastBlock);
        //log(3, 'ZSTD_compressSubBlock_multi last sub-block uncompressed, %zu bytes', (iend - ip));
        //FORWARD_IF_ERROR(cSize, 'ZSTD_noCompressBlock failed');
        if (ERR_isError(cSize)<>0) then
          exit(cSize);
        assert(cSize <> 0);
        op :=op + cSize;
        { We have to regenerate the repcodes because we've skipped some sequences }
        if (sp < send) then
        begin
            move(  prevCBlock^.rep, rep, sizeof(rep));
            seq := sstart;
            while seq < sp do
            begin
                rep := ZSTD_updateRep(rep.rep, seq^.offset - 1, ord(ZSTD_getSequenceLength(seqStorePtr, seq).litLength = 0));
                inc(seq);
            end;
            move(   rep, nextCBlock^.rep, sizeof(rep));
        end;
    end;
    //log(3, 'ZSTD_compressSubBlock_multi compressed');
    result := op-ostart;
end;

function ZSTD_compressSuperBlock(zc:pZSTD_CCtx;
                               dst:pbyte;dstCapacity:int32;
                               src:pbyte; srcSize:int32;
                               lastBlock:uint32 ):int32;
var
  entropyMetadata:ZSTD_entropyCTablesMetadata_t;
  err:int32;
begin
    err:=ZSTD_buildSuperBlockEntropy( @zc^.seqStore,
           @zc^.blockState.prevCBlock^.entropy,
           @zc^.blockState.nextCBlock^.entropy,
           @zc^.appliedParams,
           @entropyMetadata,
          pbyte(zc^.entropyWorkspace), ENTROPY_WORKSPACE_SIZE { statically allocated in resetCCtx });
    if (ERR_isError(err)<>0) then
      exit(err);
    result := ZSTD_compressSubBlock_multi( @zc^.seqStore,
            zc^.blockState.prevCBlock,
            zc^.blockState.nextCBlock,
             @entropyMetadata,
             @zc^.appliedParams,
            dst, dstCapacity,
            src, srcSize,
            zc^.bmi2, lastBlock,
            pbyte(zc^.entropyWorkspace), ENTROPY_WORKSPACE_SIZE { statically allocated in resetCCtx });
end;
end.
