unit zstd_ldm;
{$mode objfpc}{$H+}
interface
uses zstd,zstd_internal,zstd_compress_internal,math,zstd_cwkspf,zstd_fastf,zstd_double_fast,error_private,zstd_common;
  //zstd,zstdmt_compress;{ ZSTD_CCtx, int32 }
  //zstd_fastf,{ ZSTD_fillHashTable() }
  //zstd_double_fast;{ ZSTD_fillDoubleHashTable() }
const
  ZSTD_LDM_DEFAULT_WINDOW_LOG = ZSTD_WINDOWLOG_LIMIT_DEFAULT;
  LDM_BUCKET_SIZE_LOG =3;
  LDM_MIN_MATCH_LENGTH =64;
  LDM_HASH_RLOG =7;
  LDM_HASH_CHAR_OFFSET =10;
{ =:=   Memory management   =:= }
type
    TREPO = array[0..ZSTD_REP_NUM-1] of Uint32;
function ZSTD_ldm_getTableSize(params:ldmParams_t ):int32;
function ZSTD_ldm_getMaxNbSeq(params:ldmParams_t; maxChunkSize:int32 ):int32;
procedure ZSTD_ldm_skipRawSeqStoreBytes(rawSeqStore:prawSeqStore_t;nbBytes:int32);
procedure ZSTD_ldm_skipSequences(rawSeqStore:prawSeqStore_t;srcSize:int32; minMatch:Uint32);
function ZSTD_ldm_blockCompress(rawSeqStore:prawSeqStore_t;ms:pZSTD_matchState_t;seqStore:pseqStore_t;  rep:TREPO;
    src:pbyte; srcSize:int32):int32;
function ZSTD_ldm_generateSequences(ldmState:pldmState_t;sequences:prawSeqStore_t;params:pldmParams_t;src:pbyte; srcSize:int32):int32;
procedure ZSTD_ldm_fillHashTable(
            state:pldmState_t; ip,
            iend:pbyte; params:pldmParams_t);
procedure ZSTD_ldm_adjustParameters(params:pldmParams_t;cParams:pZSTD_compressionParameters);
implementation
uses zstd_compressf;
procedure ZSTD_ldm_adjustParameters(params:pldmParams_t;cParams:pZSTD_compressionParameters);
begin
    params^.windowLog := cParams^.windowLog;
    assert(LDM_BUCKET_SIZE_LOG <= ZSTD_LDM_BUCKETSIZELOG_MAX);
    //log(3,  'ZSTD_ldm_adjustParameters');
    if (params^.bucketSizeLog=0) then
      params^.bucketSizeLog := LDM_BUCKET_SIZE_LOG;
    if (params^.minMatchLength=0) then
      params^.minMatchLength := LDM_MIN_MATCH_LENGTH;
    if (params^.hashLog = 0) then
    begin
        params^.hashLog := MAX(ZSTD_HASHLOG_MIN, params^.windowLog - LDM_HASH_RLOG);
        assert(params^.hashLog <= ZSTD_HASHLOG_MAX);
    end;
    if (params^.hashRateLog = 0) then
    begin
      if params^.windowLog < params^.hashLog then
        params^.hashRateLog := 0
      else
        params^.hashRateLog := params^.windowLog - params^.hashLog;
    end;
    params^.bucketSizeLog := MIN(params^.bucketSizeLog, params^.hashLog);
end;

function ZSTD_ldm_getTableSize(params:ldmParams_t ):int32;
var
  ldmHSize,ldmBucketSizeLog,ldmBucketSize,totalSize:int32;
begin
    ldmHSize := int32(1)  shl  params.hashLog;
    ldmBucketSizeLog := MIN(params.bucketSizeLog, params.hashLog);
    ldmBucketSize := int32(1)  shl  (params.hashLog - ldmBucketSizeLog);
    totalSize := ZSTD_cwksp_alloc_size(ldmBucketSize)+ ZSTD_cwksp_alloc_size(ldmHSize * sizeof(ldmEntry_t));
    if params.enableLdm<>0 then
      result := totalSize
    else
      result := 0;
end;

function ZSTD_ldm_getMaxNbSeq(params:ldmParams_t; maxChunkSize:int32 ):int32;
begin
  if params.enableLdm<>0 then
    result := (maxChunkSize div params.minMatchLength)
  else
    result := 0;
end;

{* ZSTD_ldm_getSmallHash() :
 *  numBits should be <= 32
 *  If numBits=0, returns 0.
 *  @return : the most significant numBits of value. }
function ZSTD_ldm_getSmallHash(value:Uint64; numBits:Uint32 ):Uint32;
begin
    assert(numBits <= 32);
    if numBits = 0 then
      result := 0
    else
      result := Uint32(value  shr  (64 - numBits));
end;

{* ZSTD_ldm_getChecksum() :
 *  numBitsToDiscard should be <= 32
 *  @return : the next most significant 32 bits after numBitsToDiscard }
function ZSTD_ldm_getChecksum(hash:Uint64; numBitsToDiscard:Uint32):Uint32;
begin
    assert(numBitsToDiscard <= 32);
    result := (hash  shr  (64 - 32 - numBitsToDiscard))  and  $FFFFFFFF;
end;

{* ZSTD_ldm_getTag() ;
 *  Given the hash, returns the most significant numTagBits bits
 *  after (32 + hbits) bits.
 *
 *  If there are not enough bits remaining, return the last
 *  numTagBits bits. }
function ZSTD_ldm_getTag(hash:Uint64; hbits:Uint32; numTagBits:Uint32 ):Uint32;
begin
    assert((numTagBits < 32)  and (hbits <= 32));
    if (32 - hbits < numTagBits) then
    begin
        result :=  hash  and  ((Uint32(1)  shl  numTagBits) - 1);
    end
    else 
    begin
        result :=  (hash  shr  (32 - hbits - numTagBits))  and  ((Uint32(1)  shl  numTagBits) - 1);
    end;
end;

{* ZSTD_ldm_getBucket() :
 *  Returns a pointer to the start of the bucket associated with hash. }
function ZSTD_ldm_getBucket(ldmState:pldmState_t;hash:int32; ldmParams:ldmParams_t):pldmEntry_t;
begin
    result := ldmState^.hashTable + (hash  shl  ldmParams.bucketSizeLog);
end;

{* ZSTD_ldm_insertEntry() :
 *  Insert the entry with corresponding hash into the hash table }
procedure ZSTD_ldm_insertEntry(ldmState:pldmState_t;hash:int32; entry:ldmEntry_t;ldmParams:ldmParams_t);
var
  bucketOffsets:pbyte;
begin
    bucketOffsets := ldmState^.bucketOffsets;
    ZSTD_ldm_getBucket(ldmState, hash, ldmParams)[bucketOffsets[hash]] := entry;
    inc(bucketOffsets[hash]);
    bucketOffsets[hash]  :=bucketOffsets[hash]  and  (Uint32(1)  shl  ldmParams.bucketSizeLog) - 1;
end;

{* ZSTD_ldm_makeEntryAndInsertByTag() :
 *
 *  Gets the small hash, checksum, and tag from the rollingHash.
 *
 *  If the tag matches (1  shl  ldmParams.hashRateLog)-1, then
 *  creates an ldmEntry from the offset, and inserts it into the hash table.
 *
 *  hBits is the length of the small hash, which is the most significant hBits
 *  of rollingHash. The checksum is the next 32 most significant bits, followed
 *  by ldmParams.hashRateLog bits that make up the tag. }
procedure ZSTD_ldm_makeEntryAndInsertByTag(ldmState:pldmState_t;rollingHash:Uint64;
  hBits:Uint32;offset:Uint32;ldmParams:ldmParams_t);
var
  tag,tagMask,hash,checksum:Uint32;
  entry:ldmEntry_t;
begin
    tag := ZSTD_ldm_getTag(rollingHash, hBits, ldmParams.hashRateLog);
    tagMask := (Uint32(1)  shl  ldmParams.hashRateLog) - 1;
    if (tag = tagMask) then
    begin
        hash := ZSTD_ldm_getSmallHash(rollingHash, hBits);
        checksum := ZSTD_ldm_getChecksum(rollingHash, hBits);
        
        entry.offset := offset;
        entry.checksum := checksum;
        ZSTD_ldm_insertEntry(ldmState, hash, entry, ldmParams);
    end;
end;

{* ZSTD_ldm_countBackwardsMatch() :
 *  Returns the number of bytes that match backwards before pIn and pMatch.
 *
 *  We count only bytes where pMatch >= pBase and pIn >= pAnchor. }
function  ZSTD_ldm_countBackwardsMatch(pIn, pAnchor,pMatch, pMatchBase:pbyte):int32;
var
  matchLength:int32;
begin
    matchLength := 0;
    while ((pIn > pAnchor)  and (pMatch > pMatchBase)  and (pIn[-1] = pMatch[-1])) do
    begin
        dec(pIn);
        dec(pMatch);
        inc(matchLength);
    end;
    result := matchLength;
end;

{* ZSTD_ldm_countBackwardsMatch_2segments() :
 *  Returns the number of bytes that match backwards from pMatch,
 *  even with the backwards match spanning 2 different segments.
 *
 *  On reaching `pMatchBase`, start counting from mEnd }
function ZSTD_ldm_countBackwardsMatch_2segments(pIn, pAnchor,pMatch, pMatchBase,pExtDictStart, pExtDictEnd:pbyte):int32;
var
  matchLength:int32;
begin
    matchLength := ZSTD_ldm_countBackwardsMatch(pIn, pAnchor, pMatch, pMatchBase);
    if (pMatch - matchLength <> pMatchBase)  or  (pMatchBase = pExtDictStart) then
    begin
        { If backwards match is entirely in the extDict or prefix, immediately return }
        exit(matchLength);
    end;
    //log(3,  'ZSTD_ldm_countBackwardsMatch_2segments: found 2-parts backwards match (length in prefix=%zu)', matchLength);
    matchLength :=matchLength + ZSTD_ldm_countBackwardsMatch(pIn - matchLength, pAnchor, pExtDictEnd, pExtDictStart);
    //log(3,  'final backwards match length := %zu', matchLength);
    result := matchLength;
end;

{* ZSTD_ldm_fillFastTables() :
 *
 *  Fills the relevant tables for the ZSTD_fast and ZSTD_dfast strategies.
 *  This is similar to ZSTD_loadDictionaryContent.
 *
 *  The tables for the other strategies are filled within their
 *  block compressors. }
function  ZSTD_ldm_fillFastTables(ms:pZSTD_matchState_t;lend:pbyte):int32;
var
  iend:pbyte;
begin
    iend := lend;

    case (ms^.cParams.strategy) of
     ZSTD_fast:
        ZSTD_fillHashTable(ms, iend, ZSTD_dtlm_fast);

     ZSTD_dfast:
        ZSTD_fillDoubleHashTable(ms, iend, ZSTD_dtlm_fast);

     ZSTD_greedy,
     ZSTD_lazy,
     ZSTD_lazy2,
     ZSTD_btlazy2,
     ZSTD_btopt,
     ZSTD_btultra,
     ZSTD_btultra2:;
     
    else
        assert(false);  { not possible : not a valid strategy id }
    end;

    result := 0;
end;

{* ZSTD_ldm_fillLdmHashTable() :
 *
 *  Fills hashTable from (lastHashed + 1) to iend (non-inclusive).
 *  lastHash is the rolling hash that corresponds to lastHashed.
 *
 *  Returns the rolling hash corresponding to position iend-1. }
function ZSTD_ldm_fillLdmHashTable(state:pldmState_t;
  lastHash:Uint64; lastHashed,iend, base:pbyte;hbits:Uint32; ldmParams:ldmParams_t):Uint64;
var
  rollingHash:Uint64;
  cur:pbyte;
begin
    rollingHash := lastHash;
    cur := lastHashed + 1;

    while (cur < iend) do
    begin
        rollingHash := ZSTD_rollingHash_rotate(rollingHash, cur[-1],
                                              cur[ldmParams.minMatchLength-1],
                                              state^.hashPower);
        ZSTD_ldm_makeEntryAndInsertByTag(state,
                                         rollingHash, hBits,
                                         Uint32(cur - base), ldmParams);
        inc(cur);
    end;
    result := rollingHash;
end;

procedure ZSTD_ldm_fillHashTable(
            state:pldmState_t; ip,
            iend:pbyte; params:pldmParams_t);
var
  startingHash:Uint64;
begin
    //log(3,  'ZSTD_ldm_fillHashTable');
    if (int32(iend - ip) >= params^.minMatchLength) then
    begin
        startingHash := ZSTD_rollingHash_compute(ip, params^.minMatchLength);
        ZSTD_ldm_fillLdmHashTable(
            state, startingHash, ip, iend - params^.minMatchLength, state^.window.base,
            params^.hashLog - params^.bucketSizeLog,
            params^);
    end;
end;


{* ZSTD_ldm_limitTableUpdate() :
 *
 *  Sets cctx^.nextToUpdate to a position corresponding closer to anchor
 *  if it is far way
 *  (after a long match, only update tables a limited amount). }
procedure ZSTD_ldm_limitTableUpdate(ms:pZSTD_matchState_t;anchor:pbyte);
var
  curr:Uint32;
begin
    curr := Uint32(anchor - ms^.window.base);
    if (curr > ms^.nextToUpdate + 1024) then
    begin
        ms^.nextToUpdate :=
            curr - MIN(512, curr - ms^.nextToUpdate - 1024);
    end;
end;

function  ZSTD_ldm_generateSequences_internal(
        ldmState:pldmState_t; rawSeqStore:prawSeqStore_t;
        params:pldmParams_t; src:pbyte; srcSize:int32):int32;
var
  extDict:int32;
  minMatchLength,hBits,ldmBucketSize,hashRateLog,ldmTagMask,dictLimit,lowestIndex,checksum:Uint32;
  hashPower,rollingHash:Uint64;
  base,dictBase,dictStart,dictEnd,lowPrefixPtr,istart,iend,ilimit,anchor,ip,lastHashed:pbyte;
  mLength,forwardMatchLength:int32;
  curr:Uint32;
  bestEntry:pldmEntry_t;
  bucket,cur:pldmEntry_t;
  curForwardMatchLength, backwardMatchLength,curBackwardMatchLength,curTotalMatchLength,bestMatchLength:int32;
  curMatchBase,pMatch,matchEnd,lowMatchPtr:pbyte;
  matchIndex,offset:Uint32;
  seq:prawSeq;
begin
    { LDM parameters }
    extDict := ZSTD_window_hasExtDict(ldmState^.window);
    minMatchLength := params^.minMatchLength;
    hashPower := ldmState^.hashPower;
    hBits := params^.hashLog - params^.bucketSizeLog;
    ldmBucketSize := uint32(1) shl  params^.bucketSizeLog;
    hashRateLog := params^.hashRateLog;
    ldmTagMask := (uint32(1) shl  params^.hashRateLog) - 1;
    { Prefix and extDict parameters }
    dictLimit := ldmState^.window.dictLimit;
    base := ldmState^.window.base;
    if extDict<>0 then
    begin
      lowestIndex := ldmState^.window.lowLimit;
      dictBase := ldmState^.window.dictBase; 
      dictStart := dictBase + lowestIndex; 
      dictEnd := dictBase + dictLimit;
    end
    else
    begin
      lowestIndex := dictLimit;
      dictBase := nil;
      dictStart := nil;
      dictEnd := nil;
    end;
    lowPrefixPtr := base + dictLimit;
    { Input bounds } 
    istart := src;
    iend := istart + srcSize;
    ilimit := iend - MAX(minMatchLength, HASH_READ_SIZE);
    { Input positions }
    anchor := istart;
    ip := istart;
    { Rolling hash }
    lastHashed := nil;
    rollingHash := 0;

    while (ip <= ilimit) do
    begin
        curr := Uint32(ip - base);
        forwardMatchLength := 0;
        backwardMatchLength := 0;
        bestEntry := nil;
        if (ip <> istart) then
        begin
            rollingHash := ZSTD_rollingHash_rotate(rollingHash, lastHashed[0],
                                                  lastHashed[minMatchLength],
                                                  hashPower);
        end 
        else 
        begin
            rollingHash := ZSTD_rollingHash_compute(ip, minMatchLength);
        end;
        lastHashed := ip;

        { Do not insert and do not look for a match }
        if (ZSTD_ldm_getTag(rollingHash, hBits, hashRateLog) <> ldmTagMask) then
        begin
           inc(ip);
           continue;
        end;
  
        { Get the best entry and compute the match lengths }
          bucket :=ZSTD_ldm_getBucket(ldmState,ZSTD_ldm_getSmallHash(rollingHash, hBits),params^);
          bestMatchLength := 0;
          checksum := ZSTD_ldm_getChecksum(rollingHash, hBits);
          cur := bucket;
          while  cur < bucket + ldmBucketSize do
          begin
              if (cur^.checksum <> checksum)  or  (cur^.offset <= lowestIndex) then
              begin
                  continue;
              end;
              if (extDict<>0) then
              begin
                if cur^.offset < dictLimit then
                begin
                  curMatchBase :=  dictBase;
                  pMatch := curMatchBase + cur^.offset;
                  matchEnd :=  dictEnd;
                  lowMatchPtr :=  dictStart;
                end
                else
                begin
                  curMatchBase :=  base;
                  pMatch := curMatchBase + cur^.offset;
                  matchEnd := iend;
                  lowMatchPtr := lowPrefixPtr;
                end;
                  curForwardMatchLength := ZSTD_count_2segments(
                                              ip, pMatch, iend,
                                              matchEnd, lowPrefixPtr);
                  if (curForwardMatchLength < minMatchLength) then
                  begin
                      continue;
                  end;
                  curBackwardMatchLength :=ZSTD_ldm_countBackwardsMatch_2segments(ip, anchor,
                                                             pMatch, lowMatchPtr,
                                                             dictStart, dictEnd);
                  curTotalMatchLength := curForwardMatchLength +curBackwardMatchLength;
              end
              else
              begin { !extDict }
                  pMatch := base + cur^.offset;
                  curForwardMatchLength := ZSTD_count(ip, pMatch, iend);
                  if (curForwardMatchLength < minMatchLength) then
                  begin
                      continue;
                  end;
                  curBackwardMatchLength :=ZSTD_ldm_countBackwardsMatch(ip, anchor, pMatch,lowPrefixPtr);
                  curTotalMatchLength := curForwardMatchLength +curBackwardMatchLength;
              end;

              if (curTotalMatchLength > bestMatchLength) then
              begin
                  bestMatchLength := curTotalMatchLength;
                  forwardMatchLength := curForwardMatchLength;
                  backwardMatchLength := curBackwardMatchLength;
                  bestEntry := cur;
              end;
          end;


        { No match found -- continue searching }
        if (bestEntry = nil) then
        begin
            ZSTD_ldm_makeEntryAndInsertByTag(ldmState, rollingHash,
                                             hBits, curr,
                                             params^);
            inc(ip);
            continue;
        end;

        { Match found }
        mLength := forwardMatchLength + backwardMatchLength;
        ip :=ip - backwardMatchLength;

        begin
            { Store the sequence:
             * ip := curr - backwardMatchLength
             * The match is at (bestEntry^.offset - backwardMatchLength)
             }
            matchIndex := bestEntry^.offset;
            offset:= curr - matchIndex;
            seq := rawSeqStore^.seq + rawSeqStore^.size;

            { Out of sequence storage }
            if (rawSeqStore^.size = rawSeqStore^.capacity) then
                exit(ERROR(dstint32ooSmall));
            seq^.litLength := Uint32(ip - anchor);
            seq^.matchLength := Uint32(mLength);
            seq^.offset := offset;
            inc(rawSeqStore^.size);
        end;

        { Insert the current entry into the hash table }
        ZSTD_ldm_makeEntryAndInsertByTag(ldmState, rollingHash, hBits,
                                         Uint32(lastHashed - base),
                                         params^);

        assert(ip + backwardMatchLength = lastHashed);

        { Fill the hash table from lastHashed+1 to ip+mLength}
        { Heuristic: don't need to fill the entire table at end of block }
        if (ip + mLength <= ilimit) then
        begin
            rollingHash := ZSTD_ldm_fillLdmHashTable(
                              ldmState, rollingHash, lastHashed,
                              ip + mLength, base, hBits, params^);
            lastHashed := ip + mLength - 1;
        end;
        ip :=ip + mLength;
        anchor := ip;
    end;
    result := iend - anchor;
end;

{! ZSTD_ldm_reduceTable() :
 *  reduce table indexes by `reducerValue` }
procedure ZSTD_ldm_reduceTable(table:pldmEntry_t; size,reducerValue:Uint32);
var
  u:Uint32;
begin

    for u := 0 to size-1 do
    begin
        if (table[u].offset < reducerValue) then
          table[u].offset := 0
        else 
          table[u].offset :=table[u].offset - reducerValue;
    end;
end;

function ZSTD_ldm_generateSequences(ldmState:pldmState_t;sequences:prawSeqStore_t;params:pldmParams_t;src:pbyte; srcSize:int32):int32;
var
  maxDist:Uint32;
  istart,iend:pbyte;
  kMaxChunkSize,nbChunks,chunk,leftoverSize:int32;
  remaining,chunkSize,newLeftoverSize,prevSize:int32;
  ldmHSize,correction:Uint32;
  chunkStart,chunkEnd:pbyte;
begin
    maxDist := uint32(1) shl  params^.windowLog;
    istart := src;
    iend := istart + srcSize;
    kMaxChunkSize := 1  shl  20;
    nbChunks := (srcSize div kMaxChunkSize) + ord((srcSize mod kMaxChunkSize) <> 0);
    leftoverSize := 0;

    assert(ZSTD_CHUNKSIZE_MAX >= kMaxChunkSize);
    { Check that ZSTD_window_update() has been called for this chunk prior
     * to passing it to this function.
     }
    assert(ldmState^.window.nextSrc >= src + srcSize);
    { The input could be very large (in zstdmt), so it must be broken up into
     * chunks to enforce the maximum distance and handle overflow correction.
     }
    assert(sequences^.pos <= sequences^.size);
    assert(sequences^.size <= sequences^.capacity);
    chunk := 0;

    
    
    while ( chunk < nbChunks)  and (sequences^.size < sequences^.capacity) do
    begin
        chunkStart := istart + chunk * kMaxChunkSize;
        remaining := int32(iend - chunkStart);
        if (remaining < kMaxChunkSize) then
           chunkEnd := iend
        else
          chunkEnd := chunkStart + kMaxChunkSize;
        chunkSize := chunkEnd - chunkStart;
        prevSize := sequences^.size;

        assert(chunkStart < iend);
        { 1. Perform overflow correction if necessary. }
        if (ZSTD_window_needOverflowCorrection(ldmState^.window, chunkEnd)<>0) then
        begin
            ldmHSize := uint32(1) shl  params^.hashLog;
            correction := ZSTD_window_correctOverflow(@ldmState^.window, { cycleLog } 0, maxDist, chunkStart);
            ZSTD_ldm_reduceTable(ldmState^.hashTable, ldmHSize, correction);
            { invalidate dictionaries on overflow correction }
            ldmState^.loadedDictEnd := 0;
        end;
        { 2. We enforce the maximum offset allowed.
         *
         * kMaxChunkSize should be small enough that we don't lose too much of
         * the window through early invalidation.
         * TODO: * Test the chunk size.
         *       * Try invalidation after the sequence generation and test the
         *         the offset against maxDist directly.
         *
         * NOTE: Because of dictionaries + sequence splitting we MUST make sure
         * that any offset used is valid at the END of the sequence, since it may
         * be split into two sequences. This condition holds when using
         * ZSTD_window_enforceMaxDist(), but if we move to checking offsets
         * against maxDist directly, we'll have to carefully handle that case.
         }
        ZSTD_window_enforceMaxDist( @ldmState^.window, chunkEnd, maxDist,  @ldmState^.loadedDictEnd, nil);
        { 3. Generate the sequences for the chunk, and get newLeftoverSize. }
        newLeftoverSize := ZSTD_ldm_generateSequences_internal(
            ldmState, sequences, params, chunkStart, chunkSize);
        if (ZSTD_isError(newLeftoverSize)<>0) then
            exit(newLeftoverSize);
        { 4. We add the leftover literals from previous iterations to the first
         *    newly generated sequence, or add the `newLeftoverSize` if none are
         *    generated.
         }
        { Prepend the leftover literals from the last call }
        if (prevSize < sequences^.size) then
        begin
            sequences^.seq[prevSize].litLength :=sequences^.seq[prevSize].litLength + Uint32(leftoverSize);
            leftoverSize := newLeftoverSize;
        end
        else 
        begin
            assert(newLeftoverSize = chunkSize);
            leftoverSize :=leftoverSize + chunkSize;
        end;
        inc(chunk);
    end;
    result := 0;
end;

procedure ZSTD_ldm_skipSequences(rawSeqStore:prawSeqStore_t;srcSize:int32; minMatch:Uint32);
var
  seq:prawSeq;
begin
    while (srcSize > 0)  and (rawSeqStore^.pos < rawSeqStore^.size) do
    begin
        seq := rawSeqStore^.seq + rawSeqStore^.pos;
        if (srcSize <= seq^.litLength) then
        begin
            { Skip past srcSize literals }
            seq^.litLength :=seq^.litLength - Uint32(srcSize);
            exit;
        end;
        srcSize :=srcSize - seq^.litLength;
        seq^.litLength := 0;
        if (srcSize < seq^.matchLength) then
        begin
            { Skip past the first srcSize of the match }
            seq^.matchLength :=seq^.matchLength - Uint32(srcSize);
            if (seq^.matchLength < minMatch) then
            begin
                { The match is too short, omit it }
                if (rawSeqStore^.pos + 1 < rawSeqStore^.size) then
                begin
                    seq[1].litLength :=seq[1].litLength + seq[0].matchLength;
                end;
                inc(rawSeqStore^.pos);
            end;
            exit;
        end;
        srcSize :=srcSize - seq^.matchLength;
        seq^.matchLength := 0;
        inc(rawSeqStore^.pos);
    end;
end;

{*
 * If the sequence length is longer than remaining then the sequence is split
 * between this block and the next.
 *
 * Returns the current sequence to handle, or if the rest of the block should
 * be literals, it returns a sequence with offset = 0.
 }
function maybeSplitSequence(rawSeqStore:prawSeqStore_t;remaining, minMatch:Uint32):rawSeq;
var
  sequence:rawSeq;
begin
    sequence := rawSeqStore^.seq[rawSeqStore^.pos];
    assert(sequence.offset > 0);
    { Likely: No partial sequence }
    if (remaining >= sequence.litLength + sequence.matchLength) then
    begin
        inc(rawSeqStore^.pos);
        exit(sequence);
    end;
    { Cut the sequence short (offset = 0 => rest is literals). }
    if (remaining <= sequence.litLength) then
    begin
        sequence.offset := 0;
    end
    else 
    if (remaining < sequence.litLength + sequence.matchLength) then
    begin
        sequence.matchLength := remaining - sequence.litLength;
        if (sequence.matchLength < minMatch) then
        begin
            sequence.offset := 0;
        end;
    end;
    { Skip past `remaining` bytes for the future sequences. }
    ZSTD_ldm_skipSequences(rawSeqStore, remaining, minMatch);
    result := sequence;
end;

procedure ZSTD_ldm_skipRawSeqStoreBytes(rawSeqStore:prawSeqStore_t;nbBytes:int32);
var
  currPos:Uint32;
  currSeq:rawSeq;
begin
    currPos := Uint32(rawSeqStore^.posInSequence + nbBytes);
    while (currPos<>0)  and (rawSeqStore^.pos < rawSeqStore^.size) do
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

function ZSTD_ldm_blockCompress(rawSeqStore:prawSeqStore_t;ms:pZSTD_matchState_t;seqStore:pseqStore_t;  rep:TREPO;
    src:pbyte; srcSize:int32):int32;
var
  cParams:pZSTD_compressionParameters;
  minMatch:uint32;
  blockCompressor:ZSTD_blockCompressor;
  istart,iend,ip:pbyte;
  lastLLSize:int32;
  sequence:rawSeq;
  i:int32;
  newLitLength:int32;
begin
    cParams :=  @ms^.cParams;
    minMatch := cParams^.minMatch;
    blockCompressor :=ZSTD_selectBlockCompressor(cParams^.strategy, ZSTD_matchState_dictMode(ms));
    { Input bounds }
    istart := src;
    iend := istart + srcSize;
    { Input positions }
    ip := istart;

    //log(3,  'ZSTD_ldm_blockCompress: srcSize:=%zu', srcSize);
    { If using opt parser, use LDMs only as candidates rather than always accepting them }
    if (cParams^.strategy >= ZSTD_btopt) then
    begin
        ms^.ldmSeqStore := rawSeqStore;
        lastLLSize := blockCompressor(ms, seqStore, rep, src, srcSize);
        ZSTD_ldm_skipRawSeqStoreBytes(rawSeqStore, srcSize);
        exit(lastLLSize);
    end;

    assert(rawSeqStore^.pos <= rawSeqStore^.size);
    assert(rawSeqStore^.size <= rawSeqStore^.capacity);
    { Loop through each sequence and apply the block compressor to the lits }
    while (rawSeqStore^.pos < rawSeqStore^.size)  and (ip < iend) do
    begin
        { maybeSplitSequence updates rawSeqStore^.pos }
        sequence := maybeSplitSequence(rawSeqStore,Uint32(iend - ip), minMatch);

        { End signal }
        if (sequence.offset = 0) then
            break;

        assert(ip + sequence.litLength + sequence.matchLength <= iend);

        { Fill tables for block compressor }
        ZSTD_ldm_limitTableUpdate(ms, ip);
        ZSTD_ldm_fillFastTables(ms, ip);
        { Run the block compressor }
        //log(3,  'pos %u : calling block compressor on segment of size %u', (ip-istart), sequence.litLength);
        
        newLitLength :=blockCompressor(ms, seqStore, rep, ip, sequence.litLength);
        ip :=ip + sequence.litLength;
        { Update the repcodes }
        for i := ZSTD_REP_NUM - 1 downto 1 do
            rep[i] := rep[i-1];
        rep[0] := sequence.offset;
            { Store the sequence }
        ZSTD_storeSeq(seqStore, newLitLength, ip - newLitLength, iend,sequence.offset + ZSTD_REP_MOVE,sequence.matchLength - MINMATCH);
        ip :=ip + sequence.matchLength;

    end;
    { Fill the tables for the block compressor }
    ZSTD_ldm_limitTableUpdate(ms, ip);
    ZSTD_ldm_fillFastTables(ms, ip);
    { Compress the last literals }
    result := blockCompressor(ms, seqStore, rep, ip, iend - ip);
end;
end.
