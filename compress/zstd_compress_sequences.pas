unit ZSTD_COMPRESS_SEQUENCES;
{$mode objfpc}{$H+}
interface
uses fse,zstd,zstd_internal,fse_compress,error_private,bitstream,math;
const
{*
 * -log2(x / 256) lookup table for x in [0, 256).
 * If x = 0: Return 0
 * Else: Return floor(-log2(x / 256) * 256)
 }
kInverseProbabilityLog256:array [0..255] of uint32= (
    0,    2048, 1792, 1642, 1536, 1453, 1386, 1329, 1280, 1236, 1197, 1162,
    1130, 1100, 1073, 1047, 1024, 1001, 980,  960,  941,  923,  906,  889,
    874,  859,  844,  830,  817,  804,  791,  779,  768,  756,  745,  734,
    724,  714,  704,  694,  685,  676,  667,  658,  650,  642,  633,  626,
    618,  610,  603,  595,  588,  581,  574,  567,  561,  554,  548,  542,
    535,  529,  523,  517,  512,  506,  500,  495,  489,  484,  478,  473,
    468,  463,  458,  453,  448,  443,  438,  434,  429,  424,  420,  415,
    411,  407,  402,  398,  394,  390,  386,  382,  377,  373,  370,  366,
    362,  358,  354,  350,  347,  343,  339,  336,  332,  329,  325,  322,
    318,  315,  311,  308,  305,  302,  298,  295,  292,  289,  286,  282,
    279,  276,  273,  270,  267,  264,  261,  258,  256,  253,  250,  247,
    244,  241,  239,  236,  233,  230,  228,  225,  222,  220,  217,  215,
    212,  209,  207,  204,  202,  199,  197,  194,  192,  190,  187,  185,
    182,  180,  178,  175,  173,  171,  168,  166,  164,  162,  159,  157,
    155,  153,  151,  149,  146,  144,  142,  140,  138,  136,  134,  132,
    130,  128,  126,  123,  121,  119,  117,  115,  114,  112,  110,  108,
    106,  104,  102,  100,  98,   96,   94,   93,   91,   89,   87,   85,
    83,   82,   80,   78,   76,   74,   73,   71,   69,   67,   66,   64,
    62,   61,   59,   57,   55,   54,   52,   50,   49,   47,   46,   44,
    42,   41,   39,   37,   36,   34,   33,   31,   30,   28,   26,   25,
    23,   22,   20,   19,   17,   16,   14,   13,   11,   10,   8,    7,
    5,    4,    2,    1
);
type
  ZSTD_defaultPolicy_e=(
    ZSTD_defaultDisallowed := 0,
    ZSTD_defaultAllowed := 1
  );
function ZSTD_selectEncodingType(
        repeatMode:pFSE_repeat; count:puint32; max:uint32;
        mostFrequent, nbSeq:int32 ; FSELog:uint32;
        prevCTable:pFSE_CTable;
        defaultNorm:pword; defaultNormLog:Uint32;
        isDefaultAllowed:ZSTD_defaultPolicy_e;
        strategy:ZSTD_strategy):symbolEncodingType_e;
function ZSTD_buildCTable(dst:pbyte; dstCapacity:int32;
                nextCTable:pFSE_CTable; FSELog:Uint32; ltype:symbolEncodingType_e;
                count:puint32; max:Uint32;
                codeTable:pBYTE; nbSeq:int32;
                defaultNorm:pint16; defaultNormLog:Uint32; defaultMax:Uint32;
                prevCTable:pFSE_CTable; prevCTableSize:int32;
                entropyWorkspace:pbyte; entropyWorkspaceSize:int32):int32;
function ZSTD_encodeSequences(
            dst:pbyte; dstCapacity:int32;
            CTable_MatchLength:pFSE_CTable; mlCodeTable:pbyte;
            CTable_OffsetBits:pFSE_CTable; ofCodeTable:pbyte;
            CTable_LitLength:pFSE_CTable; llCodeTable:pbyte;
            sequences:pseqDef;  nbSeq,  longOffsets,  bmi2:int32):int32;
function ZSTD_crossEntropyCost(norm:pword; accuracyLog:uint32;count:puint32; max:uint32):int32;
function ZSTD_fseBitCost(
    ctable:pFSE_CTable;
    count:puint32;
    max:uint32):int32;
implementation
function ZSTD_getFSEMaxSymbolValue(ctable:pFSE_CTable):uint32;
var
   ptr:pbyte;
   u16ptr:puint16;
begin
  ptr := pbyte(ctable);
  u16ptr := puint16(ptr);
  result := MEM_read16(pbyte(u16ptr + 1));
end;

{*
 * Returns true if we should use ncount=-1 else we should
 * use ncount=1 for low probability symbols instead.
 }
function ZSTD_useLowProbCount(nbSeq:int32):uint32;
begin
    { Heuristic: This should cover most blocks <= 16K and
     * start to fade out after 16K to about 32K depending on
     * comprssibility.
     }
    result := ord(nbSeq >= 2048);
end;

{*
 * Returns the cost in bytes of encoding the normalized count header.
 * Returns an error if any of the helper functions return an error.
 }
function ZSTD_NCountCost(count:puint32; max:uint32;nbSeq:int32; FSELog:uint32):int32;
var
  wksp:array [0..FSE_NCOUNTBOUND-1] of byte;
  tableLog:Uint32;
  norm:array [0..MaxSeq ] of int16;
  errCode:int32;
begin
    tableLog := FSE_optimalTableLog(FSELog, nbSeq, max);
    errCode:=FSE_normalizeCount(@norm[0], tableLog, count, nbSeq, max, ZSTD_useLowProbCount(nbSeq));
    if (ERR_isError(errCode)<>0) then 
    begin
         exit(errCode);
    end;
    result := FSE_writeNCount(@wksp[0], sizeof(wksp), @norm[0], max, tableLog);
end;

{*
 * Returns the cost in bits of encoding the distribution described by count
 * using the entropy bound.
 }
function ZSTD_entropyCost(count:puint32; max:uint32; total:int32):int32;
var
  cost,s,norm:uint32;
begin
    cost := 0;
    for s := 0 to max do
    begin
        norm := ((256 * count[s]) div total);
        if (count[s] <> 0) and (norm = 0) then
            norm := 1;
        assert(count[s] < total);
        cost :=cost + count[s] * kInverseProbabilityLog256[norm];
    end;
    result := cost  shr  8;
end;

{*
 * Returns the cost in bits of encoding the distribution in count using ctable.
 * Returns an error if ctable cannot represent all the symbols in count.
 }
function ZSTD_fseBitCost(
    ctable:pFSE_CTable;
    count:puint32;
    max:uint32):int32;
var
  kAccuracyLog,s,tableLog,badCost,bitCost:uint32;
  cost:int32;
  cstate:FSE_CState_t;
begin
    kAccuracyLog := 8;
    cost := 0;
    FSE_initCState( @cstate, ctable);
    if (ZSTD_getFSEMaxSymbolValue(ctable) < max) then
    begin
        //DEBUGLOG(5, 'Repeat FSE_CTable has maxSymbolValue %u < %u',
        //            ZSTD_getFSEMaxSymbolValue(ctable), max);
        exit(ERROR(GENERIC_ERROR));
    end;
    for s := 0 to max do
    begin
        tableLog := cstate.stateLog;
        badCost := (tableLog + 1)  shl  kAccuracyLog;
        bitCost := FSE_bitCost(cstate.symbolTT, tableLog, s, kAccuracyLog);
        if (count[s] = 0) then
            continue;
        if (bitCost >= badCost) then
        begin
            //DEBUGLOG(5, 'Repeat FSE_CTable has Prob[%u] = 0', s);
            exit(ERROR(GENERIC_ERROR));
        end;
        cost :=cost + int32(count[s]) * bitCost;
    end;
    result := cost  shr  kAccuracyLog;
end;

{*
 * Returns the cost in bits of encoding the distribution in count using the
 * table described by norm. The max symbol support by norm is assumed >= max.
 * norm must be valid for every symbol with non-zero probability in count.
 }
function ZSTD_crossEntropyCost(norm:pword; accuracyLog:uint32;count:puint32; max:uint32):int32;
var
  shift,s,normAcc,norm256:uint32;
  cost:int32;
begin
    shift := 8 - accuracyLog;
    cost := 0;
    assert(accuracyLog <= 8);
    for s := 0 to max do
    begin
      if (norm[s] <> -1) then
        normAcc := uint32(norm[s])
      else
        normAcc := 1;
      norm256 := normAcc  shl  shift;
      assert(norm256 > 0);
      assert(norm256 < 256);
      cost :=cost + count[s] * kInverseProbabilityLog256[norm256];
    end;
    result :=  cost  shr  8;
end;


function ZSTD_selectEncodingType(
        repeatMode:pFSE_repeat; count:puint32; max:uint32;
        mostFrequent, nbSeq:int32 ; FSELog:uint32;
        prevCTable:pFSE_CTable;
        defaultNorm:pword; defaultNormLog:Uint32;
        isDefaultAllowed:ZSTD_defaultPolicy_e;
        strategy:ZSTD_strategy):symbolEncodingType_e;
var
  staticFse_nbSeq_max,mult,baseLog,dynamicFse_nbSeq_min:int32;
  basicCost,repeatCost,NCountCost,compressedCost:int32;
begin
    //ASSERT(ZSTD_defaultDisallowed = 0 and ZSTD_defaultAllowed <> 0);
    if (mostFrequent = nbSeq) then
    begin
        repeatMode^ := FSE_repeat_none;
        if (ord(isDefaultAllowed)<>0) and (nbSeq <= 2) then
        begin
            { Prefer set_basic over set_rle when there are 2 or less symbols,
             * since RLE uses 1 byte, but set_basic uses 5-6 bits per symbol.
             * If basic encoding isn't possible, always choose RLE.
             }
            //DEBUGLOG(5, 'Selected set_basic');
            result := set_basic;
        end;
        //DEBUGLOG(5, 'Selected set_rle');
        result := set_rle;
    end;
    if (strategy < ZSTD_lazy) then
    begin
        if (ord(isDefaultAllowed)<>0) then
        begin
            staticFse_nbSeq_max := 1000;
            mult := 10 - ord(strategy);
            baseLog := 3;
            dynamicFse_nbSeq_min := ((int32(1)  shl  defaultNormLog) * mult)  shr  baseLog;  { 28-36 for offset, 56-72 for lengths }
            assert((defaultNormLog >= 5) and (defaultNormLog <= 6));  { xx_DEFAULTNORMLOG }
            assert((mult <= 9) and (mult >= 7));
            if ( (repeatMode^ = FSE_repeat_valid)
              and (nbSeq < staticFse_nbSeq_max) ) then
            begin
                //DEBUGLOG(5, 'Selected set_repeat');
                result :=  set_repeat;
            end;
            if ( (nbSeq < dynamicFse_nbSeq_min)
               or  (mostFrequent < (nbSeq  shr  (defaultNormLog-1))) ) then
            begin
                //DEBUGLOG(5, 'Selected set_basic');
                { The format allows default tables to be repeated, but it isn't useful.
                 * When using simple heuristics to select encoding type, we don't want
                 * to confuse these tables with dictionaries. When running more careful
                 * analysis, we don't need to waste time checking both repeating tables
                 * and default tables.
                 }
                repeatMode^ := FSE_repeat_none;
                result :=  set_basic;
            end;
        end;
    end
    else 
    begin
        if repeatMode^ <> FSE_repeat_none then
          repeatCost :=  ZSTD_fseBitCost(prevCTable, count, max)
        else
          repeatCost :=  ERROR(GENERIC_ERROR);
        NCountCost := ZSTD_NCountCost(count, max, nbSeq, FSELog);
        compressedCost := (NCountCost  shl  3) + ZSTD_entropyCost(count, max, nbSeq);
        
        if (ord(isDefaultAllowed)<>0) then
        begin
          basicCost:=ZSTD_crossEntropyCost(defaultNorm, defaultNormLog, count, max);
            //assert(not ZSTD_isError(basicCost));
            //assert(not (repeatMode^ = FSE_repeat_valid and ZSTD_isError(repeatCost)));
        end
        else
        begin
          basicCost:=ERROR(GENERIC_ERROR);
        end;
        //assert(not ZSTD_isError(NCountCost));
        assert(compressedCost < ERROR(maxCode));
        //DEBUGLOG(5, 'Estimated bit costs: basic=%u\trepeat=%u\tcompressed=%u',
        //            (unsigned)basicCost, (unsigned)repeatCost, (unsigned)compressedCost);
        if (basicCost <= repeatCost) and (basicCost <= compressedCost) then
        begin
            //DEBUGLOG(5, 'Selected set_basic');
            //assert(isDefaultAllowed<>0);
            repeatMode^ := FSE_repeat_none;
            exit(set_basic);
        end;
        if (repeatCost <= compressedCost) then
        begin
            //DEBUGLOG(5, 'Selected set_repeat');
            //assert(not ZSTD_isError(repeatCost));
            exit(set_repeat);
        end;
        //assert(compressedCost < basicCost and compressedCost < repeatCost);
    end;
    //DEBUGLOG(5, 'Selected set_compressed');
    repeatMode^ := FSE_repeat_check;
    result := set_compressed;
end;

function ZSTD_buildCTable(dst:pbyte; dstCapacity:int32;
                nextCTable:pFSE_CTable; FSELog:Uint32; ltype:symbolEncodingType_e;
                count:puint32; max:Uint32;
                codeTable:pBYTE; nbSeq:int32;
                defaultNorm:pint16; defaultNormLog:Uint32; defaultMax:Uint32;
                prevCTable:pFSE_CTable; prevCTableSize:int32;
                entropyWorkspace:pbyte; entropyWorkspaceSize:int32):int32;

var
  op,oend:pbyte;
  norm:array[0..MaxSeq] of int16;
  nbSeq_1,NCountSize:int32;
  tableLog:uint32;
  errcode:int32;
begin
    op := dst;
    oend := op + dstCapacity;
    //DEBUGLOG(6, 'ZSTD_buildCTable (dstCapacity=%u)', (unsigned)dstCapacity);

    case (ltype) of
     set_rle:
     begin
        errcode:=FSE_buildCTable_rle(nextCTable, BYTE(max));
        if (ERR_isError(errcode)<>0) then
        begin
            exit(errcode);
        end;
        if (dstCapacity=0) then
           exit(ERROR(dstint32ooSmall));//, 'not enough space');
        op^ := codeTable[0];
        exit(1);
     end;
     set_repeat:
     begin
        move( prevCTable^, nextCTable ,prevCTableSize);
        exit(0);
     end;
     set_basic:
     begin
        errCode:=FSE_buildCTable_wksp(nextCTable, defaultNorm, defaultMax, defaultNormLog, entropyWorkspace, entropyWorkspaceSize);
         if (ERR_isError(errCode)<>0) then  { note : could be pre-calculated }
         begin
              exit(errCode);
         end;
        exit(0);
     end;
     set_compressed: 
     begin
        nbSeq_1 := nbSeq;
        tableLog := FSE_optimalTableLog(FSELog, nbSeq, max);
        if (count[codeTable[nbSeq-1]] > 1) then
        begin
            dec(count[codeTable[nbSeq-1]]);
            dec(nbSeq_1);
        end;
        assert(nbSeq_1 > 1);
        assert(entropyWorkspaceSize >= FSE_BUILD_CTABLE_WORKSPACE_SIZE(MaxSeq, MaxFSELog));
        errcode:=FSE_normalizeCount(@norm[0], tableLog, count, nbSeq_1, max, ZSTD_useLowProbCount(nbSeq_1));
        //log(stderr, 'BUILD_v2: @norm=', PtrUInt(@norm[0]), ' tableLog=', tableLog, ' nbSeq_1=', nbSeq_1, ' max=', max, ' normalizeCount=', errcode);
        //log(stderr, 'norm[0..5]=', norm[0], ',', norm[1], ',', norm[2], ',', norm[3], ',', norm[4], ',', norm[5]);
        if (ERR_isError(errCode)<>0) then
        begin
             exit(errCode);
        end;
        NCountSize := FSE_writeNCount(op, oend - op, @norm[0], max, tableLog);   { overflow protected }
        //log(stderr, 'buildCTable: FSE_writeNCount=', NCountSize);
        if (ERR_isError(NCountSize)<>0) then
        begin
             exit(NCountSize);
        end;
        errcode:=FSE_buildCTable_wksp(nextCTable, @norm[0], max, tableLog, entropyWorkspace, entropyWorkspaceSize);
        //log(stderr, 'buildCTable: FSE_buildCTable_wksp=', errcode);
        if (ERR_isError(errCode)<>0) then
        begin
             exit(errCode);
        end;
        exit(NCountSize);

     end;
     else
     begin
       assert(false);
       exit(ERROR(GENERIC_ERROR));//, 'impossible to reach');
     end;
    end;
end;

function ZSTD_encodeSequences_body(
            dst:pbyte; dstCapacity:int32;
            CTable_MatchLength:pFSE_CTable;mlCodeTable:pBYTE;
            CTable_OffsetBits:pFSE_CTable; ofCodeTable:pBYTE;
            CTable_LitLength:pFSE_CTable; llCodeTable:pBYTE;
            sequences:pseqDef; nbSeq,longOffsets:int32):int32;
var
  blockStream:BIT_CStream_t;
  stateMatchLength,stateOffsetBits,stateLitLength:FSE_CState_t;
  ofBits,extraBits:uint32;
  n,streamSize:int32;
  llCode,ofCode,mlCode:byte;
  llBits,mlBits:Uint32;
begin
    if ERR_isError(BIT_initCStream( @blockStream, dst, dstCapacity))<>0 then
        exit(ERROR(dstint32ooSmall));//, 'not enough space remaining');
    //DEBUGLOG(6, 'available space for bitstream : %i  (dstCapacity=%u)',
    //            (int)(blockStream.endPtr - blockStream.startPtr),
    //            (unsigned)dstCapacity);

    { first symbols }
    FSE_initCState2( @stateMatchLength, CTable_MatchLength, mlCodeTable[nbSeq-1]);
    FSE_initCState2( @stateOffsetBits,  CTable_OffsetBits,  ofCodeTable[nbSeq-1]);
    FSE_initCState2( @stateLitLength,   CTable_LitLength,   llCodeTable[nbSeq-1]);
    BIT_addBits( @blockStream, sequences[nbSeq-1].litLength, LL_bits[llCodeTable[nbSeq-1]]);
    if (sizeof(blockStream.bitContainer) <= 4) then
      BIT_flushBits( @blockStream);
    BIT_addBits( @blockStream, sequences[nbSeq-1].matchLength, ML_bits[mlCodeTable[nbSeq-1]]);
    if (sizeof(blockStream.bitContainer) <= 4) then
      BIT_flushBits( @blockStream);
    if (longOffsets<>0) then
    begin 
        ofBits := ofCodeTable[nbSeq-1];
        extraBits := ofBits - MIN(ofBits, STREAM_ACCUMULATOR_MIN-1);
        if (extraBits<>0) then
        begin
            BIT_addBits( @blockStream, sequences[nbSeq-1].offset, extraBits);
            BIT_flushBits( @blockStream);
        end;
        BIT_addBits( @blockStream, sequences[nbSeq-1].offset  shr  extraBits,
                    ofBits - extraBits);
    end
    else 
    begin
        BIT_addBits( @blockStream, sequences[nbSeq-1].offset, ofCodeTable[nbSeq-1]);
    end;
    BIT_flushBits( @blockStream);
   
    for n:=nbSeq-2 downto 0 do
    begin
        llCode := llCodeTable[n];
        ofCode := ofCodeTable[n];
        mlCode := mlCodeTable[n];
        llBits := LL_bits[llCode];
        ofBits := ofCode;
        mlBits := ML_bits[mlCode];
                                                                        { 32b}  { 64b}
                                                                        { (7)}  { (7)}
        FSE_encodeSymbol( @blockStream,  @stateOffsetBits, ofCode);       { 15 }  { 15 }
        FSE_encodeSymbol( @blockStream,  @stateMatchLength, mlCode);      { 24 }  { 24 }
        if (sizeof(blockStream.bitContainer) <= 4) then
          BIT_flushBits( @blockStream);                                   { (7)}
        FSE_encodeSymbol( @blockStream,  @stateLitLength, llCode);        { 16 }  { 33 }
        if (sizeof(blockStream.bitContainer) <= 4) or (ofBits+mlBits+llBits >= 64-7-(LLFSELog+MLFSELog+OffFSELog)) then
          BIT_flushBits( @blockStream);                                   { (7)}
        BIT_addBits( @blockStream, sequences[n].litLength, llBits);
        if (sizeof(blockStream.bitContainer) <= 4) and ((llBits+mlBits)>24) then
           BIT_flushBits( @blockStream);
        BIT_addBits( @blockStream, sequences[n].matchLength, mlBits);
        if (sizeof(blockStream.bitContainer) <= 4) or (ofBits+mlBits+llBits > 56) then
          BIT_flushBits( @blockStream);
        if (longOffsets<>0) then
        begin
            extraBits := ofBits - MIN(ofBits, STREAM_ACCUMULATOR_MIN-1);
            if (extraBits<>0) then
            begin
                BIT_addBits( @blockStream, sequences[n].offset, extraBits);
                BIT_flushBits( @blockStream);                            { (7)}
            end;
            BIT_addBits( @blockStream, sequences[n].offset  shr  extraBits,
                        ofBits - extraBits);                            { 31 }
        end
        else 
        begin
            BIT_addBits( @blockStream, sequences[n].offset, ofBits);     { 31 }
        end;
        BIT_flushBits( @blockStream);                                    { (7)}
    end;

    //DEBUGLOG(6, 'ZSTD_encodeSequences: flushing ML state with %u bits', stateMatchLength.stateLog);
    FSE_flushCState( @blockStream,  @stateMatchLength);
    //DEBUGLOG(6, 'ZSTD_encodeSequences: flushing Off state with %u bits', stateOffsetBits.stateLog);
    FSE_flushCState( @blockStream,  @stateOffsetBits);
    //DEBUGLOG(6, 'ZSTD_encodeSequences: flushing LL state with %u bits', stateLitLength.stateLog);
    FSE_flushCState( @blockStream,  @stateLitLength);

    streamSize := BIT_closeCStream( @blockStream);
    IF(streamSize=0) then
       exit(ERROR(dstint32ooSmall));//, 'not enough space');
    result := streamSize;
end;

function  ZSTD_encodeSequences_default(
            dst:pbyte; dstCapacity:int32;
            CTable_MatchLength:pFSE_CTable; mlCodeTable:pBYTE;
            CTable_OffsetBits:pFSE_CTable; ofCodeTable:pBYTE;
            CTable_LitLength:pFSE_CTable; llCodeTable:pBYTE;
            sequences:pseqDef;  nbSeq, longOffsets:int32):int32;
begin
    result:= ZSTD_encodeSequences_body(dst, dstCapacity,
                                    CTable_MatchLength, mlCodeTable,
                                    CTable_OffsetBits, ofCodeTable,
                                    CTable_LitLength, llCodeTable,
                                    sequences, nbSeq, longOffsets);
end;



function ZSTD_encodeSequences_bmi2(
            dst:pbyte; dstCapacity:int32;
            CTable_MatchLength:pFSE_CTable; mlCodeTable:pBYTE;
            CTable_OffsetBits:pFSE_CTable; ofCodeTable:pBYTE;
            CTable_LitLength:pFSE_CTable; llCodeTable:pBYTE;
            sequences:pseqDef;  nbSeq, longOffsets:int32):int32;
begin
    result:= ZSTD_encodeSequences_body(dst, dstCapacity,
                                    CTable_MatchLength, mlCodeTable,
                                    CTable_OffsetBits, ofCodeTable,
                                    CTable_LitLength, llCodeTable,
                                    sequences, nbSeq, longOffsets);
end;



function ZSTD_encodeSequences(
            dst:pbyte; dstCapacity:int32;
            CTable_MatchLength:pFSE_CTable; mlCodeTable:pbyte;
            CTable_OffsetBits:pFSE_CTable; ofCodeTable:pbyte;
            CTable_LitLength:pFSE_CTable; llCodeTable:pbyte;
            sequences:pseqDef;  nbSeq,  longOffsets,  bmi2:int32):int32;
begin
    //DEBUGLOG(5, 'ZSTD_encodeSequences: dstCapacity := %u', uint32(dstCapacity));

    if (bmi2<>0) then
    begin
        result := ZSTD_encodeSequences_bmi2(dst, dstCapacity,
                                         CTable_MatchLength, mlCodeTable,
                                         CTable_OffsetBits, ofCodeTable,
                                         CTable_LitLength, llCodeTable,
                                         sequences, nbSeq, longOffsets);
    end;
    result := ZSTD_encodeSequences_default(dst, dstCapacity,
                                        CTable_MatchLength, mlCodeTable,
                                        CTable_OffsetBits, ofCodeTable,
                                        CTable_LitLength, llCodeTable,
                                        sequences, nbSeq, longOffsets);
end;
end.
