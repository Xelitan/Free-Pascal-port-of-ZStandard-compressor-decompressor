unit fastcover;
{$mode objfpc}{$H+}
interface
uses cover,
    zstd_internal, { includes zstd.h }
    zstd_compress_internal, { ZSTD_hash*() }
    zdict;

const
{-*************************************
*  Constants
**************************************}
  FASTCOVER_MAX_SAMPLES_SIZE =1024*1024*1024;//(sizeof(int32) == 8 ? ((unsigned)-1) : ((unsigned)1 GB))
  FASTCOVER_MAX_F =31;
  FASTCOVER_MAX_ACCEL =10;
  FASTCOVER_DEFAULT_SPLITPOINT =0.75;
  DEFAULT_F =20;
  DEFAULT_ACCEL =1;

type
pFASTCOVER_accel_t=^FASTCOVER_accel_t;
pFASTCOVER_ctx_t=^FASTCOVER_ctx_t;
pFASTCOVER_tryParameters_data_t=^FASTCOVER_tryParameters_data_t;

{-*************************************
* Acceleration
**************************************}
FASTCOVER_accel_t=record
  finalize:uint32;    { Percentage of training samples used for ZDICT_finalizeDictionary }
  skip:uint32;        { Number of dmer skipped between each dmer counted in computeFrequency }
end;

{-*************************************
* Context
**************************************}
FASTCOVER_ctx_t=record
  samples:pbyte;
  offsets:pint32;
  samplesSizes:pint32;
  nbSamples:int32;
  nbTrainSamples:int32;
  nbTestSamples:int32;
  nbDmers:int32;
  freqs:puint32;
  d:uint32;
  f:uint32;
  accelParams:FASTCOVER_accel_t;
end;
{*
 * Parameters for FASTCOVER_tryParameters().
 }
FASTCOVER_tryParameters_data_t=record
    ctx: pFASTCOVER_ctx_t;
    best:pCOVER_best_t;
    dictBufferCapacity:int32;
    parameters:ZDICT_cover_params_t;
end;
const
    FASTCOVER_defaultAccelParameters:array[0..FASTCOVER_MAX_ACCEL] of FASTCOVER_accel_t = (
  (finalize:100; skip:0),   { accel = 0, should not happen because accel = 0 defaults to accel = 1 }
  (finalize:100; skip:0),   { accel = 1 }
  (finalize:50 ; skip:1 ),   { accel = 2 }
  (finalize:34 ; skip:2 ),   { accel = 3 }
  (finalize:25 ; skip:3 ),   { accel = 4 }
  (finalize:20 ; skip:4 ),   { accel = 5 }
  (finalize:17 ; skip:5 ),   { accel = 6 }
  (finalize:14 ; skip:6 ),   { accel = 7 }
  (finalize:13 ; skip:7 ),   { accel = 8 }
  (finalize:11 ; skip:8 ),   { accel = 9 }
  (finalize:10 ; skip:9 )   { accel = 10 }
  );
function  FASTCOVER_hashPtrToIndex(p:pbyte; f,d:Uint32):int32;
function FASTCOVER_selectSegment(ctx:pFASTCOVER_ctx_t;freqs:pUint32; lbegin,lend:Uint32;
parameters:ZDICT_cover_params_t;segmentFreqs:pword):COVER_segment_t;
function FASTCOVER_checkParameters(parameters:ZDICT_cover_params_t;
  maxDictSize:int32; f,accel:uint32):int32;
procedure FASTCOVER_ctx_destroy(ctx:pFASTCOVER_ctx_t );
procedure FASTCOVER_computeFrequency(freqs:pUint32; ctx:pFASTCOVER_ctx_t);
function FASTCOVER_ctx_init(ctx:pFASTCOVER_ctx_t;
                   samplesBuffer:pbyte;
                   samplesSizes:pint32; nbSamples:uint32;
                   d:uint32;  splitPoint:double; f:uint32;
                   accelParams:FASTCOVER_accel_t):int32;
function FASTCOVER_buildDictionary(ctx:pFASTCOVER_ctx_t;
                          freqs:pUint32;
                          dictBuffer:pbyte; dictBufferCapacity:int32;
                          parameters:ZDICT_cover_params_t;
                          segmentFreqs:pword ):int32;
procedure FASTCOVER_tryParameters(opaque:pbyte);
procedure FASTCOVER_convertToCoverParams(fastCoverParams:ZDICT_fastCover_params_t;coverParams:pZDICT_cover_params_t);
procedure FASTCOVER_convertToFastCoverParams(coverParams:ZDICT_cover_params_t;
                                   fastCoverParams:pZDICT_fastCover_params_t;
                                    f,  accel:uint32);
function ZDICT_trainFromBuffer_fastCover(dictBuffer:pbyte; dictBufferCapacity:int32;
                                samplesBuffer:pbyte;
                                samplesSizes:pint32; nbSamples:uint32;
                                parameters:ZDICT_fastCover_params_t ):int32;
function ZDICT_optimizeTrainFromBuffer_fastCover(
                    dictBuffer:pbyte; dictBufferCapacity:int32;
                    samplesBuffer:pbyte;
                    samplesSizes:pint32; nbSamples:uint32;
                    parameters:pZDICT_fastCover_params_t):int32;
implementation
uses math,error_private,zstd_common;
{-*************************************
* Hash Functions
**************************************}
{*
 * Hash the d-byte value pointed to by p and mod 2^f into the frequency vector
 }
function  FASTCOVER_hashPtrToIndex(p:pbyte; f,d:Uint32):int32;
begin
  if (d = 6) then
  begin
    exit(ZSTD_hash6Ptr(p, f));
  end;
  exit(ZSTD_hash8Ptr(p, f));
end;


{-*************************************
*  Helper functions
**************************************}
{*
 * Selects the best segment in an epoch.
 * Segments of are scored according to the function:
 *
 * Let F(d) be the frequency of all dmers with hash value d.
 * Let S_i be hash value of the dmer at position i of segment S which has length k.
 *
 *     Score(S) = F(S_1) + F(S_2) + ... + F(S_begink-d+1end;)
 *
 * Once the dmer with hash value d is in the dictionary we set F(d) = 0.
 }
function FASTCOVER_selectSegment(ctx:pFASTCOVER_ctx_t;freqs:pUint32; lbegin,lend:Uint32;
parameters:ZDICT_cover_params_t;segmentFreqs:pword):COVER_segment_t;
var
  k,d,f,dmersInK,pos:Uint32;
  bestSegment,activeSegment:COVER_segment_t;
  idx,delIndex,i:int32;
begin
  { Constants }
  k := parameters.k;
  d := parameters.d;
  f := ctx^.f;
  dmersInK := k - d + 1;

  { Try each segment (activeSegment) and save the best (bestSegment) }
  fillbyte(bestSegment,sizeof(COVER_segment_t), 0);

  { Reset the activeDmers in the segment }
  { The activeSegment starts at the beginning of the epoch. }
  activeSegment.lend   := lbegin;
  activeSegment.lbegin := lbegin;
  activeSegment.score  := 0;

  { Slide the activeSegment through the whole epoch.
   * Save the best segment in bestSegment.
   }
  while (activeSegment.lend < lend) do
  begin
    { Get hash value of current dmer }
    idx := FASTCOVER_hashPtrToIndex(ctx^.samples + activeSegment.lend, f, d);

    { Add frequency of this index to score if this is the first occurrence of index in active segment }
    if (segmentFreqs[idx] = 0) then
    begin
      activeSegment.score :=activeSegment.score + freqs[idx];
    end;
    { Increment end of segment and segmentFreqs}
    activeSegment.lend :=activeSegment.lend + 1;
    segmentFreqs[idx]  :=segmentFreqs[idx] + 1;
    { If the window is now too large, drop the first position }
    if (activeSegment.lend - activeSegment.lbegin = dmersInK + 1) then
    begin
      { Get hash value of the dmer to be eliminated from active segment }
      delIndex := FASTCOVER_hashPtrToIndex(ctx^.samples + activeSegment.lbegin, f, d);
      segmentFreqs[delIndex] :=segmentFreqs[delIndex] - 1;
      { Subtract frequency of this index from score if this is the last occurrence of this index in active segment }
      if (segmentFreqs[delIndex] = 0) then
      begin
        activeSegment.score :=activeSegment.score - freqs[delIndex];
      end;
      { Increment start of segment }
      activeSegment.lbegin :=activeSegment.lbegin + 1;
    end;

    { If this segment is the best so far save it }
    if (activeSegment.score > bestSegment.score) then
    begin
      bestSegment := activeSegment;
    end;
  end;

  { Zero out rest of segmentFreqs array }
  while (activeSegment.lbegin < lend) do
  begin
    delIndex := FASTCOVER_hashPtrToIndex(ctx^.samples + activeSegment.lbegin, f, d);
    segmentFreqs[delIndex] :=segmentFreqs[delIndex] - 1;
    activeSegment.lbegin :=activeSegment.lbegin + 1;
  end;

  {  Zero the frequency of hash value of each dmer covered by the chosen segment. }
  pos := bestSegment.lbegin;
  while pos <> bestSegment.lend do 
  begin
    i := FASTCOVER_hashPtrToIndex(ctx^.samples + pos, f, d);
    freqs[i] := 0;
    inc(pos)
  end;

  result := bestSegment;
end;


function FASTCOVER_checkParameters(parameters:ZDICT_cover_params_t;
  maxDictSize:int32; f,accel:uint32):int32;
begin
  { k, d, and f are required parameters }
  if (parameters.d = 0)  or  (parameters.k = 0) then
  begin
    exit(0);
  end;
  { d has to be 6 or 8 }
  if (parameters.d <> 6)  and (parameters.d <> 8) then
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
  { 0 < f <= FASTCOVER_MAX_F}
  if (f > FASTCOVER_MAX_F) or  (f = 0) then
  begin
    exit(0);
  end;
  { 0 < splitPoint <= 1 }
  if (parameters.splitPoint <= 0)  or  (parameters.splitPoint > 1) then
  begin
    exit(0);
  end;
  { 0 < accel <= 10 }
  if (accel > 10)  or  (accel = 0) then
  begin
    exit(0);
  end;
  result := 1;
end;


{*
 * Clean up a context initialized with `FASTCOVER_ctx_init()`.
 }
procedure FASTCOVER_ctx_destroy(ctx:pFASTCOVER_ctx_t );
begin
    if (ctx=nil) then
      exit;

    freemem(ctx^.freqs);
    ctx^.freqs := nil;

    freemem(ctx^.offsets);
    ctx^.offsets := nil;
end;


{*
 * Calculate for frequency of hash value of each dmer in ctx^.samples
 }
procedure FASTCOVER_computeFrequency(freqs:pUint32; ctx:pFASTCOVER_ctx_t);
var
  f,d,skip,readLength:uint32;
  i,start,currSampleEnd,dmerIndex:int32;
begin
    f := ctx^.f;
    d := ctx^.d;
    skip := ctx^.accelParams.skip;
    readLength := MAX(d, 8);

    for i := 0 to ctx^.nbTrainSamples-1 do
    begin
        start := ctx^.offsets[i];  { start of current dmer }
        currSampleEnd := ctx^.offsets[i+1];
        while (start + readLength <= currSampleEnd) do 
        begin
            dmerIndex := FASTCOVER_hashPtrToIndex(ctx^.samples + start, f, d);
            inc(freqs[dmerIndex]);
            start := start + skip + 1;
        end;
    end;
end;


{*
 * Prepare a context for dictionary building.
 * The context is only dependent on the parameter `d` and can used multiple
 * times.
 * Returns 0 on success or error code on error.
 * The context must be destroyed with `FASTCOVER_ctx_destroy()`.
 }
function FASTCOVER_ctx_init(ctx:pFASTCOVER_ctx_t;
                   samplesBuffer:pbyte;
                   samplesSizes:pint32; nbSamples:uint32;
                   d:uint32;  splitPoint:double; f:uint32;
                   accelParams:FASTCOVER_accel_t):int32;
var
  samples:pbyte;
  totalSamplesSize,trainingSamplesSize,testSamplesSize,i:int32;
  nbTrainSamples,nbTestSamples:uint32;
begin
    samples := samplesBuffer;
    totalSamplesSize := COVER_sum(samplesSizes, nbSamples);
    { Split samples into testing and training sets }
    if splitPoint < 1.0 then
    begin
      nbTrainSamples :=  round(double(nbSamples) * splitPoint);
      nbTestSamples :=  nbSamples - nbTrainSamples;
      trainingSamplesSize :=  COVER_sum(samplesSizes, nbTrainSamples);
      testSamplesSize :=  COVER_sum(samplesSizes + nbTrainSamples, nbTestSamples);
    end
    else
    begin
      nbTrainSamples :=  nbSamples;
      nbTestSamples :=  nbSamples;
      trainingSamplesSize :=  totalSamplesSize;
      testSamplesSize :=  totalSamplesSize;
    end;
    { Checks }
    if (totalSamplesSize < MAX(d, sizeof(Uint64)))  or 
        (totalSamplesSize >= int32(FASTCOVER_MAX_SAMPLES_SIZE)) then
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
    fillbyte(ctx^, sizeof(FASTCOVER_ctx_t), 0);

    ctx^.samples := samples;
    ctx^.samplesSizes := samplesSizes;
    ctx^.nbSamples := nbSamples;
    ctx^.nbTrainSamples := nbTrainSamples;
    ctx^.nbTestSamples := nbTestSamples;
    ctx^.nbDmers := trainingSamplesSize - MAX(d, sizeof(Uint64)) + 1;
    ctx^.d := d;
    ctx^.f := f;
    ctx^.accelParams := accelParams;

    { The offsets of each file }
    ctx^.offsets := allocmem((nbSamples + 1)*sizeof(int32));
    if (ctx^.offsets = nil) then
    begin
        FASTCOVER_ctx_destroy(ctx);
        exit(ERROR(memory_allocation));
    end;

    { Fill offsets from the samplesSizes }
    
    ctx^.offsets[0] := 0;
    for i := 1 to nbSamples do 
    begin
        ctx^.offsets[i] := ctx^.offsets[i - 1] + samplesSizes[i - 1];
    end;

    { Initialize frequency array of size 2^f }
    ctx^.freqs := allocmem((Uint64(1)  shl  f)* sizeof(Uint32));
    if (ctx^.freqs = nil) then
    begin
        FASTCOVER_ctx_destroy(ctx);
        exit(ERROR(memory_allocation));
    end;

    FASTCOVER_computeFrequency(ctx^.freqs, ctx);

    exit(0);
end;


{*
 * Given the prepared context build the dictionary.
 }
function FASTCOVER_buildDictionary(ctx:pFASTCOVER_ctx_t;
                          freqs:pUint32;
                          dictBuffer:pbyte; dictBufferCapacity:int32;
                          parameters:ZDICT_cover_params_t;
                          segmentFreqs:pword ):int32;
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
  epochs := COVER_computeEpochs(Uint32(dictBufferCapacity), Uint32(ctx^.nbDmers), parameters.k, 1);
  maxZeroScoreRun := 10;
  zeroScoreRun := 0;

  { Loop through the epochs until there are no more segments or the dictionary
   * is full.
   }
  epoch := 0;
  while (tail > 0) do 
  begin
    epochBegin := Uint32(epoch * epochs.size);
    epochEnd   := epochBegin + epochs.size;
    { Select a segment }
    segment := FASTCOVER_selectSegment(ctx, freqs, epochBegin, epochEnd, parameters, segmentFreqs);

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
    move(ctx^.samples [ segment.lbegin], dict[tail],  segmentSize);
    epoch := (epoch + 1) mod epochs.num;
  end;
  exit(tail);
end;


{*
 * Tries a set of parameters and updates the COVER_best_t with the results.
 * This function is thread safe if zstd is compiled with multithreaded support.
 * It takes its parameters as an *OWNING* opaque pointer to support threading.
 }
procedure FASTCOVER_tryParameters(opaque:pbyte);
label _cleanup;
var
  data:pFASTCOVER_tryParameters_data_t;
  ctx:pFASTCOVER_ctx_t;
  parameters:ZDICT_cover_params_t;
  dictBufferCapacity,totalCompressedSize:int32;
  segmentFreqs:pword;
  dict:pbyte;
  selection:COVER_dictSelection_t;
  freqs:pUint32;
  tail:int32;
  nbFinalizeSamples:Uint32;
begin
  { Save parameters as local variables }
  data := pFASTCOVER_tryParameters_data_t(opaque);
  ctx := data^.ctx;
  parameters := data^.parameters;
  dictBufferCapacity := data^.dictBufferCapacity;
  totalCompressedSize := ERROR(GENERIC_ERROR);
  { Initialize array to keep track of frequency of dmer within activeSegment }
  segmentFreqs := allocmem((Uint64(1)  shl  ctx^.f)*sizeof(word));
  { Allocate space for hash table, dict, and freqs }
  dict := allocmem(dictBufferCapacity);
  selection := COVER_dictSelectionError(ERROR(GENERIC_ERROR));
  freqs := allocmem((Uint64(1)  shl  ctx^.f) * sizeof(Uint32));
  if (segmentFreqs=nil)  or  (dict=nil)  or  (freqs=nil) then
  begin
    goto _cleanup;
  end;
  { Copy the frequencies because we need to modify them }
  move(ctx^.freqs,freqs,  (Uint64(1) shl  ctx^.f) * sizeof(Uint32));
  { Build the dictionary }
 
  tail := FASTCOVER_buildDictionary(ctx, freqs, dict, dictBufferCapacity,
                                                    parameters, segmentFreqs);

  nbFinalizeSamples := Uint32(ctx^.nbTrainSamples * ctx^.accelParams.finalize div 100);
  selection := COVER_selectDict(dict + tail, dictBufferCapacity, dictBufferCapacity - tail,
         ctx^.samples, ctx^.samplesSizes, nbFinalizeSamples, ctx^.nbTrainSamples, ctx^.nbSamples, parameters, ctx^.offsets,
         totalCompressedSize);

  if (COVER_dictSelectionIsError(selection)<>0) then
  begin
    goto _cleanup;
  end;
_cleanup:
  freemem(dict);
  COVER_best_finish(data^.best, parameters, selection);
  freemem(data);
  freemem(segmentFreqs);
  COVER_dictSelectionfreemem(selection);
  freemem(freqs);
end;


procedure FASTCOVER_convertToCoverParams(fastCoverParams:ZDICT_fastCover_params_t;coverParams:pZDICT_cover_params_t);
begin
    coverParams^.k := fastCoverParams.k;
    coverParams^.d := fastCoverParams.d;
    coverParams^.steps := fastCoverParams.steps;
    coverParams^.nbThreads := fastCoverParams.nbThreads;
    coverParams^.splitPoint := fastCoverParams.splitPoint;
    coverParams^.zParams := fastCoverParams.zParams;
    coverParams^.shrinkDict := fastCoverParams.shrinkDict;
end;


procedure FASTCOVER_convertToFastCoverParams(coverParams:ZDICT_cover_params_t;
                                   fastCoverParams:pZDICT_fastCover_params_t;
                                    f,  accel:uint32);
begin
  fastCoverParams^.k := coverParams.k;
  fastCoverParams^.d := coverParams.d;
  fastCoverParams^.steps := coverParams.steps;
  fastCoverParams^.nbThreads := coverParams.nbThreads;
  fastCoverParams^.splitPoint := coverParams.splitPoint;
  fastCoverParams^.f := f;
  fastCoverParams^.accel := accel;
  fastCoverParams^.zParams := coverParams.zParams;
  fastCoverParams^.shrinkDict := coverParams.shrinkDict;
end;


function ZDICT_trainFromBuffer_fastCover(dictBuffer:pbyte; dictBufferCapacity:int32;
                                samplesBuffer:pbyte;
                                samplesSizes:pint32; nbSamples:uint32;
                                parameters:ZDICT_fastCover_params_t ):int32;
var
  dict:pbyte;
  ctx:FASTCOVER_ctx_t;
  coverParams:ZDICT_cover_params_t;
  accelParams:FASTCOVER_accel_t;
  initVal,tail,dictionarySize:int32;
  segmentFreqs:pword;
  nbFinalizeSamples:uint32;
begin
    dict := dictBuffer;
    { Initialize global data }
    //g_displayLevel := parameters.zParams.notificationLevel;
    { Assign splitPoint and f if not provided }
    parameters.splitPoint := 1.0;
    if parameters.f = 0 then
      parameters.f := DEFAULT_F
    else
      parameters.f := parameters.f;
    if parameters.accel = 0 then
      parameters.accel := DEFAULT_ACCEL
    else
      parameters.accel := parameters.accel;
    { Convert to cover parameter }
    fillbyte( coverParams, sizeof(coverParams), 0 );
    FASTCOVER_convertToCoverParams(parameters,  @coverParams);
    { Checks }
    if (FASTCOVER_checkParameters(coverParams, dictBufferCapacity, parameters.f,
                                   parameters.accel)=0) then
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
    { Assign corresponding FASTCOVER_accel_t to accelParams}
    accelParams := FASTCOVER_defaultAccelParameters[parameters.accel];
    { Initialize context }

    initVal := FASTCOVER_ctx_init( @ctx, samplesBuffer, samplesSizes, nbSamples,
                            coverParams.d, parameters.splitPoint, parameters.f,
                            accelParams);
    if (ZSTD_isError(initVal)<>0) then
    begin
      exit(initVal);
    end;
    //COVER_warnOnSmallCorpus(dictBufferCapacity, ctx.nbDmers, g_displayLevel);
    { Build the dictionary }

    { Initialize array to keep track of frequency of dmer within activeSegment }
    segmentFreqs := allocmem((Uint64(1)  shl  parameters.f)*sizeof(word));
    tail := FASTCOVER_buildDictionary(@ctx, ctx.freqs, dictBuffer,dictBufferCapacity, coverParams, segmentFreqs);
    nbFinalizeSamples := uint32(ctx.nbTrainSamples * ctx.accelParams.finalize div 100);
    dictionarySize := ZDICT_finalizeDictionary(dict, dictBufferCapacity, dict + tail, dictBufferCapacity - tail,samplesBuffer, samplesSizes, nbFinalizeSamples, coverParams.zParams);
    if (ZSTD_isError(dictionarySize)=0) then
    begin
        //DISPLAYLEVEL(2, "Constructed dictionary of size %u\n",(unsigned)dictionarySize);
    end;
    FASTCOVER_ctx_destroy(@ctx);
    freemem(segmentFreqs);
    exit(dictionarySize);

end;


function ZDICT_optimizeTrainFromBuffer_fastCover(
                    dictBuffer:pbyte; dictBufferCapacity:int32;
                    samplesBuffer:pbyte;
                    samplesSizes:pint32; nbSamples:uint32;
                    parameters:pZDICT_fastCover_params_t):int32;
var
  coverParams:ZDICT_cover_params_t;
  accelParams:FASTCOVER_accel_t;
  nbThreads,kMinD,kMaxD,kMinK,kMaxK,kSteps,kStepSize,kIterations:uint32;
  f,accel,shrinkDict,iteration,d,k:uint32;
  splitPoint:double;
  displayLevel,warned,initVal,dictSize,compressedSize:int32;
  best:COVER_best_t ;
  //pool:pPOOL_ctx;
  data:pFASTCOVER_tryParameters_data_t;
  ctx:FASTCOVER_ctx_t;
begin
    { constants }
    nbThreads := parameters^.nbThreads;
    if parameters^.splitPoint <= 0.0 then
      splitPoint := FASTCOVER_DEFAULT_SPLITPOINT
    else
      splitPoint := parameters^.splitPoint;
    if parameters^.d = 0 then
    begin
      kMinD := 6;
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
    if parameters^.f = 0 then
      f := DEFAULT_F
    else
      f := parameters^.f;
    if parameters^.accel = 0 then
      accel := DEFAULT_ACCEL
    else
      accel := parameters^.accel;
    shrinkDict := 0;
    { Local variables }
    displayLevel := parameters^.zParams.notificationLevel;
    iteration := 1;
    
    //pool := nil;
    warned := 0;
    { Checks }
    if (splitPoint <= 0)  or  (splitPoint > 1) then
    begin
      exit(ERROR(parameter_outOfBound));
    end;
    if (accel = 0)  or  (accel > FASTCOVER_MAX_ACCEL) then
    begin
      exit(ERROR(parameter_outOfBound));
    end;
    if (kMinK < kMaxD)  or  (kMaxK < kMinK) then
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
    COVER_best_init( @best);
    fillbyte( coverParams , sizeof(coverParams), 0);
    FASTCOVER_convertToCoverParams( parameters^,  @coverParams);
    accelParams := FASTCOVER_defaultAccelParameters[accel];
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
      
      initVal := FASTCOVER_ctx_init( @ctx, samplesBuffer, samplesSizes, nbSamples, d, splitPoint, f, accelParams);
      if (ZSTD_isError(initVal)<>0) then
      begin
        COVER_best_destroy(@best);
        //POOL_freemem(pool);
        exit(initVal);
      end;
      if (warned=0) then
      begin
        COVER_warnOnSmallCorpus(dictBufferCapacity, ctx.nbDmers, displayLevel);
        warned := 1;
      end;
      { Loop through k reusing the same context }
      k := kMinK;
      while (k <= kMaxK) do 
      begin
        { Prepare the arguments }
        data := allocmem(sizeof(FASTCOVER_tryParameters_data_t));
        if (data=nil) then
        begin
          COVER_best_destroy( @best);
          FASTCOVER_ctx_destroy( @ctx);
          //POOL_freemem(pool);
          exit(ERROR(memory_allocation));
        end;
        data^.ctx :=  @ctx;
        data^.best :=  @best;
        data^.dictBufferCapacity := dictBufferCapacity;
        data^.parameters := coverParams;
        data^.parameters.k := k;
        data^.parameters.d := d;
        data^.parameters.splitPoint := splitPoint;
        data^.parameters.steps := kSteps;
        data^.parameters.shrinkDict := shrinkDict;
        //data^.parameters.zParams.notificationLevel := g_displayLevel;
        { Check the parameters }
        if (FASTCOVER_checkParameters(data^.parameters, dictBufferCapacity,
                                       data^.ctx^.f, accel)=0) then
        begin
          freemem(data);
          continue;
        end;
        { Call the function and pass ownership of data to it }
        COVER_best_start( @best);
        //if (pool<>nil) then
        //begin
        //  POOL_add(pool,  @FASTCOVER_tryParameters, data);
        //end 
        //else 
        //begin
          FASTCOVER_tryParameters(pbyte(data));
        //end;
        { Print status }
        inc(iteration);
        k :=k + kStepSize;
      end;
      COVER_best_wait( @best);
      FASTCOVER_ctx_destroy( @ctx);
      d :=d + 2;
    end;
    { Fill the output buffer and parameters with output of the best parameters }

    dictSize := best.dictSize;
    if (ZSTD_isError(best.compressedSize)<>0) then
    begin
      compressedSize := best.compressedSize;
      COVER_best_destroy(@best);
      //POOL_freemem(pool);
      exit(compressedSize);
    end;
    FASTCOVER_convertToFastCoverParams(best.parameters, parameters, f, accel);
    move( best.dict^, dictBuffer^,dictSize);
    COVER_best_destroy(@best);
    //POOL_freemem(pool);
    exit(dictSize);

end;
end.
