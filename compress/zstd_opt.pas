unit zstd_opt ;
{$mode objfpc}{$H+}
interface
uses zstd_compress_internal,hist,zstd_internal,zstd,fse,huf,huf_compress,math;

const
  ZSTD_LITFREQ_ADD   = 2;   { scaling factor for litFreq, so that frequencies adapt faster to new stats }
  ZSTD_FREQ_DIV      = 4;   { log factor when using previous stats to init next stats }
  ZSTD_MAX_PRICE     =(1 shl 30);
  ZSTD_PREDEF_THRESHOLD =1024;   { if srcSize < ZSTD_PREDEF_THRESHOLD, symbols' cost is assumed static, directly determined by pre-defined distributions }
  BITCOST_ACCURACY   = 8;
  BITCOST_MULTIPLIER =(1  shl  BITCOST_ACCURACY);
  UINT_MAX = 4294967295;
{ =:=   Memory management   =:= }
type
   Trepo=array[0..2] of Uint32;
{************************
*  LDM helper functions  *
************************}

{ Struct containing info needed to make decision about ldm inclusion }
pZSTD_optLdm_t=^ZSTD_optLdm_t;
ZSTD_optLdm_t = record
    seqStore:rawSeqStore_t;         { External match candidates store for this block }
    startPosInBlock:Uint32;            { Start position of the current match candidate }
    endPosInBlock:Uint32;              { End position of the current match candidate }
    offset:Uint32;                     { Offset of the match candidate }
end;
function  ZSTD_compressBlock_btopt(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
function  ZSTD_compressBlock_btultra(
        ms:pZSTD_matchState_t;seqStore:pseqStore_t; rep:Trepo;
        src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_btultra2(ms:pZSTD_matchState_t;seqStore:pseqStore_t; rep:Trepo;
        src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_btopt_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_btultra_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_btopt_dictMatchState(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
function  ZSTD_compressBlock_btultra_dictMatchState(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
procedure ZSTD_updateTree(ms:pZSTD_matchState_t; ip, iend:pbyte);
implementation
uses zstd_compressf;
function  ZSTD_bitWeight(stat:Uint32):Uint32;
begin
    result := (ZSTD_highbit32(stat+1) * BITCOST_MULTIPLIER);
end;

function  ZSTD_fracWeight(rawStat:Uint32):Uint32;
var
  stat,hb,BWeight,FWeight,weight:Uint32;
begin
    stat := rawStat + 1;
    hb := ZSTD_highbit32(stat);
    BWeight := hb * BITCOST_MULTIPLIER;
    FWeight := (stat  shl  BITCOST_ACCURACY)  shr  hb;
    weight := BWeight + FWeight;
    result := weight;
end;

{ debugging function,
 * @return price in bytes as fractional value
 * for debug messages only }
function  ZSTD_fCost(price:Uint32):double;
begin
    result := price / (BITCOST_MULTIPLIER*8);
end;


function  ZSTD_compressedLiterals(optPtr:poptState_t):int32;
begin
    result := ord(optPtr^.literalCompressionMode <> ZSTD_lcm_uncompressed);
end;
function WEIGHT(stat,opt:uint32):int32;
begin
    if opt<>0 then
    result:=ZSTD_fracWeight(stat)
    else
    result:=ZSTD_bitWeight(stat);
end;

procedure ZSTD_setBasePrices(optPtr:poptState_t; optLevel:int32);
begin
    if (ZSTD_compressedLiterals(optPtr)<>0) then
        optPtr^.litSumBasePrice := WEIGHT(optPtr^.litSum, optLevel);
    optPtr^.litLengthSumBasePrice := WEIGHT(optPtr^.litLengthSum, optLevel);
    optPtr^.matchLengthSumBasePrice := WEIGHT(optPtr^.matchLengthSum, optLevel);
    optPtr^.offCodeSumBasePrice := WEIGHT(optPtr^.offCodeSum, optLevel);
end;


{ ZSTD_downscaleStat() :
 * reduce all elements in table by a factor 2^(ZSTD_FREQ_DIV+malus)
 * return the resulting sum of elements }
function  ZSTD_downscaleStat(table:puint32; lastEltIndex:Uint32; malus:int32):Uint32;
var
  s,sum:Uint32;
begin
  sum:=0;
  //log(3,  'ZSTD_downscaleStat (nbElts:=%u)', lastEltIndex+1);
  for s:=0 to lastEltIndex do
  begin
      table[s] := 1 + (table[s]  shr  (ZSTD_FREQ_DIV+malus));
      sum :=sum + table[s];
  end;
  result := sum;
end;

{ ZSTD_rescaleFreqs() :
 * if first block (detected by optPtr^.litLengthSum = 0) : init statistics
 *    take hints from dictionary if there is one
 *    or init from zero, using src for literals stats, or flat 1 for match symbols
 * otherwise downscale existing stats, to be used as seed for next block.
 }
procedure ZSTD_rescaleFreqs(optPtr:poptState_t;src:pbyte;srcSize,optLevel:int32);
var
  compressedLiterals:int32;
  scaleLog,bitCost:Uint32;
  ll,ml,lof,lit:uint32;
  llstate,mlstate,ofstate:FSE_CState_t;  
begin
    compressedLiterals := ZSTD_compressedLiterals(optPtr);
    //log(3,  'ZSTD_rescaleFreqs (srcSize:=%u)', srcSize);
    optPtr^.priceType := zop_dynamic;

    if (optPtr^.litLengthSum = 0) then
    begin  { first block : init }
        if (srcSize <= ZSTD_PREDEF_THRESHOLD) then
        begin  { heuristic }
            //log(3,  '(srcSize <= ZSTD_PREDEF_THRESHOLD) :=> zop_predef');
            optPtr^.priceType := zop_predef;
        end;

        if (optPtr^.symbolCosts^.huf.repeatMode = HUF_repeat_valid) then
        begin
            { huffman table presumed generated by dictionary }
            optPtr^.priceType := zop_dynamic;

            if (compressedLiterals<>0) then
            begin
                optPtr^.litSum := 0;
                for lit:=0 to MaxLit do
                begin
                    scaleLog := 11;   { scale to 2K }
                    bitCost := HUF_getNbBits(@optPtr^.symbolCosts^.huf.CTable[0], lit);
                    if bitCost<>0 then
                    optPtr^.litFreq[lit] :=  1  shl  (scaleLog-bitCost)
                    else
                    optPtr^.litFreq[lit] :=  1 {minimum to calculate cost};
                    optPtr^.litSum :=optPtr^.litSum + optPtr^.litFreq[lit];
                end;   
            end;

             
                    
            FSE_initCState( @llstate, optPtr^.symbolCosts^.fse.litlengthCTable);
            optPtr^.litLengthSum := 0;
            for ll:=0 to MaxLL do
            begin
                scaleLog := 10;   { scale to 1K }
                bitCost := FSE_getMaxNbBits(llstate.symbolTT, ll);
                if bitCost<>0 then
                optPtr^.litLengthFreq[ll] := 1  shl  (scaleLog-bitCost)
                else
                optPtr^.litLengthFreq[ll] := 1 {minimum to calculate cost};
                optPtr^.litLengthSum :=optPtr^.litLengthSum + optPtr^.litLengthFreq[ll];
            end;


            FSE_initCState( @mlstate, optPtr^.symbolCosts^.fse.matchlengthCTable);
            optPtr^.matchLengthSum := 0;
            for ml:=0 to MaxML do
            begin
                scaleLog := 10;
                bitCost := FSE_getMaxNbBits(mlstate.symbolTT, ml);
                if bitCost<>0 then
                optPtr^.matchLengthFreq[ml] := 1  shl  (scaleLog-bitCost)
                else
                optPtr^.matchLengthFreq[ml] := 1 {minimum to calculate cost};
                optPtr^.matchLengthSum :=optPtr^.matchLengthSum + optPtr^.matchLengthFreq[ml];
            end;

            FSE_initCState( @ofstate, optPtr^.symbolCosts^.fse.offcodeCTable);
            optPtr^.offCodeSum := 0;
            for lof:=0 to MaxOff do
            begin
                scaleLog := 10;
                bitCost := FSE_getMaxNbBits(ofstate.symbolTT, lof);
                if bitCost<>0 then
                optPtr^.offCodeFreq[lof] := 1  shl  (scaleLog-bitCost)
                else
                optPtr^.offCodeFreq[lof] := 1 {minimum to calculate cost};
                optPtr^.offCodeSum :=optPtr^.offCodeSum + optPtr^.offCodeFreq[lof];
            end;
        end 
        else 
        begin  { not a dictionary }

            if (compressedLiterals<>0) then
            begin
                lit := MaxLit;
                HIST_count_simple(optPtr^.litFreq,  @lit, src, srcSize);   { use raw first block to init statistics }
                optPtr^.litSum := ZSTD_downscaleStat(optPtr^.litFreq, MaxLit, 1);
            end;

            for ll:=0 to MaxLL do
                optPtr^.litLengthFreq[ll] := 1;

            optPtr^.litLengthSum := MaxLL+1;

            for ml:=0 to MaxML do
                optPtr^.matchLengthFreq[ml] := 1;
                    
            optPtr^.matchLengthSum := MaxML+1;

            for lof:=0 to MaxOff do
                optPtr^.offCodeFreq[lof] := 1;

            optPtr^.offCodeSum := MaxOff+1;

        end;
    end 
    else 
    begin   { new block : re-use previous statistics, scaled down }

        if (compressedLiterals<>0) then
            optPtr^.litSum := ZSTD_downscaleStat(optPtr^.litFreq, MaxLit, 1);
        optPtr^.litLengthSum := ZSTD_downscaleStat(optPtr^.litLengthFreq, MaxLL, 0);
        optPtr^.matchLengthSum := ZSTD_downscaleStat(optPtr^.matchLengthFreq, MaxML, 0);
        optPtr^.offCodeSum := ZSTD_downscaleStat(optPtr^.offCodeFreq, MaxOff, 0);
    end;

    ZSTD_setBasePrices(optPtr, optLevel);
end;

{ ZSTD_rawLiteralsCost() :
 * price of literals (only) in specified segment (which length can be 0).
 * does not include price of literalLength symbol }
function ZSTD_rawLiteralsCost(literals:pbyte; litLength:Uint32;optPtr:poptState_t;optLevel:int32):Uint32;
var
  price,u:Uint32;
begin
    if (litLength = 0) then 
      exit(0);

    if (ZSTD_compressedLiterals(optPtr)=0) then
        exit((litLength  shl  3) * BITCOST_MULTIPLIER);  { Uncompressed - 8 bytes per literal. }

    if (optPtr^.priceType = zop_predef) then
        exit((litLength*6) * BITCOST_MULTIPLIER);  { 6 bit per literal - no statistic used }

    { dynamic statistics }
   
    price := litLength * optPtr^.litSumBasePrice;
    for u:=0  to litLength -1 do
    begin
        price :=price - WEIGHT(optPtr^.litFreq[literals[u]], optLevel);
    end;
    result := price;

end;

{ ZSTD_litLengthPrice() :
 * cost of literalLength symbol }
function  ZSTD_litLengthPrice(litLength:Uint32; optPtr:poptState_t; optLevel:int32):Uint32;
var
  llCode:Uint32;
begin
    if (optPtr^.priceType = zop_predef) then
      exit(WEIGHT(litLength, optLevel));

    { dynamic statistics }   
    llCode := ZSTD_LLcode(litLength);
    result := (LL_bits[llCode] * BITCOST_MULTIPLIER)
           + optPtr^.litLengthSumBasePrice
           - WEIGHT(optPtr^.litLengthFreq[llCode], optLevel);
end;

{ ZSTD_getMatchPrice() :
 * Provides the cost of the match part (offset + matchLength) of a sequence
 * Must be combined with ZSTD_fullLiteralsCost() to get the full cost of a sequence.
 * optLevel: when <2, favors small offset for decompression speed (improved cache efficiency) }
function ZSTD_getMatchPrice(offset,matchLength:Uint32;optPtr:poptState_t;optLevel:int32):Uint32;
var
  price,offCode,mlBase,mlCode:Uint32;
begin
    offCode := ZSTD_highbit32(offset+1);
    mlBase := matchLength - MINMATCH;

    if (optPtr^.priceType = zop_predef) then  { fixed scheme, do not use statistics }
        exit(WEIGHT(mlBase, optLevel) + ((16 + offCode) * BITCOST_MULTIPLIER));

    { dynamic statistics }
    price := (offCode * BITCOST_MULTIPLIER) + (optPtr^.offCodeSumBasePrice - WEIGHT(optPtr^.offCodeFreq[offCode], optLevel));
    if (optLevel<2) and  (offCode >= 20) then
        price :=price + (offCode-19)*2 * BITCOST_MULTIPLIER; { handicap for long distance offsets, favor decompression speed }

    { match Length }
    mlCode := ZSTD_MLcode(mlBase);
    price :=price + (ML_bits[mlCode] * BITCOST_MULTIPLIER) + (optPtr^.matchLengthSumBasePrice - WEIGHT(optPtr^.matchLengthFreq[mlCode], optLevel));

    price :=price + BITCOST_MULTIPLIER div 5;   { heuristic : make matches a bit more costly to favor less sequences ^. faster decompression speed }

    //log(3,  'ZSTD_getMatchPrice(ml:%u) := %u', matchLength, price);
    result := price;
end;

{ ZSTD_updateStats() :
 * assumption : literals + litLengtn <= iend }
procedure ZSTD_updateStats(optPtr:poptState_t;litLength:Uint32; literals:pbyte;offsetCode,matchLength:Uint32 );
var
  u,llCode,offCode,mlBase,mlCode:Uint32;
begin
    { literals }
    if (ZSTD_compressedLiterals(optPtr)<>0) then
    begin
        for u:=0 to litLength-1 do
            optPtr^.litFreq[literals[u]] :=optPtr^.litFreq[literals[u]] + ZSTD_LITFREQ_ADD;
        optPtr^.litSum :=optPtr^.litSum + litLength*ZSTD_LITFREQ_ADD;
    end;

    { literal Length }
 
    llCode := ZSTD_LLcode(litLength);
    inc(optPtr^.litLengthFreq[llCode]);
    inc(optPtr^.litLengthSum);


    { match offset code (0-2:=>repCode; 3+:=>offset+2) }
 
    offCode := ZSTD_highbit32(offsetCode+1);
    inc(optPtr^.offCodeFreq[offCode]);
    inc(optPtr^.offCodeSum);


    { match Length } 
    mlBase := matchLength - MINMATCH;
    mlCode := ZSTD_MLcode(mlBase);
    inc(optPtr^.matchLengthFreq[mlCode]);
    inc(optPtr^.matchLengthSum);
end;


{ ZSTD_readMINMATCH() :
 * function safe only for comparisons
 * assumption : memPtr must be at least 4 bytes before end of buffer }
function  ZSTD_readMINMATCH(memPtr:pbyte; llength:Uint32):Uint32;
begin
    case (llength) of
      4 : exit(MEM_read32(memPtr));
      3 : {$ifdef ENDIAN_LITTLE}
                exit(MEM_read32(memPtr) shl 8);
             {$ENDIF}
             {$ifdef ENDIAN_BIG}
                exit(MEM_read32(memPtr) shr 8);
             {$ENDIF}
      else  exit(puint32(memPtr)^);
    end;
end;


{ Update hashTable3 up to ip (excluded)
   Assumption : always within prefix (i.e. not within extDict) }
function  ZSTD_insertAndFindFirstIndexHash3 (ms:pZSTD_matchState_t;nextToUpdate3:pUint32;ip:pbyte):Uint32;
var
  hashTable3:puint32;
  hashLog3,idx,target:Uint32;
  base:pbyte;
  hash3:int32;
begin
    hashTable3:= ms^.hashTable3;
    hashLog3 := ms^.hashLog3;
    base := ms^.window.base;
    idx := nextToUpdate3^;
    target := Uint32(ip - base);
    hash3 := ZSTD_hash3Ptr(ip, hashLog3);

    while(idx < target) do
    begin
        hashTable3[ZSTD_hash3Ptr(base+idx, hashLog3)] := idx;
        idx:=idx+1;
    end;

    nextToUpdate3^ := target;
    result := hashTable3[hash3];
end;


{-*************************************
*  Binary Tree search
**************************************}
{* ZSTD_insertBt1() : add one or multiple positions to tree.
 *  ip : assumed <= iend-8 .
 * @return : nb of positions added }
function  ZSTD_insertBt1(ms:pZSTD_matchState_t;ip:pbyte; iend:pbyte;mls:Uint32; extDict:int32):Uint32;
var
  cParams:pZSTD_compressionParameters;
  hashTable,smallerPtr,largerPtr,nextPtr,predictPtr,bt:pUint32;
  hashLog,btLog,btMask,matchIndex,dictLimit,curr,btLow:Uint32;
  h,commonLengthSmaller,commonLengthLarger:int32;
  base,dictBase,dictEnd,match,prefixStart:pbyte;
  dummy32,windowLow,matchEndIdx,nbCompares,predictedSmall,predictedLarge,positions:Uint32;
  bestLength,matchLength:int32;
begin
    cParams :=  @ms^.cParams;
    hashTable := ms^.hashTable;
    hashLog := cParams^.hashLog;
    h  := ZSTD_hashPtr(ip, hashLog, mls);
    bt := ms^.chainTable;
    btLog  := cParams^.chainLog - 1;
    btMask := (1  shl  btLog) - 1;
    matchIndex := hashTable[h];
    commonLengthSmaller:=0;
    commonLengthLarger:=0;
    base := ms^.window.base;
    dictBase := ms^.window.dictBase;
    dictLimit := ms^.window.dictLimit;
    dictEnd := dictBase + dictLimit;
    prefixStart := base + dictLimit;
    curr := Uint32(ip-base);
    if btMask >= curr then
      btLow := 0
    else
      btLow := curr - btMask;
    smallerPtr := bt + 2*(curr and btMask);
    largerPtr  := smallerPtr + 1;
    windowLow := ms^.window.lowLimit;
    matchEndIdx := curr+8+1;
    bestLength := 8;
    nbCompares := Uint32(1)  shl  cParams^.searchLog;

    predictedSmall := bt [2*((curr-1) and btMask) + 0];
    predictedLarge := bt [2*((curr-1) and btMask) + 1];
    predictedSmall :=predictedSmall + ord(predictedSmall>0);
    predictedLarge :=predictedLarge + ord(predictedLarge>0);


    //log(3,  'ZSTD_insertBt1 (%u)', curr);

    hashTable[h] := curr;   { Update Hash Table }

    while (nbCompares<>0)  and  (matchIndex >= windowLow) do
    begin
      dec(nbCompares);
      nextPtr := bt + 2*(matchIndex  and  btMask);
      matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }

      predictPtr := bt + 2*((matchIndex-1)  and  btMask);   { written this way, as bt is a roll buffer }
        if (matchIndex = predictedSmall) then
        begin
            { no need to check length, result known }
            smallerPtr^ := matchIndex;
            if (matchIndex <= btLow) then
            begin 
              smallerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop the search }
            smallerPtr := nextPtr+1;               { new 'smaller' :=> larger of match }
            matchIndex := nextPtr[1];              { new matchIndex larger than previous (closer to current) }
            predictedSmall := predictPtr[1] + ord(predictPtr[1]>0);
            continue;
        end;
        if (matchIndex = predictedLarge) then
        begin
            largerPtr^ := matchIndex;
            if (matchIndex <= btLow) then
            begin 
              largerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop the search }
            largerPtr := nextPtr;
            matchIndex := nextPtr[0];
            predictedLarge := predictPtr[0] + ord(predictPtr[0]>0);
            continue;
        end;

        if ((extDict=0)  or  (matchIndex+matchLength >= dictLimit)) then
        begin
            match := base + matchIndex;
            matchLength :=matchLength + ZSTD_count(ip+matchLength, match+matchLength, iend);
        end 
        else 
        begin
            match := dictBase + matchIndex;
            matchLength :=matchLength + ZSTD_count_2segments(ip+matchLength, match+matchLength, iend, dictEnd, prefixStart);
            if (matchIndex+matchLength >= dictLimit) then
                match := base + matchIndex;   { to prepare for next usage of match[matchLength] }
        end;

        if (matchLength > bestLength) then
        begin
            bestLength := matchLength;
            if (matchLength > matchEndIdx - matchIndex) then
                matchEndIdx := matchIndex + Uint32(matchLength);
        end;

        if (ip+matchLength = iend) then
        begin   { equal : no way to know if inf or sup }
            break;   { drop , to guarantee consistency ; miss a bit of compression, but other solutions can corrupt tree }
        end;

        if (match[matchLength] < ip[matchLength]) then
        begin  { necessarily within buffer }
            { match is smaller than current }
            smallerPtr^ := matchIndex;             { update smaller idx }
            commonLengthSmaller := matchLength;    { all smaller will now have at least this guaranteed common length }
            if (matchIndex <= btLow) then
            begin 
              smallerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop searching }
            smallerPtr := nextPtr+1;               { new 'candidate' :=> larger than match, which was smaller than target }
            matchIndex := nextPtr[1];              { new matchIndex, larger than previous and closer to current }
        end 
        else 
        begin
            { match is larger than current }
            largerPtr^ := matchIndex;
            commonLengthLarger := matchLength;
            if (matchIndex <= btLow) then
            begin 
              largerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop searching }
            largerPtr := nextPtr;
            matchIndex := nextPtr[0];
        end;   
    end;

    smallerPtr^ := 0;
    largerPtr^ := 0; 
    positions := 0;
    if (bestLength > 384) then
      positions := MIN(192, Uint32(bestLength - 384));   { speed optimization }
    result := MAX(positions, matchEndIdx - (curr + 8));
end;


procedure ZSTD_updateTree_internal(ms:pZSTD_matchState_t;ip:pbyte;iend:pbyte;mls:Uint32;dictMode:ZSTD_dictMode_e );
var
  base:pbyte;
  target,idx,lforward:Uint32;
begin
    base := ms^.window.base;
    target := Uint32(ip - base);
    idx := ms^.nextToUpdate;
    //log(3,  'ZSTD_updateTree_internal, from %u to %u  (dictMode:%u)',idx, target, dictMode);

    while(idx < target) do
    begin
        lforward := ZSTD_insertBt1(ms, base+idx, iend, mls, ord(dictMode = ZSTD_extDict));
        idx :=idx + lforward;
    end;
    ms^.nextToUpdate := target;
end;

procedure ZSTD_updateTree(ms:pZSTD_matchState_t; ip, iend:pbyte);
begin
    ZSTD_updateTree_internal(ms, ip, iend, ms^.cParams.minMatch, ZSTD_noDict);
end;


function  ZSTD_insertBtAndGetAllMatches (
                    matches:pZSTD_match_t;   { store result (found matches) in this table (presumed large enough) }
                    ms:pZSTD_matchState_t;
                    nextToUpdate3:pUint32;
                    ip, iLimit:pbyte;dictMode:ZSTD_dictMode_e;
                    rep:Trepo;
                    ll0:Uint32;   { tells if associated literal length is 0 or not. This value must be 0 or 1 }
                    lengthToBeat:Uint32;
                    mls:Uint32 { template }):Uint32;
var
  cParams:pZSTD_compressionParameters;
  sufficient_len,curr,hashLog,minMatch,matchIndex,btLog,btMask:Uint32;
  base:pbyte;
  bt,hashTable:pUint32;
  h,commonLengthSmaller,commonLengthLarger:int32;    
  dictBase,dictEnd,prefixStart:pbyte;
  dictLimit,btLow,windowLow,matchLow,matchEndIdx,dummy32,mnum,nbCompares:Uint32;
  smallerPtr,largerPtr,nextPtr:pUint32;
  dms:pZSTD_matchState_t;
  dmsCParams:pZSTD_compressionParameters;
  dmsBase,dmsEnd,repMatch,match:pbyte;
  dmsHighLimit,dmsLowLimit,dmsIndexDelta,dmsHashLog,dmsBtLog,dmsBtMask,dmsBtLow:Uint32;
  lastR,repCode,repOffset,repIndex,repLen:Uint32;
  matchIndex3:Uint32;
  mlen,matchLength,bestLength:int32;
  dmsH:int32;
  dictMatchIndex:uint32;
  dmsBt:puint32;
begin
    cParams            :=  @ms^.cParams;
    sufficient_len     := MIN(cParams^.targetLength, ZSTD_OPT_NUM -1);
    base               := ms^.window.base;
    curr               := Uint32(ip-base);
    hashLog            := cParams^.hashLog;
    if (mls=3) then
      minMatch           := 3
    else
      minMatch           := 4;
    hashTable          := ms^.hashTable;
    h                  := ZSTD_hashPtr(ip, hashLog, mls);
    matchIndex         := hashTable[h];
    bt                 := ms^.chainTable;
    btLog              := cParams^.chainLog - 1;
    btMask             := (Uint32(1)  shl  btLog) - 1;
    commonLengthSmaller:=0; 
    commonLengthLarger :=0;
    
    dictBase    := ms^.window.dictBase;
    dictLimit   := ms^.window.dictLimit;
    dictEnd     := dictBase + dictLimit;
    prefixStart := base + dictLimit;
    if (btMask >= curr) then
    btLow       := 0
    else
    btLow       := curr - btMask;
    windowLow   := ZSTD_getLowestMatchIndex(ms, curr, cParams^.windowLog);
    if windowLow<>0 then
      matchLow    := windowLow
    else
      matchLow    := 1;
    smallerPtr  := bt + 2*(curr and btMask);
    largerPtr   := bt + 2*(curr and btMask) + 1;
    matchEndIdx := curr+8+1;   { farthest referenced position of any match :=> detects repetitive patterns }
    mnum        := 0;
    nbCompares  := Uint32(1)  shl  cParams^.searchLog;

    if dictMode = ZSTD_dictMatchState then
    begin
      dms           := ms^.dictMatchState;
      dmsCParams    :=  @dms^.cParams;
      dmsBase       := dms^.window.base;
      dmsEnd        := dms^.window.nextSrc;
      dmsHighLimit  := Uint32(dmsEnd - dmsBase);
      dmsLowLimit   := dms^.window.lowLimit;
      dmsIndexDelta := windowLow - dmsHighLimit;
      dmsHashLog    := dmsCParams^.hashLog;
      dmsBtLog      := dmsCParams^.chainLog - 1;
      dmsBtMask     := (Uint32(1)  shl  dmsBtLog) - 1;
    end
    else
    begin
      dms           := nil;
      dmsCParams    := nil;
      dmsBase       := nil;
      dmsEnd        := nil;
      dmsHighLimit  := 0;
      dmsLowLimit   := 0;
      dmsIndexDelta := 0;
      dmsHashLog    := hashLog;
      dmsBtLog      := btLog;
      dmsBtMask     := 0;
    end;
    if (dictMode = ZSTD_dictMatchState)  and  (dmsBtMask < dmsHighLimit - dmsLowLimit) then
      dmsBtLow      := dmsHighLimit - dmsBtMask
    else
      dmsBtLow      := dmsLowLimit;
    
    bestLength := lengthToBeat-1;
    //log(3,  'ZSTD_insertBtAndGetAllMatches: current:=%u', curr);

    { check repCode }
    
    lastR := ZSTD_REP_NUM + ll0;

    for repCode := ll0 to lastR-1 do
    begin
        if (repCode=ZSTD_REP_NUM) then
        repOffset := (rep[0] - 1)
        else
        repOffset := rep[repCode];
        repIndex := curr - repOffset;
        repLen := 0;
        if (repOffset-1 { intentional overflow, discards 0 and -1 } < curr-dictLimit) then
        begin  { equivalent to `curr > repIndex >= dictLimit` }
            { We must validate the repcode offset because when we're using a dictionary the
             * valid offset range shrinks when the dictionary goes out of bounds.
             }
            if ((repIndex >= windowLow)  and  (ZSTD_readMINMATCH(ip, minMatch) = ZSTD_readMINMATCH(ip - repOffset, minMatch))) then
            begin
                repLen := Uint32(ZSTD_count(ip+minMatch, ip+minMatch-repOffset, iLimit)) + minMatch;
            end;
        end
        else 
        begin  { repIndex < dictLimit  or  repIndex >= curr }
            if dictMode = ZSTD_dictMatchState then
            repMatch := dmsBase + repIndex - dmsIndexDelta
            else
            repMatch := dictBase + repIndex;
            if ( (dictMode = ZSTD_extDict) and  
               ( 
               ((repOffset-1) {intentional overflow} < curr - windowLow)  { equivalent to `curr > repIndex >= windowLow` } 
               and  
               ((Uint32((dictLimit-1) - repIndex) >= 3) ) { intentional overflow : do not test positions overlapping 2 memory segments }
               )
               and  (ZSTD_readMINMATCH(ip, minMatch) = ZSTD_readMINMATCH(repMatch, minMatch)) ) then
            begin
                repLen := Uint32(ZSTD_count_2segments(ip+minMatch, repMatch+minMatch, iLimit, dictEnd, prefixStart)) + minMatch;
            end;
            if ((dictMode = ZSTD_dictMatchState)
               and  ( ((repOffset-1) {intentional overflow} < curr - (dmsLowLimit + dmsIndexDelta))  { equivalent to `curr > repIndex >= dmsLowLimit` }
                  and  (Uint32((dictLimit-1) - repIndex) >= 3) ) { intentional overflow : do not test positions overlapping 2 memory segments }
               and  (ZSTD_readMINMATCH(ip, minMatch) = ZSTD_readMINMATCH(repMatch, minMatch)) ) then
            begin
                repLen := Uint32(ZSTD_count_2segments(ip+minMatch, repMatch+minMatch, iLimit, dmsEnd, prefixStart)) + minMatch;
            end;   
        end;
        { save longer solution }
        if (repLen > bestLength) then
        begin
            //log(3,  'found repCode %u (ll0:%u, offset:%u) of length %u', repCode, ll0, repOffset, repLen);
            bestLength := repLen;
            matches[mnum].off := repCode - ll0;
            matches[mnum].len := Uint32(repLen);
            inc(mnum);
            if ( (repLen > sufficient_len) or  (ip+repLen = iLimit) ) then
            begin  { best possible }
                exit(mnum);
            end;
        end;   
    end;

    { HC3 match finder }
    
    if ((mls = 3) {static}  and  (bestLength < mls)) then
    begin
        matchIndex3 := ZSTD_insertAndFindFirstIndexHash3(ms, nextToUpdate3, ip);
        if ((matchIndex3 >= matchLow)
           and  (curr - matchIndex3 < (1 shl 18)) {heuristic : longer distance likely too expensive} ) then
        begin
            if ((dictMode = ZSTD_noDict) {static}  or  (dictMode = ZSTD_dictMatchState) {static}  or  (matchIndex3 >= dictLimit)) then
            begin
                match := base + matchIndex3;
                mlen := ZSTD_count(ip, match, iLimit);
            end
            else 
            begin
                match := dictBase + matchIndex3;
                mlen := ZSTD_count_2segments(ip, match, iLimit, dictEnd, prefixStart);
            end;

            { save best solution }
            if (mlen >= mls { = 3 > bestLength }) then
            begin
                //log(3,  'found small match with hlog3, of length %u',Uint32(mlen));
                bestLength := mlen;
                matches[0].off := (curr - matchIndex3) + ZSTD_REP_MOVE;
                matches[0].len := Uint32(mlen);
                mnum := 1;
                if (mlen > sufficient_len) or (ip+mlen = iLimit) then
                begin  { best possible length }
                    ms^.nextToUpdate := curr+1;  { skip insertion }
                    exit(1);
                end;   
            end;   
        end;
        { no dictMatchState lookup: dicts don't have a populated HC3 table }
    end;

    hashTable[h] := curr;   { Update Hash Table }

    while (nbCompares<>0)  and  (matchIndex >= matchLow) do
    begin
        dec(nbCompares);
        nextPtr := bt + 2*(matchIndex  and  btMask);
        matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }

        if ((dictMode = ZSTD_noDict)  or  (dictMode = ZSTD_dictMatchState)  or  (matchIndex+matchLength >= dictLimit)) then
        begin
            match := base + matchIndex;
            matchLength :=matchLength + ZSTD_count(ip+matchLength, match+matchLength, iLimit);
        end
        else 
        begin
            match := dictBase + matchIndex;
            matchLength :=matchLength + ZSTD_count_2segments(ip+matchLength, match+matchLength, iLimit, dictEnd, prefixStart);
            if (matchIndex+matchLength >= dictLimit) then
                match := base + matchIndex;   { prepare for match[matchLength] read }
        end;

        if (matchLength > bestLength) then
        begin
            //log(3,  'found match of length %u at distance %u (offCode:=%u)',Uint32(matchLength), curr - matchIndex, curr - matchIndex + ZSTD_REP_MOVE);

            if (matchLength > matchEndIdx - matchIndex) then
                matchEndIdx := matchIndex + Uint32(matchLength);
            bestLength := matchLength;
            matches[mnum].off := (curr - matchIndex) + ZSTD_REP_MOVE;
            matches[mnum].len := Uint32(matchLength);
            inc(mnum);
            if ( (matchLength > ZSTD_OPT_NUM) 
                or  (ip+matchLength = iLimit) { equal : no way to know if inf or sup }) then
            begin
                if (dictMode = ZSTD_dictMatchState) then
                  nbCompares := 0; { break should also skip searching dms }
                break; { drop, to preserve bt consistency (miss a little bit of compression) }
            end;
        end;

        if (match[matchLength] < ip[matchLength]) then
        begin
            { match smaller than current }
            smallerPtr^ := matchIndex;             { update smaller idx }
            commonLengthSmaller := matchLength;    { all smaller will now have at least this guaranteed common length }
            if (matchIndex <= btLow) then
            begin 
              smallerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop the search }
            smallerPtr := nextPtr+1;               { new candidate :=> larger than match, which was smaller than current }
            matchIndex := nextPtr[1];              { new matchIndex, larger than previous, closer to current }
        end
        else 
        begin
            largerPtr^ := matchIndex;
            commonLengthLarger := matchLength;
            if (matchIndex <= btLow) then
            begin 
              largerPtr:= @dummy32; 
              break; 
            end;   { beyond tree size, stop the search }
            largerPtr := nextPtr;
            matchIndex := nextPtr[0];
        end;   
    end;

    smallerPtr^ := 0; 
    largerPtr^ := 0;

    if ((ord(dictMode) = ord(ZSTD_dictMatchState))  and  (nbCompares<>0)) then
    begin
        dmsH := ZSTD_hashPtr(ip, dmsHashLog, mls);
        dictMatchIndex := dms^.hashTable[dmsH];
        dmsBt := dms^.chainTable;
        commonLengthLarger := 0;
        commonLengthSmaller := 0;
        while (nbCompares<>0)  and  (dictMatchIndex > dmsLowLimit) do
        begin
          dec(nbCompares);
          nextPtr := dmsBt + 2*(dictMatchIndex  and  dmsBtMask);
          matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }
          match := dmsBase + dictMatchIndex;
          matchLength :=matchLength + ZSTD_count_2segments(ip+matchLength, match+matchLength, iLimit, dmsEnd, prefixStart);
            if (dictMatchIndex+matchLength >= dmsHighLimit) then
                match := base + dictMatchIndex + dmsIndexDelta;   { to prepare for next usage of match[matchLength] }

            if (matchLength > bestLength) then
            begin
                matchIndex := dictMatchIndex + dmsIndexDelta;
                //log(3,  'found dms match of length %u at distance %u (offCode:=%u)',Uint32(matchLength), curr - matchIndex, curr - matchIndex + ZSTD_REP_MOVE);
                if (matchLength > matchEndIdx - matchIndex) then
                    matchEndIdx := matchIndex + Uint32(matchLength);
                bestLength := matchLength;
                matches[mnum].off := (curr - matchIndex) + ZSTD_REP_MOVE;
                matches[mnum].len := Uint32(matchLength);
                inc(mnum);
                if ( (matchLength > ZSTD_OPT_NUM)
                    or  (ip+matchLength = iLimit) { equal : no way to know if inf or sup }) then
                begin
                    break;   { drop, to guarantee consistency (miss a little bit of compression) }
                end;
            end;

            if (dictMatchIndex <= dmsBtLow) then
              break;   { beyond tree size, stop the search }
            if (match[matchLength] < ip[matchLength]) then
            begin
                commonLengthSmaller := matchLength;    { all smaller will now have at least this guaranteed common length }
                dictMatchIndex := nextPtr[1];              { new matchIndex larger than previous (closer to current) }
            end
            else 
            begin
                { match is larger than current }
                commonLengthLarger := matchLength;
                dictMatchIndex := nextPtr[0];
            end;
        end;
    end;

    ms^.nextToUpdate := matchEndIdx - 8;  { skip repetitive patterns }
    result := mnum;
end;


function  ZSTD_BtGetAllMatches (matches:pZSTD_match_t;   { store result (match found, increasing size) in this table }
  ms:pZSTD_matchState_t;nextToUpdate3:pUint32;ip:pbyte; iHighLimit:pbyte;dictMode:ZSTD_dictMode_e;rep:Trepo;ll0:Uint32;lengthToBeat:Uint32):Uint32;
var
  cParams:pZSTD_compressionParameters;
  matchLengthSearch:Uint32;
begin
    cParams := @ms^.cParams;
    matchLengthSearch := cParams^.minMatch;
    //log(3,  'ZSTD_BtGetAllMatches');
    if (ip < ms^.window.base + ms^.nextToUpdate) then
      exit(0);   { skipped area }
    ZSTD_updateTree_internal(ms, ip, iHighLimit, matchLengthSearch, dictMode);
    case (matchLengthSearch) of
      3    : exit(ZSTD_insertBtAndGetAllMatches(matches, ms, nextToUpdate3, ip, iHighLimit, dictMode, rep, ll0, lengthToBeat, 3));    
      4    : exit(ZSTD_insertBtAndGetAllMatches(matches, ms, nextToUpdate3, ip, iHighLimit, dictMode, rep, ll0, lengthToBeat, 4));
      5    : exit(ZSTD_insertBtAndGetAllMatches(matches, ms, nextToUpdate3, ip, iHighLimit, dictMode, rep, ll0, lengthToBeat, 5));
      6,7  : exit(ZSTD_insertBtAndGetAllMatches(matches, ms, nextToUpdate3, ip, iHighLimit, dictMode, rep, ll0, lengthToBeat, 6));
      else exit(ZSTD_insertBtAndGetAllMatches(matches, ms, nextToUpdate3, ip, iHighLimit, dictMode, rep, ll0, lengthToBeat, 4));
    end;
end;



{ ZSTD_optLdm_skipRawSeqStoreBytes():
 * Moves forward in rawSeqStore by nbBytes, which will update the fields 'pos' and 'posInSequence'.
 }
procedure ZSTD_optLdm_skipRawSeqStoreBytes(rawSeqStore:prawSeqStore_t; nbBytes:int32);
var
  currPos:Uint32;
  currSeq:rawSeq;
begin
    currPos := Uint32(rawSeqStore^.posInSequence + nbBytes);
    while (currPos<>0)  and  (rawSeqStore^.pos < rawSeqStore^.size) do
    begin
        currSeq := rawSeqStore^.seq[rawSeqStore^.pos];
        if (currPos >= currSeq.litLength + currSeq.matchLength) then
        begin
            currPos :=currPos - currSeq.litLength + currSeq.matchLength;
            inc(rawSeqStore^.pos);
        end
        else 
        begin
            rawSeqStore^.posInSequence := currPos;
            break;
        end;
    end;
    if (currPos = 0)  or  (rawSeqStore^.pos = rawSeqStore^.size) then
    begin
        rawSeqStore^.posInSequence := 0;
    end;
end;

{ ZSTD_opt_getNextMatchAndUpdateSeqStore():
 * Calculates the beginning and end of the next match in the current block.
 * Updates 'pos' and 'posInSequence' of the ldmSeqStore.
 }
procedure ZSTD_opt_getNextMatchAndUpdateSeqStore(optLdm:pZSTD_optLdm_t; currPosInBlock:Uint32;blockBytesRemaining:Uint32);
var
  currSeq:rawSeq;
  currBlockEndPos,literalsBytesRemaining,matchBytesRemaining:Uint32;
begin

    { Setting match end position to MAX to ensure we never use an LDM during this block }
    if (optLdm^.seqStore.size = 0)  or  (optLdm^.seqStore.pos >= optLdm^.seqStore.size) then
    begin
        optLdm^.startPosInBlock := UINT_MAX;
        optLdm^.endPosInBlock := UINT_MAX;
        exit;
    end;
    { Calculate appropriate bytes left in matchLength and litLength after adjusting
       based on ldmSeqStore^.posInSequence }
    currSeq := optLdm^.seqStore.seq[optLdm^.seqStore.pos];
    currBlockEndPos := currPosInBlock + blockBytesRemaining;
    if (optLdm^.seqStore.posInSequence < currSeq.litLength) then
      literalsBytesRemaining := currSeq.litLength - Uint32(optLdm^.seqStore.posInSequence)
    else
      literalsBytesRemaining :=  0;
    if (literalsBytesRemaining = 0) then
      matchBytesRemaining :=  currSeq.matchLength - (Uint32(optLdm^.seqStore.posInSequence) - currSeq.litLength)
    else
      matchBytesRemaining := currSeq.matchLength;
    { If there are more literal bytes than bytes remaining in block, no ldm is possible }
    if (literalsBytesRemaining >= blockBytesRemaining) then
    begin
        optLdm^.startPosInBlock := UINT_MAX;
        optLdm^.endPosInBlock := UINT_MAX;
        ZSTD_optLdm_skipRawSeqStoreBytes( @optLdm^.seqStore, blockBytesRemaining);
        exit;
    end;

    { Matches may be < MINMATCH by this process. In that case, we will reject them
       when we are deciding whether or not to add the ldm }
    optLdm^.startPosInBlock := currPosInBlock + literalsBytesRemaining;
    optLdm^.endPosInBlock := optLdm^.startPosInBlock + matchBytesRemaining;
    optLdm^.offset := currSeq.offset;

    if (optLdm^.endPosInBlock > currBlockEndPos) then
    begin
        { Match ends after the block ends, we can't use the whole match }
        optLdm^.endPosInBlock := currBlockEndPos;
        ZSTD_optLdm_skipRawSeqStoreBytes( @optLdm^.seqStore, currBlockEndPos - currPosInBlock);
    end
    else 
    begin
        { Consume nb of bytes equal to size of sequence left }
        ZSTD_optLdm_skipRawSeqStoreBytes( @optLdm^.seqStore, literalsBytesRemaining + matchBytesRemaining);
    end;
end;

{ ZSTD_optLdm_maybeAddMatch():
 * Adds a match if it's long enough, based on it's 'matchStartPosInBlock'
 * and 'matchEndPosInBlock', into 'matches'. Maintains the correct ordering of 'matches'
 }
procedure ZSTD_optLdm_maybeAddMatch(matches:pZSTD_match_t; nbMatches:pUint32;optLdm:pZSTD_optLdm_t;currPosInBlock:Uint32);
var
  posDiff,candidateMatchLength,candidateOffCode:Uint32;
begin
    posDiff := currPosInBlock - optLdm^.startPosInBlock;
    { Note: ZSTD_match_t actually contains offCode and matchLength (before subtracting MINMATCH) }
    candidateMatchLength := optLdm^.endPosInBlock - optLdm^.startPosInBlock - posDiff;
    candidateOffCode := optLdm^.offset + ZSTD_REP_MOVE;

    { Ensure that current block position is not outside of the match }
    if (currPosInBlock < optLdm^.startPosInBlock)
       or  (currPosInBlock >= optLdm^.endPosInBlock)
       or  (candidateMatchLength < MINMATCH) then
    begin
        exit;
    end;

    if ( nbMatches^ = 0)  or  ((candidateMatchLength > matches[nbMatches^-1].len)  and  (nbMatches^ < ZSTD_OPT_NUM)) then
    begin
        //log(3,  'ZSTD_optLdm_maybeAddMatch(): Adding ldm candidate match (offCode: %u matchLength %u) at block position:=%u',
        //         candidateOffCode, candidateMatchLength, currPosInBlock);
        matches[nbMatches^].len := candidateMatchLength;
        matches[nbMatches^].off := candidateOffCode;
        inc(nbMatches^);
    end;
end;

{ ZSTD_optLdm_processMatchCandidate():
 * Wrapper function to update ldm seq store and call ldm functions as necessary.
 }
procedure ZSTD_optLdm_processMatchCandidate(optLdm:pZSTD_optLdm_t;matches:pZSTD_match_t; nbMatches:pUint32;currPosInBlock,remainingBytes:Uint32);
var
  posOvershoot:Uint32;
begin
    if (optLdm^.seqStore.size = 0)  or  (optLdm^.seqStore.pos >= optLdm^.seqStore.size) then
    begin
        exit;
    end;

    if (currPosInBlock >= optLdm^.endPosInBlock) then
    begin
        if (currPosInBlock > optLdm^.endPosInBlock) then
        begin
            { The position at which ZSTD_optLdm_processMatchCandidate() is called is not necessarily
             * at the end of a match from the ldm seq store, and will often be some bytes
             * over beyond matchEndPosInBlock. As such, we need to correct for these 'overshoots'
             }
            posOvershoot := currPosInBlock - optLdm^.endPosInBlock;
            ZSTD_optLdm_skipRawSeqStoreBytes( @optLdm^.seqStore, posOvershoot);
        end; 
        ZSTD_opt_getNextMatchAndUpdateSeqStore(optLdm, currPosInBlock, remainingBytes);
    end;
    ZSTD_optLdm_maybeAddMatch(matches, nbMatches, optLdm, currPosInBlock);
end;

{-*******************************
*  Optimal parser
********************************}


function  ZSTD_totalLen(sol:ZSTD_optimal_t):Uint32;
begin
    result := sol.litlen + sol.mlen;
end;


procedure listStats(table:pUint32; lastEltID:int32);
var
  nbElts,enb:int32;
begin
  nbElts := lastEltID + 1;
  for enb:=0 to nbElts-1 do
  begin
      { RAWLOG(2, '%3i:%3i,  ', enb, table[enb]); }
      //log(3,  '%4i,', table[enb]);
  end;
  //log(2, ' \n');
end;


function  ZSTD_compressBlock_opt_generic(ms:pZSTD_matchState_t;seqStore:pseqStore_t;rep:Trepo;src:pbyte;srcSize:int32;optLevel:int32;dictMode:ZSTD_dictMode_e ):int32;
label _shortestPath;
var
  optStatePtr:poptState_t;
  istart,anchor,iend,iLimit,base,prefixStart,inr,ip:pbyte;
  cParams:pZSTD_compressionParameters;
  sufficient_len,minMatch,nextToUpdate3,cur, last_pos,nbMatches,i:Uint32;
  opt:pZSTD_optimal_t;
  lastSequence:ZSTD_optimal_t;
  matches:pZSTD_match_t;
  optLdm:ZSTD_optLdm_t;
  litlen,ll0:Uint32;
  maxML,maxOffset:Uint32;
  literalsPrice,pos,matchNb,prev:Uint32;
  lend,offset,matchPrice,sequencePrice:Uint32;
  price:int32;
  previousPrice,basePrice,startML,lastML:Uint32;
  storeEnd,storeStart,seqPos,backDist,storePos:Uint32;
  llen,mlen,offCode,advance:uint32;
   newReps:repcodes_t;
   reps:repcodes_t;
begin
    optStatePtr :=  @ms^.opt;
    istart := src;
    ip := istart;
    anchor := istart;
    iend := istart + srcSize;
    iLimit := iend - 8;
    base := ms^.window.base;
    prefixStart := base + ms^.window.dictLimit;
    cParams := @ms^.cParams;

    sufficient_len := MIN(cParams^.targetLength, ZSTD_OPT_NUM -1);
    if (cParams^.minMatch = 3) then
      minMatch := 3
    else
      minMatch := 4;
    nextToUpdate3 := ms^.nextToUpdate;

    opt := optStatePtr^.priceTable;
    matches := optStatePtr^.matchTable;
    if ms^.ldmSeqStore<>nil then
      optLdm.seqStore := ms^.ldmSeqStore^
    else
      optLdm.seqStore := knilRawSeqStore;
    optLdm.offset := 0;
    optLdm.startPosInBlock :=  0;
    optLdm.endPosInBlock :=  0;
    ZSTD_opt_getNextMatchAndUpdateSeqStore(@optLdm, Uint32(ip-istart), Uint32(iend-ip));

    { init }
    //log(3,  'ZSTD_compressBlock_opt_generic: current:=%u, prefix:=%u, nextToUpdate:=%u',
    //            Uint32(ip - base), ms^.window.dictLimit, ms^.nextToUpdate);
    ZSTD_rescaleFreqs(optStatePtr, src, srcSize, optLevel);
    ip :=ip + ord(ip=prefixStart);

    { Match Loop }
    while (ip < ilimit) do
    begin
        last_pos := 0;

        { find first match }
        
        begin   
          litlen := Uint32(ip - anchor);
          ll0 := ord(litlen = 0);
          nbMatches := ZSTD_BtGetAllMatches(matches, ms, @nextToUpdate3, ip, iend, dictMode, rep, ll0, minMatch);
          ZSTD_optLdm_processMatchCandidate(@optLdm, matches, @nbMatches,
                                              Uint32(ip-istart), Uint32(iend - ip));
            if (nbMatches=0) then
            begin 
              inc(ip); 
              continue; 
            end;

            { initialize opt[0] }
 
            for i:=0 to ZSTD_REP_NUM-1 do 
              opt[0].rep[i] := rep[i]; 
            opt[0].mlen := 0;  { means is_a_literal }
            opt[0].litlen := litlen;
            { We don't need to include the actual price of the literals because
             * it is static for the duration of the forward pass, and is included
             * in every price. We include the literal length to avoid negative
             * prices when we subtract the previous literal length.
             }
            opt[0].price := ZSTD_litLengthPrice(litlen, optStatePtr, optLevel);

            { large match ^. immediate encoding }
            
   
            maxML := matches[nbMatches-1].len;
            maxOffset := matches[nbMatches-1].off;
            //log(3,  'found %u matches of maxLength:=%u and maxOffCode:=%u at cPos:=%u :=> start new series',
            //            nbMatches, maxML, maxOffset, Uint32(ip-prefixStart));

            if (maxML > sufficient_len) then
            begin
                lastSequence.litlen := litlen;
                lastSequence.mlen := maxML;
                lastSequence.off := maxOffset;
                //log(3,  'large match (%u>%u), immediate encoding',
                //            maxML, sufficient_len);
                cur := 0;
                last_pos := ZSTD_totalLen(lastSequence);
                goto _shortestPath;
            end;   


            { set prices for first matches starting position = 0 }
            
            begin   
                literalsPrice := opt[0].price + ZSTD_litLengthPrice(0, optStatePtr, optLevel);
                for pos := 1 to minMatch-1 do 
                begin
                    opt[pos].price := ZSTD_MAX_PRICE;   { mlen, litlen and price will be fixed during forward scanning }
                end;
                for matchNb := 0  to nbMatches-1  do
                
                begin
                    offset := matches[matchNb].off;
                    lend := matches[matchNb].len;
                    for pos:=pos to lend do
                    begin
                        matchPrice := ZSTD_getMatchPrice(offset, pos, optStatePtr, optLevel);
                        sequencePrice := literalsPrice + matchPrice;
                        //log(3,  'rPos:%u :=> set initial price : %.2f',
                        //            pos, ZSTD_fCost(sequencePrice));
                        opt[pos].mlen := pos;
                        opt[pos].off := offset;
                        opt[pos].litlen := litlen;
                        opt[pos].price := sequencePrice;
                    end;   
                end;
                last_pos := pos-1;
            end;
        end;

        { check further positions }
        cur := 1;
        while (cur <= last_pos) do
        begin
            inr := ip + cur;
            //log(3,  'cPos:%zi=rPos:%u', inr-istart, cur);

            { Fix current position with one literal if cheaper }
            if (opt[cur-1].mlen = 0) then
              litlen := opt[cur-1].litlen + 1
            else
              litlen := 1;
            price := opt[cur-1].price+ ZSTD_rawLiteralsCost(ip+cur-1, 1, optStatePtr, optLevel)
                              + ZSTD_litLengthPrice(litlen, optStatePtr, optLevel)
                              - ZSTD_litLengthPrice(litlen-1, optStatePtr, optLevel);
            if (price <= opt[cur].price) then
            begin
                //log(3,  'cPos:%zi=rPos:%u : better price (%.2f<=%.2f) using literal (ll=%u) (hist:%u,%u,%u)',
                //            inr-istart, cur, ZSTD_fCost(price), ZSTD_fCost(opt[cur].price), litlen,
                //            opt[cur-1].rep[0], opt[cur-1].rep[1], opt[cur-1].rep[2]);
                opt[cur].mlen := 0;
                opt[cur].off := 0;
                opt[cur].litlen := litlen;
                opt[cur].price := price;
            end
            else 
            begin
                //log(3,  'cPos:%zi=rPos:%u : literal would cost more (%.2f>%.2f) (hist:%u,%u,%u)',
                //            inr-istart, cur, ZSTD_fCost(price), ZSTD_fCost(opt[cur].price),
                //            opt[cur].rep[0], opt[cur].rep[1], opt[cur].rep[2]);
            end;

            { Set the repcodes of the current position. We must do it here
             * because we rely on the repcodes of the 2nd to last sequence being
             * correct to set the next chunks repcodes during the backward
             * traversal.
             }
            //ASSERT(sizeof(opt[cur].rep) = sizeof(repcodes_t));

            if (opt[cur].mlen <> 0) then
            begin
                prev := cur - opt[cur].mlen;
                newReps := ZSTD_updateRep(opt[prev].rep, opt[cur].off, ord(opt[cur].litlen=0));
                move(newReps, opt[cur].rep,  sizeof(repcodes_t));
            end
            else 
            begin
                move(opt[cur - 1].rep, opt[cur].rep,  sizeof(repcodes_t));
            end;

            { last match must start at a minimum distance of 8 from oend }
            if (inr > ilimit) then
              continue;

            if (cur = last_pos) then
              break;

            if ( (optLevel=0) {static_test}
               and  (opt[cur+1].price <= opt[cur].price + (BITCOST_MULTIPLIER/2)) ) then
            begin
                //log(3,  'move to next rPos:%u : price is <=', cur+1);
                continue;  { skip unpromising positions; about ~+6% speed, -0.01 ratio }
            end;

            
              ll0 := ord(opt[cur].mlen <> 0);
              if (opt[cur].mlen = 0) then
                litlen :=  opt[cur].litlen
              else
                litlen :=  0;
              previousPrice := opt[cur].price;
              basePrice := previousPrice + ZSTD_litLengthPrice(0, optStatePtr, optLevel);
              nbMatches := ZSTD_BtGetAllMatches(matches, ms, @nextToUpdate3, inr, iend, dictMode, opt[cur].rep, ll0, minMatch);
              ZSTD_optLdm_processMatchCandidate(@optLdm, matches, @nbMatches,Uint32(inr-istart), Uint32(iend-inr));

              if (nbMatches=0) then 
              begin
                  //log(3,  'rPos:%u : no match found', cur);
                  continue;
              end;

              maxML := matches[nbMatches-1].len;
              //log(3,  'cPos:%zi=rPos:%u, found %u matches, of maxLength:=%u',inr-istart, cur, nbMatches, maxML);

              if ( (maxML > sufficient_len)
                 or  (cur + maxML >= ZSTD_OPT_NUM) ) then
              begin
                  lastSequence.mlen := maxML;
                  lastSequence.off := matches[nbMatches-1].off;
                  lastSequence.litlen := litlen;
                  if (opt[cur].mlen=0) then
                   cur :=cur - opt[cur].litlen;// : 0;  { last sequence is actually only literals, fix cur to last match - note : may underflow, in which case, it's first sequence, and it's okay }
                  last_pos := cur + ZSTD_totalLen(lastSequence);
                  if (cur > ZSTD_OPT_NUM) then
                    cur := 0;   { underflow :=> first match }
                  goto _shortestPath;
              end;

                { set prices using matches found at position = cur }
                for matchNb := 0 to nbMatches-1 do
                begin
                    offset := matches[matchNb].off;
                    lastML := matches[matchNb].len;
                    if (matchNb>0) then
                      startML := matches[matchNb-1].len+1
                    else
                      startML := minMatch;

                    //log(3,  'testing match %u :=> offCode:=%4u, mlen:=%2u, llen:=%2u',
                    //            matchNb, matches[matchNb].off, lastML, litlen);

                    for mlen := lastML downto startML do
                    begin  { scan downward }
                        pos := cur + mlen;
                        price := basePrice + ZSTD_getMatchPrice(offset, mlen, optStatePtr, optLevel);

                        if ((pos > last_pos)  or  (price < opt[pos].price)) then
                        begin
                            //log(3,  'rPos:%u (ml:=%2u) :=> new better price (%.2f<%.2f)',pos, mlen, ZSTD_fCost(price), ZSTD_fCost(opt[pos].price));
                            while (last_pos < pos) do
                            begin 
                              opt[last_pos+1].price := ZSTD_MAX_PRICE; 
                              inc(last_pos); 
                            end;   { fill empty positions }
                            opt[pos].mlen := mlen;
                            opt[pos].off := offset;
                            opt[pos].litlen := litlen;
                            opt[pos].price := price;
                        end
                        else 
                        begin
                            //log(3,  'rPos:%u (ml:=%2u) :=> new price is worse (%.2f>=%.2f)',pos, mlen, ZSTD_fCost(price), ZSTD_fCost(opt[pos].price));
                            if (optLevel=0) then
                              break;  { early update abort; gets ~+10% speed for about -0.01 ratio loss }
                        end;
                    end;   
                end;
                inc(cur);
        end;  { for (cur := 1; cur <= last_pos; cur++) }

        lastSequence := opt[last_pos];
        if last_pos > ZSTD_totalLen(lastSequence) then
          cur :=  last_pos - ZSTD_totalLen(lastSequence)  { single sequence, and it starts before `ip` }
        else
          cur :=  0;  { single sequence, and it starts before `ip` }

_shortestPath:   { cur, last_pos, best_mlen, best_off have to be set }

        { Set the next chunk's repcodes based on the repcodes of the beginning
         * of the last match, and the last sequence. This avoids us having to
         * update them while traversing the sequences.
         }
        if (lastSequence.mlen <> 0) then
        begin
            reps := ZSTD_updateRep(opt[cur].rep, lastSequence.off, ord(lastSequence.litlen=0));
            move(reps, rep, sizeof(repcodes_t));
        end 
        else 
        begin
            move(opt[cur].rep, rep,  sizeof(repcodes_t));
        end;
        
        storeEnd := cur + 1;
        storeStart := storeEnd;
        seqPos := cur;

        //log(3,  'start reverse traversal (last_pos:%u, cur:%u)',
        //            last_pos, cur);
        //log(3,  'last sequence copied into pos:=%u (llen:=%u,mlen:=%u,ofc:=%u)',
        //            storeEnd, lastSequence.litlen, lastSequence.mlen, lastSequence.off);
        opt[storeEnd] := lastSequence;
        while (seqPos > 0) do
        begin
            backDist := ZSTD_totalLen(opt[seqPos]);
            dec(storeStart);
            //log(3,  'sequence from rPos:=%u copied into pos:=%u (llen:=%u,mlen:=%u,ofc:=%u)',
            //            seqPos, storeStart, opt[seqPos].litlen, opt[seqPos].mlen, opt[seqPos].off);
            opt[storeStart] := opt[seqPos];
            if (seqPos > backDist) then
            seqPos := seqPos - backDist
            else
            seqPos := 0;
        end;

        { save sequences }
        //log(3,  'sending selected sequences into seqStore');
        
        for storePos:=storeStart to storeEnd do
        begin
            llen := opt[storePos].litlen;
            mlen := opt[storePos].mlen;
            offCode := opt[storePos].off;
            advance := llen + mlen;
            //log(3,  'considering seq starting at %zi, llen:=%u, mlen:=%u',
            //            anchor - istart, llen,mlen);

            if (mlen=0) then
            begin  { only literals :=> must be last 'sequence', actually starting a new stream of sequences }
                ip := anchor + llen;     { last 'sequence' is a bunch of literals :=> don't progress anchor }
                continue;   { will finish }
            end;

            ZSTD_updateStats(optStatePtr, llen, anchor, offCode, mlen);
            ZSTD_storeSeq(seqStore, llen, anchor, iend, offCode, mlen-MINMATCH);
            anchor :=anchor + advance;
            ip := anchor;
        end;
        ZSTD_setBasePrices(optStatePtr, optLevel);
    end;   { while (ip < ilimit) }

    { Return the last literals size }
    result := int32(iend - anchor);
end;


function  ZSTD_compressBlock_btopt(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
begin
    //log(3,  'ZSTD_compressBlock_btopt');
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 0 {optLevel}, ZSTD_noDict);
end;


{ used in 2-pass strategy }
function ZSTD_upscaleStat(table:puint32 ; lastEltIndex:Uint32; bonus:int32):Uint32;
var
  s, sum:Uint32;
begin
    sum:=0;
    for s:=0 to lastEltIndex do
    begin
      table[s] :=table[s]  shl  ZSTD_FREQ_DIV+bonus;
      dec(table[s]);
      sum :=sum + table[s];
    end;
    result := sum;
end;

{ used in 2-pass strategy }
procedure ZSTD_upscaleStats(optPtr:poptState_t);
begin
    if (ZSTD_compressedLiterals(optPtr)<>0) then
        optPtr^.litSum := ZSTD_upscaleStat(optPtr^.litFreq, MaxLit, 0);
    optPtr^.litLengthSum := ZSTD_upscaleStat(optPtr^.litLengthFreq, MaxLL, 0);
    optPtr^.matchLengthSum := ZSTD_upscaleStat(optPtr^.matchLengthFreq, MaxML, 0);
    optPtr^.offCodeSum := ZSTD_upscaleStat(optPtr^.offCodeFreq, MaxOff, 0);
end;

{ ZSTD_initStats_ultra():
 * make a first compression pass, just to seed stats with more accurate starting values.
 * only works on first block, with no dictionary and no ldm.
 * this function cannot error, hence its contract must be respected.
 }
procedure ZSTD_initStats_ultra(ms:pZSTD_matchState_t;seqStore:pseqStore_t;rep:Trepo;src:pbyte;srcSize:int32);
var
  tmpRep:TRepo;
begin
    move(rep, tmpRep,  sizeof(tmpRep));

    //log(3,  'ZSTD_initStats_ultra (srcSize:=%zu)', srcSize);

    ZSTD_compressBlock_opt_generic(ms, seqStore, tmpRep, src, srcSize, 2 {optLevel}, ZSTD_noDict);   { generate stats into ms^.opt}

    { invalidate first scan from history }
    ZSTD_resetSeqStore(seqStore);
    ms^.window.base :=ms^.window.base - srcSize;
    ms^.window.dictLimit :=ms^.window.dictLimit + Uint32(srcSize);
    ms^.window.lowLimit := ms^.window.dictLimit;
    ms^.nextToUpdate := ms^.window.dictLimit;

    { re-inforce weight of collected statistics }
    ZSTD_upscaleStats( @ms^.opt);
end;

function  ZSTD_compressBlock_btultra(
        ms:pZSTD_matchState_t;seqStore:pseqStore_t; rep:Trepo;
        src:pbyte; srcSize:int32):int32;
begin
    //log(3,  'ZSTD_compressBlock_btultra (srcSize:=%zu)', srcSize);
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 2 {optLevel}, ZSTD_noDict);
end;

function ZSTD_compressBlock_btultra2(ms:pZSTD_matchState_t;seqStore:pseqStore_t; rep:Trepo;
        src:pbyte; srcSize:int32):int32;
var
  curr:Uint32;
begin
    curr := Uint32(src - ms^.window.base);
    //log(3,  'ZSTD_compressBlock_btultra2 (srcSize:=%zu)', srcSize);

    { 2-pass strategy:
     * this strategy makes a first pass over first block to collect statistics
     * and seed next round's statistics with it.
     * After 1st pass, function forgets everything, and starts a new block.
     * Consequently, this can only work if no data has been previously loaded in tables,
     * aka, no dictionary, no prefix, no ldm preprocessing.
     * The compression ratio gain is generally small (~0.5% on first block),
     * the cost is 2x cpu time on first block. }
    if ( (ms^.opt.litLengthSum=0)    { first block }
       and  (seqStore^.sequences = seqStore^.sequencesStart)  { no ldm }
       and  (ms^.window.dictLimit = ms^.window.lowLimit)   { no dictionary }
       and  (curr = ms^.window.dictLimit)   { start of frame, nothing already loaded nor skipped }
       and  (srcSize > ZSTD_PREDEF_THRESHOLD)
      ) then
    begin
        ZSTD_initStats_ultra(ms, seqStore, rep, src, srcSize);
    end;

    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 2 {optLevel}, ZSTD_noDict);
end;

function ZSTD_compressBlock_btopt_dictMatchState(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 0 {optLevel}, ZSTD_dictMatchState);
end;

function  ZSTD_compressBlock_btultra_dictMatchState(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 2 {optLevel}, ZSTD_dictMatchState);
end;

function ZSTD_compressBlock_btopt_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 0 {optLevel}, ZSTD_extDict);
end;

function ZSTD_compressBlock_btultra_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:Trepo;src:pbyte; srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_opt_generic(ms, seqStore, rep, src, srcSize, 2 {optLevel}, ZSTD_extDict);
end;

{ note : no btultra2 variant for extDict nor dictMatchState,
 * because btultra2 is not meant to work with dictionaries
 * and is only specific for the first block (no prefix) }

end.


