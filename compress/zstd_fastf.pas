unit zstd_fastf;
{$mode objfpc}{$H+}
interface
uses zstd_internal,zstd_compress_internal,zstd;  { ZSTD_hashPtr, ZSTD_count, ZSTD_storeSeq }
type
  TREPO = array[0..ZSTD_REP_NUM-1] of Uint32;
procedure ZSTD_fillHashTable(ms:pZSTD_matchState_t;lend:pbyte;dtlm:ZSTD_dictTableLoadMethod_e);
function ZSTD_compressBlock_fast(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_fast_extDict(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
function ZSTD_compressBlock_fast_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;

implementation

procedure ZSTD_fillHashTable(ms:pZSTD_matchState_t;lend:pbyte;dtlm:ZSTD_dictTableLoadMethod_e);
var
  cParams:pZSTD_compressionParameters;
  hashTable:pUint32;
  hBits,mls,fastHashFillStep,curr,p:Uint32;
  base,ip,iend:pbyte;
  hash0,hash:int32;
begin
    cParams := @ms^.cParams;
    hashTable := ms^.hashTable;
    hBits := cParams^.hashLog;
    mls := cParams^.minMatch;
    base := ms^.window.base;
    ip := base + ms^.nextToUpdate;
    iend := lend - HASH_READ_SIZE;
    fastHashFillStep := 3;

    { Always insert every fastHashFillStep position into the hash table.
     * Insert the other positions if their hash entry is empty.
     }
    while (ip + fastHashFillStep < iend + 2) do
    begin
        curr := Uint32(ip - base);
        hash0 := ZSTD_hashPtr(ip, hBits, mls);
        hashTable[hash0] := curr;
        if (dtlm = ZSTD_dtlm_fast) then
          continue;
        { Only load extra positions for ZSTD_dtlm_full }

        for p := 1 to fastHashFillStep-1 do
        begin
            hash := ZSTD_hashPtr(ip + p, hBits, mls);
            if (hashTable[hash] = 0) then
            begin  { not yet filled }
                hashTable[hash] := curr + p;
            end;   
        end;      
    end;
end;


function ZSTD_compressBlock_fast_generic(ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32;mls:Uint32):int32;
label _match,_offset;
var
  cParams:pZSTD_compressionParameters;
  hashTable:puint32;
  hlog,endIndex,prefixStartIndex,offset_1,offset_2,offsetSaved:Uint32;
  stepSize:int32;
  base,istart,ip0,ip1,anchor,prefixStart,iend,ilimit:pbyte;

  match1,match0,repMatch,ip2:pbyte;
  curr,windowLow,maxRep,offcode,matchIndex0,matchIndex1,current0,current1,val1,val0,tmpOff:Uint32;
  mLength,h0,h1,step,rLength:int32;
begin
    cParams :=  @ms^.cParams;
    hashTable := ms^.hashTable;
    hlog := cParams^.hashLog;
    { support stepSize of 0 }
    stepSize := cParams^.targetLength + ord(cParams^.targetLength=0) + 1;
    base := ms^.window.base;
    istart := src;
    { We check ip0 (ip + 0) and ip1 (ip + 1) each loop }
    ip0 := istart;
    anchor := istart;
    endIndex := Uint32(int32(istart - base) + srcSize);
    prefixStartIndex := ZSTD_getLowestPrefixIndex(ms, endIndex, cParams^.windowLog);
    prefixStart := base + prefixStartIndex;
    iend := istart + srcSize;
    ilimit := iend - HASH_READ_SIZE;
    offset_1:=rep[0];
    offset_2:=rep[1];
    offsetSaved := 0;

    { init }
    //log(3, 'ZSTD_compressBlock_fast_generic');
    ip0 :=ip0 + ord(ip0 = prefixStart);
    ip1 := ip0 + 1;
      
    curr := Uint32(ip0 - base);
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
    { Main Search Loop }
    while (ip1 < ilimit) do
    begin   { < instead of <=, because check at ip0+2 }
        ip2 := ip0 + 2;
        h0 := ZSTD_hashPtr(ip0, hlog, mls);
        val0 := MEM_read32(ip0);
        h1 := ZSTD_hashPtr(ip1, hlog, mls);
        val1 := MEM_read32(ip1);
        current0 := Uint32(ip0-base);
        current1 := Uint32(ip1-base);
        matchIndex0 := hashTable[h0];
        matchIndex1 := hashTable[h1];
        repMatch := ip2 - offset_1;
        match0 := base + matchIndex0;
        match1 := base + matchIndex1;

        hashTable[h0] := current0;   { update hash table }
        hashTable[h1] := current1;   { update hash table }

        assert(ip0 + 1 = ip1);

        if ((offset_1 > 0)  and  (MEM_read32(repMatch) = MEM_read32(ip2))) then
        begin
          if (ip2[-1] = repMatch[-1])  then
            mLength := 1
          else
            mLength := 0;
            ip0 := ip2 - mLength;
            match0 := repMatch - mLength;
            mLength :=mLength + 4;
            offcode := 0;
            goto _match;
        end;
        if (matchIndex0 > prefixStartIndex) and (MEM_read32(match0) = val0) then
        begin
            { found a regular match }
            goto _offset;
        end;
        if (matchIndex1 > prefixStartIndex) and (MEM_read32(match1) = val1) then
        begin
            { found a regular match after one literal }
            ip0 := ip1;
            match0 := match1;
            goto _offset;
        end;
 
        step := (int32(ip0-anchor)  shr  (kSearchStrength - 1)) + stepSize;
        assert(step >= 2);
        ip0 :=ip0 + step;
        ip1 :=ip1 + step;
        continue;

_offset: { Requires: ip0, match0 }
        { Compute the offset code }
        offset_2 := offset_1;
        offset_1 := Uint32(ip0-match0);
        offcode := offset_1 + ZSTD_REP_MOVE;
        mLength := 4;
        { Count the backwards match length }
        while (((ip0>anchor)  and  (match0>prefixStart))
             and (ip0[-1] = match0[-1])) do 
        begin 
          dec(ip0); 
          dec(match0); 
          inc(mLength); 
        end; { catch up }

_match: { Requires: ip0, match0, offcode }
        { Count the forward length }
        mLength :=mLength + ZSTD_count(ip0+mLength, match0+mLength, iend);
        ZSTD_storeSeq(seqStore, int32(ip0-anchor), anchor, iend, offcode, mLength-MINMATCH);
        { match found }
        ip0 :=ip0 + mLength;
        anchor := ip0;

        if (ip0 <= ilimit) then
        begin
            { Fill Table }
            assert(base+current0+2 > istart);  { check base overflow }
            hashTable[ZSTD_hashPtr(base+current0+2, hlog, mls)] := current0+2;  { here because current+2 could be > iend-8 }
            hashTable[ZSTD_hashPtr(ip0-2, hlog, mls)] := Uint32(ip0-2-base);

            if (offset_2 > 0) then
            begin { offset_2=0 means offset_2 is invalidated }
                while ( (ip0 <= ilimit) and (MEM_read32(ip0) = MEM_read32(ip0 - offset_2)) ) do
                begin
                    { store sequence }
                    rLength := ZSTD_count(ip0+4, ip0+4-offset_2, iend) + 4;
                    tmpOff := offset_2; 
                    offset_2 := offset_1; 
                    offset_1 := tmpOff; 
                   { swap offset_2 <=> offset_1 }
                  hashTable[ZSTD_hashPtr(ip0, hlog, mls)] := Uint32(ip0-base);
                  ip0 :=ip0 + rLength;
                  ZSTD_storeSeq(seqStore, 0 {litLen}, anchor, iend, 0 {offCode}, rLength-MINMATCH);
                  anchor := ip0;
                  continue;   { faster when present (confirmed on gcc-8) ... (?) }
                end;
            end;   
        end;   
        ip1 := ip0 + 1;
    end;

    { save reps for next block }
    if offset_1<>0 then
      rep[0] := offset_1
    else
      rep[0] := offsetSaved;
    if offset_2<>0 then
      rep[1] := offset_2
    else
      rep[1] := offsetSaved;

    { Return the last literals size }
    result := int32(iend - anchor);
end;


function ZSTD_compressBlock_fast(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
var
mls:Uint32;
begin
    mls := ms^.cParams.minMatch;
    assert(ms^.dictMatchState = nil);
    case(mls) of
      4 : exit(ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, 4));
      5 : exit(ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, 5));
      6 : exit(ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, 6));
      7 : exit(ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, 7));
    else
      exit(ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, 4));
    end;
end;

function ZSTD_compressBlock_fast_dictMatchState_generic(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32; mls:Uint32):int32;
var
  cParams:pZSTD_compressionParameters;
  hashTable,dictHashTable:pUint32;
  hlog,stepSize,prefixStartIndex,offset_1,offset_2,offsetSaved,dictStartIndex:Uint32;
  base,istart,ip,anchor,prefixStart,iend,ilimit,repMatch2,repEnd2:pbyte;
  dms:pZSTD_matchState_t;
  dictCParams:pZSTD_compressionParameters;
  dictBase,dictStart,dictEnd,match,repMatch,repMatchEnd,dictMatch:pbyte;
  dictIndexDelta,dictAndPrefixLength,dictHLog,maxDistance,endIndex,curr,matchIndex,repIndex:Uint32;
  mLength,h,dictHash,repLength2:int32;
  dictMatchIndex,offset,current2,repIndex2,tmpOffset:uint32;
begin
    cParams :=  @ms^.cParams;
    
    hashTable := ms^.hashTable;
    hlog := cParams^.hashLog;
    { support stepSize of 0 }
    stepSize := cParams^.targetLength + not (cParams^.targetLength);
    base := ms^.window.base;
    istart := src;
    ip := istart;
    anchor := istart;
    prefixStartIndex := ms^.window.dictLimit;
    prefixStart := base + prefixStartIndex;
    iend := istart + srcSize;
    ilimit := iend - HASH_READ_SIZE;
    offset_1:=rep[0];
    offset_2:=rep[1];
    offsetSaved := 0;
    
    dms := ms^.dictMatchState;
    dictCParams := @dms^.cParams ;
    dictHashTable := dms^.hashTable;
    dictStartIndex       := dms^.window.dictLimit;
    dictBase     := dms^.window.base;
    dictStart    := dictBase + dictStartIndex;
    dictEnd      := dms^.window.nextSrc;
    dictIndexDelta       := prefixStartIndex - Uint32(dictEnd - dictBase);
    dictAndPrefixLength  := Uint32(ip - prefixStart + dictEnd - dictStart);
    dictHLog             := dictCParams^.hashLog;

    { if a dictionary is still attached, it necessarily means that
     * it is within window size. So we just check it. }
    maxDistance := Uint32(1)  shl  cParams^.windowLog;
    endIndex := Uint32(int32(ip - base) + srcSize);
    assert(endIndex - prefixStartIndex <= maxDistance);

    { ensure there will be no no underflow
     * when translating a dict index into a local index }
    assert(prefixStartIndex >= Uint32(dictEnd - dictBase));

    { init }
    //log(3,  'ZSTD_compressBlock_fast_dictMatchState_generic');
    ip :=ip + ord(dictAndPrefixLength = 0);
    { dictMatchState repCode checks don't currently handle repCode = 0
     * disabling. }
    assert(offset_1 <= dictAndPrefixLength);
    assert(offset_2 <= dictAndPrefixLength);
    
    { Main Search Loop }
    while (ip < ilimit) do
    begin   { < instead of <=, because repcode check at (ip+1) }
        h := ZSTD_hashPtr(ip, hlog, mls);
        curr := Uint32(ip-base);
        matchIndex := hashTable[h];
        match := base + matchIndex;
        repIndex := curr + 1 - offset_1;
        if (repIndex < prefixStartIndex) then
          repMatch := dictBase + (repIndex - dictIndexDelta)
        else
          repMatch := base + repIndex;
        hashTable[h] := curr;   { update hash table }

        if ( (Uint32((prefixStartIndex-1) - repIndex) >= 3) { intentional underflow : ensure repIndex isn't overlapping dict + prefix }
          and (MEM_read32(repMatch) = MEM_read32(ip+1)) ) then
        begin
            if repIndex < prefixStartIndex then
               repMatchEnd := dictEnd
            else
                repMatchEnd := iend;
            mLength := ZSTD_count_2segments(ip+1+4, repMatch+4, iend, repMatchEnd, prefixStart) + 4;
            inc(ip);
            ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, 0, mLength-MINMATCH);
        end
        else 
        if ( (matchIndex <= prefixStartIndex) ) then
        begin
            dictHash := ZSTD_hashPtr(ip, dictHLog, mls);
            dictMatchIndex := dictHashTable[dictHash];
            dictMatch := dictBase + dictMatchIndex;
            if (dictMatchIndex <= dictStartIndex)  or 
                (MEM_read32(dictMatch) <> MEM_read32(ip)) then
            begin
                assert(stepSize >= 1);
                ip :=ip + ((ip-anchor)  shr  kSearchStrength) + stepSize;
                continue;
            end
            else 
            begin
                { found a dict match }
                offset := Uint32(curr-dictMatchIndex-dictIndexDelta);
                mLength := ZSTD_count_2segments(ip+4, dictMatch+4, iend, dictEnd, prefixStart) + 4;
                while (((ip>anchor)  and  (dictMatch>dictStart))
                     and (ip[-1] = dictMatch[-1])) do
                begin
                  dec(ip); 
                  dec(dictMatch); 
                  inc(mLength);
                end; { catch up }
                offset_2 := offset_1;
                offset_1 := offset;
                ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);
            end;
        end
        else 
        if (MEM_read32(match) <> MEM_read32(ip)) then
        begin
          { it's not a match, and we're not going to check the dictionary }
          assert(stepSize >= 1);
          ip :=ip + ((ip-anchor)  shr  kSearchStrength) + stepSize;
          continue;
        end
        else 
        begin
            { found a regular match }
            offset := Uint32(ip-match);
            mLength := ZSTD_count(ip+4, match+4, iend) + 4;
            while (((ip>anchor)  and  (match>prefixStart))
                 and (ip[-1] = match[-1])) do
            begin 
              dec(ip); 
              dec(match); 
              inc(mLength); 
            end; { catch up }
            offset_2 := offset_1;
            offset_1 := offset;
            ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);
        end;

        { match found }
        ip :=ip + mLength;
        anchor := ip;

        if (ip <= ilimit) then
        begin
            { Fill Table }
            assert(base+curr+2 > istart);  { check base overflow }
            hashTable[ZSTD_hashPtr(base+curr+2, hlog, mls)] := curr+2;  { here because curr+2 could be > iend-8 }
            hashTable[ZSTD_hashPtr(ip-2, hlog, mls)] := Uint32(ip-2-base);

            { check immediate repcode }
            while (ip <= ilimit) do
            begin
                current2 := Uint32(ip-base);
                repIndex2 := current2 - offset_2;
                if repIndex2 < prefixStartIndex then
                  repMatch2 := dictBase - dictIndexDelta + repIndex2
                else
                  repMatch2 :=  base + repIndex2;
                        
                if ( (Uint32((prefixStartIndex-1) - Uint32(repIndex2)) >= 3) { intentional overflow }
                   and (MEM_read32(repMatch2) = MEM_read32(ip)) ) then
                begin
                    if repIndex2 < prefixStartIndex then
                      repEnd2 := dictEnd
                    else
                      repEnd2 := iend;
                    repLength2 := ZSTD_count_2segments(ip+4, repMatch2+4, iend, repEnd2, prefixStart) + 4;
                    tmpOffset := offset_2; 
                    offset_2 := offset_1; 
                    offset_1 := tmpOffset;   { swap offset_2 <=> offset_1 }
                    ZSTD_storeSeq(seqStore, 0, anchor, iend, 0, repLength2-MINMATCH);
                    hashTable[ZSTD_hashPtr(ip, hlog, mls)] := current2;
                    ip :=ip + repLength2;
                    anchor := ip;
                    continue;
                end;
                break;
            end;
        end;
    end;

    { save reps for next block }
    if offset_1<>0 then
      rep[0] := offset_1 
    else
      rep[0] := offsetSaved;
    if offset_2<>0 then
      rep[1] := offset_2
    else
      rep[1] := offsetSaved;

    { Return the last literals size }
    result := int32(iend - anchor);
end;

function ZSTD_compressBlock_fast_dictMatchState(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
var
  mls:Uint32;
begin
    mls := ms^.cParams.minMatch;
    assert(ms^.dictMatchState <> nil);
    case(mls) of
      4 :exit(ZSTD_compressBlock_fast_dictMatchState_generic(ms, seqStore, rep, src, srcSize, 4));
      5 :exit(ZSTD_compressBlock_fast_dictMatchState_generic(ms, seqStore, rep, src, srcSize, 5));
      6 :exit(ZSTD_compressBlock_fast_dictMatchState_generic(ms, seqStore, rep, src, srcSize, 6));
      7 :exit(ZSTD_compressBlock_fast_dictMatchState_generic(ms, seqStore, rep, src, srcSize, 7));
      else
        exit(ZSTD_compressBlock_fast_dictMatchState_generic(ms, seqStore, rep, src, srcSize, 4));
    end;
end;


function ZSTD_compressBlock_fast_extDict_generic(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32; mls:Uint32):int32;
var
  cParams:pZSTD_compressionParameters;
  hashTable,dictHashTable:pUint32;
  hlog,stepSize,prefixStartIndex,offset_1,offset_2,offsetSaved,dictStartIndex:Uint32;
  base,istart,ip,anchor,prefixStart,iend,ilimit,repMatch2,repEnd2:pbyte;
  dms:pZSTD_matchState_t;
  dictCParams:pZSTD_compressionParameters;
  dictBase,dictStart,dictEnd,match,repMatch,repMatchEnd,dictMatch,matchBase,repBase,matchEnd,lowMatchPtr:pbyte;
  dictIndexDelta,dictAndPrefixLength,dictHLog,maxDistance,endIndex,curr,matchIndex,repIndex:Uint32;
  mLength,h,dictHash,repLength2,rLength:int32;
  dictMatchIndex,offset,current2,repIndex2,tmpOffset,lowLimit,dictLimit:uint32;
begin
    cParams :=  @ms^.cParams;
    hashTable := ms^.hashTable;
    hlog := cParams^.hashLog;
    { support stepSize of 0 }
    stepSize := cParams^.targetLength + ord(cParams^.targetLength=0);
    base := ms^.window.base;
    dictBase := ms^.window.dictBase;
    istart := src;
    ip := istart;
    anchor := istart;
    endIndex := Uint32(int32(istart - base) + srcSize);
    lowLimit := ZSTD_getLowestMatchIndex(ms, endIndex, cParams^.windowLog);
    dictStartIndex := lowLimit;
    dictStart := dictBase + dictStartIndex;
    dictLimit := ms^.window.dictLimit;
    if dictLimit < lowLimit then
       prefixStartIndex := lowLimit
    else
       prefixStartIndex :=dictLimit;
    prefixStart := base + prefixStartIndex;
    dictEnd := dictBase + prefixStartIndex;
    iend := istart + srcSize;
    ilimit := iend - 8;
    offset_1:=rep[0];
    offset_2:=rep[1];

    //log(3,  'ZSTD_compressBlock_fast_extDict_generic (offset_1:=%u)', offset_1);

    { switch to 'regular' variant if extDict is invalidated due to maxDistance }
    if (prefixStartIndex = dictStartIndex) then
        exit( ZSTD_compressBlock_fast_generic(ms, seqStore, rep, src, srcSize, mls));

    { Search Loop }
    while (ip < ilimit) do
    begin  { < instead of <=, because (ip+1) }
        h := ZSTD_hashPtr(ip, hlog, mls);
        matchIndex := hashTable[h];
        if matchIndex < prefixStartIndex then
           matchBase := dictBase
        else
            matchBase :=base;
        match := matchBase + matchIndex;
        curr := Uint32(ip-base);
        repIndex := curr + 1 - offset_1;
        if repIndex < prefixStartIndex then
          repBase := dictBase
        else
          repBase := base;
        repMatch := repBase + repIndex;
        hashTable[h] := curr;   { update hash table }
        //log(3,  'offset_1 := %u , curr := %u', offset_1, curr);
        assert(offset_1 <= curr +1);   { check repIndex }

        if ( ((Uint32((prefixStartIndex-1) - repIndex) >= 3) { intentional underflow }  and  (repIndex > dictStartIndex))
           and (MEM_read32(repMatch) = MEM_read32(ip+1)) ) then
        begin
          if repIndex < prefixStartIndex then
            repMatchEnd := dictEnd
          else
            repMatchEnd := iend;
          rLength := ZSTD_count_2segments(ip+1 +4, repMatch +4, iend, repMatchEnd, prefixStart) + 4;
          inc(ip);
          ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, 0, rLength-MINMATCH);
          ip :=ip + rLength;
          anchor := ip;
        end
        else 
        begin
            if ( (matchIndex < dictStartIndex)  or 
                 (MEM_read32(match) <> MEM_read32(ip)) ) then
            begin
                assert(stepSize >= 1);
                ip :=ip + ((ip-anchor)  shr  kSearchStrength) + stepSize;
                continue;
            end;
            begin  
              if matchIndex < prefixStartIndex then
              begin
                matchEnd := dictEnd;
                lowMatchPtr := dictStart;
              end
              else
              begin
                matchEnd := iend;
                lowMatchPtr := prefixStart;
              end;
              offset := curr - matchIndex;
              mLength := ZSTD_count_2segments(ip+4, match+4, iend, matchEnd, prefixStart) + 4;
              while (((ip>anchor)  and  (match>lowMatchPtr)) and (ip[-1] = match[-1])) do
              begin 
                dec(ip); 
                dec(match); 
                inc(mLength) 
              end;   { catch up }
              offset_2 := offset_1; 
              offset_1 := offset;  { update offset history }
              ZSTD_storeSeq(seqStore, int32(ip-anchor), anchor, iend, offset + ZSTD_REP_MOVE, mLength-MINMATCH);
              ip :=ip + mLength;
              anchor := ip;
            end;   
        end;

        if (ip <= ilimit) then
        begin
            { Fill Table }
            hashTable[ZSTD_hashPtr(base+curr+2, hlog, mls)] := curr+2;
            hashTable[ZSTD_hashPtr(ip-2, hlog, mls)] := Uint32(ip-2-base);
            { check immediate repcode }
            while (ip <= ilimit) do
            begin
                current2 := Uint32(ip-base);
                repIndex2 := current2 - offset_2;
                if repIndex2 < prefixStartIndex then
                  repMatch2 := dictBase + repIndex2
                else
                  repMatch2 := base + repIndex2;
                if ( ((Uint32((prefixStartIndex-1) - repIndex2) >= 3)  and  (repIndex2 > dictStartIndex))  { intentional overflow }
                   and (MEM_read32(repMatch2) = MEM_read32(ip)) ) then
                begin
                  if repIndex2 < prefixStartIndex then
                    repEnd2 := dictEnd
                  else
                    repEnd2 := iend;
                  repLength2 := ZSTD_count_2segments(ip+4, repMatch2+4, iend, repEnd2, prefixStart) + 4; 
                      tmpOffset := offset_2; 
                      offset_2 := offset_1; 
                      offset_1 := tmpOffset; 
                      { swap offset_2 <=> offset_1 }
                    ZSTD_storeSeq(seqStore, 0 {litlen}, anchor, iend, 0 {offcode}, repLength2-MINMATCH);
                    hashTable[ZSTD_hashPtr(ip, hlog, mls)] := current2;
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
    result := int32(iend - anchor);
end;


function ZSTD_compressBlock_fast_extDict(
        ms:pZSTD_matchState_t; seqStore:pseqStore_t; rep:TREPO;
        src:pbyte;srcSize:int32):int32;
var
  mls:Uint32;
begin
    mls:= ms^.cParams.minMatch;
    case (mls) of
      4 :exit(ZSTD_compressBlock_fast_extDict_generic(ms, seqStore, rep, src, srcSize, 4));
      5 :exit(ZSTD_compressBlock_fast_extDict_generic(ms, seqStore, rep, src, srcSize, 5));
      6 :exit(ZSTD_compressBlock_fast_extDict_generic(ms, seqStore, rep, src, srcSize, 6));
      7 :exit(ZSTD_compressBlock_fast_extDict_generic(ms, seqStore, rep, src, srcSize, 7));
      else
        exit(ZSTD_compressBlock_fast_extDict_generic(ms, seqStore, rep, src, srcSize, 4));
    end;
end;
end.
