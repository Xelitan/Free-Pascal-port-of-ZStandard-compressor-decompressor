unit huf_decompress;
{$mode objfpc}{$H+}
interface
{ **************************************************************
*  Dependencies
***************************************************************}
uses //zstd_deps,  { ZSTD_memcpy, ZSTD_memset }
     //compiler,
     bitstream,  { BIT_* }
     fse,        { to compress headers }
      huf,
      error_private;


const
   HUF_DECOMPRESS_WORKSPACE_SIZE = (2 shl 10);
   HUF_DECOMPRESS_WORKSPACE_SIZE_Uint32 =(HUF_DECOMPRESS_WORKSPACE_SIZE / sizeof(Uint32)) ;

type

pDTableDesc=^DTableDesc;
pHUF_DEltX1 =^HUF_DEltX1; 
pHUF_ReadDTableX1_Workspace=^HUF_ReadDTableX1_Workspace;
pHUF_DEltX2=^HUF_DEltX2;
psortedSymbol_t=^sortedSymbol_t;
palgo_time_t=^algo_time_t;

decompressionAlgo=function(dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;

{-**************************}
{  generic DTableDesc       }
{-**************************}
DTableDesc=record
 maxTableLog:BYTE; 
 tableType:BYTE; 
 tableLog:BYTE; 
 reserved:BYTE; 
end;
{-**************************}
{  single-symbol decoding   }
{-**************************}
HUF_DEltX1 =packed record
  byte:byte; 
  nbBits:byte; 
end;   { single-symbol decoding; MUST be 2 bytes }
HUF_ReadDTableX1_Workspace=record
        rankVal:array[0..HUF_TABLELOG_ABSOLUTEMAX] of Uint32;
        rankStart:array[0..HUF_TABLELOG_ABSOLUTEMAX] of Uint32;
        statsWksp:array[0..255] of Uint32;   { must be >= FSE_DECOMPRESS_WKSP_SIZE_Uint32(6, FSE_MAX_SYMBOL_VALUE=255) ~213 Uint32 }
        symbols:array[0..HUF_SYMBOLVALUE_MAX] of BYTE;
        huffWeight:array[0..HUF_SYMBOLVALUE_MAX] of BYTE;
end;
HUF_decompress_usingDTable_t=function(dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
{ ************************}
{ double-symbols decoding }
{ ************************}

HUF_DEltX2=record 
  sequence:smallint; 
  nbBits:BYTE; 
  length:BYTE; 
end;  { double-symbols decoding }
sortedSymbol_t=record
  symbol:BYTE; 
  weight:BYTE; 
end;
algo_time_t=record 
  tableTime:Uint32; 
  decode256Time:Uint32; 
end;
{
typedef unsigned char BYTE;
After this type definition, the identifier BYTE can be used as an abbreviation for the type unsigned char, for example..
}
//typedef U32 rankValCol_t[HUF_TABLELOG_MAX + 1];
//typedef rankValCol_t rankVal_t[HUF_TABLELOG_MAX];
  prankValCol_t=^rankValCol_t;
  rankValCol_t = array [0..HUF_TABLELOG_MAX] of Uint32;
  prankVal_t=^rankVal_t;
  rankVal_t = array [0..HUF_TABLELOG_MAX-1] of rankValCol_t;
const
   algoTime:array [0..15 { Quantization },0..2 { single, double, quad }] of algo_time_t =
(
    { single, double, quad }
    ((tableTime:   0;decode256Time:0  ), (tableTime:1   ;decode256Time: 1 ), (tableTime:2   ;decode256Time:2  )),  { Q=0 : impossible }
    ((tableTime:   0;decode256Time:0  ), (tableTime:1   ;decode256Time: 1 ), (tableTime:2   ;decode256Time:2  )),  { Q=1 : impossible }
    ((tableTime:  38;decode256Time:130), (tableTime:1313;decode256Time: 74), (tableTime:2151;decode256Time: 38)),   { Q = 2 : 12-18% }
    ((tableTime: 448;decode256Time:128), (tableTime:1353;decode256Time: 74), (tableTime:2238;decode256Time: 41)),   { Q = 3 : 18-25% }
    ((tableTime: 556;decode256Time:128), (tableTime:1353;decode256Time: 74), (tableTime:2238;decode256Time: 47)),   { Q = 4 : 25-32% }
    ((tableTime: 714;decode256Time:128), (tableTime:1418;decode256Time: 74), (tableTime:2436;decode256Time: 53)),   { Q = 5 : 32-38% }
    ((tableTime: 883;decode256Time:128), (tableTime:1437;decode256Time: 74), (tableTime:2464;decode256Time: 61)),   { Q = 6 : 38-44% }
    ((tableTime: 897;decode256Time:128), (tableTime:1515;decode256Time: 75), (tableTime:2622;decode256Time: 68)),   { Q = 7 : 44-50% }
    ((tableTime: 926;decode256Time:128), (tableTime:1613;decode256Time: 75), (tableTime:2730;decode256Time: 75)),   { Q = 8 : 50-56% }
    ((tableTime: 947;decode256Time:128), (tableTime:1729;decode256Time: 77), (tableTime:3359;decode256Time: 77)),   { Q = 9 : 56-62% }
    ((tableTime:1107;decode256Time:128), (tableTime:2083;decode256Time: 81), (tableTime:4006;decode256Time: 84)),   { Q =10 : 62-69% }
    ((tableTime:1177;decode256Time:128), (tableTime:2379;decode256Time: 87), (tableTime:4785;decode256Time: 88)),   { Q =11 : 69-75% }
    ((tableTime:1242;decode256Time:128), (tableTime:2415;decode256Time: 93), (tableTime:5155;decode256Time: 84)),   { Q =12 : 75-81% }
    ((tableTime:1349;decode256Time:128), (tableTime:2644;decode256Time:106), (tableTime:5260;decode256Time:106)),   { Q =13 : 81-87% }
    ((tableTime:1455;decode256Time:128), (tableTime:2422;decode256Time:124), (tableTime:4174;decode256Time:124)),   { Q =14 : 87-93% }
    ((tableTime: 722;decode256Time:128), (tableTime:1891;decode256Time:145), (tableTime:1936;decode256Time:146))   { Q =15 : 93-99% }
);
function HUF_decompress1X_usingDTable_bmi2(dst:pbyte;maxDstSize:int32; cSrc:pbyte;cSrcSize:int32; const DTable:puint32; bmi2:int32):int32;
function HUF_decompress4X_hufOnly_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32; workSpace:pbyte;wkspSize,bmi2:int32):int32;
function HUF_decompress1X1_DCtx_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32; workSpace:pbyte;wkspSize,bmi2:int32):int32;
function HUF_decompress4X_usingDTable_bmi2(dst:pbyte;maxDstSize:int32; cSrc:pbyte;cSrcSize:int32; const DTable:puint32; bmi2:int32):int32;
function HUF_readDTableX2_wksp(DTable:puint32;const src:pbyte;srcSize:int32;
  workSpace:pbyte;wkspSize:int32):int32;
implementation
uses entropy_common,zstd;
function HUF_getDTableDesc(const table:puint32):DTableDesc;
begin
    move(table^,result,sizeof(uint32))
end;


{*
 * Packs 4 HUF_DEltX1 structs into a Uint64. This is used to lay down 4 entries at
 * a time.
 }
function HUF_DEltX1_set4(symbol,nbBits:BYTE):Uint64;
var
  D4:Uint64;
begin
    {$ifdef ENDIAN_LITTLE}
        D4 := symbol + (nbBits  shl  8);
    {$endif}
    {$ifdef ENDIAN_BIG}
        D4 := (symbol  shl  8) + nbBits;
    {$endif}
    D4 :=D4 * $0001000100010001;
    result := D4;
end;

function HUF_readDTableX1_wksp_bmi2(DTable:puint32;const src:pbyte;srcSize:int32;workSpace:pbyte;wkspSize,bmi2:int32):int32;
var
  tableLog,nbSymbols:Uint32;
  iSize:int32;
  dtPtr:pbyte;
  dt:pHUF_DEltX1;
  wksp:pHUF_ReadDTableX1_Workspace;
  dtd:DTableDesc;
  n,nextRankStart,unroll,nLimit:int32;
  u,w,s:int32;
  D:HUF_DEltX1;
  D4:Uint64;
  symbol,rankStart,symbolCount,length,uStart:int32;
  nbBits:byte;
  curr:uint32;
begin
    tableLog := 0;
    nbSymbols := 0;
    dtPtr := pbyte(DTable + 1);
    dt := pHUF_DEltX1(dtPtr);
    wksp := pHUF_ReadDTableX1_Workspace(workSpace);

    ASSERT(sizeof(HUF_DEltX1) = 2);   { MUST be 2 bytes }
    ASSERT(HUF_DECOMPRESS_WORKSPACE_SIZE >= sizeof(HUF_ReadDTableX1_Workspace));
    if (sizeof(HUF_ReadDTableX1_Workspace) > wkspSize) then
      exit(ERROR(tableLog_tooLarge));

    ASSERT(sizeof(DTableDesc) = sizeof(uint32));
    { ZSTD_memset(huffWeight, 0, sizeof(huffWeight)); }   { is not necessary, even though some analyzer complain ... }

    iSize := HUF_readStats_wksp(wksp^.huffWeight, HUF_SYMBOLVALUE_MAX + 1, wksp^.rankVal,  @nbSymbols,  @tableLog, src, srcSize, @wksp^.statsWksp, sizeof(wksp^.statsWksp), bmi2);
    if (ERR_isError(iSize)<>0) then
      exit(iSize);

    { Table header }
    dtd := HUF_getDTableDesc(DTable);
    if (tableLog > Uint32(dtd.maxTableLog+1)) then
      exit(ERROR(tableLog_tooLarge));   { DTable too small, Huffman tree cannot fit in }
    dtd.tableType := 0;
    dtd.tableLog := tableLog;
    move(dtd, DTable^,sizeof(dtd));
    

    { Compute symbols and rankStart given rankVal:
     *
     * rankVal already contains the number of values of each weight.
     *
     * symbols contains the symbols ordered by weight. First are the rankVal[0]
     * weight 0 symbols, followed by the rankVal[1] weight 1 symbols, and so on.
     * symbols[0] is filled (but unused) to avoid a branch.
     *
     * rankStart contains the offset where each rank belongs in the DTable.
     * rankStart[0] is not filled because there are no entries in the table for
     * weight 0.
     }
        
    nextRankStart := 0;
    unroll := 4;
    nLimit := int32(nbSymbols) - unroll + 1;
    for n:=0 to tableLog do
    begin
        curr := nextRankStart;
        nextRankStart :=nextRankStart + wksp^.rankVal[n];
        wksp^.rankStart[n] := curr;
    end;
    n:=0;
    while n < nLimit do
    begin
        for u:=0 to unroll-1 do 
        begin
            w := wksp^.huffWeight[n+u];
            wksp^.symbols[wksp^.rankStart[w]] := (n+u);
            inc(wksp^.rankStart[w]);
        end;
        n :=n + unroll
    end;
    for n:=n to nbSymbols-1 do 
    begin
        w := wksp^.huffWeight[n];
        wksp^.symbols[wksp^.rankStart[w]] := n;
        inc(wksp^.rankStart[w]);
    end;


    { fill DTable
     * We fill all entries of each weight in order.
     * That way length is a constant for each iteration of the outter loop.
     * We can switch based on the length to a different inner loop which is
     * optimized for that particular case.
     }
    
    symbol:=wksp^.rankVal[0];
    rankStart:=0;
    for w:=1 to tableLog do 
    begin
        symbolCount := wksp^.rankVal[w];
        length := (1  shl  w)  shr  1;
        uStart := rankStart;
        nbBits := (tableLog + 1 - w);
        case (length) of
          1:
            for s:=0 to symbolCount-1 do
            begin
                D.byte := wksp^.symbols[symbol + s];
                D.nbBits := nbBits;
                dt[uStart] := D;
                uStart :=uStart + 1;
            end;
          2:
            for s:=0 to symbolCount-1 do
            begin
                D.byte := wksp^.symbols[symbol + s];
                D.nbBits := nbBits;
                dt[uStart+0] := D;
                dt[uStart+1] := D;
                uStart :=uStart + 2;
            end;
          4:
            for s:=0 to symbolCount-1 do
            begin
                D4 := HUF_DEltX1_set4(wksp^.symbols[symbol + s], nbBits);
                MEM_write64(pbyte(dt + uStart), D4);
                uStart :=uStart + 4;
            end;
          8:
            for s:=0 to symbolCount-1 do
            begin
                D4 := HUF_DEltX1_set4(wksp^.symbols[symbol + s], nbBits);
                MEM_write64(pbyte(dt + uStart), D4);
                MEM_write64(pbyte(dt + uStart + 4), D4);
                uStart :=uStart + 8;
            end;
          else
            for s:=0 to symbolCount-1 do
            begin
                D4 := HUF_DEltX1_set4(wksp^.symbols[symbol + s], nbBits);
                u:=0;
                while (u < length) do
                begin
                    MEM_write64(pbyte(dt + uStart + u + 0), D4);
                    MEM_write64(pbyte(dt + uStart + u + 4), D4);
                    MEM_write64(pbyte(dt + uStart + u + 8), D4);
                    MEM_write64(pbyte(dt + uStart + u + 12), D4);
                    u := u + 16;
                end;
                assert(u = length);
                uStart := uStart + length;
            end;
        end;
        symbol :=symbol + symbolCount;
        rankStart :=rankStart + symbolCount * length;
    end;
    exit(iSize);
end;

function HUF_readDTableX1_wksp(DTable:puint32;const src:pbyte;srcSize:int32;workSpace:pbyte;wkspSize:int32):int32;
begin
    result := HUF_readDTableX1_wksp_bmi2(DTable, src, srcSize, workSpace, wkspSize, { bmi2 } 0);
end;

function HUF_decodeSymbolX1(Dstream:pBIT_DStream_t; dt:pHUF_DEltX1;dtLog:Uint32):BYTE;
var
  val:PtrUInt;
begin
    val := BIT_lookBitsFast(Dstream, dtLog); { note : dtLog >= 1 }
    result := dt[val].byte;
    BIT_skipBits(Dstream, dt[val].nbBits);
end;

function HUF_decodeStreamX1(p:pBYTE; bitDPtr:pBIT_DStream_t; pEnd:pbyte;dt:pHUF_DEltX1; dtLog:Uint32 ):int32;
var
  pStart:pbyte;
begin
    pStart := p;

    { up to 4 symbols at a time }
    while ((BIT_reloadDStream(bitDPtr) = BIT_DStream_unfinished)  and  (p < pEnd-3)) do
    begin
        {$ifdef CPU64}
            p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
            inc(p);
        {$endif}
        {$ifdef CPU64}
          p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
          inc(p);
        {$else}
        if (HUF_TABLELOG_MAX<=12) then
        begin
          p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
          inc(p);
        end;
        {$endif}
        {$ifdef CPU64}
          p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
          inc(p);
        {$endif}
        p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
        inc(p);
    end;

    { [0-3] symbols remaining }
    {$ifdef CPU32}
        while ((BIT_reloadDStream(bitDPtr) = BIT_DStream_unfinished)  and  (p < pEnd)) do
        begin
            p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
            inc(p);
        end;
    {$endif}
    { no more data to retrieve from bitstream, no need to reload }
    while (p < pEnd) do
    begin
        p^ := HUF_decodeSymbolX1(bitDPtr, dt, dtLog);
        inc(p);
    end;

    result := pEnd-pStart;
end;

function HUF_decompress1X1_usingDTable_internal_body(dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  op,oend:pbyte;
  dtPtr:pbyte;
  dt:pHUF_DEltX1;
  bitD:BIT_DStream_t;
  dtd:DTableDesc;
  dtLog:Uint32;
  err:int32;
begin
    op := dst;
    oend := op + dstSize;
    dtPtr := pbyte(DTable + 1);
    dt := pHUF_DEltX1(dtPtr);
    dtd := HUF_getDTableDesc(DTable);
    dtLog := dtd.tableLog;

    err := BIT_initDStream( @bitD, cSrc, cSrcSize) ;
    if (ERR_isError(err)<>0) then
    	exit(err);
    HUF_decodeStreamX1(op,  @bitD, oend, dt, dtLog);

    if (BIT_endOfDStream( @bitD)=0) then
      exit(ERROR(corruption_detected));

    result := dstSize;
end;

function HUF_decompress4X1_usingDTable_internal_body(
  dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  istart,ostart,oend,olimit,dtPtr:pbyte;
  dt:pHUF_DEltX1;
  bitD1,bitD2,bitD3,bitD4:BIT_DStream_t;
  length1,length2,length3,length4,segmentSize:int32;
  istart1,istart2,istart3,istart4:pbyte;
  opStart2,opStart3,opStart4:pbyte;
  op1,op2,op3,op4:pbyte;
  dtd:DTableDesc;
  dtLog,endSignal,endCheck:Uint32;
  err:int32;
begin
    { Check }
    if (cSrcSize < 10) then
      exit(ERROR(corruption_detected));  { strict minimum : jump table + 1 byte per stream }

    istart :=  cSrc;
    ostart := dst;
    oend := ostart + dstSize;
    olimit := oend - 3;
    dtPtr := pbyte(DTable + 1);
    dt := pHUF_DEltX1(dtPtr);

    { Init }

    length1 := MEM_readLE16(istart);
    length2 := MEM_readLE16(istart+2);
    length3 := MEM_readLE16(istart+4);
    length4 := cSrcSize - (length1 + length2 + length3 + 6);
    istart1 := istart + 6;  { jumpTable }
    istart2 := istart1 + length1;
    istart3 := istart2 + length2;
    istart4 := istart3 + length3;
    segmentSize := (dstSize+3) div 4;
    opStart2 := ostart + segmentSize;
    opStart3 := opStart2 + segmentSize;
    opStart4 := opStart3 + segmentSize;
    op1 := ostart;
    op2 := opStart2;
    op3 := opStart3;
    op4 := opStart4;
    dtd := HUF_getDTableDesc(DTable);
    dtLog := dtd.tableLog;
    endSignal := 1;

    if (length4 > cSrcSize) then
      exit(ERROR(corruption_detected));   { overflow }
    err:=BIT_initDStream( @bitD1, istart1, length1);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:=BIT_initDStream( @bitD2, istart2, length2);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:=BIT_initDStream( @bitD3, istart3, length3);
    if (ERR_isError(err)<>0) then
      exit(err);
    err:=BIT_initDStream( @bitD4, istart4, length4);
    if (ERR_isError(err)<>0) then
      exit(err);

    { up to 16 symbols per loop (4 symbols per stream) in 64-bit mode }
    while (endSignal<>0)  and  (op4 < olimit) do
    begin
        {$ifdef CPU64}
            op1^ := HUF_decodeSymbolX1(@bitD1, dt, dtLog);
            inc(op1);
        {$endif}

        {$ifdef CPU64}
            op2^ := HUF_decodeSymbolX1(@bitD2, dt, dtLog);
            inc(op2);
        {$endif}
        {$ifdef CPU64}
            op3^ := HUF_decodeSymbolX1(@bitD3, dt, dtLog);
            inc(op3);
        {$endif}
        {$ifdef CPU64}
            op4^ := HUF_decodeSymbolX1(@bitD4, dt, dtLog);
            inc(op4);
        {$endif}

        {$ifdef CPU64}
          op1^ := HUF_decodeSymbolX1( @bitD1, dt, dtLog);
          inc(op1);
        {$else}
          if (HUF_TABLELOG_MAX<=12) then
          begin
            op1^ := HUF_decodeSymbolX1( @bitD1, dt, dtLog);
            inc(op1);
          end;
        {$endif}
        {$ifdef CPU64}
          op2^ := HUF_decodeSymbolX1( @bitD2, dt, dtLog);
          inc(op2);
        {$else}
          if (HUF_TABLELOG_MAX<=12) then
          begin
            op2^ := HUF_decodeSymbolX1( @bitD2, dt, dtLog);
            inc(op2);
          end;
        {$endif}
        {$ifdef CPU64}
          op3^ := HUF_decodeSymbolX1( @bitD3, dt, dtLog);
          inc(op3);
        {$else}
          if (HUF_TABLELOG_MAX<=12) then
          begin
            op3^ := HUF_decodeSymbolX1( @bitD3, dt, dtLog);
            inc(op3);
          end;
        {$endif}

        {$ifdef CPU64}
          op4^ := HUF_decodeSymbolX1( @bitD4, dt, dtLog);
          inc(op4);
        {$else}
          if (HUF_TABLELOG_MAX<=12) then
          begin
            op4^ := HUF_decodeSymbolX1( @bitD4, dt, dtLog);
            inc(op4);
          end;
        {$endif}
        {$ifdef CPU64}
            op1^ := HUF_decodeSymbolX1(@bitD1, dt, dtLog);
            inc(op1);
        {$endif}
        {$ifdef CPU64}
            op2^ := HUF_decodeSymbolX1(@bitD2, dt, dtLog);
            inc(op2);
        {$endif}
        {$ifdef CPU64}
            op3^ := HUF_decodeSymbolX1(@bitD3, dt, dtLog);
            inc(op3);
        {$endif}
        {$ifdef CPU64}
            op4^ := HUF_decodeSymbolX1(@bitD4, dt, dtLog);
            inc(op4);
        {$endif}
        op1^ := HUF_decodeSymbolX1(@bitD1, dt, dtLog);
        inc(op1); 
        op2^ := HUF_decodeSymbolX1(@bitD2, dt, dtLog);
        inc(op2);
        op3^ := HUF_decodeSymbolX1(@bitD3, dt, dtLog);
        inc(op3);
        op4^ := HUF_decodeSymbolX1(@bitD4, dt, dtLog);
        inc(op4);
        
        endSignal  :=endSignal  and ord(BIT_reloadDStreamFast( @bitD1) = BIT_DStream_unfinished);
        endSignal  :=endSignal  and ord(BIT_reloadDStreamFast( @bitD2) = BIT_DStream_unfinished);
        endSignal  :=endSignal  and ord(BIT_reloadDStreamFast( @bitD3) = BIT_DStream_unfinished);
        endSignal  :=endSignal  and ord(BIT_reloadDStreamFast( @bitD4) = BIT_DStream_unfinished);
    end;

    { check corruption }
    { note : should not be necessary : op# advance in lock step, and we control op4.
     *        but curiously, binary generated by gcc 7.2  and  7.3 with -mbmi2 runs faster when >=1 test is present }
    if (op1 > opStart2) then
      exit(ERROR(corruption_detected));
    if (op2 > opStart3) then
      exit(ERROR(corruption_detected));
    if (op3 > opStart4) then
      exit(ERROR(corruption_detected));
    { note : op4 supposed already verified within main loop }

    { finish bitStreams one by one }
    HUF_decodeStreamX1(op1,  @bitD1, opStart2, dt, dtLog);
    HUF_decodeStreamX1(op2,  @bitD2, opStart3, dt, dtLog);
    HUF_decodeStreamX1(op3,  @bitD3, opStart4, dt, dtLog);
    HUF_decodeStreamX1(op4,  @bitD4, oend,     dt, dtLog);

    { check }

    endCheck := BIT_endOfDStream( @bitD1)  and  BIT_endOfDStream( @bitD2)  and  BIT_endOfDStream( @bitD3)  and  BIT_endOfDStream( @bitD4);
    if (endCheck=0) then
      exit(ERROR(corruption_detected));

    { decoded size }
    result := dstSize;
end;

function HUF_decompress1X1_usingDTable_internal_default(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result := HUF_decompress1X1_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress1X1_usingDTable_internal_bmi2(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result :=  HUF_decompress1X1_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress1X1_usingDTable_internal(
              dst:pbyte;  dstSize:int32;
              cSrc:pbyte; cSrcSize:int32;
              DTable:puint32; bmi2:int32 ):int32;
begin
    if (bmi2<>0) then
    begin
        exit(HUF_decompress1X1_usingDTable_internal_bmi2(dst, dstSize, cSrc, cSrcSize, DTable));
    end;
    result := HUF_decompress1X1_usingDTable_internal_default(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X1_usingDTable_internal_default(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result := HUF_decompress4X1_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X1_usingDTable_internal_bmi2(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result :=  HUF_decompress4X1_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X1_usingDTable_internal(
              dst:pbyte;  dstSize:int32;
              cSrc:pbyte; cSrcSize:int32;
              DTable:puint32; bmi2:int32 ):int32;
begin
    if (bmi2<>0) then
    begin
        exit(HUF_decompress4X1_usingDTable_internal_bmi2(dst, dstSize, cSrc, cSrcSize, DTable));
    end;
    result := HUF_decompress4X1_usingDTable_internal_default(dst, dstSize, cSrc, cSrcSize, DTable);
end;


function HUF_decompress1X1_usingDTable(
          dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;
    DTable:puint32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if (dtd.tableType <> 0) then
      exit(ERROR(GENERIC_ERROR));
    result := HUF_decompress1X1_usingDTable_internal(dst, dstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);
end;

function HUF_decompress1X1_DCtx_wksp(DCtx:puint32; dst:pbyte; dstSize:int32;
  cSrc:pbyte;cSrcSize:int32;workSpace:pbyte;wkspSize:int32):int32;
var
  ip:pbyte;
  hSize:int32;
begin
    ip := cSrc;
    hSize := HUF_readDTableX1_wksp(DCtx, cSrc, cSrcSize, workSpace, wkspSize);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    if (hSize >= cSrcSize) then
      exit(ERROR(srcSize_wrong));
    ip :=ip + hSize; 
    cSrcSize :=cSrcSize - hSize;

    result := HUF_decompress1X1_usingDTable_internal(dst, dstSize, ip, cSrcSize, DCtx, { bmi2 } 0);
end;


function HUF_decompress4X1_usingDTable(
          dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;
    DTable:puint32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if (dtd.tableType <> 0) then
      exit(ERROR(GENERIC_ERROR));
    result := HUF_decompress4X1_usingDTable_internal(dst, dstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);
end;

function HUF_decompress4X1_DCtx_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;
                                   cSrc:pbyte;cSrcSize:int32;
                                   workSpace:pbyte;wkspSize,bmi2:int32):int32;
var
  ip:pbyte;
  hSize:int32;
begin
    ip := cSrc;

    hSize := HUF_readDTableX1_wksp_bmi2(dctx, cSrc, cSrcSize, workSpace, wkspSize, bmi2);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    if (hSize >= cSrcSize) then
      exit(ERROR(srcSize_wrong));
    ip :=ip + hSize; 
    cSrcSize :=cSrcSize - hSize;

    result := HUF_decompress4X1_usingDTable_internal(dst, dstSize, ip, cSrcSize, dctx, bmi2);
end;

function HUF_decompress4X1_DCtx_wksp(dctx:puint32;dst:pbyte;dstSize:int32;
  cSrc:pbyte;cSrcSize:int32;workSpace:pbyte;wkspSize:int32):int32;
begin
    result := HUF_decompress4X1_DCtx_wksp_bmi2(dctx, dst, dstSize, cSrc, cSrcSize, workSpace, wkspSize, 0);
end;

{ HUF_fillDTableX2Level2() :
 * `rankValOrigin` must be a table of at least (HUF_TABLELOG_MAX + 1) Uint32 }
procedure HUF_fillDTableX2Level2(DTable:pHUF_DEltX2; sizeLog,consumed:Uint32;
                           rankValOrigin:pUint32;minWeight:int32;
                           sortedSymbols:psortedSymbol_t;sortedListSize:Uint32;
                           nbBitsBaseline:Uint32;baseSeq:smallint);
var
  DElt:HUF_DEltX2;
  rankVal:array[0..HUF_TABLELOG_MAX] of Uint32;
  i, skipSize,s:Uint32;
  symbol,weight,nbBits,length,start,lend:Uint32;
begin
    { get pre-calculated rankVal }
    move(rankValOrigin^,rankVal[0],  sizeof(rankVal));

    { fill skipped values }
    if (minWeight>1) then
    begin
        skipSize := rankVal[minWeight];
        MEM_writeLE16( @(DElt.sequence), baseSeq);
        DElt.nbBits   := (consumed);
        DElt.length   := 1;
        for i:=0 to skipSize-1 do
            DTable[i] := DElt;
    end;

    { fill DTable }
     
    for s:=0 to sortedListSize-1 do
    begin   { note : sortedSymbols already skipped }
    
            symbol := sortedSymbols[s].symbol;
            weight := sortedSymbols[s].weight;
            nbBits := nbBitsBaseline - weight;
            length := 1  shl  (sizeLog-nbBits);
            start := rankVal[weight];
            i := start;
            lend := start + length;

            MEM_writeLE16( @(DElt.sequence), int16(baseSeq + (symbol  shl  8)));
            DElt.nbBits := (nbBits + consumed);
            DElt.length := 2;
            repeat 
              DTable[i] := DElt;
              inc(i); 
            until (i>=lend);   { since length >= 1 }

            rankVal[weight] :=rankVal[weight] + length;
    end;
end;


procedure HUF_fillDTableX2(DTable:pHUF_DEltX2; targetLog:Uint32;sortedList:psortedSymbol_t; sortedListSize:Uint32;
  rankStart:pUint32; rankValOrigin:rankVal_t; maxWeight,nbBitsBaseline:Uint32);
var
  rankVal:array[0..HUF_TABLELOG_MAX] of Uint32;
  scaleLog:int32;
  minBits,s:Uint32;
  symbol:int16;
  weight,nbBits,start,length,lend,u:Uint32;
  DElt:HUF_DEltX2;
  sortedRank:Uint32;
  minWeight:int32;
begin
    scaleLog := nbBitsBaseline - targetLog;   { note : targetLog >= srcLog, hence scaleLog <= 1 }
    minBits  := nbBitsBaseline - maxWeight;

    move(rankValOrigin[0], rankVal[0],  sizeof(rankVal));

    { fill DTable }
    for s:=0 to sortedListSize-1 do
    begin
        symbol := sortedList[s].symbol;
        weight := sortedList[s].weight;
        nbBits := nbBitsBaseline - weight;
        start := rankVal[weight];
        length := 1  shl  (targetLog-nbBits);

        if (targetLog-nbBits >= minBits) then
        begin   { enough room for a second symbol }

            minWeight := nbBits + scaleLog;
            if (minWeight < 1) then
               minWeight := 1;
            sortedRank := rankStart[minWeight];
            HUF_fillDTableX2Level2(DTable+start, targetLog-nbBits, nbBits,
                           rankValOrigin[nbBits], minWeight,
                           sortedList+sortedRank, sortedListSize-sortedRank,
                           nbBitsBaseline, symbol);
        end
        else 
        begin
            MEM_writeLE16( @(DElt.sequence), symbol);
            DElt.nbBits := (nbBits);
            DElt.length := 1;
            lend := start + length;
            for u := start to lend-1 do 
              DTable[u] := DElt;
        end; 
        rankVal[weight] :=rankVal[weight] + length;
    end;
end;
function HUF_ALIGN(x, mask:int32):int32;
begin
     dec(mask);
     result := ((x + mask) and not mask);
end;
function HUF_readDTableX2_wksp(DTable:puint32;const src:pbyte;srcSize:int32;
  workSpace:pbyte;wkspSize:int32):int32;
var
  tableLog, maxW, sizeOfSort, nbSymbols,maxTableLog:Uint32;
  dtd:DTableDesc;
  iSize:int32;
  dtPtr:pbyte;
  dt:pHUF_DEltX2;
  w,r,s, nextRankStart,curr,nextRankVal:Uint32;
  rankVal:prankValCol_t;
  rankStart,rankStats,rankStart0,rankVal0,rankValPtr:pUint32;
  sortedSymbol:psortedSymbol_t;
  weightList:pbyte;
  spaceUsed32,rescale:int32;
  minBits,consumed:Uint32;
begin
    dtd := HUF_getDTableDesc(DTable);
    maxTableLog := dtd.maxTableLog;
    dtPtr := pbyte(DTable+1);   { force compiler to avoid strict-aliasing }
    dt := pHUF_DEltX2(dtPtr);
    spaceUsed32 := 0;

    rankVal := prankValCol_t(pUint32(workSpace) + spaceUsed32);
    spaceUsed32 :=spaceUsed32 + (sizeof(rankValCol_t) * HUF_TABLELOG_MAX)  shr  2;
    rankStats := pUint32(workSpace) + spaceUsed32;
    spaceUsed32 :=spaceUsed32 + HUF_TABLELOG_MAX + 1;
    rankStart0 := pUint32(workSpace) + spaceUsed32;
    spaceUsed32 :=spaceUsed32 + HUF_TABLELOG_MAX + 2;
    sortedSymbol := psortedSymbol_t(workSpace) + (spaceUsed32 * sizeof(Uint32)) div sizeof(sortedSymbol_t);
    spaceUsed32 :=spaceUsed32 + HUF_ALIGN(sizeof(sortedSymbol_t) * (HUF_SYMBOLVALUE_MAX + 1), sizeof(Uint32))  shr  2;
    weightList := pBYTE(pUint32(workSpace) + spaceUsed32);
    spaceUsed32 :=spaceUsed32 + HUF_ALIGN(HUF_SYMBOLVALUE_MAX + 1, sizeof(Uint32))  shr  2;

    if ((spaceUsed32  shl  2) > wkspSize) then
      exit(ERROR(tableLog_tooLarge));

    rankStart := rankStart0 + 1;
    fillbyte(rankStats^, sizeof(Uint32) * (2 * HUF_TABLELOG_MAX + 2 + 1), 0);

    ASSERT(sizeof(HUF_DEltX2) = sizeof(uint32));   { if compiler fails here, assertion is wrong }
    if (maxTableLog > HUF_TABLELOG_MAX) then
      exit(ERROR(tableLog_tooLarge));
    { ZSTD_memset(weightList, 0, sizeof(weightList)); }  { is not necessary, even though some analyzer complain ... }

    iSize := HUF_readStats(weightList, HUF_SYMBOLVALUE_MAX + 1, rankStats,  @nbSymbols,  @tableLog, src, srcSize);
    if (ERR_isError(iSize)<>0) then
      exit(iSize);

    { check result }
    if (tableLog > maxTableLog) then
      exit(ERROR(tableLog_tooLarge));   { DTable can't fit code depth }

    { find maxWeight }
    maxW := tableLog;
    while (rankStats[maxW]=0) do
    begin
      dec(maxW);
    end;  { necessarily finds a solution before 0 }

    { Get start index of each weight }
     
    nextRankStart := 0;
    for w:=1  to maxW do 
    begin
        curr := nextRankStart;
        nextRankStart :=nextRankStart + rankStats[w];
        rankStart[w] := curr;
    end;
    rankStart[0] := nextRankStart;   { put all 0w symbols at the end of sorted list}
    sizeOfSort := nextRankStart;

    { sort symbols by weight }
    
    for s:=0 to nbSymbols-1 do 
    begin
        w := weightList[s];
        r := rankStart[w];
        inc(rankStart[w]);
        sortedSymbol[r].symbol := s;
        sortedSymbol[r].weight := w;
    end;
    rankStart[0] := 0;   { forget 0w symbols; this is beginning of weight(1) }
    

    { Build rankVal }
    rankVal0 := rankVal[0];
    rescale := (maxTableLog-tableLog) - 1;   { tableLog <= maxTableLog }
    nextRankVal := 0;

    for w:=1 to maxW-1 do 
    begin
        curr := nextRankVal;
        nextRankVal :=nextRankVal + rankStats[w]  shl  (w+rescale);
        rankVal0[w] := curr;
    end; 
    minBits := tableLog+1 - maxW;
    for consumed := minBits to maxTableLog - minBits  do 
    begin
      rankValPtr := rankVal[consumed];
      for w := 1 to maxW do
      begin
        rankValPtr[w] := rankVal0[w]  shr  consumed;
      end;   
    end;

    HUF_fillDTableX2(dt, maxTableLog,
                   sortedSymbol, sizeOfSort,
                   rankStart0, rankVal, maxW,
                   tableLog+1);

    dtd.tableLog := maxTableLog;
    dtd.tableType := 1;
    move(dtd, DTable^,sizeof(dtd));
    exit(iSize);
end;


function HUF_decodeSymbolX2(op:pbyte;Dstream:pBIT_DStream_t;dt:pHUF_DEltX2;dtLog:Uint32):Uint32;
var
  val:int32;
begin
    val := BIT_lookBitsFast(DStream, dtLog);   { note : dtLog >= 1 }
    move( dt[val],op^, 2);
    BIT_skipBits(DStream, dt[val].nbBits);
    result := dt[val].length;
end;

function HUF_decodeLastSymbolX2(op:pbyte;Dstream:pBIT_DStream_t;dt:pHUF_DEltX2;dtLog:Uint32):Uint32;
var
  val:int32;
begin
    val := BIT_lookBitsFast(DStream, dtLog);   { note : dtLog >= 1 }
    move( dt[val],op^, 1);
    if (dt[val].length=1) then
      BIT_skipBits(DStream, dt[val].nbBits)
    else 
    begin
        if (DStream^.bitsConsumed < (sizeof(DStream^.bitContainer)*8)) then
        begin
            BIT_skipBits(DStream, dt[val].nbBits);
            if (DStream^.bitsConsumed > (sizeof(DStream^.bitContainer)*8)) then
                { ugly hack; works only because it's the last symbol. Note : can't easily extract nbBits from just this symbol }
                DStream^.bitsConsumed := (sizeof(DStream^.bitContainer)*8);
        end;
    end;
    exit(1);
end;

function HUF_decodeStreamX2(p:pbyte; bitDPtr:pBIT_DStream_t; pEnd:pbyte;dt:pHUF_DEltX2;dtLog:Uint32):int32;
var
  pStart:pbyte;
begin
    pStart := p;

    { up to 8 symbols at a time }
    while ((BIT_reloadDStream(bitDPtr) = BIT_DStream_unfinished)  and  (p < pEnd-(sizeof(bitDPtr^.bitContainer)-1))) do
    begin
        {$ifdef CPU64}
            p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);
        {$endif}

        {$ifdef CPU64}
          p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);
        {$else}
        if (HUF_TABLELOG_MAX<=12) then
        begin
	     p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);
        end;
        {$endif}

        {$ifdef CPU64}
            p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);
        {$endif}

        p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);
    end;

    { closer to end : up to 2 symbols at a time }
    while ((BIT_reloadDStream(bitDPtr) = BIT_DStream_unfinished)  and  (p <= pEnd-2)) do
        p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);

    while (p <= pEnd-2) do
        p :=p + HUF_decodeSymbolX2(p, bitDPtr, dt, dtLog);   { no need to reload : reached the end of DStream }

    if (p < pEnd) then
        p :=p + HUF_decodeLastSymbolX2(p, bitDPtr, dt, dtLog);

    result := p-pStart;
end;

function HUF_decompress1X2_usingDTable_internal_body(dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  bitD:BIT_DStream_t;
  ostart,oend,dtPtr:pbyte;
  dt:pHUF_DEltX2;
  dtd:DTableDesc;
  err:int32;
begin
    { Init }
    err:=BIT_initDStream( @bitD, cSrc, cSrcSize);
    if (ERR_isError(err)<>0) then
    	exit(err);
    { decode }
    ostart :=  dst;
    oend := ostart + dstSize;
    dtPtr := pbyte(DTable+1);   { force compiler to not use strict-aliasing }
    dt := pHUF_DEltX2(dtPtr);
    dtd := HUF_getDTableDesc(DTable);
    HUF_decodeStreamX2(ostart,  @bitD, oend, dt, dtd.tableLog);
    

    { check }
    if (BIT_endOfDStream( @bitD)=0) then
      exit(ERROR(corruption_detected));

    { decoded size }
    result := dstSize;
end;

function HUF_decompress4X2_usingDTable_internal_body(dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  istart,ostart,oend,olimit,dtPtr:pbyte;
  dt:pHUF_DEltX2;
  bitD1,bitD2,bitD3,bitD4:BIT_DStream_t;
  length1,length2,length3,length4,segmentSize:int32;
  istart1,istart2,istart3,istart4:pbyte;
  opStart2,opStart3,opStart4:pbyte;
  op1,op2,op3,op4:pbyte;
  dtd:DTableDesc;
  dtLog,endSignal,endCheck:Uint32;
  err:int32;
begin
    if (cSrcSize < 10) then
      exit(ERROR(corruption_detected));   { strict minimum : jump table + 1 byte per stream }

    istart := cSrc;
    ostart :=  dst;
    oend := ostart + dstSize;
    olimit := oend - (sizeof(int32)-1);
    dtPtr := pbyte(DTable+1);
    dt := pHUF_DEltX2(dtPtr);

    { Init }

    length1 := MEM_readLE16(istart);
    length2 := MEM_readLE16(istart+2);
    length3 := MEM_readLE16(istart+4);
    length4 := cSrcSize - (length1 + length2 + length3 + 6);
    istart1 := istart + 6;  { jumpTable }
    istart2 := istart1 + length1;
    istart3 := istart2 + length2;
    istart4 := istart3 + length3;
    segmentSize := (dstSize+3) div 4;
    opStart2 := ostart + segmentSize;
    opStart3 := opStart2 + segmentSize;
    opStart4 := opStart3 + segmentSize;
    op1 := ostart;
    op2 := opStart2;
    op3 := opStart3;
    op4 := opStart4;
    endSignal := 1;
    dtd := HUF_getDTableDesc(DTable);
    dtLog := dtd.tableLog;

    if (length4 > cSrcSize) then
      exit(ERROR(corruption_detected));   { overflow }
    err:=BIT_initDStream( @bitD1, istart1, length1);
    if (ERR_isError(err)<>0) then
	    exit(err);
    err:=BIT_initDStream( @bitD2, istart2, length2);
    if (ERR_isError(err)<>0) then
	    exit(err);
    err:=BIT_initDStream( @bitD3, istart3, length3);
    if (ERR_isError(err)<>0) then
	    exit(err);
    err:=BIT_initDStream( @bitD4, istart4, length4);
    if (ERR_isError(err)<>0) then
	    exit(err);

    { 16-32 symbols per loop (4-8 symbols per stream) }
    while ((endSignal<>0)  and  (op4 < olimit) ) do 
    begin

        {$ifdef CPU64}
            op1 :=op1 + HUF_decodeSymbolX2(op1, @bitD1, dt, dtLog);
            op2 :=op2 + HUF_decodeSymbolX2(op2, @bitD2, dt, dtLog);
            op3 :=op3 + HUF_decodeSymbolX2(op3, @bitD3, dt, dtLog);
            op4 :=op4 + HUF_decodeSymbolX2(op4, @bitD4, dt, dtLog);
        {$endif}
        {$ifdef CPU64}
          op1 :=op1 + HUF_decodeSymbolX2(op1, @bitD1, dt, dtLog);
          op2 :=op2 + HUF_decodeSymbolX2(op2, @bitD2, dt, dtLog);
          op3 :=op3 + HUF_decodeSymbolX2(op3, @bitD3, dt, dtLog);
          op4 :=op4 + HUF_decodeSymbolX2(op4, @bitD4, dt, dtLog);
        {$else}
        if (HUF_TABLELOG_MAX<=12) then
        begin
          op1 :=op1 + HUF_decodeSymbolX2(op1, @bitD1, dt, dtLog);
          op2 :=op2 + HUF_decodeSymbolX2(op2, @bitD2, dt, dtLog);
          op3 :=op3 + HUF_decodeSymbolX2(op3, @bitD3, dt, dtLog);
          op4 :=op4 + HUF_decodeSymbolX2(op4, @bitD4, dt, dtLog);
        end;
        {$endif}

        {$ifdef CPU64}
            op1 :=op1 + HUF_decodeSymbolX2(op1, @bitD1, dt, dtLog);
            op2 :=op2 + HUF_decodeSymbolX2(op2, @bitD2, dt, dtLog);
            op3 :=op3 + HUF_decodeSymbolX2(op3, @bitD3, dt, dtLog);
            op4 :=op4 + HUF_decodeSymbolX2(op4, @bitD4, dt, dtLog);
        {$endif}
        op1 :=op1 + HUF_decodeSymbolX2(op1, @bitD1, dt, dtLog);
        op2 :=op2 + HUF_decodeSymbolX2(op2, @bitD2, dt, dtLog);
        op3 :=op3 + HUF_decodeSymbolX2(op3, @bitD3, dt, dtLog);
        op4 :=op4 + HUF_decodeSymbolX2(op4, @bitD4, dt, dtLog);
        endSignal := Uint32(
                    (BIT_reloadDStreamFast( @bitD1) = BIT_DStream_unfinished)
                   and  (BIT_reloadDStreamFast( @bitD2) = BIT_DStream_unfinished)
                   and  (BIT_reloadDStreamFast( @bitD3) = BIT_DStream_unfinished)
                   and  (BIT_reloadDStreamFast( @bitD4) = BIT_DStream_unfinished));
    end;

    { check corruption }
    if (op1 > opStart2) then
      exit(ERROR(corruption_detected));
    if (op2 > opStart3) then
      exit(ERROR(corruption_detected));
    if (op3 > opStart4) then
      exit(ERROR(corruption_detected));
    { note : op4 already verified within main loop }

    { finish bitStreams one by one }
    HUF_decodeStreamX2(op1,  @bitD1, opStart2, dt, dtLog);
    HUF_decodeStreamX2(op2,  @bitD2, opStart3, dt, dtLog);
    HUF_decodeStreamX2(op3,  @bitD3, opStart4, dt, dtLog);
    HUF_decodeStreamX2(op4,  @bitD4, oend,     dt, dtLog);

    { check }
    endCheck := BIT_endOfDStream( @bitD1)  and  BIT_endOfDStream( @bitD2)  and  BIT_endOfDStream( @bitD3)  and  BIT_endOfDStream( @bitD4);
    if (endCheck=0) then
      exit(ERROR(corruption_detected));

    { decoded size }
    result := dstSize;
end;
function HUF_decompress1X2_usingDTable_internal_default(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result := HUF_decompress1X2_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress1X2_usingDTable_internal_bmi2(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result :=  HUF_decompress1X2_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress1X2_usingDTable_internal(
              dst:pbyte;  dstSize:int32;
              cSrc:pbyte; cSrcSize:int32;
              DTable:puint32; bmi2:int32 ):int32;
begin
    if (bmi2<>0) then
    begin
        exit(HUF_decompress1X2_usingDTable_internal_bmi2(dst, dstSize, cSrc, cSrcSize, DTable));
    end;
    result := HUF_decompress1X2_usingDTable_internal_default(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X2_usingDTable_internal_default(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result := HUF_decompress4X2_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X2_usingDTable_internal_bmi2(
              dst:pbyte;  dstSize:int32;
        const cSrc:pbyte; cSrcSize:int32;
        const DTable:puint32):int32;
begin
    result :=  HUF_decompress4X2_usingDTable_internal_body(dst, dstSize, cSrc, cSrcSize, DTable);
end;

function HUF_decompress4X2_usingDTable_internal(
              dst:pbyte;  dstSize:int32;
              cSrc:pbyte; cSrcSize:int32;
              DTable:puint32; bmi2:int32 ):int32;
begin
    if (bmi2<>0) then
    begin
        exit(HUF_decompress4X2_usingDTable_internal_bmi2(dst, dstSize, cSrc, cSrcSize, DTable));
    end;
    result := HUF_decompress4X2_usingDTable_internal_default(dst, dstSize, cSrc, cSrcSize, DTable);
end;
function HUF_decompress1X2_usingDTable(dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  dtd:DTableDesc;
begin
     dtd := HUF_getDTableDesc(DTable);
    if (dtd.tableType <> 1) then
      exit(ERROR(GENERIC_ERROR));
    result := HUF_decompress1X2_usingDTable_internal(dst, dstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);
end;

function HUF_decompress1X2_DCtx_wksp(dctx:puint32;dst:pbyte;dstSize:int32;
  cSrc:pbyte;cSrcSize:int32;workSpace:pbyte;wkspSize:int32):int32;
var
  ip:pbyte;
  hSize:int32;
begin
    ip := cSrc;

    hSize := HUF_readDTableX2_wksp(DCtx, cSrc, cSrcSize, workSpace, wkspSize);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    if (hSize >= cSrcSize) then
      exit(ERROR(srcSize_wrong));
    ip :=ip + hSize; 
    cSrcSize :=cSrcSize - hSize;

    result := HUF_decompress1X2_usingDTable_internal(dst, dstSize, ip, cSrcSize, DCtx, { bmi2 } 0);
end;


function HUF_decompress4X2_usingDTable(dst:pbyte;dstSize:int32;
    cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
   dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if (dtd.tableType <> 1) then
      exit(ERROR(GENERIC_ERROR));
    result := HUF_decompress4X2_usingDTable_internal(dst, dstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);
end;

function HUF_decompress4X2_DCtx_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;
  cSrc:pbyte;cSrcSize:int32;workSpace:pbyte;wkspSize,bmi2:int32):int32;
var
  ip:pbyte;
  hSize:int32;
begin
    ip := cSrc;

    hSize := HUF_readDTableX2_wksp(dctx, cSrc, cSrcSize,
                                         workSpace, wkspSize);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    if (hSize >= cSrcSize) then
      exit(ERROR(srcSize_wrong));
    ip :=ip + hSize; 
    cSrcSize :=cSrcSize - hSize;

    result := HUF_decompress4X2_usingDTable_internal(dst, dstSize, ip, cSrcSize, dctx, bmi2);
end;

function HUF_decompress4X2_DCtx_wksp(dctx:puint32;dst:pbyte;dstSize:int32;
                                   cSrc:pbyte;cSrcSize:int32;
                                   workSpace:pbyte;wkspSize:int32):int32;
begin
    result := HUF_decompress4X2_DCtx_wksp_bmi2(dctx, dst, dstSize, cSrc, cSrcSize, workSpace, wkspSize, { bmi2 } 0);
end;


{ **********************************}
{ Universal decompression selectors }
{ **********************************}

function HUF_decompress1X_usingDTable(dst:pbyte;maxDstSize:int32;
  cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if dtd.tableType<>0 then
      result := HUF_decompress1X2_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, { bmi2 } 0)
    else
      result := HUF_decompress1X1_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);

end;

function HUF_decompress4X_usingDTable(dst:pbyte;maxDstSize:int32;
  cSrc:pbyte;cSrcSize:int32;DTable:puint32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if dtd.tableType<>0 then
      result := HUF_decompress4X2_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, { bmi2 } 0)
    else
      result := HUF_decompress4X1_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, { bmi2 } 0);
end;

{* HUF_selectDecoder() :
 *  Tells which decoder is likely to decode faster,
 *  based on a set of pre-computed metrics.
 * @return : 0=HUF_decompress4X1, 1=HUF_decompress4X2 .
 *  Assumption : 0 < dstSize <= 128 KB }
function HUF_selectDecoder (dstSize,cSrcSize:int32):Uint32;
var
  Q,D256,DTime0,DTime1:Uint32;
begin
    assert(dstSize > 0);
    assert(dstSize <= 128*1024);

    { decoder timing evaluation }
    if (cSrcSize >= dstSize) then
      Q :=   15    { Q < 16 }
    else
      Q :=  Uint32(cSrcSize * 16 div dstSize);   { Q < 16 }
    D256 := Uint32(dstSize  shr  8);
    DTime0 := algoTime[Q][0].tableTime + (algoTime[Q][0].decode256Time * D256);
    DTime1 := algoTime[Q][1].tableTime + (algoTime[Q][1].decode256Time * D256);
    DTime1 :=DTime1 + DTime1  shr  3;  { advantage to algorithm using less memory, to reduce cache eviction }
    result := ord(DTime1 < DTime0);
end;


function HUF_decompress4X_hufOnly_wksp(dctx:puint32;dst:pbyte;
  dstSize:int32;cSrc:pbyte;cSrcSize:int32;workSpace:pbyte;wkspSize:int32 ):int32;
var
  algoNb:Uint32;
begin
    { validation checks }
    if (dstSize = 0) then
      exit(ERROR(dstint32ooSmall));
    if (cSrcSize = 0) then
      exit(ERROR(corruption_detected));

    algoNb := HUF_selectDecoder(dstSize, cSrcSize);
    if algoNb<>0 then
      result :=HUF_decompress4X2_DCtx_wksp(dctx, dst, dstSize, cSrc,cSrcSize, workSpace, wkspSize)
    else
      result :=HUF_decompress4X1_DCtx_wksp(dctx, dst, dstSize, cSrc, cSrcSize, workSpace, wkspSize);

    
end;

function HUF_decompress1X_DCtx_wksp(dctx:puint32;dst:pbyte;dstSize:int32;
                                  cSrc:pbyte;cSrcSize:int32;
                                  workSpace:pbyte;wkspSize:int32):int32;
var
  algoNb:Uint32;
begin
    { validation checks }
    if (dstSize = 0) then
      exit(ERROR(dstint32ooSmall));
    if (cSrcSize > dstSize) then
      exit(ERROR(corruption_detected));   { invalid }
    if (cSrcSize = dstSize) then
    begin 
      move(cSrc^,dst^,  dstSize); 
      exit(dstSize); 
    end;   { not compressed }
    if (cSrcSize = 1) then
    begin 
      fillbyte(dst^, dstSize, cSrc^); 
      exit(dstSize); 
    end;   { RLE }

    algoNb := HUF_selectDecoder(dstSize, cSrcSize);
    if algoNb<>0 then
      result :=HUF_decompress1X2_DCtx_wksp(dctx, dst, dstSize, cSrc,cSrcSize, workSpace, wkspSize)
    else
      result :=HUF_decompress1X1_DCtx_wksp(dctx, dst, dstSize, cSrc,cSrcSize, workSpace, wkspSize);
end;


function HUF_decompress1X_usingDTable_bmi2(dst:pbyte;maxDstSize:int32; cSrc:pbyte;cSrcSize:int32; const DTable:puint32; bmi2:int32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);

    assert(dtd.tableType = 0);
    if dtd.tableType<>0 then
      result := HUF_decompress1X2_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, bmi2)
    else
      result := HUF_decompress1X1_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, bmi2);

end;


function HUF_decompress1X1_DCtx_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32; workSpace:pbyte;wkspSize,bmi2:int32):int32;
var
  ip:pbyte;
  hSize:int32;
begin
    ip := cSrc;
    hSize := HUF_readDTableX1_wksp_bmi2(dctx, cSrc, cSrcSize, workSpace, wkspSize, bmi2);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    if (hSize >= cSrcSize) then
      exit(ERROR(srcSize_wrong));
    ip :=ip + hSize; 
    cSrcSize :=cSrcSize - hSize;

    result := HUF_decompress1X1_usingDTable_internal(dst, dstSize, ip, cSrcSize, dctx, bmi2);
end;


function HUF_decompress4X_usingDTable_bmi2(dst:pbyte;maxDstSize:int32; cSrc:pbyte;cSrcSize:int32; const DTable:puint32; bmi2:int32):int32;
var
  dtd:DTableDesc;
begin
    dtd := HUF_getDTableDesc(DTable);
    if dtd.tableType<>0 then
      result := HUF_decompress4X2_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, bmi2)
    else
      result := HUF_decompress4X1_usingDTable_internal(dst, maxDstSize, cSrc, cSrcSize, DTable, bmi2);                           

end;

function HUF_decompress4X_hufOnly_wksp_bmi2(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32; workSpace:pbyte;wkspSize,bmi2:int32):int32;
var
  algoNb:Uint32;
begin
    { validation checks }
    if (dstSize = 0) then
      exit(ERROR(dstint32ooSmall));
    if (cSrcSize = 0) then
      exit(ERROR(corruption_detected));

    algoNb := HUF_selectDecoder(dstSize, cSrcSize);
    if algoNb<>0 then
        result := HUF_decompress4X2_DCtx_wksp_bmi2(dctx, dst, dstSize, cSrc, cSrcSize, workSpace, wkspSize, bmi2)
    else
        result := HUF_decompress4X1_DCtx_wksp_bmi2(dctx, dst, dstSize, cSrc, cSrcSize, workSpace, wkspSize, bmi2);
end;


function HUF_readDTableX1(DTable:puint32; const src:pbyte;srcSize:int32):int32;
var
  workSpace:array[0..512] of Uint32 ;
begin
    result := HUF_readDTableX1_wksp(DTable, src, srcSize,
                                 @workSpace, sizeof(workSpace));
end;

function HUF_decompress1X1_DCtx(dctx:puint32;dst:pbyte;dstSize:int32;
                              cSrc:pbyte; cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress1X1_DCtx_wksp(DCtx, dst, dstSize, cSrc, cSrcSize,
                                       @workSpace, sizeof(workSpace));
end;

function HUF_decompress1X1 (dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  DTable:array [0..(1 + (1 shl (HUF_TABLELOG_MAX)))-1] of Uint32;
begin
    fillbyte(DTable,sizeof(DTable),$01000001);
    result := HUF_decompress1X1_DCtx (DTable, dst, dstSize, cSrc, cSrcSize);
end;



function HUF_readDTableX2(DTable:puint32; const src:pbyte;srcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
  result := HUF_readDTableX2_wksp(DTable, src, srcSize,
                               @workSpace, sizeof(workSpace));
end;

function HUF_decompress1X2_DCtx(dctx:puint32;dst:pbyte;dstSize:int32;
                              cSrc:pbyte; cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress1X2_DCtx_wksp(DCtx, dst, dstSize, cSrc, cSrcSize,
                                       @workSpace, sizeof(workSpace));
end;

function HUF_decompress1X2 (dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  DTable:array[0..(1 + (1 shl (HUF_TABLELOG_MAX)))] of HUF_DTable;
begin
    fillbyte(DTable,sizeof(DTable),$01000001);
    result := HUF_decompress1X2_DCtx(DTable, dst, dstSize, cSrc, cSrcSize);
end;



function HUF_decompress4X1_DCtx (dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress4X1_DCtx_wksp(dctx, dst, dstSize, cSrc, cSrcSize,
                                       @workSpace, sizeof(workSpace));
end;
function HUF_decompress4X1 (dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  DTable:array [0..((1 + (1 shl (HUF_TABLELOG_MAX)))-1)] of HUF_DTable;
begin
    fillbyte(DTable,sizeof(DTable),$01000001);
    result := HUF_decompress4X1_DCtx(DTable, dst, dstSize, cSrc, cSrcSize);
end;



function HUF_decompress4X2_DCtx(dctx:puint32;dst:pbyte;dstSize:int32;
                              cSrc:pbyte; cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress4X2_DCtx_wksp(dctx, dst, dstSize, cSrc, cSrcSize,
                                       @workSpace, sizeof(workSpace));
end;

function HUF_decompress4X2 (dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  DTable:array [0..(1 + (1 shl (HUF_TABLELOG_MAX)))] of HUF_DTable;
begin
    FillDWord(DTable,sizeof(DTable),HUF_TABLELOG_MAX*$01000001);
    result := HUF_decompress4X2_DCtx(DTable, dst, dstSize, cSrc, cSrcSize);
end;

function HUF_decompress (dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
   decompress:array [0..1] of decompressionAlgo;
   algoNb:uint32;
begin

    decompress[0]:=@HUF_decompress4X1;
    decompress[1]:=@HUF_decompress4X2;
    { validation checks }
    if (dstSize = 0) then
      exit(ERROR(dstint32ooSmall));
    if (cSrcSize > dstSize) then
      exit(ERROR(corruption_detected));   { invalid }
    if (cSrcSize = dstSize) then
    begin 
      move( cSrc^, dst^,dstSize); 
      exit(dstSize); 
    end;   { not compressed }
    if (cSrcSize = 1) then
    begin
      fillbyte(dst^,dstSize,cSrc^);
      exit(dstSize); 
    end;   { RLE }

    algoNb := HUF_selectDecoder(dstSize, cSrcSize);
    result := decompress[algoNb](dst, dstSize, cSrc, cSrcSize);
    
end;

function HUF_decompress4X_DCtx (dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  algoNb:uint32;
begin
    { validation checks }
    if (dstSize = 0) then
      exit(ERROR(dstint32ooSmall));
    if (cSrcSize > dstSize) then
      exit(ERROR(corruption_detected));   { invalid }
    if (cSrcSize = dstSize) then
    begin 
      move(cSrc^,dst^,  dstSize); 
      exit(dstSize); 
    end;   { not compressed }
    if (cSrcSize = 1) then
    begin 
      fillbyte(dst^, dstSize, cSrc^); 
      exit(dstSize); 
    end;   { RLE }

    algoNb := HUF_selectDecoder(dstSize, cSrcSize);
    if algoNb<>0 then
      result := HUF_decompress4X2_DCtx(dctx, dst, dstSize, cSrc, cSrcSize)
    else
      result := HUF_decompress4X1_DCtx(dctx, dst, dstSize, cSrc, cSrcSize) ;
end;

function HUF_decompress4X_hufOnly(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress4X_hufOnly_wksp(dctx, dst, dstSize, cSrc, cSrcSize,
                                         @workSpace, sizeof(workSpace));
end;

function HUF_decompress1X_DCtx(dctx:puint32;dst:pbyte;dstSize:int32;cSrc:pbyte;cSrcSize:int32):int32;
var
  workSpace:array[0..511] of Uint32 ;
begin
    result := HUF_decompress1X_DCtx_wksp(dctx, dst, dstSize, cSrc, cSrcSize,
                                      @workSpace, sizeof(workSpace));
end;

end.
