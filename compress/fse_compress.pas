unit fse_compress;
{$mode objfpc}{$H+}
interface
uses
hist,       { HIST_count_wksp }
bitstream,
fse, entropy_common,zstd_internal,
error_private;

{ **************************************************************
*  Templates
***************************************************************}
{
  designed to be included
  for type-specific functions (template emulation in C)
  Objective is to write these functions only once, for improved maintenance
}
type
  pfseWkspMax_t=^fseWkspMax_t;
  fseWkspMax_t=record
    CTable_max:array [0..2561 {FSE_CTABLE_SIZE_Uint32(FSE_MAX_TABLELOG=12, FSE_MAX_SYMBOL_VALUE=255)}] of FSE_CTable;
    case integer of
     0:(hist_wksp:array [0..1023{HIST_WKSP_SIZE_Uint32-1}] of Uint32);
     1:(scratchBuffer:array [0.. 4096{1  shl  FSE_MAX_TABLELOG}] of BYTE);
  end;
  function FSE_optimalTableLog(maxTableLog:uint32; srcSize:int32; maxSymbolValue:uint32):uint32;
  function FSE_writeNCount (buffer:pbyte;  bufferSize:int32;
                    normalizedCounter:pint16; maxSymbolValue,tableLog:int32):int32;
  function FSE_buildCTable_rle (ct:pFSE_CTable; symbolValue:BYTE ):int32;
function FSE_buildCTable_wksp(ct:pFSE_CTable;normalizedCounter:pint16; 
  maxSymbolValue,tableLog:uint32;workSpace:pbyte;wkspSize:int32):int32;
function FSE_normalizeCount (normalizedCounter:pint16; tableLog:uint32;
  count:puint32; total:int32;maxSymbolValue,useLowProbCount:uint32):int32;
function FSE_optimalTableLog_internal(maxTableLog:uint32; srcSize:int32; maxSymbolValue:uint32; minus:uint32 ):uint32;
function FSE_compress_usingCTable_generic (dst:pbyte;  dstSize:int32;src:pbyte;  srcSize:int32; ct:pFSE_CTable;  fast:uint32):int32;
function FSE_compress_usingCTable (dst:pbyte;  dstSize:int32;src:pbyte;  srcSize:int32;ct:pFSE_CTable):int32;
implementation
{ Function templates }

{ FSE_buildCTable_wksp() :
 * Same as FSE_buildCTable(), but using an externally allocated scratch buffer (`workSpace`).
 * wkspSize should be sized to handle worst case situation, which is `1 shl max_tableLog * sizeof(byte)`
 * workSpace must also be properly aligned with byte requirements
 }
function FSE_buildCTable_wksp(ct:pFSE_CTable;normalizedCounter:pint16; 
  maxSymbolValue,tableLog:uint32;workSpace:pbyte;wkspSize:int32):int32;
var
  tableSize,tableMask,step,highThreshold,u:Uint32;
  ptr,FSCT:pbyte;
  tableU16:pword;
  symbolTT:pFSE_symbolCompressionTransform;
  cumul:pUint32;
  tableSymbol:pbyte;
  s,total:Uint32;
  position,symbol,maxBitsOut,minStatePlus:Uint32;
  nbOccurrences,freq:int32;
begin
    tableSize := 1  shl  tableLog;
    tableMask := tableSize - 1;
    ptr := pbyte(ct);
    tableU16 := pword(ptr) + 2;
    if tableLog<>0 then
      FSCT := pbyte(pUint32(ptr) + 1 { header } + tableSize shr 1)
    else
      FSCT := pbyte(pUint32(ptr) + 1 { header } + 1);
    symbolTT := pFSE_symbolCompressionTransform(FSCT);
    step := FSE_TABLESTEP(tableSize);

    cumul := pUint32(workSpace);
    tableSymbol := pbyte(cumul + (maxSymbolValue + 2));

    highThreshold := tableSize-1;

    if (int32(workSpace)  and  3)<>0 then
      exit(ERROR(GENERIC_ERROR)); { Must be 4 byte aligned }
    if (FSE_BUILD_CTABLE_WORKSPACE_SIZE(maxSymbolValue, tableLog) > wkspSize) then
      exit(ERROR(tableLog_tooLarge));
    { CTable header }
    tableU16[-2] := uint16(tableLog);
    tableU16[-1] := uint16(maxSymbolValue);
    assert(tableLog < 16);   { required for threshold strategy to work }

    { For explanations on how to distribute symbol values over the table :
     * http://fastcompression.blogspot.fr/2014/02/fse-distributing-symbol-values.html }


     fillbyte(tableSymbol^, sizeof(byte) * tableSize, 0);   { useless initialization, just to keep scan-build happy }

    { symbol start positions }
    
    cumul[0] := 0;
    for u:=1 to maxSymbolValue+1 do 
    begin
        if (normalizedCounter[u-1]=-1) then
        begin  { Low proba symbol }
            cumul[u] := cumul[u-1] + 1;
            tableSymbol[highThreshold] := byte(u-1);
            dec(highThreshold);
        end
        else 
        begin
            cumul[u] := cumul[u-1] + normalizedCounter[u-1];
        end;
    end;
    cumul[maxSymbolValue+1] := tableSize+1;

    { Spread symbols }
     
    position := 0;
    for symbol:=0 to maxSymbolValue do
    begin
      freq := normalizedCounter[symbol];
      for nbOccurrences:=0 to freq-1 do
      begin
        tableSymbol[position] := byte(symbol);
        position := (position + step)  and  tableMask;
        while (position > highThreshold) do
            position := (position + step)  and  tableMask;   { Low proba area }
      end;
    end;

    assert(position=0);  { Must have initialized all positions }

    { Build table } 
    for u:=0 to tableSize-1 do 
    begin
      s := tableSymbol[u];   { note : static analyzer may not understand tableSymbol is properly initialized }
      tableU16[cumul[s]] := word(tableSize+u);   { TableU16 : sorted by symbol order; gives next state value }
      inc(cumul[s]);
    end;

    { Build Symbol Transformation Table }
     
    total := 0;
    
    for s:=0 to maxSymbolValue do
    begin
        case (normalizedCounter[s]) of
          0:
          begin
            { filling nonetheless, for compatibility with FSE_getMaxNbBits() }
            symbolTT[s].deltaNbBits := ((tableLog+1)  shl  16) - (1 shl tableLog);
          end;
         -1,1:
          begin
            symbolTT[s].deltaNbBits := (tableLog  shl  16) - (1 shl tableLog);
            symbolTT[s].deltaFindState := total - 1;
            inc(total);
          end;
         else
            begin 
                maxBitsOut := tableLog - BIT_highbit32 (normalizedCounter[s]-1);
                minStatePlus := normalizedCounter[s]  shl  maxBitsOut;
                symbolTT[s].deltaNbBits := (maxBitsOut  shl  16) - minStatePlus;
                symbolTT[s].deltaFindState := total - normalizedCounter[s];
                total :=total +  normalizedCounter[s];
            end;   
        end;   
    end;

    result := 0;
end;


function FSE_buildCTable(ct:pFSE_CTable; normalizedCounter:pint16; maxSymbolValue,tableLog:int32):int32;
var
  tableSymbol:array[0..{FSE_MAX_TABLESIZE-1}4095] of byte;   { memset() is not necessary, even if static analyzer complain about it }
begin
  result := FSE_buildCTable_wksp(ct, normalizedCounter, maxSymbolValue, tableLog, @tableSymbol[0], sizeof(tableSymbol));
end;




{-**************************************************************
*  FSE NCount encoding
***************************************************************}
function FSE_NCountWriteBound(maxSymbolValue,tableLog:int32):int32;
var
  maxHeaderSize:int32;
begin
    maxHeaderSize := (((maxSymbolValue+1) * tableLog)  shr  3) + 3;
    if maxSymbolValue<>0 then
      result := maxHeaderSize  { maxSymbolValue=0 ? use default }
    else
      result := FSE_NCOUNTBOUND;
end;

function FSE_writeNCount_generic (header:pbyte;headerBufferSize:int32;
  normalizedCounter:pint16; maxSymbolValue,tableLog,writeIsSafe:uint32):int32;
var
  ostart,lout,oend:pbyte;
  nbBits,tableSize,remaining,threshold,bitCount,previousIs0:int32;
  bitStream,symbol,alphabetSize,start:uint32;
  count,max:int32;
begin
    ostart := header;
    lout := ostart;
    oend := ostart + headerBufferSize;
    tableSize := 1  shl  tableLog;
    bitStream := 0;
    bitCount := 0;
    symbol := 0;
    alphabetSize := maxSymbolValue + 1;
    previousIs0 := 0;

    { Table Size }
    bitStream :=bitStream + (tableLog-FSE_MIN_TABLELOG)  shl  bitCount;
    bitCount  :=bitCount  + 4;

    { Init }
    remaining := tableSize+1;   { +1 for extra accuracy }
    threshold := tableSize;
    nbBits := tableLog+1;

    while ((symbol < alphabetSize) and (remaining>1)) do
    begin  { stops at 1 }
        if (previousIs0<>0) then
        begin
            start := symbol;
            while (symbol < alphabetSize) and (normalizedCounter[symbol]=0) do
              inc(symbol);
            if (symbol = alphabetSize) then
              break;   { incorrect distribution }
            while (symbol >= start+24) do
            begin
                start:=start+24;
                bitStream :=bitStream + Uint32($FFFF)  shl  bitCount;
                if ((writeIsSafe=0) and (lout > oend-2)) then
                    exit(ERROR(dstint32ooSmall));   { Buffer overflow }
                lout[0] :=  bitStream;
                lout[1] := (bitStream shr 8);
                lout:=lout+2;
                bitStream :=bitStream shr 16;
            end;
            while (symbol >= start+3) do
            begin
                start:=start+3;
                bitStream :=bitStream + 3  shl  bitCount;
                bitCount  :=bitCount  + 2;
            end;
            bitStream:=bitStream + (symbol-start)  shl  bitCount;
            bitCount :=bitCount  + 2;
            if (bitCount>16) then
            begin
                if ((writeIsSafe=0) and (lout > oend - 2)) then
                    exit(ERROR(dstint32ooSmall));   { Buffer overflow }
                lout[0] := bitStream;
                lout[1] := (bitStream shr 8);
                lout :=lout + 2;
                bitStream :=bitStream  shr  16;
                bitCount  :=bitCount - 16;
            end;
        end; 
         
        count := normalizedCounter[symbol];
        inc(symbol);
        max := (2*threshold-1) - remaining;
        if count < 0 then
          remaining :=remaining - (-count)
        else
          remaining :=remaining - count;
        inc(count);   { +1 for extra accuracy }
        if (count>=threshold) then
            count :=count + max;   { [0..max[ [max..threshold[ (...) [threshold+max 2*threshold[ }
        bitStream :=bitStream + count  shl  bitCount;
        bitCount  :=bitCount  + nbBits;
        bitCount  :=bitCount  - ord(count<max);
        previousIs0  := ord(count=1);
        if (remaining<1) then
        begin
          //log(stderr, 'FSE_writeNCount: remaining<1 at symbol=', symbol, ' remaining=', remaining, ' count=', count);
          exit(ERROR(GENERIC_ERROR));
        end;
        while (remaining<threshold) do
        begin 
          dec(nbBits); 
          threshold :=threshold shr 1; 
        end;
        if (bitCount>16) then
        begin
            if ((writeIsSafe=0) and (lout > oend - 2)) then
                exit(ERROR(dstint32ooSmall));   { Buffer overflow }
            lout[0] := bitStream;
            lout[1] := (bitStream shr 8);
            lout :=lout + 2;
            bitStream :=bitStream  shr 16;
            bitCount :=bitCount - 16;
        end;   
    end;

    if (remaining <> 1) then
    begin
        //log(stderr, 'FSE_writeNCount: remaining<>1 at end, remaining=', remaining, ' symbol=', symbol, ' alphabetSize=', alphabetSize);
        exit(ERROR(GENERIC_ERROR));  { incorrect normalized distribution }
    end;
    assert(symbol <= alphabetSize);

    { flush remaining bitStream }
    if ((writeIsSafe=0) and (lout > oend - 2)) then
        exit(ERROR(dstint32ooSmall));   { Buffer overflow }
    lout[0] := bitStream;
    lout[1] := (bitStream shr 8);
    lout :=lout + (bitCount+7) div 8;

    result := (lout-ostart);
end;


function FSE_writeNCount (buffer:pbyte;  bufferSize:int32;
                  normalizedCounter:pint16; maxSymbolValue,tableLog:int32):int32;
begin
    if (tableLog > FSE_MAX_TABLELOG) then 
      exit(ERROR(tableLog_tooLarge));   { Unsupported }
    if (tableLog < FSE_MIN_TABLELOG) then 
      exit(ERROR(GENERIC_ERROR));   { Unsupported }

    if (bufferSize < FSE_NCountWriteBound(maxSymbolValue, tableLog)) then
        exit(FSE_writeNCount_generic(buffer, bufferSize, normalizedCounter, maxSymbolValue, tableLog, 0));

    result := FSE_writeNCount_generic(buffer, bufferSize, normalizedCounter, maxSymbolValue, tableLog, 1 { write in buffer is safe });
end;


{-**************************************************************
*  FSE Compression Code
***************************************************************}

function FSE_createCTable (maxSymbolValue,tableLog:int32):pFSE_CTable;
var
  size:int32;
begin
    if (tableLog > FSE_TABLELOG_ABSOLUTE_MAX) then
      tableLog := FSE_TABLELOG_ABSOLUTE_MAX;
    size := FSE_CTABLE_SIZE_Uint32 (tableLog, maxSymbolValue) * sizeof(Uint32);
    result := pFSE_CTable(allocmem(size));
end;

procedure FSE_freeCTable (ct:pFSE_CTable); 
begin 
  freemem(ct);
end;

{ provides the minimum logSize to safely represent a distribution }
function FSE_minTableLog(srcSize:int32; maxSymbolValue:uint32):uint32;
var
  minBitsSrc,minBitsSymbols,minBits:Uint32;
begin
    minBitsSrc := BIT_highbit32(Uint32(srcSize)) + 1;
    minBitsSymbols := BIT_highbit32(maxSymbolValue) + 2;
    if minBitsSrc < minBitsSymbols then
      minBits := minBitsSrc
    else
      minBits := minBitsSymbols;
    assert(srcSize > 1); { Not supported, RLE should be used instead }
    exit(minBits);
end;

function FSE_optimalTableLog_internal(maxTableLog:uint32; srcSize:int32; maxSymbolValue:uint32; minus:uint32 ):uint32;
var
  maxBitsSrc,tableLog,minBits:Uint32;
begin
    maxBitsSrc := BIT_highbit32(Uint32(srcSize - 1)) - minus;
    tableLog := maxTableLog;
    minBits := FSE_minTableLog(srcSize, maxSymbolValue);
    assert(srcSize > 1); { Not supported, RLE should be used instead }
    if (tableLog=0) then 
      tableLog := FSE_DEFAULT_TABLELOG;
    if (maxBitsSrc < tableLog) then 
      tableLog := maxBitsSrc;   { Accuracy can be reduced }
    if (minBits > tableLog) then 
      tableLog := minBits;   { Need a minimum to safely represent all symbol values }
    if (tableLog < FSE_MIN_TABLELOG) then 
      tableLog := FSE_MIN_TABLELOG;
    if (tableLog > FSE_MAX_TABLELOG) then 
      tableLog := FSE_MAX_TABLELOG;
    exit(tableLog)
end;

function FSE_optimalTableLog(maxTableLog:uint32; srcSize:int32; maxSymbolValue:uint32):uint32;
begin
    result := FSE_optimalTableLog_internal(maxTableLog, srcSize, maxSymbolValue, 2);
end;

{ Secondary normalization method.
   To be used when primary method fails. }

function FSE_normalizeM2(norm:pint16; tableLog:Uint32; count:puint32; total:int32; maxSymbolValue:Uint32; lowProbCount:int16):int32;
const
  NOT_YET_ASSIGNED:int16=2;
var
  s,lowThreshold,lowOne,sStart,sEnd,weight,distributed,ToDistribute:Uint32;
  vStepLog,mid,rStep,tmpTotal,lend:Uint64;
  maxV,maxC:Uint32;
begin

    distributed := 0;

    { Init }
    lowThreshold := Uint32(total  shr  tableLog);
    lowOne       := Uint32((total * 3)  shr  (tableLog + 1));

    for s:=0 to maxSymbolValue do 
    begin
        if (count[s] = 0) then
        begin
            norm[s]:=0;
            continue;
        end;
        if (count[s] <= lowThreshold) then
        begin
            norm[s] := lowProbCount;
            inc(distributed);
            total :=total - count[s];
            continue;
        end;
        if (count[s] <= lowOne) then
        begin
            norm[s] := 1;
            inc(distributed);
            total :=total - count[s];
            continue;
        end;

        norm[s]:=NOT_YET_ASSIGNED;
    end;
    ToDistribute := (1  shl  tableLog) - distributed;

    if (ToDistribute = 0) then
        exit(0);

    if ((total div ToDistribute) > lowOne) then
    begin
        { risk of rounding to zero }
        lowOne := Uint32((total * 3) div (ToDistribute * 2));
        for s:=0 to maxSymbolValue do
        begin
            if ((norm[s] = NOT_YET_ASSIGNED) and (count[s] <= lowOne)) then
            begin
                norm[s] := 1;
                inc(distributed);
                total :=total - count[s];
                continue;
            end;   
        end;
        ToDistribute := (1  shl  tableLog) - distributed;
    end;

    if (distributed = maxSymbolValue+1) then
    begin 
        { all values are pretty poor;
           probably incompressible data (should have already been detected);
           find max, then give all remaining points to max }
        maxV := 0; 
        maxC := 0;
        for s:=0 to maxSymbolValue do 
            if (count[s] > maxC) then
            begin
              maxV:=s; 
              maxC:=count[s]; 
            end;
        norm[maxV] :=norm[maxV] + int16(ToDistribute);
        exit(0)
    end;

    if (total = 0) then
    begin
      { all of the symbols were low enough for the lowOne or lowThreshold }
      s:=0;
      while (ToDistribute > 0) do
      begin
          if (norm[s] > 0) then
          begin 
            dec(ToDistribute); 
            inc(norm[s]); 
          end;
          s := (s+1) mod (maxSymbolValue+1);
      end;
      exit(0);
    end;

    vStepLog := 62 - tableLog;
    mid := (Uint64(1)  shl  (vStepLog-1)) - 1;
    rStep := (((Uint64(1) shl vStepLog) * ToDistribute) + mid div Uint32(total));   { scale on remaining }
    tmpTotal := mid;
    for s:=0 to maxSymbolValue do 
    begin
        if (norm[s]=NOT_YET_ASSIGNED) then
        begin  
            lend := tmpTotal + (count[s] * rStep);
            sStart := Uint32(tmpTotal  shr  vStepLog);
            sEnd := Uint32(lend  shr  vStepLog);
            weight := sEnd - sStart;
            if (weight < 1) then
                exit(ERROR(GENERIC_ERROR));
            norm[s] := int16(weight);
            tmpTotal := lend;
        end;   
    end;   
    exit(0)
end;

function FSE_normalizeCount (normalizedCounter:pint16; tableLog:uint32;
  count:puint32; total:int32;maxSymbolValue,useLowProbCount:uint32):int32;
const
  rtbTable:array[0..7] of Uint32 = (  0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 );
var
  lowProbCount,largestP,proba:int16;
  scale,step,vStep,restToBeat:Uint64;
  errorCode:int32;
  stillToDistribute,s,largest,lowThreshold:uint32;
begin
    { Sanity checks }
    if (tableLog=0) then
      tableLog := FSE_DEFAULT_TABLELOG;
    if (tableLog < FSE_MIN_TABLELOG) then
      exit(ERROR(GENERIC_ERROR));   { Unsupported size }
    if (tableLog > FSE_MAX_TABLELOG) then
      exit(ERROR(tableLog_tooLarge));   { Unsupported size }
    if (tableLog < FSE_minTableLog(total, maxSymbolValue)) then
      exit(ERROR(GENERIC_ERROR));   { Too small tableLog, compression potentially impossible }
    if useLowProbCount<>0 then
      lowProbCount := -1
    else
      lowProbCount := 1;
    scale := 62 - tableLog;
    step := (Uint64(1) shl 62 div Uint32(total));   { <= here, one division ! }
    vStep :=Uint64(1) shl (scale-20);
    stillToDistribute := 1 shl tableLog;
    largest:=0;
    largestP:=0;
    lowThreshold := Uint32(total  shr  tableLog);

    for s:=0 to maxSymbolValue do 
    begin
        if (count[s] = total) then
          exit(0);   { rle special case }
        if (count[s] = 0) then
        begin 
          normalizedCounter[s]:=0; 
          continue; 
        end;
        if (count[s] <= lowThreshold) then
        begin
            normalizedCounter[s] := lowProbCount;
            dec(stillToDistribute);
        end
        else 
        begin
            proba := word((count[s]*step)  shr  scale);
            if (proba<8) then
            begin
                restToBeat := vStep * rtbTable[proba];
                proba :=proba + ord((count[s]*step - (Uint64(proba) shl scale)) > restToBeat);
            end;
            if (proba > largestP) then
            begin 
              largestP:=proba; 
              largest:=s; 
            end;
            normalizedCounter[s] := proba;
            stillToDistribute :=stillToDistribute - proba;
        end;   
    end;
    if (-stillToDistribute >= (normalizedCounter[largest]  shr  1)) then
    begin
        { corner case, need another normalization method }
        errorCode := FSE_normalizeM2(normalizedCounter, tableLog, count, total, maxSymbolValue, lowProbCount);
        if (FSE_isError(errorCode)<>0) then
          exit(errorCode);
    end
    else 
      normalizedCounter[largest] :=normalizedCounter[largest] + int16(stillToDistribute);

    //log(stderr, 'FSE_normalizeCount DONE: ptr=', PtrUInt(normalizedCounter), ' norm[0..3]=',
    //  normalizedCounter[0], ',', normalizedCounter[1], ',', normalizedCounter[2], ',', normalizedCounter[3]);
    exit(tableLog)
end;


{ fake FSE_CTable, for raw (uncompressed) input }
function FSE_buildCTable_raw (ct:FSE_CTable; nbBits:uint32 ):int32;
var
  tableSize,tableMask,maxSymbolValue,s,deltaNbBits:uint32;
  ptr,FSCT:pbyte;
  tableU16:pword;
  symbolTT:pFSE_symbolCompressionTransform;
begin
    tableSize := 1  shl  nbBits;
    tableMask := tableSize - 1;
    maxSymbolValue := tableMask;
    ptr := pbyte(ct);
    tableU16 := puint16(ptr) + 2;
    FSCT :=pbyte( puint32(ptr) + 1 { header } + (tableSize shr 1));   { assumption : tableLog >= 1 }
    symbolTT := pFSE_symbolCompressionTransform (FSCT);

    { Sanity checks }
    if (nbBits < 1) then
      exit(ERROR(GENERIC_ERROR));             { min size }

    { header }
    tableU16[-2] := nbBits;
    tableU16[-1] := maxSymbolValue;

    { Build table }
    for s:=0 to tableSize-1 do
        tableU16[s] := uint16(tableSize + s);

    { Build Symbol Transformation Table }
     
    deltaNbBits := (nbBits  shl  16) - (1  shl  nbBits);
    for s:=0 to maxSymbolValue do 
    begin
      symbolTT[s].deltaNbBits := deltaNbBits;
      symbolTT[s].deltaFindState := s-1;
    end;

    exit(0)
end;

{ fake FSE_CTable, for rle input (always same symbol) }
function FSE_buildCTable_rle (ct:pFSE_CTable; symbolValue:BYTE ):int32;
var
  ptr,FSCTptr:pbyte;
  tableU16:pword;
  symbolTT:pFSE_symbolCompressionTransform;
begin
    ptr := pbyte(ct);
    tableU16 := pword( ptr) + 2;
    FSCTptr := pbyte(pUint32(ptr) + 2);
    symbolTT := pFSE_symbolCompressionTransform(FSCTptr);

    { header }
    tableU16[-2] :=  0;
    tableU16[-1] :=  symbolValue;

    { Build table }
    tableU16[0] := 0;
    tableU16[1] := 0;   { just in case }

    { Build Symbol Transformation Table }
    symbolTT[symbolValue].deltaNbBits := 0;
    symbolTT[symbolValue].deltaFindState := 0;

    exit(0)
end;


function FSE_compress_usingCTable_generic (dst:pbyte;  dstSize:int32;src:pbyte;  srcSize:int32;
  ct:pFSE_CTable;  fast:uint32):int32;
VAR
  istart,iend,ip:pbyte;
  bitC:BIT_CStream_t;
  CState1, CState2:FSE_CState_t;
  initError:int32;
begin
    istart := src;
    iend := istart + srcSize;
    ip:=iend;

    { init }
    if (srcSize <= 2) then
      exit(0);
     
    initError := BIT_initCStream(@bitC, dst, dstSize);
    if (FSE_isError(initError)<>0) then
      exit(0); { not enough space available to write a bitstream }

    if (srcSize  and  1)<>0 then
    begin
      dec(ip);
        FSE_initCState2(@CState1, ct, ip^);
        dec(ip);
        FSE_initCState2(@CState2, ct, ip^);
        dec(ip);
        FSE_encodeSymbol(@bitC, @CState1, ip^);
        BIT_flushBitsFast(@bitC);
    end 
    else 
    begin
      dec(ip);
        FSE_initCState2(@CState2, ct, ip^);
        dec(ip);
        FSE_initCState2(@CState1, ct, ip^);
    end;

    { join to mod 4 }
    srcSize :=srcSize - 2;
    if ((sizeof(bitC.bitContainer)*8 > FSE_MAX_TABLELOG*4+7 ) and ((srcSize  and  2)<>0)) then
    begin  { test bit 2 }
    dec(ip);
        FSE_encodeSymbol(@bitC, @CState2, ip^);
        dec(ip);
        FSE_encodeSymbol(@bitC, @CState1, ip^);
        BIT_flushBitsFast(@bitC);
    end;

    { 2 or 4 encoding per loop }
    while ( ip>istart ) do
    begin
        dec(ip);
        FSE_encodeSymbol(@bitC, @CState2, ip^);

        if (sizeof(bitC.bitContainer)*8 < FSE_MAX_TABLELOG*2+7 ) then  { this test must be static }
            BIT_flushBitsFast(@bitC);
        dec(ip);
        FSE_encodeSymbol(@bitC, @CState1, ip^);

        if (sizeof(bitC.bitContainer)*8 > FSE_MAX_TABLELOG*4+7 ) then
        begin  { this test must be static }
            dec(ip);
            FSE_encodeSymbol(@bitC, @CState2, ip^);
            dec(ip);
            FSE_encodeSymbol(@bitC, @CState1, ip^);
        end;

        BIT_flushBitsFast(@bitC);
    end;

    FSE_flushCState(@bitC, @CState2);
    FSE_flushCState(@bitC, @CState1);
    result := BIT_closeCStream(@bitC);
end;

function FSE_compress_usingCTable (dst:pbyte;  dstSize:int32;src:pbyte;  srcSize:int32;ct:pFSE_CTable):int32;
var
  fast:uint32;
begin
    fast := ord(dstSize >= FSE_BLOCKBOUND(srcSize));

    if (fast<>0) then
        result := FSE_compress_usingCTable_generic(dst, dstSize, src, srcSize, ct, 1)
    else
        result := FSE_compress_usingCTable_generic(dst, dstSize, src, srcSize, ct, 0);
end;


function FSE_compressBound(size:int32) :int32; 
begin 
  result := FSE_COMPRESSBOUND(size); 
end;

{ FSE_compress_wksp() :
 * Same as FSE_compress2(), but using an externally allocated scratch buffer (`workSpace`).
 * `wkspSize` size must be `(1 shl tableLog)`.
 }
function FSE_compress_wksp (dst:pbyte;  dstSize:int32; src:pbyte;  srcSize:int32; maxSymbolValue,tableLog:uint32; workSpace:pbyte;wkspSize:int32):int32;
var
  ostart,op,oend,scratchBuffer:pbyte;
  count:array[0..FSE_MAX_SYMBOL_VALUE] of uint32;
  norm:array[0..FSE_MAX_SYMBOL_VALUE] of int16;
  CTable:pFSE_CTable;
  CTableSize,scratchBufferSize,maxCount,nc_err,cSize:int32;
begin
    ostart := dst;
    op := ostart;
    oend := ostart + dstSize;

    CTable := pFSE_CTable(workSpace);
    CTableSize := FSE_CTABLE_SIZE_Uint32(tableLog, maxSymbolValue);
    scratchBuffer := pbyte(CTable + CTableSize);
    scratchBufferSize := wkspSize - (CTableSize * sizeof(FSE_CTable));

    { init conditions }
    if (wkspSize < FSE_COMPRESS_WKSP_SIZE_Uint32(tableLog, maxSymbolValue)) then
      exit(ERROR(tableLog_tooLarge));
    if (srcSize <= 1) then
      exit(0);  { Not compressible }
    if (maxSymbolValue=0) then
      maxSymbolValue := FSE_MAX_SYMBOL_VALUE;
    if (tableLog=0) then
      tableLog := FSE_DEFAULT_TABLELOG;

    { Scan input and build symbol stats }
    maxCount:=HIST_count_wksp(count,  @maxSymbolValue, src, srcSize, scratchBuffer, scratchBufferSize);
    if (ERR_isError(maxCount)<>0) then
       exit(maxCount);
    if (maxCount = srcSize) then
      exit(1);   { only a single symbol in src : rle }
    if (maxCount = 1) then
      exit(0);         { each symbol present maximum once :=> not compressible }
    if (maxCount < (srcSize  shr  7)) then
      exit(0);   { Heuristic : not compressible enough }


    tableLog := FSE_optimalTableLog(tableLog, srcSize, maxSymbolValue);

    { Write table description header }
    nc_err:=FSE_writeNCount(op, oend-op, @norm[0], maxSymbolValue, tableLog);   
    if (ERR_isError(nc_err)<>0) then
       exit(nc_err);
    op :=op + nc_err;

    { Compress }
    //CHECK_F( FSE_buildCTable_wksp(CTable, norm, maxSymbolValue, tableLog, scratchBuffer, scratchBufferSize) );
    cSize:=FSE_compress_usingCTable(op, oend - op, src, srcSize, @CTable[0]);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);
    if (cSize = 0) then
      exit(0);   { not enough space for compressed data }
    op :=op + cSize;

    { check compressibility }
    if ( int32(op-ostart) >= srcSize-1 ) then
      exit(0);

    result := op-ostart;
end;

function FSE_compress2 (dst:pbyte;  dstCapacity:int32; src:pbyte;  srcSize:int32; maxSymbolValue,tableLog:int32):int32;
var
  scratchBuffer:fseWkspMax_t;
begin
    //DEBUG_STATIC_ASSERT(sizeof(scratchBuffer) >= FSE_COMPRESS_WKSP_SIZE_Uint32(FSE_MAX_TABLELOG, FSE_MAX_SYMBOL_VALUE));   { compilation failures here means scratchBuffer is not large enough }
    if (tableLog > FSE_MAX_TABLELOG) then
      exit(ERROR(tableLog_tooLarge));
    result := FSE_compress_wksp(dst, dstCapacity, src, srcSize, maxSymbolValue, tableLog, @scratchBuffer, sizeof(scratchBuffer));
end;

function FSE_compress (dst:pbyte;  dstCapacity:int32; src:pbyte;  srcSize:int32):int32;
begin
    result :=  FSE_compress2(dst, dstCapacity, src, srcSize, FSE_MAX_SYMBOL_VALUE, FSE_DEFAULT_TABLELOG);
end;
end.
