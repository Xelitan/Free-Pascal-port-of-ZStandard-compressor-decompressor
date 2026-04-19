unit zstd;
{$mode objfpc}{$H+}
interface
uses fse;
const
  ZSTD_MAGICNUMBER            =$FD2FB528;    { valid since v0.8.0 }
  ZSTD_MAGIC_DICTIONARY       =$EC30A437;    { valid since v0.7.0 }
  ZSTD_MAGIC_SKIPPABLE_START  =$184D2A50;    { all 16 values, from 0x184D2A50 to 0x184D2A5F, signal the beginning of a skippable frame }
  ZSTD_MAGIC_SKIPPABLE_MASK   =$FFFFFFF0;

  ZSTD_BLOCKSIZELOG_MAX  :int32 =17;

   ZSTD_BLOCKSIZE_MAX =131072; //(1 shl ZSTD_BLOCKSIZELOG_MAX);}
   ZSTD_VERSION_MAJOR    = 1;
   ZSTD_VERSION_MINOR    = 4;
   ZSTD_VERSION_RELEASE  = 8;
   //{$DEFINE ZSTD_VERSION_NUMBER := (ZSTD_VERSION_MAJOR *100*100 + ZSTD_VERSION_MINOR *100 + ZSTD_VERSION_RELEASE)}
   ZSTD_CLEVEL_DEFAULT= 3;
{ All magic numbers are supposed read/written to/from files/memory using little-endian convention }
  ZSTD_CONTENTSIZE_UNKNOWN :Uint64=Uint64($FFFFFFFFFFFFFFFF);   { (0ULL - 1) }
  ZSTD_CONTENTSIZE_ERROR   :Uint64=Uint64($FFFFFFFFFFFFFFFE);   { (0ULL - 2) }
{
 * The following symbols and constants
 * are not planned to join "stable API" status in the near future.
 * They can still change in future versions.
 * Some of them are planned to remain in the static_only section indefinitely.
 * Some of them might be removed in the future (especially when redundant with existing stable functions)
 * **************************************************************************************}

  ZSTD_FRAMEHEADERSIZE_MAX  = 18   { can be useful for static allocation };
  ZSTD_SKIPPABLEHEADERSIZE  =  8;

{ compression parameter bounds }
  ZSTD_WINDOWLOG_MAX_32 =   30;
  ZSTD_WINDOWLOG_MAX_64 =   31;
  {$ifdef CPU32}
  ZSTD_WINDOWLOG_MAX   =ZSTD_WINDOWLOG_MAX_32;
  ZSTD_CHAINLOG_MAX    =ZSTD_WINDOWLOG_MAX_32;
  {$endif}
  {$ifdef CPU64}
  ZSTD_WINDOWLOG_MAX   = ZSTD_WINDOWLOG_MAX_64;
  ZSTD_CHAINLOG_MAX    = ZSTD_WINDOWLOG_MAX_64;
  {$endif}
  ZSTD_WINDOWLOG_MIN    =   10;
  ZSTD_HASHLOG_MAX      =  30;
  ZSTD_HASHLOG_MIN      =    6;
  ZSTD_CHAINLOG_MAX_32  =   29;
  ZSTD_CHAINLOG_MAX_64  =   30;
  ZSTD_CHAINLOG_MIN     =   ZSTD_HASHLOG_MIN;
  ZSTD_SEARCHLOG_MAX    =  (ZSTD_WINDOWLOG_MAX-1);
  ZSTD_SEARCHLOG_MIN    =    1;
  ZSTD_MINMATCH_MAX     =    7   { only for ZSTD_fast, other strategies are limited to 6 };
  ZSTD_MINMATCH_MIN     =    3   { only for ZSTD_btopt+, faster strategies are limited to 4 };
  ZSTD_TARGETLENGTH_MAX =   ZSTD_BLOCKSIZE_MAX;
  ZSTD_TARGETLENGTH_MIN =    0   { note : comparing this constant to an uint32 results in a tautological test };
  ZSTD_STRATEGY_MIN        :int32=1;//ZSTD_fast;
  ZSTD_STRATEGY_MAX        :int32=9;//ZS
  ZSTD_OVERLAPLOG_MIN   =    0;
  ZSTD_OVERLAPLOG_MAX   =    9;
  ZSTD_WINDOWLOG_LIMIT_DEFAULT = 27 ;  { by default, the streaming decoder will refuse any frame
                                           * requiring larger than (1<<ZSTD_WINDOWLOG_LIMIT_DEFAULT) window size,
                                           * to preserve host's memory from unreasonable requirements.
                                           * This limit can be overridden using ZSTD_DCtx_setParameter(,ZSTD_d_windowLogMax,).
                                           * The limit does not apply for one-pass decoders (such as ZSTD_decompress()), since no additional memory is allocated }


{ LDM parameter bounds }
  ZSTD_LDM_HASHLOG_MIN      =ZSTD_HASHLOG_MIN;
  ZSTD_LDM_HASHLOG_MAX      =ZSTD_HASHLOG_MAX;
  ZSTD_LDM_MINMATCH_MIN     =   4;
  ZSTD_LDM_MINMATCH_MAX     =4096;
  ZSTD_LDM_BUCKETSIZELOG_MIN=   1;
  ZSTD_LDM_BUCKETSIZELOG_MAX=   8;
  ZSTD_LDM_HASHRATELOG_MIN  =   0;
  ZSTD_LDM_HASHRATELOG_MAX  = (ZSTD_WINDOWLOG_MAX - ZSTD_HASHLOG_MIN);

{ Advanced parameter bounds }
  ZSTD_TARGETCBLOCKSIZE_MIN   =64;
  ZSTD_TARGETCBLOCKSIZE_MAX   =ZSTD_BLOCKSIZE_MAX;
  ZSTD_SRCSIZEHINT_MIN        =0;
  ZSTD_SRCSIZEHINT_MAX        =MAXINT ;

{ internal }
  ZSTD_HASHLOG3_MAX           =17;
type
{ Compression strategies, listed from fastest to strongest }
ZSTD_strategy = (ZSTD_fast=1,
               ZSTD_dfast=2,
               ZSTD_greedy=3,
               ZSTD_lazy=4,
               ZSTD_lazy2=5,
               ZSTD_btlazy2=6,
               ZSTD_btopt=7,
               ZSTD_btultra=8,
               ZSTD_btultra2=9
               { note : new strategies _might_ be added in the future.
                         Only the order (from fast to strong) is guaranteed }
);


ZSTD_cParameter=(

    { compression parameters
     * Note: When compressing with a ZSTD_CDict these parameters are superseded
     * by the parameters used to construct the ZSTD_CDict.
     * See ZSTD_CCtx_refCDict() for more info (superseded-by-cdict). }
    ZSTD_c_compressionLevel=100, { Set compression parameters according to pre-defined cLevel table.
                              * Note that exact compression parameters are dynamically determined,
                              * depending on both compression level and srcSize (when known).
                              * Default level is ZSTD_CLEVEL_DEFAULT==3.
                              * Special: value 0 means default, which is controlled by ZSTD_CLEVEL_DEFAULT.
                              * Note 1 : it's possible to pass a negative compression level.
                              * Note 2 : setting a level does not automatically set all other compression parameters
                              *   to default. Setting this will however eventually dynamically impact the compression
                              *   parameters which have not been manually set. The manually set
                              *   ones will 'stick'. }
    { Advanced compression parameters :
     * It's possible to pin down compression parameters to some specific values.
     * In which case, these values are no longer dynamically selected by the compressor }
    ZSTD_c_windowLog=101,    { Maximum allowed back-reference distance, expressed as power of 2.
                              * This will set a memory budget for streaming decompression,
                              * with larger values requiring more memory
                              * and typically compressing more.
                              * Must be clamped between ZSTD_WINDOWLOG_MIN and ZSTD_WINDOWLOG_MAX.
                              * Special: value 0 means "use default windowLog".
                              * Note: Using a windowLog greater than ZSTD_WINDOWLOG_LIMIT_DEFAULT
                              *       requires explicitly allowing such size at streaming decompression stage. }
    ZSTD_c_hashLog=102,      { Size of the initial probe table, as a power of 2.
                              * Resulting memory usage is (1 << (hashLog+2)).
                              * Must be clamped between ZSTD_HASHLOG_MIN and ZSTD_HASHLOG_MAX.
                              * Larger tables improve compression ratio of strategies <= dFast,
                              * and improve speed of strategies > dFast.
                              * Special: value 0 means "use default hashLog". }
    ZSTD_c_chainLog=103,     { Size of the multi-probe search table, as a power of 2.
                              * Resulting memory usage is (1 << (chainLog+2)).
                              * Must be clamped between ZSTD_CHAINLOG_MIN and ZSTD_CHAINLOG_MAX.
                              * Larger tables result in better and slower compression.
                              * This parameter is useless for "fast" strategy.
                              * It's still useful when using "dfast" strategy,
                              * in which case it defines a secondary probe table.
                              * Special: value 0 means "use default chainLog". }
    ZSTD_c_searchLog=104,    { Number of search attempts, as a power of 2.
                              * More attempts result in better and slower compression.
                              * This parameter is useless for "fast" and "dFast" strategies.
                              * Special: value 0 means "use default searchLog". }
    ZSTD_c_minMatch=105,     { Minimum size of searched matches.
                              * Note that Zstandard can still find matches of smaller size,
                              * it just tweaks its search algorithm to look for this size and larger.
                              * Larger values increase compression and decompression speed, but decrease ratio.
                              * Must be clamped between ZSTD_MINMATCH_MIN and ZSTD_MINMATCH_MAX.
                              * Note that currently, for all strategies < btopt, effective minimum is 4.
                              *                    , for all strategies > fast, effective maximum is 6.
                              * Special: value 0 means "use default minMatchLength". }
    ZSTD_c_targetLength=106, { Impact of this field depends on strategy.
                              * For strategies btopt, btultra & btultra2:
                              *     Length of Match considered "good enough" to stop search.
                              *     Larger values make compression stronger, and slower.
                              * For strategy fast:
                              *     Distance between match sampling.
                              *     Larger values make compression faster, and weaker.
                              * Special: value 0 means "use default targetLength". }
    ZSTD_c_strategy=107,     { See ZSTD_strategy enum definition.
                              * The higher the value of selected strategy, the more complex it is,
                              * resulting in stronger and slower compression.
                              * Special: value 0 means "use default strategy". }

    { LDM mode parameters }
    ZSTD_c_enableLongDistanceMatching=160, { Enable long distance matching.
                                     * This parameter is designed to improve compression ratio
                                     * for large inputs, by finding large matches at long distance.
                                     * It increases memory usage and window size.
                                     * Note: enabling this parameter increases default ZSTD_c_windowLog to 128 MB
                                     * except when expressly set to a different value.
                                     * Note: will be enabled by default if ZSTD_c_windowLog >= 128 MB and
                                     * compression strategy >= ZSTD_btopt (== compression level 16+) }
    ZSTD_c_ldmHashLog=161,   { Size of the table for long distance matching, as a power of 2.
                              * Larger values increase memory usage and compression ratio,
                              * but decrease compression speed.
                              * Must be clamped between ZSTD_HASHLOG_MIN and ZSTD_HASHLOG_MAX
                              * default: windowlog - 7.
                              * Special: value 0 means "automatically determine hashlog". }
    ZSTD_c_ldmMinMatch=162,  { Minimum match size for long distance matcher.
                              * Larger/too small values usually decrease compression ratio.
                              * Must be clamped between ZSTD_LDM_MINMATCH_MIN and ZSTD_LDM_MINMATCH_MAX.
                              * Special: value 0 means "use default value" (default: 64). }
    ZSTD_c_ldmBucketSizeLog=163, { Log size of each bucket in the LDM hash table for collision resolution.
                              * Larger values improve collision resolution but decrease compression speed.
                              * The maximum value is ZSTD_LDM_BUCKETSIZELOG_MAX.
                              * Special: value 0 means "use default value" (default: 3). }
    ZSTD_c_ldmHashRateLog=164, { Frequency of inserting/looking up entries into the LDM hash table.
                              * Must be clamped between 0 and (ZSTD_WINDOWLOG_MAX - ZSTD_HASHLOG_MIN).
                              * Default is MAX(0, (windowLog - ldmHashLog)), optimizing hash table usage.
                              * Larger values improve compression speed.
                              * Deviating far from default value will likely result in a compression ratio decrease.
                              * Special: value 0 means "automatically determine hashRateLog". }

    { frame parameters }
    ZSTD_c_contentSizeFlag=200, { Content size will be written into frame header _whenever known_ (default:1)
                              * Content size must be known at the beginning of compression.
                              * This is automatically the case when using ZSTD_compress2(),
                              * For streaming scenarios, content size must be provided with ZSTD_CCtx_setPledgedSrcSize() }
    ZSTD_c_checksumFlag=201, { A 32-bits checksum of content is written at end of frame (default:0) }
    ZSTD_c_dictIDFlag=202,   { When applicable, dictionary's ID is written into frame header (default:1) }

    { multi-threading parameters }
    { These parameters are only active if multi-threading is enabled (compiled with build macro ZSTD_MULTITHREAD).
     * Otherwise, trying to set any other value than default (0) will be a no-op and return an error.
     * In a situation where it's unknown if the linked library supports multi-threading or not,
     * setting ZSTD_c_nbWorkers to any value >= 1 and consulting the return value provides a quick way to check this property.
     }
    ZSTD_c_nbWorkers=400,    { Select how many threads will be spawned to compress in parallel.
                              * When nbWorkers >= 1, triggers asynchronous mode when invoking ZSTD_compressStream*() :
                              * ZSTD_compressStream*() consumes input and flush output if possible, but immediately gives back control to caller,
                              * while compression is performed in parallel, within worker thread(s).
                              * (note : a strong exception to this rule is when first invocation of ZSTD_compressStream2() sets ZSTD_e_end :
                              *  in which case, ZSTD_compressStream2() delegates to ZSTD_compress2(), which is always a blocking call).
                              * More workers improve speed, but also increase memory usage.
                              * Default value is `0`, aka "single-threaded mode" : no worker is spawned,
                              * compression is performed inside Caller's thread, and all invocations are blocking }
    ZSTD_c_jobSize=401,      { Size of a compression job. This value is enforced only when nbWorkers >= 1.
                              * Each compression job is completed in parallel, so this value can indirectly impact the nb of active threads.
                              * 0 means default, which is dynamically determined based on compression parameters.
                              * Job size must be a minimum of overlap size, or 1 MB, whichever is largest.
                              * The minimum size is automatically and transparently enforced. }
    ZSTD_c_overlapLog=402,   { Control the overlap size, as a fraction of window size.
                              * The overlap size is an amount of data reloaded from previous job at the beginning of a new job.
                              * It helps preserve compression ratio, while each job is compressed in parallel.
                              * This value is enforced only when nbWorkers >= 1.
                              * Larger values increase compression ratio, but decrease speed.
                              * Possible values range from 0 to 9 :
                              * - 0 means "default" : value will be determined by the library, depending on strategy
                              * - 1 means "no overlap"
                              * - 9 means "full overlap", using a full window size.
                              * Each intermediate rank increases/decreases load size by a factor 2 :
                              * 9: full window;  8: w/2;  7: w/4;  6: w/8;  5:w/16;  4: w/32;  3:w/64;  2:w/128;  1:no overlap;  0:default
                              * default value varies between 6 and 9, depending on strategy }

    { note : additional experimental parameters are also available
     * within the experimental section of the API.
     * At the time of this writing, they include :
     * ZSTD_c_rsyncable
     * ZSTD_c_format
     * ZSTD_c_forceMaxWindow
     * ZSTD_c_forceAttachDict
     * ZSTD_c_literalCompressionMode
     * ZSTD_c_targetCBlockSize
     * ZSTD_c_srcSizeHint
     * ZSTD_c_enableDedicatedDictSearch
     * ZSTD_c_stableInBuffer
     * ZSTD_c_stableOutBuffer
     * ZSTD_c_blockDelimiters
     * ZSTD_c_validateSequences
     * Because they are not stable, it's necessary to define ZSTD_STATIC_LINKING_ONLY to access them.
     * note : never ever use experimentalParam? names directly;
     *        also, the enums values themselves are unstable and can still change.
     }
     ZSTD_c_experimentalParam1=500,
     ZSTD_c_experimentalParam2=10,
     ZSTD_c_experimentalParam3=1000,
     ZSTD_c_experimentalParam4=1001,
     ZSTD_c_experimentalParam5=1002,
     ZSTD_c_experimentalParam6=1003,
     ZSTD_c_experimentalParam7=1004,
     ZSTD_c_experimentalParam8=1005,
     ZSTD_c_experimentalParam9=1006,
     ZSTD_c_experimentalParam10=1007,
     ZSTD_c_experimentalParam11=1008,
     ZSTD_c_experimentalParam12=1009
);

ZSTD_bounds= record
    error:int32;
    lowerBound:int32;
    upperBound:int32 ;
end;
ZSTD_ResetDirective=(
    ZSTD_reset_session_only = 1,
    ZSTD_reset_parameters = 2,
    ZSTD_reset_session_and_parameters = 3
);
{ The advanced API pushes parameters one by one into an existing DCtx context.
 * Parameters are sticky, and remain valid for all following frames
 * using the same DCtx context.
 * It's possible to reset parameters to default values using ZSTD_DCtx_reset().
 * Note : This API is compatible with existing ZSTD_decompressDCtx() and ZSTD_decompressStream().
 *        Therefore, no new decompression function is necessary.
 }

ZSTD_dParameter=(

    ZSTD_d_windowLogMax=100, { Select a size limit (in power of 2) beyond which
                              * the streaming API will refuse to allocate memory buffer
                              * in order to protect the host from unreasonable memory requirements.
                              * This parameter is only useful in streaming mode, since no internal buffer is allocated in single-pass mode.
                              * By default, a decompression context accepts window sizes <= (1 << ZSTD_WINDOWLOG_LIMIT_DEFAULT).
                              * Special: value 0 means "use default maximum windowLog". }

    { note : additional experimental parameters are also available
     * within the experimental section of the API.
     * At the time of this writing, they include :
     * ZSTD_d_format
     * ZSTD_d_stableOutBuffer
     * ZSTD_d_forceIgnoreChecksum
     * Because they are not stable, it's necessary to define ZSTD_STATIC_LINKING_ONLY to access them.
     * note : never ever use experimentalParam? names directly
     }
     ZSTD_d_experimentalParam1=1000,
     ZSTD_d_experimentalParam2=1001,
     ZSTD_d_experimentalParam3=1002

);


ZSTD_inBuffer=record
  src:pbyte;    {*< start of input buffer }
  size:int32 ;        {*< size of input buffer }
  pos:int32 ;         {*< position where reading stopped. Will be updated. Necessarily 0 <= pos <= size }
end; 

ZSTD_outBuffer=record
  dst:pbyte;         {*< start of output buffer }
  size:int32 ;        {*< size of output buffer }
  pos:int32 ;         {*< position where writing stopped. Will be updated. Necessarily 0 <= pos <= size }
end;

{===== ZSTD_CStream management functions =====}

{===== Streaming compression functions =====}
ZSTD_EndDirective=(
    ZSTD_e_continue=0, { collect more data, encoder decides when to output compressed result, for optimal compression ratio }
    ZSTD_e_flush=1,    { flush any data provided so far,
                        * it creates (at least) one new block, that can be decoded immediately on reception;
                        * frame will continue: any future data can still reference previously compressed data, improving compression.
                        * note : multithreaded compression will block to flush as much output as possible. }
    ZSTD_e_end=2       { flush any remaining data _and_ close current frame.
                        * note that frame is only closed after compressed data is fully flushed (return value == 0).
                        * After that point, any additional data starts a new frame.
                        * note : each frame is independent (does not reference any content from previous frame).
                        : note : multithreaded compression will block to flush as much output as possible. }
);
  //ZSTD_DStream=ZSTD_DCtx ;  {*< DCtx and DStream are now effectively same object (>= v1.3.0) }
                                 { For compatibility with versions <= v1.2.0, prefer differentiating them. }
//ZSTD_CDict=ZSTD_CDict_s ;
//ZSTD_DDict=ZSTD_DDict_s ;


ZSTD_Sequence=record
    offset:uint32;      { The offset of the match. (NOT the same as the offset code)
                               * If offset == 0 and matchLength == 0, this sequence represents the last
                               * literals in the block of litLength size.
                               }

    litLength:uint32;   { Literal length of the sequence. }
    matchLength:uint32; { Match length of the sequence. }

                              { Note: Users of this API may provide a sequence with matchLength == litLength == offset == 0.
                               * In this case, we will treat the sequence as a marker for a block boundary.
                               }

    rep:uint32;         { Represents which repeat offset is represented by the field 'offset'.
                               * Ranges from [0, 3].
                               *
                               * Repeat offsets are essentially previous offsets from previous sequences sorted in
                               * recency order. For more detail, see doc/zstd_compression_format.md
                               *
                               * If rep == 0, then 'offset' does not contain a repeat offset.
                               * If rep > 0:
                               *  If litLength != 0:
                               *      rep == 1 --> offset == repeat_offset_1
                               *      rep == 2 --> offset == repeat_offset_2
                               *      rep == 3 --> offset == repeat_offset_3
                               *  If litLength == 0:
                               *      rep == 1 --> offset == repeat_offset_2
                               *      rep == 2 --> offset == repeat_offset_3
                               *      rep == 3 --> offset == repeat_offset_1 - 1
                               *
                               * Note: This field is optional. ZSTD_generateSequences() will calculate the value of
                               * 'rep', but repeat offsets do not necessarily need to be calculated from an external
                               * sequence provider's perspective. For example, ZSTD_compressSequences() does not
                               * use this 'rep' field at all (as of now).
                               }
end;

ZSTD_compressionParameters=record
    windowLog:uint32;       {*< largest match distance : larger == more compression, more memory needed during decompression }
    chainLog:uint32;        {*< fully searched segment : larger == more compression, slower, more memory (useless for fast) }
    hashLog:uint32;         {*< dispatch table : larger == faster, more memory }
    searchLog:uint32;       {*< nb of searches : larger == more compression, slower }
    minMatch:uint32;        {*< match length searched : larger == faster decompression, sometimes less compression }
    targetLength:uint32;    {*< acceptable match size for optimal parser (only) : larger == more compression, slower }
    strategy:ZSTD_strategy;   {*< see ZSTD_strategy definition above }
end;

ZSTD_frameParameters=record
    contentSizeFlag:int32; {*< 1: content size will be in frame header (when known) }
    checksumFlag:int32;    {*< 1: generate a 32-bits checksum using XXH64 algorithm at end of frame, for error detection }
    noDictIDFlag:int32;    {*< 1: no dictID will be saved into frame header (dictID is only useful for dictionary compression) }
end;

ZSTD_parameters=record
    cParams:ZSTD_compressionParameters;
    fParams:ZSTD_frameParameters;
end;

ZSTD_dictContentType_e=(
    ZSTD_dct_auto = 0,       { dictionary is "full" when starting with ZSTD_MAGIC_DICTIONARY, otherwise it is "rawContent" }
    ZSTD_dct_rawContent = 1, { ensures dictionary is always loaded as rawContent, even if it starts with ZSTD_MAGIC_DICTIONARY }
    ZSTD_dct_fullDict = 2    { refuses to load a dictionary if it does not respect Zstandard's specification, starting with ZSTD_MAGIC_DICTIONARY }
);

ZSTD_dictLoadMethod_e=(
    ZSTD_dlm_byCopy = 0,  {*< Copy dictionary content internally }
    ZSTD_dlm_byRef = 1    {*< Reference dictionary content -- the dictionary buffer must outlive its users. }
);

ZSTD_format_e=(
    ZSTD_f_zstd1 = 0,           { zstd frame format, specified in zstd_compression_format.md (default) }
    ZSTD_f_zstd1_magicless = 1  { Variant of zstd frame format, without initial 4-bytes magic number.
                                 * Useful to save 4 bytes per generated frame.
                                 * Decoder cannot recognise automatically this format, requiring this instruction. }
);

ZSTD_forceIgnoreChecksum_e=(
    { Note: this enum controls ZSTD_d_forceIgnoreChecksum }
    ZSTD_d_validateChecksum = 0,
    ZSTD_d_ignoreChecksum = 1
);

ZSTD_dictAttachPref_e=(
    { Note: this enum and the behavior it controls are effectively internal
     * implementation details of the compressor. They are expected to continue
     * to evolve and should be considered only in the context of extremely
     * advanced performance tuning.
     *
     * Zstd currently supports the use of a CDict in three ways:
     *
     * - The contents of the CDict can be copied into the working context. This
     *   means that the compression can search both the dictionary and input
     *   while operating on a single set of internal tables. This makes
     *   the compression faster per-byte of input. However, the initial copy of
     *   the CDict's tables incurs a fixed cost at the beginning of the
     *   compression. For small compressions (< 8 KB), that copy can dominate
     *   the cost of the compression.
     *
     * - The CDict's tables can be used in-place. In this model, compression is
     *   slower per input byte, because the compressor has to search two sets of
     *   tables. However, this model incurs no start-up cost (as long as the
     *   working context's tables can be reused). For small inputs, this can be
     *   faster than copying the CDict's tables.
     *
     * - The CDict's tables are not used at all, and instead we use the working
     *   context alone to reload the dictionary and use params based on the source
     *   size. See ZSTD_compress_insertDictionary() and ZSTD_compress_usingDict().
     *   This method is effective when the dictionary sizes are very small relative
     *   to the input size, and the input size is fairly large to begin with.
     *
     * Zstd has a simple internal heuristic that selects which strategy to use
     * at the beginning of a compression. However, if experimentation shows that
     * Zstd is making poor choices, it is possible to override that choice with
     * this enum.
     }
    ZSTD_dictDefaultAttach = 0, { Use the default heuristic. }
    ZSTD_dictForceAttach   = 1, { Never copy the dictionary. }
    ZSTD_dictForceCopy     = 2, { Always copy the dictionary. }
    ZSTD_dictForceLoad     = 3  { Always reload the dictionary }
);

ZSTD_literalCompressionMode_e=(
  ZSTD_lcm_auto = 0,          {*< Automatically determine the compression mode based on the compression level.
                               *   Negative compression levels will be uncompressed, and positive compression
                               *   levels will be compressed. }
  ZSTD_lcm_huffman = 1,       {*< Always attempt Huffman compression. Uncompressed literals will still be
                               *   emitted if Huffman compression is not profitable. }
  ZSTD_lcm_uncompressed = 2   {*< Always emit uncompressed literals. }
);
ZSTD_sequenceFormat_e=(
  ZSTD_sf_noBlockDelimiters = 0,         { Representation of ZSTD_Sequence has no block delimiters, sequences only }
  ZSTD_sf_explicitBlockDelimiters = 1    { Representation of ZSTD_Sequence contains explicit block delimiters }
);
ZSTD_frameProgression=record
    ingested:uint64;   { nb input bytes read and buffered }
    consumed:uint64;   { nb input bytes actually compressed }
    produced:uint64;   { nb of compressed bytes generated and buffered }
    flushed:uint64;    { nb of compressed bytes flushed : not provided; can be tracked from caller side }
    currentJobID:uint32;         { MT only : latest started job nb }
    nbActiveWorkers:uint32;      { MT only : nb of workers actively compressing at probe time }
end;
{=====   Buffer-less streaming decompression functions  =====}
ZSTD_frameType_e=( ZSTD_frame, ZSTD_skippableFrame ) ;
ZSTD_frameHeader=record
    frameContentSize:uint64; { if == ZSTD_CONTENTSIZE_UNKNOWN, it means this field is not available. 0 means "empty" }
    windowSize:uint64;       { can be very large, up to <= frameContentSize }
    blockSizeMax:uint32;
    frameType:ZSTD_frameType_e;          { if == ZSTD_skippableFrame, frameContentSize is the size of skippable content }
    headerSize:uint32;
    dictID:uint32;
    checksumFlag:uint32;
end;
  //ZSTD_CCtx_params=ZSTD_CCtx_params_s ;

{! Custom memory allocation :
 *  These prototypes make it possible to pass your own allocation/free functions.
 *  ZSTD_customMem is provided at creation time, using ZSTD_create*_advanced() variants listed below.
 *  All allocation/free operations will be completed using these custom variants instead of regular <stdlib.h> ones.
 }
 ZSTD_allocFunction=function(opaque:pbyte; size:int32):pbyte;
 ZSTD_freeFunction=function(opaque, address:pbyte):pbyte;

  ZSTD_customMem=record
   customAlloc:ZSTD_allocFunction; 
   customFree:ZSTD_freeFunction; 
   opaque:pbyte; 
  end;
  const ZSTD_defaultCMem:ZSTD_customMem = ( customAlloc:nil; customFree:nil; opaque:nil );  {*< this constant defers to stdlib's functions }

{ ! Thread pool :
 * These prototypes make it possible to share a thread pool among multiple compression contexts.
 * This can limit resources for applications with multiple threads where each one uses
 * a threaded compression mode (via ZSTD_c_nbWorkers parameter).
 * ZSTD_createThreadPool creates a new thread pool with a given number of threads.
 * Note that the lifetime of such pool must exist while being used.
 * ZSTD_CCtx_refThreadPool assigns a thread pool to a context (use NULL argument value
 * to use an internal thread pool).
 * ZSTD_freeThreadPool frees a thread pool.
 }
 //ZSTD_threadPool=POOL_ctx_s ;
 { Enables rsyncable mode,
  * which makes compressed files more rsync friendly
  * by adding periodic synchronization points to the compressed data.
  * The target average block size is ZSTD_c_jobSize / 2.
  * It's possible to modify the job size to increase or decrease
  * the granularity of the synchronization point.
  * Once the jobSize is smaller than the window size,
  * it will result in compression ratio degradation.
  * NOTE 1: rsyncable mode only works when multithreading is enabled.
  * NOTE 2: rsyncable performs poorly in combination with long range mode,
  * since it will decrease the effectiveness of synchronization points,
  * though mileage may vary.
  * NOTE 3: Rsyncable mode limits maximum compression speed to ~400 MB/s.
  * If the selected compression level is already running significantly slower,
  * the overall speed won't be significantly impacted.
  }
 ZSTD_c_rsyncable = ZSTD_c_experimentalParam1;

{ Select a compression format.
 * The value must be of type ZSTD_format_e.
 * See ZSTD_format_e enum definition for details }
  ZSTD_c_format = ZSTD_c_experimentalParam2;

{ Force back-reference distances to remain < windowSize,
 * even when referencing into Dictionary content (default:0) }
  ZSTD_c_forceMaxWindow = ZSTD_c_experimentalParam3;

{ Controls whether the contents of a CDict
 * are used in place, or copied into the working context.
 * Accepts values from the ZSTD_dictAttachPref_e enum.
 * See the comments on that enum for an explanation of the feature. }
  ZSTD_c_forceAttachDict =ZSTD_c_experimentalParam4;

{ Controls how the literals are compressed (default is auto).
 * The value must be of type ZSTD_literalCompressionMode_e.
 * See ZSTD_literalCompressionMode_t enum definition for details.
 }
  ZSTD_c_literalCompressionMode= ZSTD_c_experimentalParam5;

{ Tries to fit compressed block size to be around targetCBlockSize.
 * No target when targetCBlockSize == 0.
 * There is no guarantee on compressed block size (default:0) }
  ZSTD_c_targetCBlockSize =ZSTD_c_experimentalParam6;

{ User's best guess of source size.
 * Hint32 is not valid when srcSizeHint32 == 0.
 * There is no guarantee that hint32 is close to actual source size,
 * but compression ratio may regress significantly if guess considerably underestimates }
  ZSTD_c_srcSizeHint = ZSTD_c_experimentalParam7;
  ZSTD_c_enableDedicatedDictSearch =ZSTD_c_experimentalParam8;
  ZSTD_c_stableInBuffer =ZSTD_c_experimentalParam9;
  ZSTD_c_stableOutBuffer =ZSTD_c_experimentalParam10;
  ZSTD_c_blockDelimiters =ZSTD_c_experimentalParam11;
  ZSTD_c_validateSequences =ZSTD_c_experimentalParam12;
  ZSTD_d_format = ZSTD_d_experimentalParam1;
  ZSTD_d_stableOutBuffer =ZSTD_d_experimentalParam2;
  ZSTD_d_forceIgnoreChecksum =ZSTD_d_experimentalParam3;
type
ZSTD_nextInputType_e =( ZSTDnit_frameHeader, ZSTDnit_blockHeader, ZSTDnit_block, ZSTDnit_lastBlock, ZSTDnit_checksum, ZSTDnit_skippableFrame );
pZSTD_inBuffer=^ZSTD_inBuffer;
pZSTD_outBuffer=^ZSTD_outBuffer;

pZSTD_Sequence=^ZSTD_Sequence;
pZSTD_compressionParameters=^ZSTD_compressionParameters;
pZSTD_frameParameters=^ZSTD_frameParameters;
pZSTD_parameters=^ZSTD_parameters;
pZSTD_frameProgression=^ZSTD_frameProgression;
pZSTD_frameHeader=^ZSTD_frameHeader;

ppbyte=^pbyte;

procedure MEM_writeLE16(memPtr:pbyte; value:Uint16);
procedure MEM_writeLE24(memPtr:pbyte; value:Uint32);
procedure MEM_write16(memPtr:pbyte; value:Uint16);
function MEM_read16(p:pbyte):uint16;
function MEM_readLE32(p:pbyte):uint32;
function MEM_read32(p:pbyte):uint32;
function MEM_readLE24(p:pbyte):uint32;
function MEM_readLE16(p:pbyte):uint16;
function MEM_readst(p:pbyte):uint32;
function MEM_read64(p:pbyte):uint64;
procedure MEM_write64(memPtr:pbyte; value:Uint64);
procedure MEM_writeLE64(memPtr:pbyte; value:Uint64);
procedure MEM_write32(memPtr:pbyte; value:Uint32);
procedure MEM_writeLE32(memPtr:pbyte; value:Uint32);
function MEM_readLE64(memPtr:pbyte):Uint64;
function ZSTD_FRAMEHEADERSIZE_MIN(format:ZSTD_format_e):int32; 
function ZSTD_FRAMEHEADERSIZE_PREFIX(format:ZSTD_format_e):int32; 
implementation
function ZSTD_FRAMEHEADERSIZE_PREFIX(format:ZSTD_format_e):int32; 
begin
  if format = ZSTD_f_zstd1 then
   result :=5
  else 
  result :=1;   { minimum input size required to query frame header size }
end;
function ZSTD_FRAMEHEADERSIZE_MIN(format:ZSTD_format_e):int32;    
begin
  if format = ZSTD_f_zstd1 then
   result :=6
  else 
  result :=2;
end;
function MEM_read16(p:pbyte):uint16;
begin
  result := puint16(p)^;
end;
function MEM_readLE16(p:pbyte):uint16;
begin
    {$ifdef ENDIAN_LITTLE}
        result:=MEM_read16(p);
    {$endif}
    {$ifdef ENDIAN_BIG}
        result := uint16(p[0] + (p[1] shl 8));
    {$endif}
end;
procedure MEM_write16(memPtr:pbyte; value:Uint16);
begin
    move(value, memPtr^,sizeof(Uint16));
end;
procedure MEM_writeLE16(memPtr:pbyte; value:Uint16);
begin
    {$ifdef ENDIAN_LITTLE}
        MEM_write16(memPtr,value);
    {$endif}
    {$ifdef ENDIAN_BIG}
        memPtr[0] := Byte(value);
        memPtr[1] := Byte(value shr 8);
    {$endif}
end;
procedure MEM_writeLE24(memPtr:pbyte; value:Uint32);
begin
  MEM_writeLE16(memPtr,value);
  memPtr[2]:=BYTE(value shr 16);
end;
function MEM_readLE32(p:pbyte):uint32;
begin
    {$ifdef ENDIAN_LITTLE}
        result := puint32(p)^;
    {$endif}
    {$ifdef ENDIAN_BIG}
        result := swapendian(puint32(p)^);
    {$endif}
end;
function MEM_readLE24(p:pbyte):uint32;
begin
  result := MEM_readLE16(p) + (Uint32(p[2]) shl 16);
end;
function MEM_readst(p:pbyte):uint32;
begin
  result := MEM_read32(p);
end;
function MEM_read32(p:pbyte):uint32;
begin
  result := puint32(p)^;
end;
function MEM_read64(p:pbyte):uint64;
begin
  result := puint64(p)^;
end;
procedure MEM_write32(memPtr:pbyte; value:Uint32);
begin
    move(value, memPtr^,sizeof(Uint32));
end;
procedure MEM_writeLE32(memPtr:pbyte; value:Uint32);
begin
    {$ifdef ENDIAN_LITTLE}
        MEM_write32(memPtr,value);
    {$endif}
    {$ifdef ENDIAN_BIG}
        MEM_write32(memPtr, swapendian(value));
    {$endif}
end;
procedure MEM_write64(memPtr:pbyte; value:Uint64);
begin
  puint64(memPtr)^ := value;
end;
procedure MEM_writeLE64(memPtr:pbyte; value:Uint64);
begin
    {$ifdef ENDIAN_LITTLE}
        MEM_write64(memPtr,value);
    {$endif}
    {$ifdef ENDIAN_BIG}
        MEM_write64(memPtr, swapendian(value));
    {$endif}
end;
function MEM_readLE64(memPtr:pbyte):Uint64;
begin
    {$ifdef ENDIAN_LITTLE}
        result:=MEM_read64(memPtr);
    {$endif}
    {$ifdef ENDIAN_BIG}
        result:=swapendian(MEM_read64(memPtr));
    {$endif}
end;
end.
