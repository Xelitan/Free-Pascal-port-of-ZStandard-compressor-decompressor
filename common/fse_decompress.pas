unit fse_decompress;
{$mode objfpc}{$H+}
interface
uses fse,sysutils,error_private,zstd,bitstream,zstd_internal;
  type
    DTable_max_t = array[0..4096 {FSE_DTABLE_SIZE_Uint32(FSE_MAX_TABLELOG)=1 + (1<< ( 12 )}] of FSE_DTable;
{ Function names }
//#define FSE_CAT(X,Y) X##Y
//#define FSE_FUNCTION_NAME(X,Y) FSE_CAT(X,Y)
//#define FSE_TYPE_NAME(X,Y) FSE_CAT(X,Y)
function FSE_createDTable (tableLog:uint32):pFSE_DTable;
procedure FSE_freeDTable(dt:pFSE_DTable);
function FSE_buildDTable_internal(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32; workSpace:pbyte; wkspSize:int32):int32;
function FSE_buildDTable_wksp(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32; workSpace:pbyte; wkspSize:int32):int32;
function FSE_buildDTable_rle(dt:pFSE_DTable; symbolValue:BYTE):int32;
function FSE_buildDTable_raw (dt:pFSE_DTable; nbBits:uint32 ):int32;
function FSE_decompress_usingDTable_generic(dst:pbyte; maxDstSize:int32;cSrc:pbyte; cSrcSize:int32;dt:pFSE_DTable;fast:uint32):int32;
function FSE_decompress_usingDTable(dst:pbyte;originalSize:int32;cSrc:pbyte; cSrcSize:int32;dt:pFSE_DTable):int32;
function FSE_decompress_wksp(dst:pbyte;  dstCapacity:int32; cSrc:pbyte;  cSrcSize:int32;  maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
function FSE_decompress_wksp_body(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize,bmi2: int32):int32;
function FSE_decompress_wksp_body_default(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
function FSE_decompress_wksp_body_bmi2(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
function FSE_decompress_wksp_bmi2(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32; bmi2:int32):int32;
function FSE_buildDTable(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32):int32;
function FSE_decompress(dst:pbyte;  dstCapacity:int32; cSrc:pbyte; cSrcSize:int32):int32;
implementation
uses entropy_common;
{ Function templates }
function FSE_createDTable (tableLog:uint32):pFSE_DTable;
begin
    if (tableLog > FSE_TABLELOG_ABSOLUTE_MAX) then
      tableLog := FSE_TABLELOG_ABSOLUTE_MAX;
    result := allocmem( FSE_DTABLE_SIZE_Uint32(tableLog) * sizeof (Uint32) );
end;

procedure FSE_freeDTable(dt:pFSE_DTable);
begin
  freemem(dt);
end;

function FSE_buildDTable_internal(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32; workSpace:pbyte; wkspSize:int32):int32;
var
  tdPtr:pbyte;
  tableDecode:pFSE_DECODE_TYPE;
  symbolNext:pWord;
  spread:pbyte;
  maxSV1,tableSize,highThreshold,s:Uint32;
  DTableH:FSE_DTableHeader;
  largeLimit:int16;
  tableMask,step:int32;
  ladd,sv:uint64;
  pos,i,n,position,ss,unroll,u,uPosition:int32;
  symbol:byte;
  nextState:uint32;
begin
  tdPtr       := pbyte(dt+1);   { because *dt is unsigned, 32-bits aligned on 32-bits }
  tableDecode := pFSE_DECODE_TYPE(tdPtr);
  symbolNext  := pWord(workSpace);
  spread      := pbyte(symbolNext + maxSymbolValue + 1);

  maxSV1      := maxSymbolValue + 1;
  tableSize   := 1  shl  tableLog;
  highThreshold := tableSize-1;

  { Sanity Checks }
  if (FSE_BUILD_DTABLE_WKSP_SIZE(tableLog, maxSymbolValue) > wkspSize) then
    exit(ERROR(maxSymbolValue_tooLarge));
    
  if (maxSymbolValue > FSE_MAX_SYMBOL_VALUE) then
    exit(ERROR(maxSymbolValue_tooLarge));
    
  if (tableLog > FSE_MAX_TABLELOG) then
    exit(ERROR(tableLog_tooLarge));

    { Init, lay down lowprob symbols }   
  
  DTableH.tableLog := uint16(tableLog);
  DTableH.fastMode := 1;
   
  largeLimit:= int16(1  shl  (tableLog-1));
  for s:=0 to maxSV1-1 do
  begin
    if (normalizedCounter[s]=-1) then
    begin
      tableDecode[highThreshold].symbol := byte(s);//FSE_FUNCTION_TYPE(s);
      highThreshold := highThreshold-1;
      symbolNext[s] := 1;
    end 
    else 
    begin
      if (normalizedCounter[s] >= largeLimit) then
        DTableH.fastMode:=0;
      symbolNext[s] := normalizedCounter[s];
    end;
  end; 
  move(pbyte(@DTableH)[0],dt[0],sizeof(DTableH));

    { Spread symbols }
  if (highThreshold = tableSize - 1) then
  begin
      tableMask := tableSize-1;
      step      := FSE_TABLESTEP(tableSize);
      { First lay down the symbols in order.
       * We use a uint64_t to lay down 8 bytes at a time. This reduces branch
       * misses since small blocks generally have small table logs, so nearly
       * all symbols have counts <= 8. We ensure we have 8 bytes at the end of
       * our buffer to handle the over-write.
       }
      ladd := uint64($0101010101010101);
      pos  := 0;
      sv   := 0;
      for s:=0 to maxSV1-1 do
      begin
        n := normalizedCounter[s];
        MEM_write64(spread + pos, sv);
        i := 8 ;
        while (i < n) do
        begin
          MEM_write64(spread + pos + i, sv);
          i :=i + 8;
        end;
        pos :=pos + n;
        sv  :=sv  + ladd;
      end;

      { Now we spread those positions across the table.
       * The benefit of doing it in two stages is that we avoid the the
       * variable size inner loop, which caused lots of branch misses.
       * Now we can run through all the positions without any branch misses.
       * We unroll the loop twice, since that is what emperically worked best.
       }
      position := 0;
      unroll   := 2;
      ss  := 0;
      while ( ss < int32(tableSize)) do
      begin
          for u := 0 to unroll-1 do
          begin
            uPosition := (position + (u * step))  and  tableMask;
            tableDecode[uPosition].symbol := spread[ss + u];
          end;
          position := (position + (unroll * step))  and  tableMask;
          ss :=ss + unroll; 
      end;
  end
  else 
  begin
      tableMask := tableSize-1;
      step      := FSE_TABLESTEP(tableSize);
      position  := 0;
      for s:=0 to maxSV1-1 do
      begin
          for i:=0 to normalizedCounter[s]-1 do
          begin
              tableDecode[position].symbol := byte(s);//FSE_FUNCTION_TYPE(s);
              position := (position + step)  and  tableMask;
              while (position > highThreshold) do
                position := (position + step)  and  tableMask;   { lowprob area }
          end;
      end;
      if (position<>0) then
         exit(ERROR(GENERIC_ERROR));   { position must reach all cells once, otherwise normalizedCounter is incorrect }
  end;

  { Build Decoding table }

  for u:=0 to tableSize-1 do
  begin
      symbol    := {FSE_FUNCTION_TYPE}byte(tableDecode[u].symbol);
      nextState := symbolNext[symbol];
      inc(symbolNext[symbol]);
      tableDecode[u].nbBits   := byte (tableLog - BIT_highbit32(nextState) );
      tableDecode[u].newState := Word ( (nextState  shl  tableDecode[u].nbBits) - tableSize);
  end;

  result := 0;
end;

function FSE_buildDTable_wksp(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32; workSpace:pbyte; wkspSize:int32):int32;
begin
  result := FSE_buildDTable_internal(dt, normalizedCounter, maxSymbolValue, tableLog, workSpace, wkspSize);
end;


{-*******************************************************
*  Decompression (Byte symbols)
********************************************************}
function FSE_buildDTable_rle(dt:pFSE_DTable; symbolValue:BYTE):int32;
var
  ptr,dPtr:pbyte;
  DTableH:pFSE_DTableHeader;
  cell:pFSE_decode_t;
begin
  ptr := pbyte(dt);
  DTableH := pFSE_DTableHeader(ptr);
  dPtr := pbyte(dt + 1);
  cell := pFSE_decode_t(dPtr);

  DTableH^.tableLog := 0;
  DTableH^.fastMode := 0;

  cell^.newState := 0;
  cell^.symbol := symbolValue;
  cell^.nbBits := 0;

  result := 0;
end;


function FSE_buildDTable_raw (dt:pFSE_DTable; nbBits:uint32 ):int32;
var
  ptr,dPtr:pbyte;
  DTableH:pFSE_DTableHeader;
  dinfo:pFSE_decode_t;
  tableSize,tableMask,maxSV1,s:uint32;
begin
    ptr := pbyte(dt);
    DTableH := pFSE_DTableHeader(ptr);
    dPtr  := pbyte(dt + 1);
    dinfo := pFSE_decode_t(dPtr);
    tableSize := 1  shl  nbBits;
    tableMask := tableSize - 1;
    maxSV1    := tableMask+1;


    { Sanity checks }
    if (nbBits < 1) then
      exit(ERROR(GENERIC_ERROR));         { min size }

    { Build Decoding Table }
    DTableH^.tableLog := uint16(nbBits);
    DTableH^.fastMode := 1;
    for s:=0 to maxSV1-1 do
    begin
        dinfo[s].newState := 0;
        dinfo[s].symbol   := BYTE(s);
        dinfo[s].nbBits   := BYTE(nbBits);
    end;

    result := 0;
end;

function  FSE_decompress_usingDTable_generic(dst:pbyte; maxDstSize:int32;cSrc:pbyte; cSrcSize:int32;dt:pFSE_DTable;fast:uint32):int32;
var
  ostart,op,omax,olimit:pbyte;
  bitD:BIT_DStream_t;
  state1,state2:FSE_DState_t;
begin
    ostart := pbyte(dst);
        op := ostart;
    omax   := op + maxDstSize;
    olimit := omax-3;

    { Init }
    if (ERR_isError(BIT_initDStream(@bitD, cSrc, cSrcSize))<>0) then
       exit(BIT_initDStream(@bitD, cSrc, cSrcSize));

    FSE_initDState(@state1,  @bitD, dt);
    FSE_initDState(@state2,  @bitD, dt);

    { 4 symbols per loop }
    while (BIT_reloadDStream( @bitD)=BIT_DStream_unfinished)  and  (op<olimit) do
    begin
        op[0] := FSE_decodeSymbol(@state1, @bitD);

        if (FSE_MAX_TABLELOG*2+7 > sizeof(bitD.bitContainer)*8) then    { This test must be static }
            BIT_reloadDStream(@bitD);

        op[1] := FSE_decodeSymbol(@state2, @bitD);

        if (FSE_MAX_TABLELOG*4+7 > sizeof(bitD.bitContainer)*8) then   { This test must be static }
        begin 
          if (BIT_reloadDStream(@bitD) > BIT_DStream_unfinished) then
          begin 
            op:=op+2; 
            break; 
          end;
        end;

        op[2] := FSE_decodeSymbol(@state1,@bitD);

        if (FSE_MAX_TABLELOG*2+7 > sizeof(bitD.bitContainer)*8) then    { This test must be static }
            BIT_reloadDStream(@bitD);

        op[3] := FSE_decodeSymbol(@state2,@bitD);
        op:=op+4; 
    end;

    { tail }
    { note : BIT_reloadDStream( and bitD) >= FSE_DStream_partiallyFilled; Ends at exactly BIT_DStream_completed }
    while (true) do
    begin
        if (op>(omax-2)) then
          exit(ERROR(dstint32ooSmall));
        op^ := FSE_decodeSymbol(@state1,@bitD);
        op:=op+1;
        if (BIT_reloadDStream(@bitD)=BIT_DStream_overflow) then
        begin
            op^ := FSE_decodeSymbol(@state2,@bitD);
            op:=op+1;
            break;
        end;

        if (op>(omax-2)) then
          exit(ERROR(dstint32ooSmall));
        op^ := FSE_decodeSymbol(@state2,@bitD);
        op:=op+1;
        if (BIT_reloadDStream(@bitD)=BIT_DStream_overflow) then
        begin
            op^ := FSE_decodeSymbol(@state1,@bitD);
            op:=op+1;
            break;
        end;   
    end;

    result := op-ostart;
end;


function FSE_decompress_usingDTable(dst:pbyte;originalSize:int32;cSrc:pbyte; cSrcSize:int32;dt:pFSE_DTable):int32;
var
  ptr:pbyte;
  DTableH:pFSE_DTableHeader;
  fastMode:Uint32;
begin
    ptr     := pbyte(dt);
    DTableH := pFSE_DTableHeader(ptr);
    fastMode := DTableH^.fastMode;

    { select fast mode (static) }
    if (fastMode<>0) then
      exit(FSE_decompress_usingDTable_generic(dst, originalSize, cSrc, cSrcSize, dt, 1));
    exit(FSE_decompress_usingDTable_generic(dst, originalSize, cSrc, cSrcSize, dt, 0));
end;


function FSE_decompress_wksp(dst:pbyte;  dstCapacity:int32; cSrc:pbyte;  cSrcSize:int32;  maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
begin
  result := FSE_decompress_wksp_bmi2(dst, dstCapacity, cSrc, cSrcSize, maxLog, workSpace, wkspSize, { bmi2 } 0);
end;

function  FSE_decompress_wksp_body(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize,bmi2: int32):int32;
var
  ip,istart:pbyte;
  counting:array [0..FSE_MAX_SYMBOL_VALUE] of int16;
  tableLog,maxSymbolValue:uint32;
  dtable:pFSE_DTable;
  NCountLength:int32;
  ptr:pbyte;
  DTableH:pFSE_DTableHeader;
  fastMode:Uint32;
begin
    istart := pbyte(cSrc);
    ip     := istart;
    
    maxSymbolValue := FSE_MAX_SYMBOL_VALUE;
    dtable         := pFSE_DTable(workSpace);

    { normal FSE decoding mode }
    NCountLength := FSE_readNCount_bmi2(@counting[0],  @maxSymbolValue,  @tableLog, istart, cSrcSize, bmi2);
    if (FSE_isError(NCountLength)<>0) then
      exit(NCountLength);
    if (tableLog > maxLog) then
      exit(ERROR(tableLog_tooLarge));

    ip :=ip + NCountLength;
    cSrcSize :=cSrcSize - NCountLength;

    if (FSE_DECOMPRESS_WKSP_SIZE(tableLog, maxSymbolValue) > wkspSize) then
      exit(ERROR(tableLog_tooLarge));
    workSpace := pbyte(dtable + FSE_DTABLE_SIZE_Uint32(tableLog));
    wkspSize  :=wkspSize - FSE_DTABLE_SIZE(tableLog);

    NCountLength := FSE_buildDTable_internal(dtable, @counting[0], maxSymbolValue, tableLog, workSpace, wkspSize);
    if (FSE_isError(NCountLength)<>0) then
      exit(NCountLength);

    ptr := pbyte(dtable);
    DTableH := pFSE_DTableHeader(ptr);
    fastMode := DTableH^.fastMode;

    { select fast mode (static) }
    if (fastMode<>0) then
     exit(FSE_decompress_usingDTable_generic(dst, dstCapacity, ip, cSrcSize, dtable, 1));
    exit(FSE_decompress_usingDTable_generic(dst, dstCapacity, ip, cSrcSize, dtable, 0));
end;

{ Avoids the FORCE_INLINE of the _body() function. }
function FSE_decompress_wksp_body_default(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
begin
    result := FSE_decompress_wksp_body(dst, dstCapacity, cSrc, cSrcSize, maxLog, workSpace, wkspSize, 0);
end;

function FSE_decompress_wksp_body_bmi2(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32):int32;
begin
    result := FSE_decompress_wksp_body(dst, dstCapacity, cSrc, cSrcSize, maxLog, workSpace, wkspSize, 1);
end;

function FSE_decompress_wksp_bmi2(dst:pbyte;  dstCapacity:int32;cSrc:pbyte;  cSrcSize:int32;maxLog:uint32; workSpace:pbyte; wkspSize: int32; bmi2:int32):int32;
begin
  result := FSE_decompress_wksp_body_bmi2(dst, dstCapacity, cSrc, cSrcSize, maxLog, workSpace, wkspSize);
end;

function FSE_buildDTable(dt:pFSE_DTable; normalizedCounter:pint16; maxSymbolValue, tableLog:uint32):int32;
var
  //wksp:array [0..FSE_BUILD_DTABLE_WKSP_SIZE_Uint32(FSE_TABLELOG_ABSOLUTE_MAX=15, FSE_MAX_SYMBOL_VALUE=255)] of Uint32;
  wksp:pbyte;
  i:integer;
begin
  i:=FSE_BUILD_DTABLE_WKSP_SIZE_Uint32(FSE_TABLELOG_ABSOLUTE_MAX, FSE_MAX_SYMBOL_VALUE)*sizeof(uint32);
  wksp:=allocmem(i);
  result :=FSE_buildDTable_wksp(dt, normalizedCounter, maxSymbolValue, tableLog, wksp, i);
  freemem(wksp);
end;

function FSE_decompress(dst:pbyte;  dstCapacity:int32; cSrc:pbyte; cSrcSize:int32):int32;
var
  //wksp:array [0..FSE_DECOMPRESS_WKSP_SIZE_Uint32(FSE_MAX_TABLELOG, FSE_MAX_SYMBOL_VALUE)] of Uint32;
  wksp:pbyte;
  i:integer;
begin
    { Static analyzer seems unable to understand this table will be properly initialized later }
  i:=FSE_DECOMPRESS_WKSP_SIZE_Uint32(FSE_MAX_TABLELOG, FSE_MAX_SYMBOL_VALUE);
  wksp:=allocmem(i);
  result := FSE_decompress_wksp(dst, dstCapacity, cSrc, cSrcSize, FSE_MAX_TABLELOG, wksp, i);
  freemem(wksp);
end;
end.
