unit ZSTD_DOUBLE_FAST;
{$mode objfpc}{$H+}
interface
uses zstd_compress_internal,zstd_internal,zstd;

procedure ZSTD_fillDoubleHashTable(ms:pZSTD_matchState_t;lend:pbyte; dtlm:ZSTD_dictTableLoadMethod_e);
function ZSTD_compressBlock_doubleFast(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_doubleFast_extDict(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
function ZSTD_compressBlock_doubleFast_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
implementation


procedure ZSTD_fillDoubleHashTable(ms:pZSTD_matchState_t;lend:pbyte; dtlm:ZSTD_dictTableLoadMethod_e);
var
  cParams:pZSTD_compressionParameters;
  hashLarge,hashSmall:puint32;
  hBitsL,mls,hBitsS,fastHashFillStep,curr,i:Uint32;
  base,ip,iend:pbyte;
  smHash,lgHash:int32;
begin
    cParams :=  @ms^.cParams;
    hashLarge := ms^.hashTable;
    hBitsL := cParams^.hashLog;
    mls := cParams^.minMatch;
    hashSmall := ms^.chainTable;
    hBitsS := cParams^.chainLog;
    base := ms^.window.base;
    ip := base + ms^.nextToUpdate;
    iend := lend - HASH_READ_SIZE;
    fastHashFillStep := 3;

    { Always insert every fastHashFillStep position into the hash tables.
     * Insert the other positions into the large hash table if their entry
     * is empty.
     }
    while (ip + fastHashFillStep - 1 <= iend) do
    begin
        curr := Uint32(ip - base);
        for i := 0 to fastHashFillStep-1 do
        begin
            smHash := ZSTD_hashPtr(ip + i, hBitsS, mls);
            lgHash := ZSTD_hashPtr(ip + i, hBitsL, 8);
            if (i = 0) then
                hashSmall[smHash] := curr + i;
            if (i = 0)  or  (hashLarge[lgHash] = 0) then
                hashLarge[lgHash] := curr + i;
            { Only load extra positions for ZSTD_dtlm_full }
            if (dtlm = ZSTD_dtlm_fast) then
                break;
        end;
        ip :=ip + fastHashFillStep;   
    end;
end;


function ZSTD_compressBlock_doubleFast_generic(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32;
        mls:Uint32{ template }; dictMode:ZSTD_dictMode_e):int32;
label _match_stored,_search_next_long,_match_found;
var
  dms:pZSTD_matchState_t;
  dictCParams:pZSTD_compressionParameters;
  dictHashLong,dictHashSmall:puint32;
  dictStartIndex,dictIndexDelta,dictHBitsL,dictHBitsS,dictAndPrefixLength,curr,windowLow,maxRep:uint32;
  dictBase,dictStart,dictEnd,matchLong,match,repMatch,repMatchEnd,dictMatchL,dictMatchL3,matchL3:pbyte;
  mLength,h2,h,dictHL,dictHS,hl3,dictHLNext,repLength2,rLength:int32;
  offset,matchIndexL,matchIndexS,repIndex,dictMatchIndexL,dictMatchIndexS,matchIndexL3:uint32;
  dictMatchIndexL3,indexToInsert,current2,repIndex2,tmpOffset,tmpOff:uint32;
  repMatch2,repEnd2:pbyte;
  cParams:pZSTD_compressionParameters;
  hashLarge,hashSmall,hashLong:puint32;
  hBitsL,hBitsS,endIndex,i,prefixLowestIndex:Uint32;
  base,ip,istart,anchor,iend,ilimit,prefixLowest:pbyte;
  smHash,lgHash:int32;
  offset_1,offset_2,offsetSaved:Uint32;
begin
    cParams :=  @ms^.cParams;
    hashLong := ms^.hashTable;
    hBitsL := cParams^.hashLog;
    hashSmall := ms^.chainTable;
    hBitsS := cParams^.chainLog;
    base := ms^.window.base;
    istart := src;
    ip := istart;
    anchor := istart;
    endIndex := Uint32(int32(istart - base) + srcSize);
    { presumes that, if there is a dictionary, it must be using Attach mode }
    prefixLowestIndex := ZSTD_getLowestPrefixIndex(ms, endIndex, cParams^.windowLog);
    prefixLowest := base + prefixLowestIndex;
    iend := istart + srcSize;
    ilimit := iend - HASH_READ_SIZE;
    offset_1:=rep[0];
    offset_2:=rep[1];
    offsetSaved := 0;

    dms := ms^.dictMatchState;
    if dictMode = ZSTD_dictMatchState then
    begin
      dictCParams := @dms^.cParams;
      dictHashLong  := dms^.hashTable;
      dictHashSmall := dms^.chainTable;
      dictStartIndex       := dms^.window.dictLimit;
      dictBase     := dms^.window.base;
      dictStart    := dictBase + dictStartIndex;
      dictEnd      := dms^.window.nextSrc;
      dictIndexDelta       := prefixLowestIndex - Uint32(dictEnd - dictBase) ;
      dictHBitsL           := dictCParams^.hashLog;
      dictHBitsS           := dictCParams^.chainLog;
    end
    else
    begin
      dictCParams :=  nil;
      dictHashLong  := nil;
      dictHashSmall := nil;
      dictStartIndex       := 0;
      dictBase     := nil;
      dictStart    := nil;
      dictEnd      := nil;
      dictIndexDelta       := 0;
      dictHBitsL           := hBitsL;
      dictHBitsS           := hBitsS;
    end;
    dictAndPrefixLength  := Uint32((ip - prefixLowest) + (dictEnd - dictStart));
    //log(3,  'ZSTD_compressBlock_doubleFast_generic');

    assert((dictMode = ZSTD_noDict)  or  (dictMode = ZSTD_dictMatchState));

    { if a dictionary is attached, it must be within window range }
    if (dictMode = ZSTD_dictMatchState) then
    begin
        assert(ms^.window.dictLimit + (Uint32(1)  shl  cParams^.windowLog) >= endIndex);
    end;

    { init }
    ip :=ip + ord(dictAndPrefixLength = 0);
    if (dictMode = ZSTD_noDict) then
    begin
        curr := Uint32(ip - base);
        windowLow := ZSTD_getLowestPrefixIndex(ms, curr, cParams^.windowLog);
        maxRep := curr - windowLow;
        if (offset_2 > maxRep) then
        begin
          offset_2 := 0;
          offsetSaved := offset_2; 
        end;
        if (offset_1 > maxRep) then
        begin
          offset_1 := 0;
          offsetSaved := offset_1; 
        end;
    end;
    if (dictMode = ZSTD_dictMatchState) then
    begin
        { dictMatchState repCode checks don't currently handle repCode = 0
         * disabling. }
        assert(offset_1 <= dictAndPrefixLength);
        assert(offset_2 <= dictAndPrefixLength);
    end;

    { Main Search Loop }
    while (ip < ilimit) do
    begin   { < instead of <=, because repcode check at (ip+1) }
        h2 := ZSTD_hashPtr(ip, hBitsL, 8);
        h := ZSTD_hashPtr(ip, hBitsS, mls);
        dictHL := ZSTD_hashPtr(ip, dictHBitsL, 8);
        dictHS := ZSTD_hashPtr(ip, dictHBitsS, mls);
        curr := Uint32(ip-base);
        matchIndexL := hashLong[h2];
        matchIndexS := hashSmall[h];
        matchLong := base + matchIndexL;
        match := base + matchIndexS;
        repIndex := curr + 1 - offset_1;
        if (dictMode = ZSTD_dictMatchState) and (repIndex < prefixLowestIndex) then
          repMatch :=dictBase + (repIndex - dictIndexDelta)
        else
          repMatch :=base + repIndex;
        hashSmall[h] := curr;
        hashLong[h2] := hashSmall[h];   { update hash tables }

        { check dictMatchState repcode }
        if (dictMode = ZSTD_dictMatchState)
            and (Uint32((prefixLowestIndex-1) - repIndex) >= 3 { intentional underflow })
            and (MEM_read32(repMatch) = MEM_read32(ip+1)) then
        begin
          if repIndex < prefixLowestIndex then
            repMatchEnd := dictEnd 
          else
            repMatchEnd :=iend;
          mLength := ZSTD_count_2segments(ip+1+4, repMatch+4, iend, repMatchEnd, prefixLowest) + 4;
          inc(ip);
          ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, 0, mLength-MINMATCH);
          goto _match_stored;
        end;

        { check noDict repcode }
        if ( dictMode = ZSTD_noDict)
          and (offset_1 > 0)  and  (MEM_read32(ip+1-offset_1) = MEM_read32(ip+1)) then
        begin
            mLength := ZSTD_count(ip+1+4, ip+1+4-offset_1, iend) + 4;
            inc(ip);
            ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, 0, mLength-MINMATCH);
            goto _match_stored;
        end;

        if (matchIndexL > prefixLowestIndex) then
        begin
            { check prefix long match }
            if (MEM_read64(matchLong) = MEM_read64(ip)) then
            begin
                mLength := ZSTD_count(ip+8, matchLong+8, iend) + 8;
                offset := Uint32(ip-matchLong);
                while (((ip>anchor)  and  (matchLong>prefixLowest)) and (ip[-1] = matchLong[-1])) do
                begin 
                  dec(ip); 
                  dec(matchLong); 
                  inc(mLength); 
                end; { catch up }
                goto _match_found;
            end;
        end
        else 
        if (dictMode = ZSTD_dictMatchState) then
        begin
            { check dictMatchState long match }
            dictMatchIndexL := dictHashLong[dictHL];
            dictMatchL := dictBase + dictMatchIndexL;
            assert(dictMatchL < dictEnd);

            if (dictMatchL > dictStart) and (MEM_read64(dictMatchL) = MEM_read64(ip)) then
            begin
                mLength := ZSTD_count_2segments(ip+8, dictMatchL+8, iend, dictEnd, prefixLowest) + 8;
                offset := Uint32(curr - dictMatchIndexL - dictIndexDelta);
                while (((ip>anchor)  and  (dictMatchL>dictStart)) and (ip[-1] = dictMatchL[-1])) do 
                begin 
                  dec(ip); 
                  dec(dictMatchL); 
                  inc(mLength); 
                end; { catch up }
                goto _match_found;
            end;   
        end;

        if (matchIndexS > prefixLowestIndex) then
        begin
            { check prefix short match }
            if (MEM_read32(match) = MEM_read32(ip)) then
            begin
                goto _search_next_long;
            end;
        end
        else 
        if (dictMode = ZSTD_dictMatchState) then
        begin
            { check dictMatchState short match }
            dictMatchIndexS := dictHashSmall[dictHS];
            match := dictBase + dictMatchIndexS;
            matchIndexS := dictMatchIndexS + dictIndexDelta;

            if (match > dictStart) and (MEM_read32(match) = MEM_read32(ip)) then
            begin
                goto _search_next_long;
            end;   
        end;

          
        ip :=ip + ((ip-anchor)  shr  kSearchStrength) + 1;
        continue;

_search_next_long:

        begin   
          hl3 := ZSTD_hashPtr(ip+1, hBitsL, 8);
          dictHLNext := ZSTD_hashPtr(ip+1, dictHBitsL, 8);
          matchIndexL3 := hashLong[hl3];
          matchL3 := base + matchIndexL3;
          hashLong[hl3] := curr + 1;

            { check prefix long +1 match }
            if (matchIndexL3 > prefixLowestIndex) then
            begin
                if (MEM_read64(matchL3) = MEM_read64(ip+1)) then
                begin
                  mLength := ZSTD_count(ip+9, matchL3+8, iend) + 8;
                  inc(ip);
                  offset := Uint32(ip-matchL3);
                  while (((ip>anchor)  and  (matchL3>prefixLowest)) and (ip[-1] = matchL3[-1])) do
                  begin 
                    dec(ip); 
                    dec(matchL3); 
                    inc(mLength); 
                  end; { catch up }
                  goto _match_found;
                end;
            end
            else 
            if (dictMode = ZSTD_dictMatchState) then
            begin
                { check dict long +1 match }
                dictMatchIndexL3 := dictHashLong[dictHLNext];
                dictMatchL3 := dictBase + dictMatchIndexL3;
                assert(dictMatchL3 < dictEnd);
                if (dictMatchL3 > dictStart) and (MEM_read64(dictMatchL3) = MEM_read64(ip+1)) then
                begin
                    mLength := ZSTD_count_2segments(ip+1+8, dictMatchL3+8, iend, dictEnd, prefixLowest) + 8;
                    inc(ip);
                    offset := Uint32(curr + 1 - dictMatchIndexL3 - dictIndexDelta);
                    while (((ip>anchor)  and  (dictMatchL3>dictStart)) and (ip[-1] = dictMatchL3[-1])) do
                    begin 
                      dec(ip); 
                      dec(dictMatchL3); 
                      inc(mLength); 
                    end; { catch up }
                    goto _match_found;
                end;   
            end;   
        end;
          
        { if no long +1 match, explore the short match we found }
        if (dictMode = ZSTD_dictMatchState) and (matchIndexS < prefixLowestIndex) then
        begin
            mLength := ZSTD_count_2segments(ip+4, match+4, iend, dictEnd, prefixLowest) + 4;
            offset := Uint32(curr - matchIndexS);
            while (((ip>anchor)  and  (match>dictStart)) and (ip[-1] = match[-1])) do
            begin 
              dec(ip); 
              dec(match); 
              inc(mLength); 
            end; { catch up }
        end
        else 
        begin
            mLength := ZSTD_count(ip+4, match+4, iend) + 4;
            offset := Uint32(ip - match);
            while (((ip>anchor)  and  (match>prefixLowest)) and (ip[-1] = match[-1])) do
            begin 
              dec(ip); 
              dec(match); 
              inc(mLength); 
            end; { catch up }
        end;

        { fall-through }

_match_found:
        offset_2 := offset_1;
        offset_1 := offset;

        ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);

_match_stored:
        { match found }
        ip :=ip + mLength;
        anchor := ip;
          
        if (ip <= ilimit) then
        begin
            { Complementary insertion }
            { done after iLimit test, as candidates could be > iend-8 }
             
            indexToInsert := curr+2;
            hashLong[ZSTD_hashPtr(base+indexToInsert, hBitsL, 8)] := indexToInsert;
            hashLong[ZSTD_hashPtr(ip-2, hBitsL, 8)] := Uint32(ip-2-base);
            hashSmall[ZSTD_hashPtr(base+indexToInsert, hBitsS, mls)] := indexToInsert;
            hashSmall[ZSTD_hashPtr(ip-1, hBitsS, mls)] := Uint32(ip-1-base);
            
            { check immediate repcode }
            if (dictMode = ZSTD_dictMatchState) then
            begin
                while (ip <= ilimit) do
                begin
                    current2 := Uint32(ip-base);
                    repIndex2 := current2 - offset_2;
                    if (dictMode = ZSTD_dictMatchState) and (repIndex2 < prefixLowestIndex) then
                      repMatch2 :=  dictBase + repIndex2 - dictIndexDelta
                    else
                      repMatch2 :=  base + repIndex2;
                      
                    if ( Uint32((prefixLowestIndex-1) - Uint32(repIndex2)) >= 3) { intentional overflow }
                       and (MEM_read32(repMatch2) = MEM_read32(ip))  then
                    begin
                        if repIndex2 < prefixLowestIndex then
                        repEnd2 := dictEnd
                        else
                        repEnd2 := iend;
                        repLength2 := ZSTD_count_2segments(ip+4, repMatch2+4, iend, repEnd2, prefixLowest) + 4;
                        tmpOffset := offset_2; 
                        offset_2 := offset_1; 
                        offset_1 := tmpOffset;   { swap offset_2 <=> offset_1 }
                        ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, repLength2-MINMATCH);
                        hashSmall[ZSTD_hashPtr(ip, hBitsS, mls)] := current2;
                        hashLong[ZSTD_hashPtr(ip, hBitsL, 8)] := current2;
                        ip :=ip + repLength2;
                        anchor := ip;
                        continue;
                    end;
                    break;
                end;   
            end;

            if (dictMode = ZSTD_noDict) then
            begin
                while ( (ip <= ilimit) and ( (offset_2>0) and  (MEM_read32(ip) = MEM_read32(ip - offset_2)) )) do
                begin
                    { store sequence }
                    rLength := ZSTD_count(ip+4, ip+4-offset_2, iend) + 4;
                    tmpOff := offset_2; offset_2 := offset_1; offset_1 := tmpOff;  { swap offset_2 <=> offset_1 }
                    hashSmall[ZSTD_hashPtr(ip, hBitsS, mls)] := Uint32(ip-base);
                    hashLong[ZSTD_hashPtr(ip, hBitsL, 8)] := Uint32(ip-base);
                    ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, rLength-MINMATCH);
                    ip :=ip + rLength;
                    anchor := ip;
                    continue;   { faster when present ... (?) }
                end;   
            end;   
        end;
    end;   { while (ip < ilimit) }

    { save reps for next block }
    if offset_1<>0 then
      rep[0] := offset_1
    else 
      rep[0] := offsetSaved;
    if offset_1<>0 then
      rep[1] := offset_2
    else
      rep[1] := offsetSaved;

    { Return the last literals size }
    result :=int32(iend - anchor);
end;


function ZSTD_compressBlock_doubleFast(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
var
  mls:Uint32;
begin
    mls := ms^.cParams.minMatch;
    case(mls) of
     4 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 4, ZSTD_noDict));
     5 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 5, ZSTD_noDict));
     6 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 6, ZSTD_noDict));
     7 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 7, ZSTD_noDict));
     else
     exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 4, ZSTD_noDict));
    end;
end;


function ZSTD_compressBlock_doubleFast_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
var
  mls:Uint32;
begin
    mls := ms^.cParams.minMatch;
    case(mls) of
     4 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 4, ZSTD_dictMatchState));
     5 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 5, ZSTD_dictMatchState));
     6 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 6, ZSTD_dictMatchState));
     7 :exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 7, ZSTD_dictMatchState));
     else
     exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, 4, ZSTD_dictMatchState));
    end;
end;


function ZSTD_compressBlock_doubleFast_extDict_generic(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32;
        mls:Uint32{ template }):int32;
var
  cParams:pZSTD_compressionParameters;
  hashLong,hashSmall:puint32;
  hBitsL,hBitsS,endIndex,lowLimit,dictStartIndex,dictLimit,prefixStartIndex,offset_1,offset_2:Uint32;
  istart,ip,anchor,iend,ilimit,base,prefixStart,dictBase,dictStart,dictEnd:pbyte;
  hSmall,hLong,mLength,h3,repLength2:int32;
  matchIndex,matchLongIndex,curr,repIndex,offset,matchIndex3,indexToInsert:Uint32;
  matchBase,match,matchLongBase,matchLong,repBase,repMatch,repMatchEnd,matchEnd,lowMatchPtr:pbyte;
  match3Base,match3,repMatch2,repEnd2:pbyte;
  current2,repIndex2,tmpOffset:Uint32;
begin
    cParams := @ms^.cParams;
    hashLong := ms^.hashTable;
    hBitsL := cParams^.hashLog;
    hashSmall := ms^.chainTable;
    hBitsS := cParams^.chainLog;
    istart := src;
    ip := istart;
    anchor := istart;
    iend := istart + srcSize;
    ilimit := iend - 8;
    base := ms^.window.base;
    endIndex := Uint32(int32(istart - base) + srcSize);
    lowLimit := ZSTD_getLowestMatchIndex(ms, endIndex, cParams^.windowLog);
    dictStartIndex := lowLimit;
    dictLimit := ms^.window.dictLimit;
    if (dictLimit > lowLimit) then
      prefixStartIndex := dictLimit
    else
      prefixStartIndex := lowLimit;
    prefixStart := base + prefixStartIndex;
    dictBase := ms^.window.dictBase;
    dictStart := dictBase + dictStartIndex;
    dictEnd := dictBase + prefixStartIndex;
    offset_1:=rep[0];
    offset_2:=rep[1];

    //log(3,  'ZSTD_compressBlock_doubleFast_extDict_generic (srcSize:=%zu)', srcSize);

    { if extDict is invalidated due to maxDistance, switch to 'regular' variant }
    if (prefixStartIndex = dictStartIndex) then
        exit(ZSTD_compressBlock_doubleFast_generic(ms, seqStore, rep, src, srcSize, mls, ZSTD_noDict));

    { Search Loop }
    while (ip < ilimit) do
    begin  { < instead of <=, because (ip+1) }
        hSmall := ZSTD_hashPtr(ip, hBitsS, mls);
        matchIndex := hashSmall[hSmall];
        if matchIndex < prefixStartIndex then
           matchBase :=  dictBase
        else
            matchBase := base;
        match := matchBase + matchIndex;

        hLong := ZSTD_hashPtr(ip, hBitsL, 8);
        matchLongIndex := hashLong[hLong];
        if matchLongIndex < prefixStartIndex then
          matchLongBase := dictBase
        else
          matchLongBase := base;
        matchLong := matchLongBase + matchLongIndex;

        curr := Uint32(ip-base);
        repIndex := curr + 1 - offset_1;   { offset_1 expected <= curr +1 }
        if repIndex < prefixStartIndex then
          repBase := dictBase
        else
          repBase := base;
        repMatch := repBase + repIndex;
        hashLong[hLong] := curr;
        hashSmall[hSmall] := hashLong[hLong] ;  { update hash table }

        if (((Uint32((prefixStartIndex-1) - repIndex) >= 3) { intentional underflow : ensure repIndex doesn't overlap dict + prefix }
             and  (repIndex > dictStartIndex))
          and (MEM_read32(repMatch) = MEM_read32(ip+1)) ) then
        begin
            if repIndex < prefixStartIndex then
              repMatchEnd :=  dictEnd
            else
              repMatchEnd :=  iend;
            mLength := ZSTD_count_2segments(ip+1+4, repMatch+4, iend, repMatchEnd, prefixStart) + 4;
            inc(ip);
            ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, 0, mLength-MINMATCH);
        end
        else 
        begin
            if ((matchLongIndex > dictStartIndex) and (MEM_read64(matchLong) = MEM_read64(ip))) then
            begin
                if matchLongIndex < prefixStartIndex then
                begin
                  matchEnd :=  dictEnd;
                  lowMatchPtr := dictStart;
                end
                else
                begin
                  matchEnd := iend;
                  lowMatchPtr := prefixStart;
                end;
                mLength := ZSTD_count_2segments(ip+8, matchLong+8, iend, matchEnd, prefixStart) + 8;
                offset := curr - matchLongIndex;
                while (((ip>anchor)  and  (matchLong>lowMatchPtr)) and (ip[-1] = matchLong[-1])) do
                begin 
                  dec(ip); 
                  dec(matchLong); 
                  inc(mLength); 
                end;   { catch up }
                offset_2 := offset_1;
                offset_1 := offset;
                ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);
            end
            else 
            if ((matchIndex > dictStartIndex) and (MEM_read32(match) = MEM_read32(ip))) then
            begin
                h3 := ZSTD_hashPtr(ip+1, hBitsL, 8);
                matchIndex3 := hashLong[h3];
                if matchIndex3 < prefixStartIndex then
                   match3Base := dictBase
                else
                    match3Base := base;
                match3 := match3Base + matchIndex3;
                hashLong[h3] := curr + 1;
                if ( (matchIndex3 > dictStartIndex) and (MEM_read64(match3) = MEM_read64(ip+1)) ) then
                begin
                  if matchIndex3 < prefixStartIndex then
                  begin
                    matchEnd :=  dictEnd;
                    lowMatchPtr := dictStart;
                  end
                  else
                  begin
                    matchEnd := iend;
                    lowMatchPtr := prefixStart;
                  end;
                  mLength := ZSTD_count_2segments(ip+9, match3+8, iend, matchEnd, prefixStart) + 8;
                  inc(ip);
                  offset := curr+1 - matchIndex3;
                  while (((ip>anchor)  and  (match3>lowMatchPtr)) and (ip[-1] = match3[-1])) do
                  begin 
                    dec(ip); 
                    dec(match3); 
                    inc(mLength); 
                  end; { catch up }
                end
                else 
                begin
                  if matchIndex < prefixStartIndex then
                  begin
                    matchEnd :=  dictEnd;
                    lowMatchPtr :=dictStart;
                  end
                  else
                  begin
                    matchEnd :=  iend;
                    lowMatchPtr := prefixStart;
                  end;
                  mLength := ZSTD_count_2segments(ip+4, match+4, iend, matchEnd, prefixStart) + 4;
                  offset := curr - matchIndex;
                  while (((ip>anchor)  and  (match>lowMatchPtr)) and (ip[-1] = match[-1])) do
                  begin 
                    dec(ip); 
                    dec(match); 
                    inc(mLength); 
                  end;   { catch up }
                end;
                offset_2 := offset_1;
                offset_1 := offset;
                ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);

            end
            else 
            begin
                ip :=ip + ((ip-anchor)  shr  kSearchStrength) + 1;
                continue;
            end;   
        end;

        { move to next sequence start }
        ip :=ip + mLength;
        anchor := ip;
        if (ip <= ilimit) then
        begin
            { Complementary insertion }
            { done after iLimit test, as candidates could be > iend-8 } 
            indexToInsert := curr+2;
            hashLong[ZSTD_hashPtr(base+indexToInsert, hBitsL, 8)] := indexToInsert;
            hashLong[ZSTD_hashPtr(ip-2, hBitsL, 8)] := Uint32(ip-2-base);
            hashSmall[ZSTD_hashPtr(base+indexToInsert, hBitsS, mls)] := indexToInsert;
            hashSmall[ZSTD_hashPtr(ip-1, hBitsS, mls)] := Uint32(ip-1-base);

            { check immediate repcode }
            while (ip <= ilimit) do
            begin
                current2 := Uint32(ip-base);
                repIndex2 := current2 - offset_2;
                if repIndex2 < prefixStartIndex then
                  repMatch2 :=  dictBase + repIndex2
                else
                  repMatch2 :=  base + repIndex2;
                if ( ((Uint32((prefixStartIndex-1) - repIndex2) >= 3)   { intentional overflow : ensure repIndex2 doesn't overlap dict + prefix }
                     and  (repIndex2 > dictStartIndex))
                  and (MEM_read32(repMatch2) = MEM_read32(ip)) ) then
                begin
                  if repIndex2 < prefixStartIndex then
                    repEnd2 :=  dictEnd
                  else
                    repEnd2 :=  iend;
                    repLength2 := ZSTD_count_2segments(ip+4, repMatch2+4, iend, repEnd2, prefixStart) + 4;
                    tmpOffset := offset_2; offset_2 := offset_1; offset_1 := tmpOffset;   { swap offset_2 <=> offset_1 }
                    ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, repLength2-MINMATCH);
                    hashSmall[ZSTD_hashPtr(ip, hBitsS, mls)] := current2;
                    hashLong[ZSTD_hashPtr(ip, hBitsL, 8)] := current2;
                    ip :=ip + repLength2;
                    anchor := ip;
                    continue;
                end;
                break;
            end;   
        end;   
    end;

    { save reps for next block }
    rep[0] := offset_1;
    rep[1] := offset_2;

    { Return the last literals size }
    result :=int32(iend - anchor);
end;


function ZSTD_compressBlock_doubleFast_extDict(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t;rep:TREPO;
        src:pbyte; srcSize:int32):int32;
var
  mls:Uint32;
begin
    mls := ms^.cParams.minMatch;
    case(mls) of
     4 :exit(ZSTD_compressBlock_doubleFast_extDict_generic(ms, seqStore, rep, src, srcSize, 4));
     5 :exit(ZSTD_compressBlock_doubleFast_extDict_generic(ms, seqStore, rep, src, srcSize, 5));
     6 :exit(ZSTD_compressBlock_doubleFast_extDict_generic(ms, seqStore, rep, src, srcSize, 6));
     7 :exit(ZSTD_compressBlock_doubleFast_extDict_generic(ms, seqStore, rep, src, srcSize, 7));
     else
     exit(ZSTD_compressBlock_doubleFast_extDict_generic(ms, seqStore, rep, src, srcSize, 4));
    end;
end;
end.
