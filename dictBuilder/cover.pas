unit cover;
{$mode objfpc}{$H+}
interface
uses sysutils,algoutil,math,
  zstd_internal, { includes zstd.h }
  zdict;

const
{-*************************************
*  Constants
**************************************}
  COVER_MAX_SAMPLES_SIZE :uint32=1 * 1024*1024*1024;
  COVER_DEFAULT_SPLITPOINT :double = 1.0;


{-*************************************
* Hash table
***************************************
* A small specialized hash map for storing activeDmers.
* The map does not resize, so if it becomes full it will loop forever.
* Thus, the map must be large enough to store every value.
* The map implements linear probing and keeps its load less than 0.5.
}

  MAP_EMPTY_VALUE :Uint32=-1;
  COVER_prime4bytes:Uint32 = 2654435761;
type
pCOVER_map_pair_t=^COVER_map_pair_t;
pCOVER_map_t=^COVER_map_t;
pCOVER_segment_t=^COVER_segment_t;
pCOVER_epoch_info_t=^COVER_epoch_info_t;
pCOVER_dictSelection_t=^COVER_dictSelection_t;
pCOVER_ctx_t=^COVER_ctx_t;
pCOVER_tryParameters_data_t=^COVER_tryParameters_data_t;
pCOVER_best_t=^COVER_best_t;
COVER_map_pair_t=record
   key:Uint32;
   value:Uint32;
end;
COVER_map_t=record
  data:pCOVER_map_pair_t;
  sizeLog:Uint32;
  size:Uint32;
  sizeMask:Uint32;
end;
{*
 * COVER_best_t is used for two purposes:
 * 1. Synchronizing threads.
 * 2. Saving the best parameters and dictionary.
 *
 * All of the methods except COVER_best_init() are thread safe if zstd is
 * compiled with multithreaded support.
 }

COVER_best_t=record
  //ZSTD_pthread_mutex_t mutex;
  //ZSTD_pthread_cond_t cond;
  liveJobs:int32 ;
  dict:pbyte;
  dictSize:int32;
  parameters:ZDICT_cover_params_t;
  compressedSize:int32;
end;

{*
 * A segment is a range in the source as well as the score of the segment.
 }

COVER_segment_t=record
  lbegin:Uint32 ;
  lend:Uint32 ;
  score:Uint32 ;
end;

{*
 *Number of epochs and size of each epoch.
 }

COVER_epoch_info_t=record
  num:Uint32 ;
  size:Uint32 ;
end;

{*
 * Struct used for the dictionary selection function.
 }

COVER_dictSelection_t=record
  dictContent:pBYTE;
  dictSize:int32 ;
  totalCompressedSize:int32 ;
end;
{-*************************************
* Context
**************************************}

COVER_ctx_t=record
  samples:pBYTE;
  offsets:pint32;
  samplesSizes:pint32;
  nbSamples:int32;
  nbTrainSamples:int32;
  nbTestSamples:int32;
  suffix:pUint32;
  suffixSize:int32;
  freqs:pUint32;
  dmerAt:pUint32;
  d:Uint32;
end;
{*
 * Parameters for COVER_tryParameters().
 }
COVER_tryParameters_data_t=record
  ctx:pCOVER_ctx_t;
  best:pCOVER_best_t;
  dictBufferCapacity:int32 ;
  parameters:ZDICT_cover_params_t ;
end;
 tcmpfunc=function(x:pCOVER_ctx_t;y,z:pbyte):int32;
 tgrpfunc=procedure(x:pCOVER_ctx_t;y,z:pbyte);

procedure COVER_map_clear(map:pCOVER_map_t);
function COVER_map_init(map:pCOVER_map_t; size:Uint32):int32;
function COVER_map_hash(map:pCOVER_map_t; key:Uint32):Uint32;
function COVER_map_index(map:pCOVER_map_t; key:Uint32):Uint32;
function COVER_map_at(map:pCOVER_map_t; key:Uint32):puint32;
procedure COVER_map_remove(map:pCOVER_map_t; key:Uint32);
procedure COVER_map_destroy(map:pCOVER_map_t );
function COVER_sum(samplesSizes:pint32; nbSamples:uint32):int32;
function COVER_cmp(ctx:pCOVER_ctx_t; lp,rp:pbyte):int32;
function COVER_cmp8(ctx:pCOVER_ctx_t; lp,rp:pbyte):int32;
function COVER_strict_cmp(lp,rp:pbyte):int32;
function COVER_strict_cmp8(lp,rp:pbyte):int32;
function COVER_lower_bound(first, last:pint32;value:int32 ):pint32;
procedure COVER_groupBy(data:pbyte; count, size:int32; ctx:pCOVER_ctx_t;cmp:tcmpfunc;grp:tgrpfunc);
procedure COVER_group(ctx:pCOVER_ctx_t;group,groupEnd:pbyte);
function COVER_selectSegment(ctx:pCOVER_ctx_t; freqs:pUint32;
  activeDmers:pCOVER_map_t; lbegin:Uint32;
  lend:Uint32;
  parameters:ZDICT_cover_params_t):COVER_segment_t;
function COVER_checkParameters(parameters:ZDICT_cover_params_t;maxDictSize:int32):int32;
procedure COVER_ctx_destroy(ctx:pCOVER_ctx_t);
function COVER_ctx_init(ctx:pCOVER_ctx_t; samplesBuffer:pbyte;
                          samplesSizes:pint32; nbSamples:uint32;
                          d:uint32; splitPoint:double):int32;
procedure COVER_warnOnSmallCorpus(maxDictSize:int32; nbDmers:int32; displayLevel:int32 );
function COVER_computeEpochs(maxDictSize,nbDmers:int32; k, passes:Uint32 ):COVER_epoch_info_t;
function COVER_checkTotalCompressedSize(parameters:ZDICT_cover_params_t;
  samplesSizes:pint32; samples:pbyte;offsets:pint32;
  nbTrainSamples, nbSamples:int32;dict:pbyte;  dictBufferCapacity:int32):int32;
procedure COVER_best_init(best:pCOVER_best_t);
procedure COVER_best_wait(best:pCOVER_best_t);
procedure COVER_best_destroy(best:pCOVER_best_t);
procedure COVER_best_start(best:pCOVER_best_t);
procedure COVER_best_finish(best:pCOVER_best_t; parameters:ZDICT_cover_params_t;selection:COVER_dictSelection_t);
function COVER_dictSelectionError(error:int32):COVER_dictSelection_t;
function COVER_dictSelectionIsError(selection:COVER_dictSelection_t):uint32;
procedure COVER_dictSelectionfreemem(selection:COVER_dictSelection_t);
function COVER_selectDict(customDictContent:pbyte; dictBufferCapacity:int32;
        dictContentSize:int32 ; samplesBuffer:pbyte; samplesSizes:pint32; nbFinalizeSamples:uint32;
        nbCheckSamples,nbSamples:int32; params:ZDICT_cover_params_t ; offsets:pint32; totalCompressedSize:int32 ):COVER_dictSelection_t;
procedure COVER_tryParameters(opaque:pbyte);
function COVER_buildDictionary(ctx:pCOVER_ctx_t; freqs:pUint32;
  activeDmers:pCOVER_map_t; dictBuffer:pbyte;dictBufferCapacity:int32;
  parameters:ZDICT_cover_params_t):int32;
function ZDICT_trainFromBuffer_cover(dictBuffer:pbyte; dictBufferCapacity:int32;
    samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32;parameters:ZDICT_cover_params_t):int32;
implementation
uses error_private,zstd_common,ZSTD_COMPRESS_internal,ZSTD_COMPRESSf;
var
  g_coverCtx:pCOVER_ctx_t = nil;
{*
 * Clear the map.
 }
procedure COVER_map_clear(map:pCOVER_map_t);
begin
  fillbyte(map^.data^, map^.size * sizeof(COVER_map_pair_t), MAP_EMPTY_VALUE);
end;

{*
 * Initializes a map of the given size.
 * Returns 1 on success and 0 on failure.
 * The map must be destroyed with COVER_map_destroy().
 * The map is only guaranteed to be large enough to hold size elements.
 }
function COVER_map_init(map:pCOVER_map_t; size:Uint32):int32; 
begin
  map^.sizeLog := ZSTD_highbit32(size) + 2;
  map^.size := Uint32(1) shl  map^.sizeLog;
  map^.sizeMask := map^.size - 1;
  map^.data := allocmem(map^.size * sizeof(COVER_map_pair_t));
  if (map^.data=nil) then
  begin
    map^.sizeLog := 0;
    map^.size := 0;
    exit(0);
  end;
  COVER_map_clear(map);
  exit(1);
end;

{*
 * Internal hash function
 }

function COVER_map_hash(map:pCOVER_map_t; key:Uint32):Uint32;
begin
  result := (key * COVER_prime4bytes)  shr  (32 - map^.sizeLog);
end;

{*
 * Helper function that returns the index that a key should be placed into.
 }
function COVER_map_index(map:pCOVER_map_t; key:Uint32):Uint32;
var
  hash,i:Uint32;
  pos:pCOVER_map_pair_t;
begin
  hash := COVER_map_hash(map, key);
  i := hash;
  while (true) do
  begin
    pos :=  @map^.data[i];
    if (pos^.value = MAP_EMPTY_VALUE) then
    begin
      exit(i);
    end;
    if (pos^.key = key) then
    begin
      exit(i);
    end;
    i := ((i + 1)  and  map^.sizeMask);
  end;
end;

{*
 * Returns the pointer to the value for key.
 * If key is not in the map, it is inserted and the value is set to 0.
 * The map must not be full.
 }
function COVER_map_at(map:pCOVER_map_t; key:Uint32):puint32;
var
  pos:pCOVER_map_pair_t;
begin
  pos :=  @map^.data[COVER_map_index(map, key)];
  if (pos^.value = MAP_EMPTY_VALUE) then
  begin
    pos^.key := key;
    pos^.value := 0;
  end;
  result :=  @pos^.value;
end;

{*
 * Deletes key from the map if present.
 }
procedure COVER_map_remove(map:pCOVER_map_t; key:Uint32);
var
  i,shift:Uint32;
  del,pos:pCOVER_map_pair_t;
begin
  i := COVER_map_index(map, key);
  del :=  @map^.data[i];
  shift := 1;
  if (del^.value = MAP_EMPTY_VALUE) then
  begin
    exit;
  end;
  i:= (i + 1)  and  map^.sizeMask;
  while (true) do
  begin
    pos :=  @map^.data[i];
    { If the position is empty we are done }
    if (pos^.value = MAP_EMPTY_VALUE) then
    begin
      del^.value := MAP_EMPTY_VALUE;
      exit;
    end;
    { If pos can be moved to del do so }
    if (((i - COVER_map_hash(map, pos^.key))  and  map^.sizeMask) >= shift) then
    begin
      del^.key := pos^.key;
      del^.value := pos^.value;
      del := pos;
      shift := 1;
    end 
    else 
    begin
      inc(shift);
    end;
    i := (i + 1)  and  map^.sizeMask;
  end;
end;

{*
 * Destroys a map that is inited with COVER_map_init().
 }
procedure COVER_map_destroy(map:pCOVER_map_t ); 
begin
  if (map^.data<>nil) then
  begin
    freemem(map^.data);
  end;
  map^.data := nil;
  map^.size := 0;
end;



{-*************************************
*  Helper functions
**************************************}

{*
 * Returns the sum of the sample sizes.
 }
function COVER_sum(samplesSizes:pint32; nbSamples:uint32):int32;
var
  sum:int32;
  i:uint32;
begin
  sum := 0;
  for i := 0 to nbSamples-1 do 
  begin
    sum :=sum + samplesSizes[i];
  end;
  result := sum;
end;

{*
 * Returns -1 if the dmer at lp is less than the dmer at rp.
 * Return 0 if the dmers at lp and rp are equal.
 * Returns 1 if the dmer at lp is greater than the dmer at rp.
 }
function COVER_cmp(ctx:pCOVER_ctx_t; lp,rp:pbyte):int32;
var
  lhs,rhs:Uint32;
begin
  lhs := pUint32(lp)^;
  rhs := pUint32(rp)^;
  result := ord(CompareMem(ctx^.samples + lhs, ctx^.samples + rhs, ctx^.d));
end;
{*
 * Faster version for d <= 8.
 }
function COVER_cmp8(ctx:pCOVER_ctx_t; lp,rp:pbyte):int32;
var
  mask,lhs,rhs:Uint64;
begin
  if (ctx^.d = 8) then
    mask :=  -1
  else
    mask :=  ((Uint64(1)  shl  (8 * ctx^.d)) - 1);
  {$IFDEF ENDIAN_LITTLE}
  lhs := pUint64(ctx^.samples + pUint32(lp)^)^  and  mask;
  rhs := pUint64(ctx^.samples + pUint32(rp)^)^  and  mask;
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
  lhs := SwapEndian(pUint64(ctx^.samples + pUint32(lp)^)^)  and  mask;
  rhs := SwapEndian(pUint64(ctx^.samples + pUint32(rp)^)^)  and  mask;
  {$ENDIF}
  if (lhs < rhs) then
  begin
    exit(-1);
  end;
  result := ord(lhs > rhs);
end;

{*
 * Same as COVER_cmp() except ties are broken by pointer value
 * NOTE: g_coverCtx must be set to call this function.  A global is required because
 * qsort doesn't take an opaque pointer.
 }
function COVER_strict_cmp(lp,rp:pbyte):int32; 
begin
  result := COVER_cmp(g_coverCtx, lp, rp);
  if (result = 0) then
  begin
    if lp < rp then
      result := -1
    else
      result := 1;
  end;
end;
{*
 * Faster version for d <= 8.
 }
function COVER_strict_cmp8(lp,rp:pbyte):int32; 
begin
  result := COVER_cmp8(g_coverCtx, lp, rp);
  if (result = 0) then
  begin
    if lp < rp then
      result := -1
    else
      result := 1;
  end;
end;

{*
 * Returns the first pointer in [first, last) whose element does not compare
 * less than value.  If no such element exists it returns last.
 }
function COVER_lower_bound(first, last:pint32;value:int32 ):pint32;
var
  count,step: int32;
  ptr:pint32;
begin
  count := last - first;
  while (count <> 0) do
  begin
    step := count div 2;
    ptr := first;
    ptr :=ptr + step;
    if (ptr^ < value) then
    begin
      inc(ptr);
      first := ptr;
      count :=count - step + 1;
    end 
    else 
    begin
      count := step;
    end;
  end;
  result := first;
end;

{*
 * Generic groupBy function.
 * Groups an array sorted by cmp into groups with equivalent values.
 * Calls grp for each group.
 }

procedure COVER_groupBy(data:pbyte; count, size:int32; ctx:pCOVER_ctx_t;cmp:tcmpfunc;grp:tgrpfunc);
var
  ptr,grpEnd:pbyte;
  num:int32;
begin
  ptr := data;
  num := 0;
  while (num < count) do
  begin
    grpEnd := ptr + size;
    inc(num);
    while (num < count)  and (cmp(ctx, ptr, grpEnd) = 0) do
    begin
      grpEnd :=grpEnd + size;
      inc(num);
    end;
    grp(ctx, ptr, grpEnd);
    ptr := grpEnd;
  end;
end;

{-*************************************
*  Cover functions
**************************************}

{*
 * Called on each group of positions with the same dmer.
 * Counts the frequency of each dmer and saves it in the suffix array.
 * Fills `ctx^.dmerAt`.
 }
procedure COVER_group(ctx:pCOVER_ctx_t;group,groupEnd:pbyte);
var
  grpPtr,grpEnd:pUint32;
  dmerId,freq:Uint32;
  curOffsetPtr,offsetsEnd,sampleEndPtr:pint32;
  curSampleEnd:int32;
begin
  { The group consists of all the positions with the same first d bytes. }
  grpPtr := pUint32(group);
  grpEnd := pUint32(groupEnd);
  { The dmerId is how we will reference this dmer.
   * This allows us to map the whole dmer space to a much smaller space, the
   * size of the suffix array.
   }
  dmerId := Uint32(grpPtr - ctx^.suffix);
  { Count the number of samples this dmer shows up in }
  freq := 0;
  { Details }
  curOffsetPtr := ctx^.offsets;
  offsetsEnd   := ctx^.offsets + ctx^.nbSamples;
  { Once *grpPtr >= curSampleEnd this occurrence of the dmer is in a
   * different sample than the last.
   }
  curSampleEnd := ctx^.offsets[0];
  
  while(grpPtr <> grpEnd) do 
  begin
    { Save the dmerId for this position so we can get back to it. }
    ctx^.dmerAt[grpPtr^] := dmerId;
    { Dictionaries only help for the first reference to the dmer.
     * After that zstd can reference the match from the previous reference.
     * So only count each dmer once for each sample it is in.
     }
    if ( grpPtr^ < curSampleEnd) then
    begin
      continue;
    end;
    freq += 1;
    { Binary search to find the end of the sample *grpPtr is in.
     * In the common case that grpPtr + 1 == grpEnd we can skip the binary
     * search because the loop is over.
     }
    if (grpPtr + 1 <> grpEnd) then
    begin
      sampleEndPtr := COVER_lower_bound(curOffsetPtr, offsetsEnd, grpPtr^);
      curSampleEnd := sampleEndPtr^;
      curOffsetPtr := sampleEndPtr + 1;
    end;
    inc(grpPtr);
  end;
  { At this point we are never going to look at this segment of the suffix
   * array again.  We take advantage of this fact to save memory.
   * We store the frequency of the dmer in the first position of the group,
   * which is dmerId.
   }
  ctx^.suffix[dmerId] := freq;
end;


{*
 * Selects the best segment in an epoch.
 * Segments of are scored according to the function:
 *
 * Let F(d) be the frequency of dmer d.
 * Let S_i be the dmer at position i of segment S which has length k.
 *
 *     Score(S) = F(S_1) + F(S_2) + ... + F(S_begink-d+1end;)
 *
 * Once the dmer d is in the dictionary we set F(d) = 0.
 }
function COVER_selectSegment(ctx:pCOVER_ctx_t; freqs:pUint32;
  activeDmers:pCOVER_map_t;
  lbegin:Uint32;
  lend:Uint32;
  parameters:ZDICT_cover_params_t):COVER_segment_t;
var
  k,d,dmersInK,newDmer,delDmer,newBegin,newEnd,pos,freq:Uint32;
  bestSegment,activeSegment:COVER_segment_t;
  newDmerOcc,delDmerOcc:pUint32;
begin
  { Constants }
  k := parameters.k;
  d := parameters.d;
  dmersInK := k - d + 1;
  { Try each segment (activeSegment) and save the best (bestSegment) }
  fillbyte(bestSegment, sizeof(COVER_segment_t), 0);
  { Reset the activeDmers in the segment }
  COVER_map_clear(activeDmers);
  { The activeSegment starts at the beginning of the epoch. }
  activeSegment.lbegin := lbegin;
  activeSegment.lend := lbegin;
  activeSegment.score := 0;
  { Slide the activeSegment through the whole epoch.
   * Save the best segment in bestSegment.
   }
  while (activeSegment.lend < lend) do
  begin
    { The dmerId for the dmer at the next position }
    newDmer := ctx^.dmerAt[activeSegment.lend];
    { The entry in activeDmers for this dmerId }
    newDmerOcc := COVER_map_at(activeDmers, newDmer);
    { If the dmer isn't already present in the segment add its score. }
    if ( newDmerOcc^ = 0) then
    begin
      { The paper suggest using the L-0.5 norm, but experiments show that it
       * doesn't help.
       }
      activeSegment.score :=activeSegment.score + freqs[newDmer];
    end;
    { Add the dmer to the segment }
    activeSegment.lend :=activeSegment.lend + 1;
    newDmerOcc^ :=newDmerOcc^ + 1;

    { If the window is now too large, drop the first position }
    if (activeSegment.lend - activeSegment.lbegin = dmersInK + 1) then
    begin
      delDmer := ctx^.dmerAt[activeSegment.lbegin];
      delDmerOcc := COVER_map_at(activeDmers, delDmer);
      inc(activeSegment.lbegin);
      dec(delDmerOcc^);
      delDmerOcc^ :=delDmerOcc^ - 1;
      { If this is the last occurrence of the dmer, subtract its score }
      if ( delDmerOcc^ = 0) then
      begin
        COVER_map_remove(activeDmers, delDmer);
        activeSegment.score :=activeSegment.score - freqs[delDmer];
      end;
    end;

    { If this segment is the best so far save it }
    if (activeSegment.score > bestSegment.score) then
    begin
      bestSegment := activeSegment;
    end;
  end;

  { Trim off the zero frequency head and tail from the segment. }
  newBegin := bestSegment.lend;
  newEnd := bestSegment.lbegin;
  pos := bestSegment.lbegin;
  while (pos <> bestSegment.lend) do
  begin
    freq := freqs[ctx^.dmerAt[pos]];
    if (freq <> 0) then
    begin
      newBegin := MIN(newBegin, pos);
      newEnd := pos + 1;
    end;
    inc(pos);
  end;
  bestSegment.lbegin := newBegin;
  bestSegment.lend := newEnd;

  { Zero out the frequency of each dmer covered by the chosen segment. }
  pos := bestSegment.lbegin;
  while (pos <> bestSegment.lend) do
  begin
    freqs[ctx^.dmerAt[pos]] := 0;
    inc(pos);
  end;
  result := bestSegment;
end;

{*
 * Check the validity of the parameters.
 * Returns non-zero if the parameters are valid and 0 otherwise.
 }
function COVER_checkParameters(parameters:ZDICT_cover_params_t;maxDictSize:int32):int32;
begin
  { k and d are required parameters }
  if (parameters.d = 0)  or  (parameters.k = 0) then
  begin
    exit(0);
  end;
  { k <= maxDictSize }
  if (parameters.k > maxDictSize) then
  begin
    exit(0);
  end;
  { d <= k }
  if (parameters.d > parameters.k) then
  begin
    exit(0);
  end;
  { 0 < splitPoint <= 1 }
  if (parameters.splitPoint <= 0)  or  (parameters.splitPoint > 1) then
  begin
    exit(0);
  end;
  result := 1;
end;

{*
 * Clean up a context initialized with `COVER_ctx_init()`.
 }
procedure COVER_ctx_destroy(ctx:pCOVER_ctx_t); 
begin
  if (ctx=nil) then
  begin
    exit;
  end;
  if (ctx^.suffix<>nil) then
  begin
    freemem(ctx^.suffix);
    ctx^.suffix := nil;
  end;
  if (ctx^.freqs<>nil) then
  begin
    freemem(ctx^.freqs);
    ctx^.freqs := nil;
  end;
  if (ctx^.dmerAt<>nil) then
  begin
    freemem(ctx^.dmerAt);
    ctx^.dmerAt := nil;
  end;
  if (ctx^.offsets<>nil) then
  begin
    freemem(ctx^.offsets);
    ctx^.offsets := nil;
  end;
end;

{*
 * Prepare a context for dictionary building.
 * The context is only dependent on the parameter `d` and can used multiple
 * times.
 * Returns 0 on success or error code on error.
 * The context must be destroyed with `COVER_ctx_destroy()`.
 }
function COVER_ctx_init(ctx:pCOVER_ctx_t; samplesBuffer:pbyte;
                          samplesSizes:pint32; nbSamples:uint32;
                          d:uint32; splitPoint:double):int32;
var
  samples:pbyte;
  totalSamplesSize,trainingSamplesSize,testSamplesSize:int32;
  nbTrainSamples,nbTestSamples,i:uint32;
begin
  samples := samplesBuffer;
  totalSamplesSize := COVER_sum(samplesSizes, nbSamples);
  { Split samples into testing and training sets }
  if splitPoint < 1.0 then
  begin
    nbTrainSamples := round(double(nbSamples) * splitPoint);
    nbTestSamples :=  nbSamples - nbTrainSamples;
    trainingSamplesSize := COVER_sum(samplesSizes, nbTrainSamples);
    testSamplesSize := COVER_sum(samplesSizes + nbTrainSamples, nbTestSamples);
  end
  else
  begin
    nbTrainSamples :=  nbSamples;
    nbTestSamples :=  nbSamples;
    trainingSamplesSize :=  totalSamplesSize;
    testSamplesSize :=  totalSamplesSize;
  end;
  { Checks }
  if ((totalSamplesSize < MAX(d, sizeof(Uint64)))  or 
      (totalSamplesSize >= int32(COVER_MAX_SAMPLES_SIZE))) then
  begin
    exit(ERROR(srcSize_wrong));
  end;
  { Check if there are at least 5 training samples }
  if (nbTrainSamples < 5) then
  begin
    exit(ERROR(srcSize_wrong));
  end;
  { Check if there's testing sample }
  if (nbTestSamples < 1) then
  begin
    exit(ERROR(srcSize_wrong));
  end;
  { Zero the context }
  fillbyte(ctx^, sizeof(COVER_ctx_t), 0);
  ctx^.samples := samples;
  ctx^.samplesSizes := samplesSizes;
  ctx^.nbSamples := nbSamples;
  ctx^.nbTrainSamples := nbTrainSamples;
  ctx^.nbTestSamples := nbTestSamples;
  { Partial suffix array }
  ctx^.suffixSize := trainingSamplesSize - MAX(d, sizeof(Uint64)) + 1;
  ctx^.suffix := allocmem(ctx^.suffixSize * sizeof(Uint32));
  { Maps index to the dmerID }
  ctx^.dmerAt := allocmem(ctx^.suffixSize * sizeof(Uint32));
  { The offsets of each file }
  ctx^.offsets :=allocmem((nbSamples + 1) * sizeof(int32));
  if (ctx^.suffix=nil)  or  (ctx^.dmerAt=nil)  or  (ctx^.offsets=nil) then
  begin
    COVER_ctx_destroy(ctx);
    exit(ERROR(memory_allocation));
  end;
  ctx^.freqs := nil;
  ctx^.d := d;

  { Fill offsets from the samplesSizes }

  ctx^.offsets[0] := 0;
  for i := 1 to nbSamples do
  begin
    ctx^.offsets[i] := ctx^.offsets[i - 1] + samplesSizes[i - 1];
  end;



  { suffix is a partial suffix array.
   * It only sorts suffixes by their first parameters.d bytes.
   * The sort is stable, so each dmer group is sorted by position in input.
   }
  for i := 0 to ctx^.suffixSize-1 do 
  begin
    ctx^.suffix[i] := i;
  end;
  { qsort doesn't take an opaque pointer, so pass as a global.
   * On OpenBSD qsort() is not guaranteed to be stable, their mergesort() is.
   }
  g_coverCtx := ctx;
  if ctx^.d <= 8 then
  begin
    //qsort(ctx^.suffix, ctx^.suffixSize, sizeof(Uint32),@COVER_strict_cmp8); 要改

  { For each dmer group (group of positions with the same first d bytes):
   * 1. For each position we set dmerAt[position] = dmerID.  The dmerID is
   *    (groupBeginPtr - suffix).  This allows us to go from position to
   *    dmerID so we can look up values in freq.
   * 2. We calculate how many samples the dmer occurs in and save it in
   *    freqs[dmerId].
   }
    COVER_groupBy(pbyte(ctx^.suffix), ctx^.suffixSize, sizeof(Uint32), ctx,
                @COVER_cmp8,  @COVER_group);
  end
  else
  begin
    //qsort(ctx^.suffix, ctx^.suffixSize, sizeof(Uint32),@COVER_strict_cm); 要改
    COVER_groupBy(pbyte(ctx^.suffix), ctx^.suffixSize, sizeof(Uint32), ctx,@COVER_cmp,  @COVER_group);
  end;
  ctx^.freqs := ctx^.suffix;
  ctx^.suffix := nil;
  exit(0);
end;

procedure COVER_warnOnSmallCorpus(maxDictSize:int32; nbDmers:int32; displayLevel:int32 );
var
  ratio:double;
begin
  ratio := double(nbDmers) / maxDictSize;
  if (ratio >= 10) then
  begin
    exit;
  end;
end;

function COVER_computeEpochs(maxDictSize,nbDmers:int32; k, passes:Uint32 ):COVER_epoch_info_t;
var
  minEpochSize:Uint32;
  epochs:COVER_epoch_info_t;
begin
  minEpochSize := k * 10;
  epochs.num := MAX(1, maxDictSize div k div passes);
  epochs.size := nbDmers div epochs.num;
  if (epochs.size >= minEpochSize) then
  begin
    exit(epochs);
  end;
  epochs.size := MIN(minEpochSize, nbDmers);
  epochs.num := nbDmers div epochs.size;
  result := epochs;
end;

{*
 * Given the prepared context build the dictionary.
 }
function COVER_buildDictionary(ctx:pCOVER_ctx_t; freqs:pUint32;
  activeDmers:pCOVER_map_t; dictBuffer:pbyte;dictBufferCapacity:int32;
  parameters:ZDICT_cover_params_t):int32;
var
  dict:pbyte;
  tail,maxZeroScoreRun,zeroScoreRun,epoch,segmentSize:int32;
  epochs:COVER_epoch_info_t;
  epochBegin,epochEnd:Uint32;
  segment:COVER_segment_t;
begin
  dict := dictBuffer;
  tail := dictBufferCapacity;
  { Divide the data into epochs. We will select one segment from each epoch. }
  epochs := COVER_computeEpochs(Uint32(dictBufferCapacity), Uint32(ctx^.suffixSize), parameters.k, 4);
  maxZeroScoreRun := MAX(10, MIN(100, epochs.num  shr  3));
  zeroScoreRun := 0;
  { Loop through the epochs until there are no more segments or the dictionary
   * is full.
   }
  epoch := 0;
  while  (tail > 0) do
  begin
    epochBegin := Uint32(epoch * epochs.size);
    epochEnd := epochBegin + epochs.size;
    { Select a segment }
    segment := COVER_selectSegment(ctx, freqs, activeDmers, epochBegin, epochEnd, parameters);
    { If the segment covers no dmers, then we are out of content.
     * There may be new content in other epochs, for continue for some time.
     }
    if (segment.score = 0) then
    begin
      inc(zeroScoreRun);
      if (zeroScoreRun >= maxZeroScoreRun) then
      begin
          break;
      end;
      continue;
    end;
    zeroScoreRun := 0;
    { Trim the segment if necessary and if it is too small then we are done }
    segmentSize := MIN(segment.lend - segment.lbegin + parameters.d - 1, tail);
    if (segmentSize < parameters.d) then
    begin
      break;
    end;
    { We fill the dictionary from the back to allow the best segments to be
     * referenced with the smallest offsets.
     }
    tail :=tail - segmentSize;
    move( ctx^.samples[segment.lbegin], dict[tail],segmentSize);
    epoch := (epoch + 1) mod epochs.num;
  end;
  result := tail;
end;

function ZDICT_trainFromBuffer_cover(dictBuffer:pbyte; dictBufferCapacity:int32; 
    samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32;parameters:ZDICT_cover_params_t):int32;
var
  dict:pbyte;
  ctx:COVER_ctx_t;
  activeDmers:COVER_map_t;
  initVal,tail,dictionarySize:int32;
begin
  dict := dictBuffer;
  parameters.splitPoint := 1.0;
  { Initialize global data }
  { Checks }
  if ( COVER_checkParameters(parameters, dictBufferCapacity)=0) then
  begin
    exit(ERROR(parameter_outOfBound));
  end;
  if (nbSamples = 0) then
  begin
    exit(ERROR(srcSize_wrong));
  end;
  if (dictBufferCapacity < ZDICT_DICTSIZE_MIN) then
  begin
    exit(ERROR(dstint32ooSmall));
  end;
  { Initialize context and activeDmers }
  initVal := COVER_ctx_init(@ctx, samplesBuffer, samplesSizes, nbSamples,parameters.d, parameters.splitPoint);
  if (ZSTD_isError(initVal)<>0) then
  begin
    exit(initVal);
  end;

  //COVER_warnOnSmallCorpus(dictBufferCapacity, ctx.suffixSize, g_displayLevel);
  if ( COVER_map_init( @activeDmers, parameters.k - parameters.d + 1)=0) then
  begin
    COVER_ctx_destroy(@ctx);
    exit(ERROR(memory_allocation));
  end;

  tail :=COVER_buildDictionary(@ctx, ctx.freqs,  @activeDmers, dictBuffer,dictBufferCapacity, parameters);
  dictionarySize := ZDICT_finalizeDictionary(dict, dictBufferCapacity, dict + tail, dictBufferCapacity - tail,
      samplesBuffer, samplesSizes, nbSamples, parameters.zParams);
  if ( ZSTD_isError(dictionarySize)=0) then
  begin
    //DISPLAYLEVEL(2, "Constructed dictionary of size %u\n",(unsigned)dictionarySize);
  end;
  COVER_ctx_destroy(@ctx);
  COVER_map_destroy( @activeDmers);
  result := dictionarySize;
end;



function COVER_checkTotalCompressedSize(parameters:ZDICT_cover_params_t;
  samplesSizes:pint32; samples:pbyte;offsets:pint32;
  nbTrainSamples, nbSamples:int32;dict:pbyte;  dictBufferCapacity:int32):int32;
label _compressCleanup;
var
   totalCompressedSize,dstCapacity,i:int32;
   cctx:pZSTD_CCtx;
   cdict:pZSTD_CDict;
   dst:pbyte;
   maxSampleSize,size:int32;
begin
  totalCompressedSize := ERROR(GENERIC_ERROR);
  { Allocate dst with enough space to compress the maximum sized sample }

  maxSampleSize := 0;
  if parameters.splitPoint < 1.0 then
    i := nbTrainSamples
  else
    i := 0;
  for i:=i to nbSamples-1 do
  begin
    maxSampleSize := MAX(samplesSizes[i], maxSampleSize);
  end;
  dstCapacity := ZSTD_compressBound(maxSampleSize);
  dst := allocmem(dstCapacity);

  { Create the cctx and cdict }
  cctx := ZSTD_createCCtx();
  cdict := ZSTD_createCDict(dict, dictBufferCapacity,parameters.zParams.compressionLevel);
  if (dst=nil)  or  (cctx=nil)  or  (cdict=nil) then
  begin
    goto _compressCleanup;
  end;
  { Compress each sample and sum their sizes (or error) }
  
  totalCompressedSize := dictBufferCapacity;
  if parameters.splitPoint < 1.0 then
    i := nbTrainSamples
  else
    i := 0;
  for i:=i to nbSamples-1 do 
  begin
    size := ZSTD_compress_usingCDict(cctx, dst, dstCapacity, samples + offsets[i],
        samplesSizes[i], cdict);
    if (ZSTD_isError(size)<>0) then
    begin
      totalCompressedSize := size;
      goto _compressCleanup;
    end;
    totalCompressedSize :=totalCompressedSize + size;
  end;
_compressCleanup:
  ZSTD_freeCCtx(cctx);
  ZSTD_freeCDict(cdict);
  if (dst<>nil) then
  begin
    freemem(dst);
  end;
  result:= totalCompressedSize;
end;


{*
 * Initialize the `COVER_best_t`.
 }
procedure COVER_best_init(best:pCOVER_best_t); 
begin
  if (best=nil) then
     exit; { compatible with init on nil }
  //(void)ZSTD_pthread_mutex_init(@best^.mutex, nil);
  //(void)ZSTD_pthread_cond_init(@best^.cond, nil);
  best^.liveJobs := 0;
  best^.dict := nil;
  best^.dictSize := 0;
  best^.compressedSize := (maxint)-1;
  fillbyte(best^.parameters, sizeof(best^.parameters), 0);
end;

{*
 * Wait until liveJobs == 0.
 }
procedure COVER_best_wait(best:pCOVER_best_t); 
begin
  if (best=nil) then
  begin
    exit;
  end;
  //ZSTD_pthread_mutex_lock(@best^.mutex);
  while (best^.liveJobs <> 0) do
  begin
    //ZSTD_pthread_cond_wait(@best^.cond, @best^.mutex);
  end;
  //ZSTD_pthread_mutex_unlock(@best^.mutex);
end;

{*
 * Call COVER_best_wait() and then destroy the COVER_best_t.
 }
procedure COVER_best_destroy(best:pCOVER_best_t); 
begin
  if (best=nil) then
  begin
    exit;
  end;
  COVER_best_wait(best);
  if (best^.dict=nil) then
  begin
    freemem(best^.dict);
  end;
  //ZSTD_pthread_mutex_destroy(@best^.mutex);
  //ZSTD_pthread_cond_destroy(@best^.cond);
end;

{*
 * Called when a thread is about to be launched.
 * Increments liveJobs.
 }
procedure COVER_best_start(best:pCOVER_best_t); 
begin
  if (best=nil) then
  begin
    exit;
  end;
  //ZSTD_pthread_mutex_lock(@best^.mutex);
  inc(best^.liveJobs);
  //ZSTD_pthread_mutex_unlock(@best^.mutex);
end;

{*
 * Called when a thread finishes executing, both on error or success.
 * Decrements liveJobs and signals any waiting threads if liveJobs == 0.
 * If this dictionary is the best so far save it and its parameters.
 }
procedure COVER_best_finish(best:pCOVER_best_t; parameters:ZDICT_cover_params_t;selection:COVER_dictSelection_t);
var
   dict:pbyte;
   compressedSize,dictSize,liveJobs:int32;
begin
  dict := selection.dictContent;
  compressedSize := selection.totalCompressedSize;
  dictSize := selection.dictSize;
  if (best=nil) then
  begin
    exit;
  end;

  //ZSTD_pthread_mutex_lock(@best^.mutex);
  dec(best^.liveJobs);
  liveJobs := best^.liveJobs;
  { If the new dictionary is better }
  if (compressedSize < best^.compressedSize) then
  begin
    { Allocate space if necessary }
    if (best^.dict=nil)  or  (best^.dictSize < dictSize) then
    begin
      if (best^.dict<>nil) then
      begin
        freemem(best^.dict);
      end;
      best^.dict := allocmem(dictSize);
      if (best^.dict=nil) then
      begin
        best^.compressedSize := ERROR(GENERIC_ERROR);
        best^.dictSize := 0;
        //ZSTD_pthread_cond_signal(@best^.cond);
        //ZSTD_pthread_mutex_unlock(@best^.mutex);
        exit;
      end;
    end;
    { Save the dictionary, parameters, and size }
    if (dict<>nil) then
    begin
      move(dict,best^.dict, dictSize);
      best^.dictSize := dictSize;
      best^.parameters := parameters;
      best^.compressedSize := compressedSize;
    end;
  end;
  if (liveJobs = 0) then
  begin
    //ZSTD_pthread_cond_broadcast(@best^.cond);
  end;
  //ZSTD_pthread_mutex_unlock(@best^.mutex);
end;

function COVER_dictSelectionError(error:int32):COVER_dictSelection_t;
begin
    fillbyte(result,sizeof(COVER_dictSelection_t),0);
end;

function COVER_dictSelectionIsError(selection:COVER_dictSelection_t):uint32;
begin
  result := ord((ZSTD_isError(selection.totalCompressedSize)<>0)  or  ( selection.dictContent=nil));
end;

procedure COVER_dictSelectionfreemem(selection:COVER_dictSelection_t);
begin
  freemem(selection.dictContent);
end;

function COVER_selectDict(customDictContent:pbyte; dictBufferCapacity:int32;
        dictContentSize:int32 ; samplesBuffer:pbyte; samplesSizes:pint32; nbFinalizeSamples:uint32;
        nbCheckSamples,nbSamples:int32; params:ZDICT_cover_params_t ; offsets:pint32; totalCompressedSize:int32 ):COVER_dictSelection_t;
var
   largestDict,largestCompressed:int32;
   customDictContentEnd,largestDictbuffer,candidateDictBuffer:pbyte;
   regressionTolerance:double;
begin
  largestDict := 0;
  largestCompressed := 0;
  customDictContentEnd := customDictContent + dictContentSize;

  largestDictbuffer := allocmem(dictBufferCapacity);
  candidateDictBuffer := allocmem(dictBufferCapacity);
  regressionTolerance := (double(params.shrinkDictMaxRegression) / 100.0) + 1.00;

  if (largestDictbuffer=nil)  or  (candidateDictBuffer=nil) then
  begin
    freemem(largestDictbuffer);
    freemem(candidateDictBuffer);
    exit(COVER_dictSelectionError(dictContentSize));
  end;

  { Initial dictionary size and compressed size }
  move(customDictContent, largestDictbuffer,  dictContentSize);
  dictContentSize := ZDICT_finalizeDictionary(
    largestDictbuffer, dictBufferCapacity, customDictContent, dictContentSize,
    samplesBuffer, samplesSizes, nbFinalizeSamples, params.zParams);

  if (ZDICT_isError(dictContentSize)<>0) then
  begin
    freemem(largestDictbuffer);
    freemem(candidateDictBuffer);
    exit(COVER_dictSelectionError(dictContentSize));
  end;

  totalCompressedSize := COVER_checkTotalCompressedSize(params, samplesSizes,
                                                       samplesBuffer, offsets,
                                                       nbCheckSamples, nbSamples,
                                                       largestDictbuffer, dictContentSize);

  if (ZSTD_isError(totalCompressedSize)<>0) then
  begin
    freemem(largestDictbuffer);
    freemem(candidateDictBuffer);
    result := COVER_dictSelectionError(totalCompressedSize);
  end;

  if (params.shrinkDict = 0) then
  begin
    result.dictContent:=largestDictbuffer;
    result.dictSize:=dictContentSize ;
    result.totalCompressedSize:=totalCompressedSize ;
    freemem(candidateDictBuffer);
    exit;
  end;

  largestDict := dictContentSize;
  largestCompressed := totalCompressedSize;
  dictContentSize := ZDICT_DICTSIZE_MIN;

  { Largest dict is initially at least ZDICT_DICTSIZE_MIN }
  while (dictContentSize < largestDict) do
  begin
    move( largestDictbuffer, candidateDictBuffer,largestDict);
    dictContentSize := ZDICT_finalizeDictionary(
      candidateDictBuffer, dictBufferCapacity, customDictContentEnd - dictContentSize, dictContentSize,
      samplesBuffer, samplesSizes, nbFinalizeSamples, params.zParams);

    if (ZDICT_isError(dictContentSize)<>0) then
    begin
      freemem(largestDictbuffer);
      freemem(candidateDictBuffer);
      exit(COVER_dictSelectionError(dictContentSize));
    end;

    totalCompressedSize := COVER_checkTotalCompressedSize(params, samplesSizes,
                                                         samplesBuffer, offsets,
                                                         nbCheckSamples, nbSamples,
                                                         candidateDictBuffer, dictContentSize);

    if (ZSTD_isError(totalCompressedSize)<>0) then
    begin
      freemem(largestDictbuffer);
      freemem(candidateDictBuffer);
      exit(COVER_dictSelectionError(totalCompressedSize));
    end;

    if (totalCompressedSize <= largestCompressed * regressionTolerance) then
    begin
      result.dictContent:=candidateDictBuffer;
      result.dictSize:=dictContentSize ;
      result.totalCompressedSize:=totalCompressedSize ;
      freemem(largestDictbuffer);
      exit;
    end;
    dictContentSize :=dictContentSize * 2;
  end;
  dictContentSize := largestDict;
  totalCompressedSize := largestCompressed;
  result.dictContent:=largestDictbuffer;
  result.dictSize:=dictContentSize ;
  result.totalCompressedSize:=totalCompressedSize ;
  freemem(candidateDictBuffer);
  exit;
end;

{*
 * Tries a set of parameters and updates the COVER_best_t with the results.
 * This function is thread safe if zstd is compiled with multithreaded support.
 * It takes its parameters as an *OWNING* opaque pointer to support threading.
 }
procedure COVER_tryParameters(opaque:pbyte);
label _cleanup;
var
  data:pCOVER_tryParameters_data_t;
  ctx:pCOVER_ctx_t;
  parameters:ZDICT_cover_params_t;
  dictBufferCapacity,totalCompressedSize,tail:int32;
  activeDmers:COVER_map_t;
  dict:pbyte;
  selection:COVER_dictSelection_t;
  freqs:pUint32;
begin
  { Save parameters as local variables }
  data := pCOVER_tryParameters_data_t(opaque);
  ctx := data^.ctx;
  parameters:= data^.parameters;
  dictBufferCapacity  := data^.dictBufferCapacity;
  totalCompressedSize := ERROR(GENERIC_ERROR);
  { Allocate space for hash table, dict, and freqs }
  
  dict := allocmem(dictBufferCapacity);
  selection:= COVER_dictSelectionError(ERROR(GENERIC_ERROR));
  freqs := allocmem(ctx^.suffixSize * sizeof(Uint32));
  if (COVER_map_init( @activeDmers, parameters.k - parameters.d + 1)=0) then
  begin
    goto _cleanup;
  end;
  if (dict=nil)  or  (freqs=nil) then
  begin
    goto _cleanup;
  end;
  { Copy the frequencies because we need to modify them }
  move(ctx^.freqs, freqs,  ctx^.suffixSize * sizeof(Uint32));
  { Build the dictionary }
  tail := COVER_buildDictionary(ctx, freqs,  @activeDmers, dict,dictBufferCapacity, parameters);
  selection := COVER_selectDict(dict + tail, dictBufferCapacity, dictBufferCapacity - tail,
      ctx^.samples, ctx^.samplesSizes, uint32(ctx^.nbTrainSamples), ctx^.nbTrainSamples, ctx^.nbSamples, parameters, ctx^.offsets,
      totalCompressedSize);

  if (COVER_dictSelectionIsError(selection)<>0) then
  begin
    goto _cleanup;
  end;
_cleanup:
  freemem(dict);
  COVER_best_finish(data^.best, parameters, selection);
  freemem(data);
  COVER_map_destroy( @activeDmers);
  COVER_dictSelectionfreemem(selection);
  if (freqs<>nil) then
  begin
    freemem(freqs);
  end;
end;

function  ZDICT_optimizeTrainFromBuffer_cover(
    dictBuffer:pbyte; dictBufferCapacity:int32;  samplesBuffer:pbyte;
    samplesSizes:pint32; nbSamples:uint32;
    parameters:pZDICT_cover_params_t):int32;
var
  nbThreads,kMinD,kMaxD,kMinK,kMaxK,kSteps,kStepSize,kIterations,shrinkDict:uint32;
  splitPoint:double;
  iteration,d,k:uint32;
  displayLevel,warned,initVal:int32;
  best:COVER_best_t;
  //pool:POOL_ctx;
  data:pCOVER_tryParameters_data_t;
  ctx:COVER_ctx_t;
  dictSize,compressedSize:int32;
begin
  { constants }
  nbThreads := parameters^.nbThreads;
  if parameters^.splitPoint <= 0.0 then
    splitPoint:= COVER_DEFAULT_SPLITPOINT
  else
    splitPoint:= parameters^.splitPoint;
  if parameters^.d = 0 then
  begin
    kMinD := 6 ;
    kMaxD := 8;
  end
  else
  begin
    kMinD := parameters^.d;
    kMaxD := parameters^.d;
  end;
  if parameters^.k = 0 then
  begin
    kMinK := 50;
    kMaxK := 2000;
  end
  else
  begin
    kMinK := parameters^.k;
    kMaxK := parameters^.k;
  end;
  if parameters^.steps = 0 then
    kSteps := 40
  else
    kSteps := parameters^.steps;
  kStepSize := MAX((kMaxK - kMinK) div kSteps, 1);
  kIterations :=(1 + (kMaxD - kMinD) div 2) * (1 + (kMaxK - kMinK) div kStepSize);
  shrinkDict := 0;
  { Local variables }
  displayLevel := parameters^.zParams.notificationLevel;
  iteration := 1;
  
  //pool:=nil;
  warned := 0;

  { Checks }
  if (splitPoint <= 0) or (splitPoint > 1) then
  begin
    exit(ERROR(parameter_outOfBound));
  end;
  if (kMinK < kMaxD) or (kMaxK < kMinK) then
  begin
    exit(ERROR(parameter_outOfBound));
  end;
  if (nbSamples = 0) then
  begin
    exit(ERROR(srcSize_wrong));
  end;
  if (dictBufferCapacity < ZDICT_DICTSIZE_MIN) then
  begin
    exit(ERROR(dstint32ooSmall));
  end;
  if (nbThreads > 1) then
  begin
    //pool := POOL_create(nbThreads, 1);
    //if (pool=nil) then
    //begin
    //  exit(ERROR(memory_allocation));
    //end;
  end;
  { Initialization }
  COVER_best_init(@best);
  { Turn down global display level to clean up display at level 2 and below }
  //if displayLevel = 0 then
  //  g_displayLevel := 0 
  //else
  //  g_displayLevel := displayLevel - 1;
  { Loop through d first because each new value needs a new context }
  d := kMinD;
  while d <= kMaxD do 
  begin
    { Initialize the context for this value of d }
    initVal := COVER_ctx_init(@ctx, samplesBuffer, samplesSizes, nbSamples, d, splitPoint);
    if (ZSTD_isError(initVal)<>0) then
    begin
      COVER_best_destroy(@best);
      //POOL_freemem(pool);
      exit(initVal);
    end;
    if (warned=0) then
    begin
      COVER_warnOnSmallCorpus(dictBufferCapacity, ctx.suffixSize, displayLevel);
      warned := 1;
    end;
    { Loop through k reusing the same context }
    k := kMinK;
    while( k <= kMaxK) do
    begin
      { Prepare the arguments }
      data := allocmem(sizeof(COVER_tryParameters_data_t));
      if (data=nil) then
      begin
        COVER_best_destroy(@best);
        COVER_ctx_destroy(@ctx);
        //POOL_freemem(pool);
        exit(ERROR(memory_allocation));
      end;
      data^.ctx := @ctx;
      data^.best := @best;
      data^.dictBufferCapacity := dictBufferCapacity;
      data^.parameters := parameters^;
      data^.parameters.k := k;
      data^.parameters.d := d;
      data^.parameters.splitPoint := splitPoint;
      data^.parameters.steps := kSteps;
      data^.parameters.shrinkDict := shrinkDict;
      //data^.parameters.zParams.notificationLevel := g_displayLevel;
      { Check the parameters }
      if (COVER_checkParameters(data^.parameters, dictBufferCapacity)=0) then
      begin
        freemem(data);
        continue;
      end;
      { Call the function and pass ownership of data to it }
      COVER_best_start(@best);
      //if (pool<>nil) then
      //begin
      //  POOL_add(pool,  @COVER_tryParameters, data);
      //end 
      //else 
      //begin
        COVER_tryParameters(pbyte(data));
      //end;
      { Print status }
      inc(iteration);
      k :=k + kStepSize;
    end;
    COVER_best_wait(@best);
    COVER_ctx_destroy(@ctx);
    d :=d + 2;
  end;
  //LOCALDISPLAYLEVEL(displayLevel, 2, "\r%79s\r", "");
  { Fill the output buffer and parameters with output of the best parameters }

    dictSize := best.dictSize;
    if (ZSTD_isError(best.compressedSize)<>0) then
    begin
      compressedSize := best.compressedSize;
      COVER_best_destroy(@best);
      //POOL_freemem(pool);
      exit(compressedSize);
    end;
    parameters^ := best.parameters;
    move( best.dict^, dictBuffer^, dictSize);
    COVER_best_destroy(@best);
    //POOL_freemem(pool);
    result := dictSize;

end;
end.
