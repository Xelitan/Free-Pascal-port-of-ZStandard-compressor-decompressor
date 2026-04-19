unit zstd_lazyf;
{$mode objfpc}{$H+}
interface
uses zstd_compress_internal,zstd_internal,zstd,math;
const
  ZSTD_LAZY_DDSS_BUCKET_LOG =2;
  ZSTD_REP_NUM = 3;
  //#define NEXT_IN_CHAIN(d, mask)   chainTable[(d)  and  (mask)]
type
  searchMethod_e=( search_hashChain, search_binaryTree);
  TREPO = array[0..ZSTD_REP_NUM-1] of Uint32;
  searchMax_f=function(ms:pZSTD_matchState_t;ip,iLimit:pbyte;offsetPtr:pint32):int32;
function ZSTD_compressBlock_greedy(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy2(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_btlazy2(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_greedy_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy2_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_btlazy2_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_greedy_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy2_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_btlazy2_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_greedy_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_lazy2_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
procedure ZSTD_dedicatedDictSearch_lazy_loadDictionary(ms:pZSTD_matchState_t; ip:pbyte);
function ZSTD_insertAndFindFirstIndex(ms:pZSTD_matchState_t; ip:pBYTE):uint32;

implementation
{-*************************************
*  Binary Tree search
**************************************}

procedure ZSTD_updateDUBT(ms:pZSTD_matchState_t;ip:pbyte; iend:pbyte;mls:Uint32);
var
  cParams:pZSTD_compressionParameters;
  hashLog,btLog,btMask,target,idx,matchIndex:Uint32;
  bt,hashTable,nextCandidatePtr,sortMarkPtr:puint32;
  base:pbyte;
  h:int32;
begin
    cParams :=  @ms^.cParams;
    hashTable := ms^.hashTable;
    hashLog := cParams^.hashLog;

    bt := ms^.chainTable;
    btLog  := cParams^.chainLog - 1;
    btMask := (1  shl  btLog) - 1;

    base := ms^.window.base;
    target := Uint32(ip - base);
    idx := ms^.nextToUpdate;

    if (idx <> target) then
        //log(3,  'ZSTD_updateDUBT, from %u to %u (dictLimit:%u)',
        //            idx, target, ms^.window.dictLimit);
    assert(ip + 8 <= iend);   { condition for ZSTD_hashPtr }

    assert(idx >= ms^.window.dictLimit);   { condition for valid base+idx }
    for idx:=idx to target -1 do 
    begin
        h  := ZSTD_hashPtr(base + idx, hashLog, mls);   { assumption : ip + 8 <= iend }
        matchIndex := hashTable[h];

        nextCandidatePtr := bt + 2*(idx and btMask);
        sortMarkPtr  := nextCandidatePtr + 1;

        //log(3,  'ZSTD_updateDUBT: insert %u', idx);
        hashTable[h] := idx;   { Update Hash Table }
        nextCandidatePtr^ := matchIndex;   { update BT like a chain }
        sortMarkPtr^ := ZSTD_DUBT_UNSORTED_MARK;
    end;
    ms^.nextToUpdate := target;
end;


{* ZSTD_insertDUBT1() :
 *  sort one already inserted but unsorted position
 *  assumption : curr >= btlow = (curr - btmask)
 *  doesn't fail }
procedure ZSTD_insertDUBT1(ms:pZSTD_matchState_t;curr:Uint32; inputEnd:pbyte;nbCompares, btLow:Uint32;dictMode:ZSTD_dictMode_e);
var
  cParams:pZSTD_compressionParameters;
  bt:puint32;
  btLog,btMask,dictLimit:Uint32;
  commonLengthSmaller,commonLengthLarger:int32;
  base,dictBase,ip,iend,dictEnd,prefixStart,match,mBase:pbyte;
  smallerPtr,largerPtr:puint32;
  matchIndex,dummy32,windowValid,maxDistance,windowLow:Uint32;
  nextPtr:puint32;
  matchLength:int32;
begin
    cParams :=  @ms^.cParams;
    bt := ms^.chainTable;
    btLog  := cParams^.chainLog - 1;
    btMask := (1  shl  btLog) - 1;
    commonLengthSmaller:=0;
    commonLengthLarger:=0;
    base := ms^.window.base;
    dictBase := ms^.window.dictBase;
    dictLimit := ms^.window.dictLimit;
    if (curr>=dictLimit) then
    begin
      ip := base + curr;
      iend := inputEnd;
    end
    else
    begin
      ip := dictBase + curr;
      iend := dictBase + dictLimit;
    end;
    dictEnd := dictBase + dictLimit;
    prefixStart := base + dictLimit;

    smallerPtr := bt + 2*(curr and btMask);
    largerPtr  := smallerPtr + 1;
    matchIndex := smallerPtr^;   { this candidate is unsorted : next sorted candidate is reached through *smallerPtr, while *largerPtr contains previous unsorted candidate (which is already saved and can be overwritten) }
    windowValid := ms^.window.lowLimit;
    maxDistance := Uint32(1)  shl  cParams^.windowLog;
    if (curr - windowValid > maxDistance) then
    begin
      windowLow := curr - maxDistance;
    end
    else
    begin
      windowLow := windowValid;
    end;

    //log(3,  'ZSTD_insertDUBT1(%u) (dictLimit:=%u, lowLimit:=%u)',
    //            curr, dictLimit, windowLow);
    assert(curr >= btLow);
    assert(ip < iend);   { condition for ZSTD_count }

    while (nbCompares<>0) and (matchIndex > windowLow) do
    begin
      dec(nbCompares);
      nextPtr := bt + 2*(matchIndex  and  btMask);
      matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }
        assert(matchIndex < curr);
        { note : all candidates are now supposed sorted,
         * but it's still possible to have nextPtr[1] = ZSTD_DUBT_UNSORTED_MARK
         * when a real index has the same value as ZSTD_DUBT_UNSORTED_MARK }

        if ( (dictMode <> ZSTD_extDict)
           or  (matchIndex+matchLength >= dictLimit)  { both in current segment}
           or  (curr < dictLimit) { both in extDict }) then
           begin
             if ( (dictMode <> ZSTD_extDict)  or  (matchIndex+matchLength >= dictLimit)) then
              mBase :=base
             else
              mBase :=dictBase;
            assert( (matchIndex+matchLength >= dictLimit)   { might be wrong if extDict is incorrectly set to 0 }
                  or  (curr < dictLimit) );
            match := mBase + matchIndex;
            matchLength :=matchLength + ZSTD_count(ip+matchLength, match+matchLength, iend);
        end
        else 
        begin
            match := dictBase + matchIndex;
            matchLength :=matchLength + ZSTD_count_2segments(ip+matchLength, match+matchLength, iend, dictEnd, prefixStart);
            if (matchIndex+matchLength >= dictLimit) then
                match := base + matchIndex;   { preparation for next read of match[matchLength] }
        end;

        //log(3,  'ZSTD_insertDUBT1: comparing %u with %u : found %u common bytes ',
        //            curr, matchIndex, Uint32(matchLength));

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
            //log(3,  'ZSTD_insertDUBT1: %u (>btLow:=%u) is smaller : next :=> %u',
            //            matchIndex, btLow, nextPtr[1]);
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
            //log(3,  'ZSTD_insertDUBT1: %u (>btLow:=%u) is larger :=> %u',
            //            matchIndex, btLow, nextPtr[0]);
            largerPtr := nextPtr;
            matchIndex := nextPtr[0];
        end;   
    end;
    largerPtr^ := 0;
    smallerPtr^ := 0;
end;


function ZSTD_DUBT_findBetterDictMatch (ms:pZSTD_matchState_t;ip:pbyte; iend:pbyte;offsetPtr:pint32;bestLength:int32;nbCompares,mls:Uint32;dictMode:ZSTD_dictMode_e):int32;
var
  dms:pZSTD_matchState_t;
  dmsCParams:pZSTD_compressionParameters;
  dictHashTable,dictBt:puint32;
  mIndex,matchIndex,hashLog,dictMatchIndex,curr,dictHighLimit,dictLowLimit,dictIndexDelta,btLog,btMask,btLow:Uint32;
  h,commonLengthSmaller,commonLengthLarger:int32;
  base,prefixStart,dictBase,dictEnd:pbyte;
  nextPtr:puint32;
  matchLength:int32;
  match:pbyte;
begin
    dms := ms^.dictMatchState;
    dmsCParams :=  @dms^.cParams;
    dictHashTable := dms^.hashTable;
    hashLog := dmsCParams^.hashLog;
    h  := ZSTD_hashPtr(ip, hashLog, mls);
    dictMatchIndex := dictHashTable[h];

    base := ms^.window.base;
    prefixStart := base + ms^.window.dictLimit;
    curr := Uint32(ip-base);
    dictBase := dms^.window.base;
    dictEnd := dms^.window.nextSrc;
    dictHighLimit := Uint32(dms^.window.nextSrc - dms^.window.base);
    dictLowLimit := dms^.window.lowLimit;
    dictIndexDelta := ms^.window.lowLimit - dictHighLimit;

    dictBt := dms^.chainTable;
    btLog  := dmsCParams^.chainLog - 1;
    btMask := (1  shl  btLog) - 1;
    if (btMask >= dictHighLimit - dictLowLimit) then
      btLow := dictLowLimit
    else
      btLow := dictHighLimit - btMask;

    commonLengthSmaller:=0; 
    commonLengthLarger:=0;

    assert(dictMode = ZSTD_dictMatchState);

    while (nbCompares<>0) and (dictMatchIndex > dictLowLimit) do
    begin
      dec(nbCompares);

        nextPtr := dictBt + 2*(dictMatchIndex  and  btMask);
        matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }
        match := dictBase + dictMatchIndex;
        matchLength :=matchLength + ZSTD_count_2segments(ip+matchLength, match+matchLength, iend, dictEnd, prefixStart);
        if (dictMatchIndex+matchLength >= dictHighLimit) then
            match := base + dictMatchIndex + dictIndexDelta;   { to prepare for next usage of match[matchLength] }

        if (matchLength > bestLength) then
        begin
            matchIndex := dictMatchIndex + dictIndexDelta;
            if ( (4*int(matchLength-bestLength)) > int(ZSTD_highbit32(curr-matchIndex+1) - ZSTD_highbit32(Uint32(offsetPtr[0])+1)) ) then
            begin
                //log(3,  'ZSTD_DUBT_findBetterDictMatch(%u) : found better match length %u ^. %u and offsetCode %u ^. %u (dictMatchIndex %u, matchIndex %u)',
                //    curr, Uint32(bestLength), matchLength, offsetPtr^, ZSTD_REP_MOVE + curr - matchIndex, dictMatchIndex, matchIndex);
                bestLength := matchLength; 
                offsetPtr^ := ZSTD_REP_MOVE + curr - matchIndex;
            end;
            if (ip+matchLength = iend) then
            begin   { reached end of input : ip[matchLength] is not valid, no way to know if it's larger or smaller than match }
                break;   { drop, to guarantee consistency (miss a little bit of compression) }
            end;
        end;

        if (match[matchLength] < ip[matchLength]) then
        begin
            if (dictMatchIndex <= btLow) then
            begin 
              break; 
            end;   { beyond tree size, stop the search }
            commonLengthSmaller := matchLength;    { all smaller will now have at least this guaranteed common length }
            dictMatchIndex := nextPtr[1];              { new matchIndex larger than previous (closer to current) }
        end
        else 
        begin
            { match is larger than current }
            if (dictMatchIndex <= btLow) then
            begin 
              break; 
            end;   { beyond tree size, stop the search }
            commonLengthLarger := matchLength;
            dictMatchIndex := nextPtr[0];
        end;
    end;

    if (bestLength >= MINMATCH) then
    begin
        mIndex := curr - (Uint32(offsetPtr^) - ZSTD_REP_MOVE);
        //log(3,  'ZSTD_DUBT_findBetterDictMatch(%u) : found match of length %u and offsetCode %u (pos %u)',
        //            curr, bestLength, Uint32(offsetPtr^), mIndex);
    end;
    result := bestLength;
end;


function ZSTD_DUBT_findBestMatch(ms:pZSTD_matchState_t;ip:pbyte; iend:pbyte;
  offsetPtr:pint32;mls:Uint32;dictMode:ZSTD_dictMode_e):int32;
var
  cParams:pZSTD_compressionParameters;
  hashTable,bt,nextCandidate,unsortedMark:puint32;
  nbCompares,nbCandidates,previousCandidate,hashLog,matchIndex,curr,windowLow,btLog,btMask,btLow,unsortLimit:uint32;
  match,base:pbyte;
  nextCandidateIdxPtr:puint32;
  nextCandidateIdx:uint32;
  commonLengthSmaller,commonLengthLarger:int32;
  dictLimit,matchEndIdx,dummy32,mIndex:Uint32;
  smallerPtr,largerPtr:puint32;
  h,bestLength,matchLength:int32;
  nextPtr:pUint32;
  dictBase,dictEnd,prefixStart:pbyte;
begin
    cParams :=  @ms^.cParams;
    hashTable := ms^.hashTable;
    hashLog := cParams^.hashLog;
    h  := ZSTD_hashPtr(ip, hashLog, mls);
    matchIndex  := hashTable[h];

    base := ms^.window.base;
    curr := Uint32(ip-base);
    windowLow := ZSTD_getLowestMatchIndex(ms, curr, cParams^.windowLog);
    bt := ms^.chainTable;
    btLog  := cParams^.chainLog - 1;
    btMask := (1  shl  btLog) - 1;
    if (btMask >= curr) then
      btLow :=  curr
    else
      btLow :=  btMask;
    unsortLimit := MAX(btLow, windowLow);

    nextCandidate := bt + 2*(matchIndex and btMask);
    unsortedMark := bt + 2*(matchIndex and btMask) + 1;
    nbCompares := Uint32(1)  shl  cParams^.searchLog;
    nbCandidates := nbCompares;
    previousCandidate := 0;

    //log(3,  'ZSTD_DUBT_findBestMatch (%u) ', curr);
    assert(ip <= iend-8);   { required for h calculation }
    assert(dictMode <> ZSTD_dedicatedDictSearch);

    { reach end of unsorted candidates list }
    while ( (matchIndex > unsortLimit) and (unsortedMark^ = ZSTD_DUBT_UNSORTED_MARK) and (nbCandidates > 1) ) do
    begin
        //log(3,  'ZSTD_DUBT_findBestMatch: candidate %u is unsorted',matchIndex);
        unsortedMark^ := previousCandidate;  { the unsortedMark becomes a reversed chain, to move up back to original position }
        previousCandidate := matchIndex;
        matchIndex := nextCandidate^;
        nextCandidate := bt + 2*(matchIndex and btMask);
        unsortedMark := bt + 2*(matchIndex and btMask) + 1;
        dec(nbCandidates);
    end;

    { nilify last candidate if it's still unsorted
     * simplification, detrimental to compression ratio, beneficial for speed }
    if ( (matchIndex > unsortLimit)
      and (unsortedMark^=ZSTD_DUBT_UNSORTED_MARK) ) then
    begin
        //log(3,  'ZSTD_DUBT_findBestMatch: nilify last unsorted candidate %u',
        //            matchIndex);
        unsortedMark^ := 0;
        nextCandidate^ := 0;
    end;

    { batch sort stacked candidates }
    matchIndex := previousCandidate;
    while (matchIndex<>0) do
    begin  { will end on matchIndex = 0 }
      nextCandidateIdxPtr := bt + 2*(matchIndex and btMask) + 1;
      nextCandidateIdx := nextCandidateIdxPtr^;
      ZSTD_insertDUBT1(ms, matchIndex, iend,nbCandidates, unsortLimit, dictMode);
      matchIndex := nextCandidateIdx;
      inc(nbCandidates);
    end;
    
    { find longest match }
   
      commonLengthSmaller := 0; 
      commonLengthLarger := 0;


      dictBase := ms^.window.dictBase;
      dictLimit := ms^.window.dictLimit;
      dictEnd := dictBase + dictLimit;
      prefixStart := base + dictLimit;
      smallerPtr := bt + 2*(curr and btMask);
      largerPtr  := bt + 2*(curr and btMask) + 1;
      matchEndIdx := curr + 8 + 1;
      bestLength := 0;

      matchIndex  := hashTable[h];
      hashTable[h] := curr;   { Update Hash Table }

      while (nbCompares<>0) and (matchIndex > windowLow) do
      begin
        dec(nbCompares);
        nextPtr := bt + 2*(matchIndex  and  btMask);
        matchLength := MIN(commonLengthSmaller, commonLengthLarger);   { guaranteed minimum nb of common bytes }

          if ((dictMode <> ZSTD_extDict)  or  (matchIndex+matchLength >= dictLimit)) then
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
              if (matchLength > matchEndIdx - matchIndex) then
                  matchEndIdx := matchIndex + Uint32(matchLength);
              if ( (4*int32(matchLength-bestLength)) > int32(ZSTD_highbit32(curr-matchIndex+1) - ZSTD_highbit32(Uint32(offsetPtr[0])+1)) ) then
              begin
                  bestLength := matchLength; 
                  offsetPtr^ := ZSTD_REP_MOVE + curr - matchIndex;
              end;
              if (ip+matchLength = iend) then
              begin   { equal : no way to know if inf or sup }
                  if (dictMode = ZSTD_dictMatchState) then
                  begin
                      nbCompares := 0; { in addition to avoiding checking any
                                       * further in this loop, make sure we
                                       * skip checking in the dictionary. }
                  end;
                  break;   { drop, to guarantee consistency (miss a little bit of compression) }
              end;
          end;

          if (match[matchLength] < ip[matchLength]) then
          begin
              { match is smaller than current }
              smallerPtr^ := matchIndex;             { update smaller idx }
              commonLengthSmaller := matchLength;    { all smaller will now have at least this guaranteed common length }
              if (matchIndex <= btLow) then
              begin 
                smallerPtr:= @dummy32; 
                break; 
              end;   { beyond tree size, stop the search }
              smallerPtr := nextPtr+1;               { new 'smaller' :=> larger of match }
              matchIndex := nextPtr[1];              { new matchIndex larger than previous (closer to current) }
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
              end;   { beyond tree size, stop the search }
              largerPtr := nextPtr;
              matchIndex := nextPtr[0];
          end;   
      end;
      largerPtr^ := 0;
      smallerPtr^ := 0;

      if (dictMode = ZSTD_dictMatchState) and (nbCompares<>0) then
      begin
          bestLength := ZSTD_DUBT_findBetterDictMatch(
                  ms, ip, iend,offsetPtr, bestLength, nbCompares,
                  mls, dictMode);
      end;

      assert(matchEndIdx > curr+8); { ensure nextToUpdate is increased }
      ms^.nextToUpdate := matchEndIdx - 8;   { skip repetitive patterns }
      if (bestLength >= MINMATCH) then
      begin
          mIndex := curr - (Uint32(offsetPtr^) - ZSTD_REP_MOVE);
          //log(3,  'ZSTD_DUBT_findBestMatch(%u) : found match of length %u and offsetCode %u (pos %u)',
          //            curr, bestLength, Uint32(offsetPtr^), mIndex);
      end;
      result := bestLength;
end;


{* ZSTD_BtFindBestMatch() : Tree updater, providing best match }
function ZSTD_BtFindBestMatch( ms:pZSTD_matchState_t;ip:pbyte; iLimit:pbyte;offsetPtr:pint32;
                mls:Uint32{ template };dictMode:ZSTD_dictMode_e):int32;
begin
    //log(3,  'ZSTD_BtFindBestMatch');
    if (ip < ms^.window.base + ms^.nextToUpdate) then
      exit(0);   { skipped area }
    ZSTD_updateDUBT(ms, ip, iLimit, mls);
    result := ZSTD_DUBT_findBestMatch(ms, ip, iLimit, offsetPtr, mls, dictMode);
end;


function ZSTD_BtFindBestMatch_selectMLS (  ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;

begin
    case (ms^.cParams.minMatch) of
      4 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_noDict));
      5 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 5, ZSTD_noDict));
      6,7 :exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 6, ZSTD_noDict));
      else{ includes case 3 }
        exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_noDict));
    end;
end;


function ZSTD_BtFindBestMatch_dictMatchState_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4 :   exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_dictMatchState));
      5 :   exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 5, ZSTD_dictMatchState));
      6,7 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 6, ZSTD_dictMatchState));
      else
        exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_dictMatchState));
    end;
end;


function ZSTD_BtFindBestMatch_extDict_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_extDict));
      5 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 5, ZSTD_extDict));
      6,7 : exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 6, ZSTD_extDict));
      else
        exit(ZSTD_BtFindBestMatch(ms, ip, iLimit, offsetPtr, 4, ZSTD_extDict));
    end;
end;



{ *********************************
*  Hash Chain
**********************************}


{ Update chains up to ip (excluded)
   Assumption : always within prefix (i.e. not within extDict) }
function ZSTD_insertAndFindFirstIndex_internal(
  ms:pZSTD_matchState_t;cParams:pZSTD_compressionParameters;ip:pbyte; mls:Uint32):Uint32;
var
  hashTable,chainTable:puint32;
  base:pbyte;
  hashLog,chainMask,target,idx:uint32;
  h:int32;
begin
    hashTable  := ms^.hashTable;
    hashLog := cParams^.hashLog;
    chainTable := ms^.chainTable;
    chainMask := (1  shl  cParams^.chainLog) - 1;
    base := ms^.window.base;
    target := Uint32(ip - base);
    idx := ms^.nextToUpdate;

    while(idx < target) do
    begin { catch up }
        h := ZSTD_hashPtr(base+idx, hashLog, mls);
        chainTable[idx and chainMask] := hashTable[h];
        hashTable[h] := idx;
        inc(idx);
    end;

    ms^.nextToUpdate := target;
    result := hashTable[ZSTD_hashPtr(ip, hashLog, mls)];
end;

function ZSTD_insertAndFindFirstIndex(ms:pZSTD_matchState_t; ip:pBYTE):uint32;
var
  cParams:pZSTD_compressionParameters;
begin
    cParams := @ms^.cParams;
    result := ZSTD_insertAndFindFirstIndex_internal(ms, cParams, ip, ms^.cParams.minMatch);
end;

procedure ZSTD_dedicatedDictSearch_lazy_loadDictionary(ms:pZSTD_matchState_t; ip:pbyte);
var
  base:pbyte;
  target,chainSize,idx,minChain,bucketSize,cacheSize,chainAttempts,chainLimit:Uint32;
  hashTable,chainTable:puint32;
  hashLog,tmpChainSize,tmpMinChain,hashIdx,h,chainPos:uint32;
  tmpHashTable,tmpChainTable:puint32;
  count,countBeyondMinChain,i:Uint32;
  bucketIdx,chainPackedPointer:Uint32;
begin
    base := ms^.window.base;
    target := Uint32(ip - base);
    hashTable := ms^.hashTable;
    chainTable := ms^.chainTable;
    chainSize := 1  shl  ms^.cParams.chainLog;
    idx := ms^.nextToUpdate;
    if chainSize < target then
      minChain :=  target
    else
      minChain :=  idx;
    bucketSize := 1  shl  ZSTD_LAZY_DDSS_BUCKET_LOG;
    cacheSize := bucketSize - 1;
    chainAttempts := (1  shl  ms^.cParams.searchLog) - cacheSize;
    if chainAttempts > 255 then
      chainLimit :=  255
    else
      chainLimit :=  chainAttempts;

    { We know the hashtable is oversized by a factor of `bucketSize`.
     * We are going to temporarily pretend `bucketSize = 1`, keeping only a
     * single entry. We will use the rest of the space to construct a temporary
     * chaintable.
     }

    hashLog := ms^.cParams.hashLog - ZSTD_LAZY_DDSS_BUCKET_LOG;
    tmpHashTable := hashTable;
    tmpChainTable := hashTable + (int32(1)  shl  hashLog);
    tmpChainSize := ((1  shl  ZSTD_LAZY_DDSS_BUCKET_LOG) - 1)  shl  hashLog;
    if tmpChainSize < target then
      tmpMinChain := target - tmpChainSize
    else
      tmpMinChain := idx;

    assert(ms^.cParams.chainLog <= 24);
    assert(ms^.cParams.hashLog >= ms^.cParams.chainLog);
    assert(idx <> 0);
    assert(tmpMinChain <= minChain);

    { fill conventional hash table and conventional chain table }
    for idx:=idx  to target -1 do
    begin
        h := Uint32(ZSTD_hashPtr(base + idx, hashLog, ms^.cParams.minMatch));
        if (idx >= tmpMinChain) then
        begin
            tmpChainTable[idx - tmpMinChain] := hashTable[h];
        end;
        tmpHashTable[h] := idx;
    end;

    { sort chains into ddss chain table }
    begin
        chainPos := 0;
        hashIdx := 0;
        while ( hashIdx < (uint32(1)  shl  hashLog)) do
        begin
            countBeyondMinChain := 0;
            i := tmpHashTable[hashIdx];
            count := 0;
            while ( i >= tmpMinChain) and (count < cacheSize) do
            begin
                { skip through the chain to the first position that won't be
                 * in the hash cache bucket }
                if (i < minChain) then
                begin
                    inc(countBeyondMinChain);
                end;
                i := tmpChainTable[i - tmpMinChain];
                inc(count);
            end;
            if (count = cacheSize) then
            begin
                for count := 0 to chainLimit-1 do
                begin
                    if (i < minChain) then
                    begin
                        if (i=0)  or  (countBeyondMinChain > cacheSize) then
                        begin
                          inc(countBeyondMinChain);
                            { only allow pulling `cacheSize` number of entries
                             * into the cache or chainTable beyond `minChain`,
                             * to replace the entries pulled out of the
                             * chainTable into the cache. This lets us reach
                             * back further without increasing the total number
                             * of entries in the chainTable, guaranteeing the
                             * DDSS chain table will fit into the space
                             * allocated for the regular one. }
                            break;
                        end;
                    end;
                    chainTable[chainPos] := i;
                    inc(chainPos);
                    //inc(count);
                    if (i < tmpMinChain) then
                    begin
                        break;
                    end;
                    i := tmpChainTable[i - tmpMinChain];
                end;
            end
            else 
            begin
                count := 0;
            end;
            if (count<>0) then
            begin
                tmpHashTable[hashIdx] := ((chainPos - count)  shl  8) + count;
            end
            else 
            begin
                tmpHashTable[hashIdx] := 0;
            end;
            inc(hashIdx);
        end;
        assert(chainPos <= chainSize); { I believe this is guaranteed... }
    end;

    { move chain pointers into the last entry of each hash bucket }
    hashIdx := (1  shl  hashLog);
    while ( hashIdx<>0 ) do
    begin
      dec(hashIdx);
      bucketIdx := hashIdx  shl  ZSTD_LAZY_DDSS_BUCKET_LOG;
      chainPackedPointer := tmpHashTable[hashIdx];
      for i := 0 to cacheSize-1 do
      begin
          hashTable[bucketIdx + i] := 0;
      end;
      hashTable[bucketIdx + bucketSize - 1] := chainPackedPointer;
    end;

    { fill the buckets of the hash table }
    for idx := ms^.nextToUpdate to  target-1 do
    begin
        h := Uint32(ZSTD_hashPtr(base + idx, hashLog, ms^.cParams.minMatch)) shl  ZSTD_LAZY_DDSS_BUCKET_LOG;
        { Shift hash cache down 1. }
        for i := cacheSize - 1 downto 0 do
            hashTable[h + i] := hashTable[h + i - 1];
        hashTable[h] := idx;
    end;

    ms^.nextToUpdate := target;
end;


{ inlining is important to hardwire a hot branch (template emulation) }
function ZSTD_HcFindBestMatch_generic (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32;mls:Uint32; dictMode:ZSTD_dictMode_e):int32;
var
  cParams:pZSTD_compressionParameters;
  chainTable:puint32;
  chainSize,chainMask:Uint32;
  base,dictBase,prefixStart,dictEnd:pbyte;
  dictLimit,curr,maxDistance,lowestValid,withinMaxDistance,isDictionary,lowLimit,minChain,nbAttempts:Uint32;
  m1:int32;
  ddsHashLog,matchIndex:Uint32;
  ddsIdx,currentMl,ml:int32;
  entry:pUint32;
  match:pbyte;
  ddsLowestIndex,ddsSize,ddsIndexDelta,bucketSize,bucketLimit,ddsAttempt:Uint32;
  ddsBase,ddsEnd:pbyte;
  chainPackedPointer,chainIndex:Uint32;
  dmsChainTable:puint32;
  dmsBase,dmsEnd:pbyte;
  dmsChainSize,dmsChainMask,dmsLowestIndex,dmsSize,dmsIndexDelta,dmsMinChain:uint32;
  dms:pZSTD_matchState_t;
  chainLength,chainAttempts,chainLimit,chainAttempt:uint32;
begin
    cParams := @ms^.cParams;
    chainTable := ms^.chainTable;
    chainSize := (1  shl  cParams^.chainLog);
    chainMask := chainSize-1;
    base := ms^.window.base;
    dictBase := ms^.window.dictBase;
    dictLimit := ms^.window.dictLimit;
    prefixStart := base + dictLimit;
    dictEnd := dictBase + dictLimit;
    curr := Uint32(ip-base);
    maxDistance := Uint32(1)  shl  cParams^.windowLog;
    lowestValid := ms^.window.lowLimit;
    if (curr - lowestValid > maxDistance) then
       withinMaxDistance := curr - maxDistance
    else
        withinMaxDistance := lowestValid;
    isDictionary := ord(ms^.loadedDictEnd <> 0);
    if isDictionary<>0 then
      lowLimit :=  lowestValid
    else
      lowLimit :=  withinMaxDistance;
    if curr > chainSize then
      minChain :=  curr - chainSize
    else
      minChain :=  0;
    nbAttempts := Uint32(1)  shl  cParams^.searchLog;
    ml:=4-1;

    dms := ms^.dictMatchState;
    if dictMode = ZSTD_dedicatedDictSearch then
    begin
      ddsHashLog := dms^.cParams.hashLog - ZSTD_LAZY_DDSS_BUCKET_LOG;
      ddsIdx := ZSTD_hashPtr(ip, ddsHashLog, mls)  shl  ZSTD_LAZY_DDSS_BUCKET_LOG;
    end
    else
    begin
      ddsHashLog := 0;
      ddsIdx := 0;
    end;

    if (dictMode = ZSTD_dedicatedDictSearch) then
    begin
        entry := @dms^.hashTable[ddsIdx];
        //PREFETCH_L1(entry);
    end;

    { HC4 match finder }
    matchIndex := ZSTD_insertAndFindFirstIndex_internal(ms, cParams, ip, mls);

    while ( (matchIndex>=lowLimit)  and  (nbAttempts>0)) do
    begin
        currentMl:=0;
        if ((dictMode <> ZSTD_extDict)  or  (matchIndex >= dictLimit)) then
        begin
            match := base + matchIndex;
            assert(matchIndex >= dictLimit);   { ensures this is true if dictMode <> ZSTD_extDict }
            if (match[ml] = ip[ml]) then  { potentially better }
                currentMl := ZSTD_count(ip, match, iLimit);
        end
        else 
        begin
            match := dictBase + matchIndex;
            assert(match+4 <= dictEnd);
            if (puint32(match)^ = puint32(ip)^) then   { assumption : matchIndex <= dictLimit-4 (by table construction) }
                currentMl := ZSTD_count_2segments(ip+4, match+4, iLimit, dictEnd, prefixStart) + 4;
        end;

        { save best solution }
        if (currentMl > ml) then
        begin
            ml := currentMl;
            offsetPtr^ := curr - matchIndex + ZSTD_REP_MOVE;
            if (ip+currentMl = iLimit) then
              break; { best possible, avoids read overflow on next attempt }
        end;

        if (matchIndex <= minChain) then
          break;
        matchIndex := chainTable[matchIndex and chainMask];
        dec(nbAttempts);
    end;

    if (dictMode = ZSTD_dedicatedDictSearch) then
    begin
        ddsLowestIndex  := dms^.window.dictLimit;
        ddsBase := dms^.window.base;
        ddsEnd  := dms^.window.nextSrc;
        ddsSize         := Uint32(ddsEnd - ddsBase);
        ddsIndexDelta   := dictLimit - ddsSize;
        bucketSize      := (1  shl  ZSTD_LAZY_DDSS_BUCKET_LOG);
        if nbAttempts < bucketSize - 1 then
        begin
          bucketLimit     := nbAttempts;
        end
        else
        begin
          bucketLimit     := bucketSize - 1;
        end;
        //for ddsAttempt := 0 to bucketSize - 2 do
        //begin
            //PREFETCH_L1(ddsBase + dms^.hashTable[ddsIdx + ddsAttempt]);
        //end;

        chainPackedPointer := dms^.hashTable[ddsIdx + bucketSize - 1];
        chainIndex := chainPackedPointer  shr  8;

        //PREFETCH_L1( @dms^.chainTable[chainIndex]);
        for ddsAttempt := 0 to  bucketLimit-1 do 
        begin
            currentMl:=0;
            matchIndex := dms^.hashTable[ddsIdx + ddsAttempt];
            match := ddsBase + matchIndex;

            if (matchIndex=0) then
            begin
                exit(ml);
            end;

            { guaranteed by table construction }
            assert(matchIndex >= ddsLowestIndex);
            assert(match+4 <= ddsEnd);
            if (puint32(match)^ = puint32(ip)^) then
            begin
                { assumption : matchIndex <= dictLimit-4 (by table construction) }
                currentMl := ZSTD_count_2segments(ip+4, match+4, iLimit, ddsEnd, prefixStart) + 4;
            end;

            { save best solution }
            if (currentMl > ml) then
            begin
                ml := currentMl;
                offsetPtr^ := curr - (matchIndex + ddsIndexDelta) + ZSTD_REP_MOVE;
                if (ip+currentMl = iLimit) then
                begin
                    { best possible, avoids read overflow on next attempt }
                    exit(ml);
                end;
            end;
        end;


        chainPackedPointer := dms^.hashTable[ddsIdx + bucketSize - 1];
        chainIndex := chainPackedPointer  shr  8;
        chainLength := chainPackedPointer  and  $FF;
        chainAttempts := nbAttempts - ddsAttempt;
        if chainAttempts > chainLength then
          chainLimit := chainLength
        else
          chainLimit := chainAttempts;

        //for chainAttempt := 0 to chainLimit-1 do
        //begin
        //    PREFETCH_L1(ddsBase + dms^.chainTable[chainIndex + chainAttempt]);
        //end;

        for chainAttempt := 0 to chainLimit-1 do 
        begin
            currentMl:=0;
            matchIndex := dms^.chainTable[chainIndex];
            match := ddsBase + matchIndex;

            { guaranteed by table construction }
            assert(matchIndex >= ddsLowestIndex);
            assert(match+4 <= ddsEnd);
            if (MEM_read32(match) = MEM_read32(ip)) then
            begin
                { assumption : matchIndex <= dictLimit-4 (by table construction) }
                currentMl := ZSTD_count_2segments(ip+4, match+4, iLimit, ddsEnd, prefixStart) + 4;
            end;

            { save best solution }
            if (currentMl > ml) then
            begin
                ml := currentMl;
                offsetPtr^ := curr - (matchIndex + ddsIndexDelta) + ZSTD_REP_MOVE;
                if (ip+currentMl = iLimit) then
                  break; { best possible, avoids read overflow on next attempt }
            end;
            inc(chainIndex);
        end;
    end
    else 
    if (dictMode = ZSTD_dictMatchState) then
    begin

        dmsChainTable := dms^.chainTable;
        dmsChainSize         := (1  shl  dms^.cParams.chainLog);
        dmsChainMask         := dmsChainSize - 1;
        dmsLowestIndex       := dms^.window.dictLimit;
        dmsBase      := dms^.window.base;
        dmsEnd       := dms^.window.nextSrc;
        dmsSize              := Uint32(dmsEnd - dmsBase);
        dmsIndexDelta        := dictLimit - dmsSize;
        if dmsSize > dmsChainSize then
          dmsMinChain := dmsSize - dmsChainSize
        else
          dmsMinChain := 0;

        matchIndex := dms^.hashTable[ZSTD_hashPtr(ip, dms^.cParams.hashLog, mls)];

        while (matchIndex>=dmsLowestIndex)  and  (nbAttempts>0) do
        begin
            currentMl:=0;
            match := dmsBase + matchIndex;
            assert(match+4 <= dmsEnd);
            if (MEM_read32(match) = MEM_read32(ip)) then { assumption : matchIndex <= dictLimit-4 (by table construction) }
                currentMl := ZSTD_count_2segments(ip+4, match+4, iLimit, dmsEnd, prefixStart) + 4;

            { save best solution }
            if (currentMl > ml) then
            begin
                ml := currentMl;
                offsetPtr^ := curr - (matchIndex + dmsIndexDelta) + ZSTD_REP_MOVE;
                if (ip+currentMl = iLimit) then
                  break; { best possible, avoids read overflow on next attempt }
            end;

            if (matchIndex <= dmsMinChain) then
              break;

            matchIndex := dmsChainTable[matchIndex  and  dmsChainMask];
            dec(nbAttempts);
        end;
    end;

    result := ml;
end;


function  ZSTD_HcFindBestMatch_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4 :   exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_noDict));
      5 :   exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 5, ZSTD_noDict));
      6,7 : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 6, ZSTD_noDict));
    else
      exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_noDict));
    end;
end;


function ZSTD_HcFindBestMatch_dictMatchState_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4   : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_dictMatchState));
      5   : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 5, ZSTD_dictMatchState));
      7,6 : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 6, ZSTD_dictMatchState));
      else
        exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_dictMatchState));
    end;
end;


function ZSTD_HcFindBestMatch_dedicatedDictSearch_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4 :   exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_dedicatedDictSearch));
      5 :   exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 5, ZSTD_dedicatedDictSearch));
      6,7 : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 6, ZSTD_dedicatedDictSearch));
      else
        exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_dedicatedDictSearch));
    end;
end;


function ZSTD_HcFindBestMatch_extDict_selectMLS (ms:pZSTD_matchState_t;
  ip:pbyte; iLimit:pbyte;offsetPtr:pint32):int32;
begin
    case (ms^.cParams.minMatch) of
      4   : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_extDict));
      5   : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 5, ZSTD_extDict));
      6,7 : exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 6, ZSTD_extDict));
      else
        exit(ZSTD_HcFindBestMatch_generic(ms, ip, iLimit, offsetPtr, 4, ZSTD_extDict));
    end;
end;


{ *******************************
*  Common parser - lazy strategy
********************************}


function ZSTD_compressBlock_lazy_generic(ms:pZSTD_matchState_t; seqStore:pseqStore_t;
  rep:TREPO;src:pbyte; srcSize:int32;searchMethod:searchMethod_e; depth:Uint32;dictMode:ZSTD_dictMode_e):int32;
const
  searchFuncs:array [0..3,0..1] of searchMax_f = (
        (
            @ZSTD_HcFindBestMatch_selectMLS,
            @ZSTD_BtFindBestMatch_selectMLS
        ),
        (
            nil,
            nil
        ),
        (
            @ZSTD_HcFindBestMatch_dictMatchState_selectMLS,
            @ZSTD_BtFindBestMatch_dictMatchState_selectMLS
        ),
        (
            @ZSTD_HcFindBestMatch_dedicatedDictSearch_selectMLS,
            nil
         )
    );

label _storeSequence;
var
  istart,ip,anchor,iend,iLimit,base,prefixLowest:pbyte;
  prefixLowestIndex:Uint32;
  searchMax:searchMax_f;
  offset_1,offset_2,savedOffset:Uint32;
  isDMS,isDDS,isDxS:int32;
  dms:pZSTD_matchState_t;
  dictLowestIndex,dictIndexDelta,dictAndPrefixLength:Uint32;
  dictBase,dictLowest,dictEnd:pbyte;
  curr,windowLow,maxRep:Uint32;
  matchLength,offset:int32;
  start:pbyte;
  offsetFound,offset2,ml2:int32;
  repMatch,repMatchEnd:pbyte;
  mlRep,gain2,gain1,litLength:int32;
  matchIndex:uint32;
  match,mStart,repEnd2:pbyte;
  current2,repIndex:Uint32;
begin
    istart := src;
    ip := istart;
    anchor := istart;
    iend := istart + srcSize;
    iLimit := iend - 8;
    base := ms^.window.base;
    prefixLowestIndex := ms^.window.dictLimit;
    prefixLowest := base + prefixLowestIndex;

    {*
     * This table is indexed first by the four ZSTD_dictMode_e values, and then
     * by the two searchMethod_e values. nils are placed for configurations
     * that should never occur (extDict modes go to the other implementation
     * below and there is no DDSS for binary tree search yet).
     }


    searchMax := searchFuncs[ord(dictMode)][ord(searchMethod = search_binaryTree)];
    offset_1 := rep[0];
    offset_2 := rep[1]; 
    savedOffset:=0;


    isDMS := ord(dictMode = ZSTD_dictMatchState);
    isDDS := ord(dictMode = ZSTD_dedicatedDictSearch);
    isDxS := ord((isDMS<>0)  or  (isDDS<>0));
    dms := ms^.dictMatchState;
    if isDxS<>0 then
    begin
      dictLowestIndex      := dms^.window.dictLimit;
      dictBase     := dms^.window.base;
      dictLowest   := dictBase + dictLowestIndex;
      dictEnd      := dms^.window.nextSrc;
      dictIndexDelta       := prefixLowestIndex - Uint32(dictEnd - dictBase) ;
    end
    else
    begin
      dictLowestIndex      := 0;
      dictBase     := nil;
      dictLowest   := nil;
      dictEnd      := nil;
      dictIndexDelta       := 0;
    end;

    dictAndPrefixLength := Uint32((ip - prefixLowest) + (dictEnd - dictLowest));

    assert(searchMax <> nil);

    //log(3,  'ZSTD_compressBlock_lazy_generic (dictMode:=%u)', Uint32(dictMode));

    { init }
    ip :=ip + ord(dictAndPrefixLength = 0);
    if (dictMode = ZSTD_noDict) then
    begin
        curr := Uint32(ip - base);
        windowLow := ZSTD_getLowestPrefixIndex(ms, curr, ms^.cParams.windowLog);
        maxRep := curr - windowLow;
        if (offset_2 > maxRep) then
        begin
          offset_2 := 0;
          savedOffset := offset_2; 
        end;
        if (offset_1 > maxRep) then
        begin
          offset_1 := 0;
          savedOffset := offset_1; 
        end;
    end;
    if (isDxS<>0) then
    begin
        { dictMatchState repCode checks don't currently handle repCode = 0
         * disabling. }
        assert(offset_1 <= dictAndPrefixLength);
        assert(offset_2 <= dictAndPrefixLength);
    end;

    { Match Loop }
    while (ip < ilimit) do
    begin
        matchLength:=0;
        offset:=0;
        start:=ip+1;

        { check repCode }
        if (isDxS<>0) then
        begin
            repIndex := Uint32(ip - base) + 1 - offset_1;
            if (((dictMode = ZSTD_dictMatchState)  or  (dictMode = ZSTD_dedicatedDictSearch)) and (repIndex < prefixLowestIndex)) then
               repMatch := dictBase + (repIndex - dictIndexDelta)
            else
                repMatch := base + repIndex;
            if ((Uint32((prefixLowestIndex-1) - repIndex) >= 3 { intentional underflow })
                and (MEM_read32(repMatch) = MEM_read32(ip+1)) ) then
            begin
                if repIndex < prefixLowestIndex then
                   repMatchEnd := dictEnd
                else
                  repMatchEnd := iend;
                matchLength := ZSTD_count_2segments(ip+1+4, repMatch+4, iend, repMatchEnd, prefixLowest) + 4;
                if (depth=0) then
                  goto _storeSequence;
            end;
        end;
        if ( (dictMode = ZSTD_noDict)
          and ((offset_1 > 0)  and  (puint32(ip+1-offset_1)^ = puint32(ip+1)^))) then
        begin
            matchLength := ZSTD_count(ip+1+4, ip+1+4-offset_1, iend) + 4;
            if (depth=0) then
              goto _storeSequence;
        end;

        { first search (depth 0) }
         
        offsetFound := 999999999;
        ml2 := searchMax(ms, ip, iend,  @offsetFound);
        if (ml2 > matchLength) then
        begin
          matchLength := ml2;
          start := ip;
          offset:=offsetFound;
        end;

        if (matchLength < 4) then
        begin
            ip :=ip + ((ip-anchor)  shr  kSearchStrength) + 1;   { jump faster over incompressible sections }
            continue;
        end;

        { let's try to find a better solution }
        if (depth>=1) then
        while (ip<ilimit) do
        begin
            inc(ip);
            if ( (dictMode = ZSTD_noDict)
              and (offset<>0) and ((offset_1>0)  and  (MEM_read32(ip) = MEM_read32(ip - offset_1)))) then
            begin
                mlRep := ZSTD_count(ip+4, ip+4-offset_1, iend) + 4;
                gain2 := int32(mlRep * 3);
                gain1 := int32(matchLength*3 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                if ((mlRep >= 4) and (gain2 > gain1)) then
                begin
                    matchLength := mlRep;
                    offset := 0;
                    start := ip;
                end;
            end;
            if (isDxS<>0) then
            begin
                repIndex := Uint32(ip - base) - offset_1;
                if repIndex < prefixLowestIndex then
                  repMatch :=  dictBase + (repIndex - dictIndexDelta)
                else
                  repMatch :=  base + repIndex;
                if ((Uint32((prefixLowestIndex-1) - repIndex) >= 3 { intentional underflow })
                    and (MEM_read32(repMatch) = MEM_read32(ip)) ) then
                begin
                    if repIndex < prefixLowestIndex then
                       repMatchEnd := dictEnd
                    else
                      repMatchEnd := iend;
                    mlRep := ZSTD_count_2segments(ip+4, repMatch+4, iend, repMatchEnd, prefixLowest) + 4;
                    gain2 := int32(mlRep * 3);
                    gain1 := int32(matchLength*3 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                    if ((mlRep >= 4) and (gain2 > gain1)) then
                    begin
                      start := ip;
                      offset := 0;
                      matchLength := mlRep;  
                    end;
                end;
            end;
 
              offset2:=999999999;
              ml2 := searchMax(ms, ip, iend,  @offset2);
              gain2 := int32(ml2*4 - ZSTD_highbit32(Uint32(offset2)+1));   { raw approx }
              gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 4);
              if ((ml2 >= 4) and (gain2 > gain1)) then
              begin
                start := ip;
                offset := offset2;
                matchLength := ml2;  
                continue;   { search a better one }
              end;

            { let's find an even better one }
            if ((depth=2) and (ip<ilimit)) then
            begin
                inc(ip);
                if ( (dictMode = ZSTD_noDict)
                  and (offset<>0) and ((offset_1>0)  and  (MEM_read32(ip) = MEM_read32(ip - offset_1)))) then
                begin
                    mlRep := ZSTD_count(ip+4, ip+4-offset_1, iend) + 4;
                    gain2 := int32(mlRep * 4);
                    gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                    if ((mlRep >= 4) and (gain2 > gain1)) then
                    begin
                      start := ip;
                      offset := 0;
                      matchLength := mlRep;  
                    end;
                end;
                if (isDxS<>0) then
                begin
                    repIndex := Uint32(ip - base) - offset_1;
                    if repIndex < prefixLowestIndex then
                      repMatch :=  dictBase + (repIndex - dictIndexDelta)
                    else
                      repMatch :=  base + repIndex;
                    if ((Uint32((prefixLowestIndex-1) - repIndex) >= 3 { intentional underflow })
                        and (MEM_read32(repMatch) = MEM_read32(ip)) ) then
                    begin
                      if repIndex < prefixLowestIndex then
                        repMatchEnd :=  dictEnd
                      else
                        repMatchEnd :=  iend;
                        mlRep := ZSTD_count_2segments(ip+4, repMatch+4, iend, repMatchEnd, prefixLowest) + 4;
                        gain2 := int32(mlRep * 4);
                        gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                        if ((mlRep >= 4) and (gain2 > gain1)) then
                        begin
                          start := ip;
                          offset := 0;
                          matchLength := mlRep;  
                        end;
                    end;
                end;
                ml2 := searchMax(ms, ip, iend,  @offset2);
                gain2 := int32(ml2*4 - ZSTD_highbit32(Uint32(offset2)+1));   { raw approx }
                gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 7);
                if ((ml2 >= 4) and (gain2 > gain1)) then
                begin
                  start := ip;
                  offset := offset2;
                  matchLength := ml2;  
                  continue;
                end;   
            end;
            break;  { nothing found : store previous solution }
        end;

        { NOTE:
         * start[-offset+ZSTD_REP_MOVE-1] is undefined behavior.
         * (-offset+ZSTD_REP_MOVE-1) is unsigned, and is added to start, which
         * overflows the pointer, which is undefined behavior.
         }
        { catch up }
        if (offset<>0) then
        begin
            if (dictMode = ZSTD_noDict) then
            begin
                while ( ((start > anchor)  and  (start - (offset-ZSTD_REP_MOVE) > prefixLowest)) and (start[-1] = (start-(offset-ZSTD_REP_MOVE))[-1]) ) do { only search for offset within prefix }
                begin 
                  dec(start); 
                  inc(matchLength); 
                end;
            end;

            if (isDxS<>0) then
            begin
                matchIndex := Uint32((start-base) - (offset - ZSTD_REP_MOVE));
                if (matchIndex < prefixLowestIndex) then
                match:= dictBase + matchIndex - dictIndexDelta
                else
                match:=base + matchIndex;
                if (matchIndex < prefixLowestIndex) then
                   mStart := dictLowest
                else
                    mStart := prefixLowest;
                while ((start>anchor) and (match>mStart) and (start[-1] = match[-1])) do
                begin 
                  dec(start); 
                  dec(match); 
                  inc(matchLength); 
                end;  { catch up }
            end;
            offset_2 := offset_1;
            offset_1 := Uint32(offset - ZSTD_REP_MOVE); 
        end;
        { store sequence }
_storeSequence:
        litLength := start - anchor;
        ZSTD_storeSeq(seqStore, litLength, anchor, iend, Uint32(offset), matchLength-MINMATCH);
        ip := start + matchLength;
        anchor := ip;

        { check immediate repcode }
        if (isDxS<>0) then
        begin
            while (ip <= ilimit) do
            begin
                current2 := Uint32(ip-base);
                repIndex := current2 - offset_2;
                if repIndex < prefixLowestIndex then
                  repMatch :=  dictBase - dictIndexDelta + repIndex
                else
                  repMatch := base + repIndex;
                  
                if ( (Uint32((prefixLowestIndex-1) - Uint32(repIndex)) >= 3 { intentional overflow })
                   and (MEM_read32(repMatch) = MEM_read32(ip)) ) then
                begin
                   if repIndex < prefixLowestIndex then 
                    repEnd2 :=  dictEnd
                   else
                    repEnd2 :=  iend;
                    matchLength := ZSTD_count_2segments(ip+4, repMatch+4, iend, repEnd2, prefixLowest) + 4;
                    offset := offset_2;
                    offset_2 := offset_1;
                    offset_1 := Uint32(offset);   { swap offset_2 <=> offset_1 }
                    ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, matchLength-MINMATCH);
                    ip :=ip + matchLength;
                    anchor := ip;
                    continue;
                end;
                break;
            end;
        end;

        if (dictMode = ZSTD_noDict) then
        begin
            while ( ((ip <= ilimit)  and  (offset_2>0))
                 and (puint32(ip)^ = puint32(ip - offset_2)^) ) do
            begin
                { store sequence }
                matchLength := ZSTD_count(ip+4, ip+4-offset_2, iend) + 4;
                offset := offset_2; 
                offset_2 := offset_1; 
                offset_1 := Uint32(offset); { swap repcodes }
                ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, matchLength-MINMATCH);
                ip :=ip + matchLength;
                anchor := ip;
                continue;   { faster when present ... (?) }
            end;    
        end;   
    end;

    { Save reps for next block }
    if offset_1<>0 then
      rep[0] := offset_1
    else
      rep[0] := savedOffset;
    if offset_2<>0 then
      rep[1] := offset_2
    else
      rep[1] := savedOffset;

    { Return the last literals size }
    result := int32(iend - anchor);
end;


function ZSTD_compressBlock_btlazy2(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_binaryTree, 2, ZSTD_noDict);
end;

function ZSTD_compressBlock_lazy2(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 2, ZSTD_noDict);
end;

function ZSTD_compressBlock_lazy(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result :=  ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 1, ZSTD_noDict);
end;

function ZSTD_compressBlock_greedy(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result :=  ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 0, ZSTD_noDict);
end;

function ZSTD_compressBlock_btlazy2_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_binaryTree, 2, ZSTD_dictMatchState);
end;

function ZSTD_compressBlock_lazy2_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 2, ZSTD_dictMatchState);
end;

function ZSTD_compressBlock_lazy_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 1, ZSTD_dictMatchState);
end;

function ZSTD_compressBlock_greedy_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 0, ZSTD_dictMatchState);
end;


function ZSTD_compressBlock_lazy2_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 2, ZSTD_dedicatedDictSearch);
end;

function ZSTD_compressBlock_lazy_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 1, ZSTD_dedicatedDictSearch);
end;

function ZSTD_compressBlock_greedy_dedicatedDictSearch(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 0, ZSTD_dedicatedDictSearch);
end;


function ZSTD_compressBlock_lazy_extDict_generic(ms:pZSTD_matchState_t; seqStore:pseqStore_t;
  rep:TREPO;src:pbyte; srcSize:int32;searchMethod:searchMethod_e; depth: Uint32):int32;
label _storeSequence;
var
  istart,ip,anchor,iend,iLimit,base,prefixStart,dictBase,dictEnd,dictStart:pbyte;
  windowLog,dictLimit,offset_1,offset_2:Uint32;
  searchMax:searchMax_f;
  start,repBase,repMatch,repEnd,match,mStart:pbyte;
  matchLength,offset,offsetFound,ml2,repLength,gain1,gain2,offset2,litLength:int32;
  curr,windowLow,repIndex,matchIndex,repCurrent:Uint32;
begin
    istart := src;
    ip := istart;
    anchor := istart;
    iend := istart + srcSize;
    iLimit := iend - 8;
    base := ms^.window.base;
    dictLimit := ms^.window.dictLimit;
    prefixStart := base + dictLimit;
    dictBase := ms^.window.dictBase;
    dictEnd  := dictBase + dictLimit;
    dictStart  := dictBase + ms^.window.lowLimit;
    windowLog := ms^.cParams.windowLog;
    if searchMethod=search_binaryTree then
      searchMax :=  @ZSTD_BtFindBestMatch_extDict_selectMLS
    else
      searchMax :=  @ZSTD_HcFindBestMatch_extDict_selectMLS;

    offset_1 := rep[0]; 
    offset_2 := rep[1];

    //log(3,  'ZSTD_compressBlock_lazy_extDict_generic');

    { init }
    ip :=ip + ord(ip = prefixStart);

    { Match Loop }
    while (ip < ilimit) do
    begin
        matchLength:=0;
        offset:=0;
        start:=ip+1;
        curr := Uint32(ip-base);

        { check repCode }
         
        windowLow := ZSTD_getLowestMatchIndex(ms, curr+1, windowLog);
        repIndex := Uint32(curr+1 - offset_1);
        if repIndex < dictLimit then
          repBase := dictBase
        else
          repBase := base;
        repMatch := repBase + repIndex;
        if ((Uint32((dictLimit-1) - repIndex) >= 3)  and  (repIndex > windowLow)) then  { intentional overflow }
        if (MEM_read32(ip+1) = MEM_read32(repMatch)) then
        begin
            { repcode detected we should take it }
            if repIndex < dictLimit then
              repEnd := dictEnd
            else
              repEnd := iend;
            matchLength := ZSTD_count_2segments(ip+1+4, repMatch+4, iend, repEnd, prefixStart) + 4;
            if (depth=0) then
              goto _storeSequence;
        end;

        { first search (depth 0) }
        offsetFound := 999999999;
        ml2 := searchMax(ms, ip, iend,  @offsetFound);
        if (ml2 > matchLength) then
        begin
          offset:=offsetFound;
          start := ip;
          matchLength := ml2; 
        end;
        if (matchLength < 4) then
        begin
            ip :=ip + ((ip-anchor)  shr  kSearchStrength) + 1;   { jump faster over incompressible sections }
            continue;
        end;

        { let's try to find a better solution }
        if (depth>=1) then
        while (ip<ilimit) do
        begin
            inc(ip );
            inc(curr);
            { check repCode }
            if (offset<>0) then
            begin
                windowLow := ZSTD_getLowestMatchIndex(ms, curr, windowLog);
                repIndex := Uint32(curr - offset_1);
                if repIndex < dictLimit then
                  repBase :=  dictBase
                else
                  repBase :=  base;
                repMatch := repBase + repIndex;
                if ((Uint32((dictLimit-1) - repIndex) >= 3)  and  (repIndex > windowLow)) then { intentional overflow }
                if (pUint32(ip)^ = pUint32(repMatch)^) then
                begin
                    { repcode detected }
                    if repIndex < dictLimit then
                      repEnd := dictEnd
                    else
                      repEnd := iend;
                    repLength := ZSTD_count_2segments(ip+4, repMatch+4, iend, repEnd, prefixStart) + 4;
                    gain2 := int32(repLength * 3);
                    gain1 := int32(matchLength*3 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                    if ((repLength >= 4) and (gain2 > gain1)) then
                    begin
                      start := ip;
                      offset := 0;
                      matchLength := repLength;  
                    end;   
                end;
            end;
            { search match, depth 1 }
 
            offset2:=999999999;
            ml2 := searchMax(ms, ip, iend,  @offset2);
            gain2 := int32(ml2*4 - ZSTD_highbit32(Uint32(offset2)+1));   { raw approx }
            gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 4);
            if ((ml2 >= 4) and (gain2 > gain1)) then
            begin
              start := ip;
              offset := offset2;
              matchLength := ml2;
              continue;   { search a better one }
            end;

            { let's find an even better one }
            if ((depth=2) and (ip<ilimit)) then
            begin
                inc(ip );
                inc(curr);
                { check repCode }
                if (offset<>0) then
                begin
                    windowLow := ZSTD_getLowestMatchIndex(ms, curr, windowLog);
                    repIndex := Uint32(curr - offset_1);
                    if repIndex < dictLimit then
                    repBase := dictBase
                    else
                      repBase := base;
                    repMatch := repBase + repIndex;
                    if ((Uint32((dictLimit-1) - repIndex) >= 3)  and  (repIndex > windowLow)) then { intentional overflow }
                    if (MEM_read32(ip) = MEM_read32(repMatch)) then
                    begin
                        { repcode detected }
                        if repIndex < dictLimit then
                        repEnd := dictEnd
                        else
                          repEnd := iend;
                        repLength := ZSTD_count_2segments(ip+4, repMatch+4, iend, repEnd, prefixStart) + 4;
                        gain2 := int32(repLength * 4);
                        gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 1);
                        if ((repLength >= 4) and (gain2 > gain1)) then
                        begin
                            matchLength := repLength;
                            offset := 0;
                            start := ip;
                        end;
                    end;
                end;
                { search match, depth 2 }
                offset2:=999999999;
                ml2 := searchMax(ms, ip, iend,  @offset2);
                gain2 := int32(ml2*4 - ZSTD_highbit32(Uint32(offset2)+1));   { raw approx }
                gain1 := int32(matchLength*4 - ZSTD_highbit32(Uint32(offset)+1) + 7);
                if ((ml2 >= 4) and (gain2 > gain1)) then
                begin
                  start := ip;
                  offset := offset2;
                  matchLength := ml2; 
                  continue;
                end;   
            end;   
            break;  { nothing found : store previous solution }
        end;

        { catch up }
        if (offset<>0) then
        begin
            matchIndex := Uint32((start-base) - (offset - ZSTD_REP_MOVE));
            if (matchIndex < dictLimit) then
            begin
              match := dictBase + matchIndex;
              mStart := dictStart;
            end
            else
            begin
                match :=base + matchIndex;
                mStart := prefixStart;
            end;
            while ((start>anchor) and (match>mStart) and (start[-1] = match[-1])) do
            begin 
              dec(start); 
              dec(match); 
              inc(matchLength); 
            end;  { catch up }
            offset_2 := offset_1; 
            offset_1 := Uint32(offset - ZSTD_REP_MOVE);
        end;

        { store sequence }
_storeSequence:
 
        litLength := start - anchor;
        ZSTD_storeSeq(seqStore, litLength, anchor, iend, Uint32(offset), matchLength-MINMATCH);
        ip := start + matchLength;
        anchor := ip;

        { check immediate repcode }
        while (ip <= ilimit) do
        begin
            repCurrent := Uint32(ip-base);
            windowLow := ZSTD_getLowestMatchIndex(ms, repCurrent, windowLog);
            repIndex := repCurrent - offset_2;
            if repIndex < dictLimit then
              repBase := dictBase
            else
              repBase := base;
            repMatch := repBase + repIndex;
            if ((Uint32((dictLimit-1) - repIndex) >= 3)  and  (repIndex > windowLow)) then  { intentional overflow }
            if (pUint32(ip)^ = pUint32(repMatch)^) then
            begin
                { repcode detected we should take it }
                if repIndex < dictLimit then
                  repEnd :=  dictEnd
                else
                  repEnd :=  iend;
                matchLength := ZSTD_count_2segments(ip+4, repMatch+4, iend, repEnd, prefixStart) + 4;
                offset := offset_2; 
                offset_2 := offset_1; 
                offset_1 := Uint32(offset);   { swap offset history }
                ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, matchLength-MINMATCH);
                ip :=ip + matchLength;
                anchor := ip;
                continue;   { faster when present ... (?) }
            end;
            break;
        end;
    end;   

    { Save reps for next block }
    rep[0] := offset_1;
    rep[1] := offset_2;

    { Return the last literals size }
    result := int32(iend - anchor);
end;


function ZSTD_compressBlock_greedy_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_extDict_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 0);
end;

function ZSTD_compressBlock_lazy_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
begin
    result := ZSTD_compressBlock_lazy_extDict_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 1);
end;

function ZSTD_compressBlock_lazy2_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;

begin
    result := ZSTD_compressBlock_lazy_extDict_generic(ms, seqStore, rep, src, srcSize, search_hashChain, 2);
end;

function ZSTD_compressBlock_btlazy2_extDict(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;

begin
    result := ZSTD_compressBlock_lazy_extDict_generic(ms, seqStore, rep, src, srcSize, search_binaryTree, 2);
end;
end.
