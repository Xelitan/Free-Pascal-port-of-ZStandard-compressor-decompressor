unit fse;
{$mode objfpc}{$H+}
interface
uses sysutils,bitstream;
const
  FSE_VERSION_MAJOR    =0;
  FSE_VERSION_MINOR    =9;
  FSE_VERSION_RELEASE  =0;
{ FSE buffer bounds }
  FSE_NCOUNTBOUND =512;
  FSE_MAX_MEMORY_USAGE =14;
  FSE_DEFAULT_MEMORY_USAGE =13;
  FSE_MAX_SYMBOL_VALUE =255;
  FSE_MIN_TABLELOG =5;
  FSE_TABLELOG_ABSOLUTE_MAX =15;

  FSE_MAX_TABLELOG  = (FSE_MAX_MEMORY_USAGE-2);

{$define FSE_MAX_TABLESIZE (1U shl FSE_MAX_TABLELOG)}
{$define FSE_MAXTABLESIZE_MASK (FSE_MAX_TABLESIZE-1)}
  FSE_DEFAULT_TABLELOG = FSE_DEFAULT_MEMORY_USAGE-2;
{$define FSE_TABLESTEP(tableSize) (((tableSize) shr 1) + ((tableSize) shr 3) + 3)}
type
pFSE_CState_t=^FSE_CState_t;
pFSE_DState_t=^FSE_DState_t;
pFSE_symbolCompressionTransform=^FSE_symbolCompressionTransform;
pFSE_DTableHeader=^FSE_DTableHeader;
pFSE_decode_t=^FSE_decode_t;

  FSE_repeat=(
   FSE_repeat_none,  {*< Cannot use the previous table }
   FSE_repeat_check, {*< Can use the previous table but it must be checked }
   FSE_repeat_valid  {*< Can use the previous table and it is assumed to be valid }
  );
  pFSE_repeat=^FSE_repeat;
  FSE_CState_t=record
    value:PtrInt;
    stateTable:pbyte;
    symbolTT:pbyte;
    stateLog:uint32;
  end;
  FSE_DState_t=record
    state:PtrInt;
    table:pbyte;   { precise table may vary, depending on U16 }
  end;
  FSE_symbolCompressionTransform=record
    deltaFindState:int32;
    deltaNbBits:Uint32;
  end; { total 8 bytes }
  FSE_DTable=uint32;
  pFSE_DTable=^FSE_DTable;
  FSE_DTableHeader=record
    tableLog:Word;
    fastMode:Word;
  end;   { sizeof Uint32 }
  FSE_CTable=uint32;
  pFSE_CTable=^FSE_CTable;
  FSE_decode_t=record
    newState:Word;
    symbol:byte;
    nbBits:byte;
  end;   { size == Uint32 }
  pFSE_DECODE_TYPE=^FSE_DECODE_TYPE;
  FSE_DECODE_TYPE  = FSE_decode_t;
procedure FSE_initCState(statePtr:pFSE_CState_t; const ct:pFSE_CTable);
procedure FSE_initCState2(statePtr:pFSE_CState_t; ct:pFSE_CTable; symbol:Uint32);
procedure FSE_encodeSymbol(bitC:pBIT_CStream_t;statePtr:pFSE_CState_t; symbol:uint32);
procedure FSE_flushCState(bitC:pBIT_CStream_t; statePtr:pFSE_CState_t);
function FSE_getMaxNbBits(symbolTTPtr:pbyte; symbolValue:Uint32):uint32;
function FSE_bitCost(symbolTTPtr:pbyte;tableLog, symbolValue, accuracyLog:Uint32):Uint32;
procedure FSE_initDState(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t;dt:pFSE_DTable);
function FSE_peekSymbol(DStatePtr:pFSE_DState_t):byte;
procedure FSE_updateState(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t);
function FSE_decodeSymbol(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t):byte;
function FSE_decodeSymbolFast(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t):byte;
function FSE_endOfDState(DStatePtr:pFSE_DState_t):uint32;
function FSE_DTABLE_SIZE(maxTableLog:int32):int32;
function FSE_CTABLE_SIZE(maxTableLog, maxSymbolValue:int32):int32;
function FSE_DTABLE_SIZE_Uint32(maxTableLog:int32):int32;
function FSE_CTABLE_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
function FSE_COMPRESSBOUND(size:int32):int32;
function FSE_BLOCKBOUND(size:int32):int32;
function FSE_DECOMPRESS_WKSP_SIZE(maxTableLog, maxSymbolValue:int32):int32;
function FSE_DECOMPRESS_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
function FSE_BUILD_DTABLE_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
function FSE_BUILD_DTABLE_WKSP_SIZE(maxTableLog, maxSymbolValue:int32):int32;
function FSE_BUILD_CTABLE_WORKSPACE_SIZE(maxSymbolValue, tableLog:int32):int32;
function FSE_BUILD_CTABLE_WORKSPACE_SIZE_Uint32(maxSymbolValue, tableLog:int32):int32;
function FSE_COMPRESS_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
function FSE_TABLESTEP(tableSize:int32):int32;
procedure BIT_flushBits(bitC:pBIT_CStream_t);
implementation
function FSE_TABLESTEP(tableSize:int32):int32;
begin
  result := (((tableSize) shr 1) + ((tableSize) shr 3) + 3);
end;
function FSE_COMPRESS_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
begin
  if (maxTableLog > 12) then
    result := ( FSE_CTABLE_SIZE_Uint32(maxTableLog, maxSymbolValue) + (1 shl (maxTableLog - 2)))
  else
    result := ( FSE_CTABLE_SIZE_Uint32(maxTableLog, maxSymbolValue) + 1024);
end;

function FSE_BUILD_CTABLE_WORKSPACE_SIZE_Uint32(maxSymbolValue, tableLog:int32):int32;
begin
   result := (maxSymbolValue + 2 + (uint64(1) shl (tableLog - 2)));
end;

function FSE_BUILD_CTABLE_WORKSPACE_SIZE(maxSymbolValue, tableLog:int32):int32;
begin
   result := (sizeof(uint32) * FSE_BUILD_CTABLE_WORKSPACE_SIZE_Uint32(maxSymbolValue, tableLog));
end;

function FSE_BUILD_DTABLE_WKSP_SIZE(maxTableLog, maxSymbolValue:int32):int32;
begin
   result := (sizeof(int16) * (maxSymbolValue + 1) + (uint64(1) shl maxTableLog) + 8)
end;

function FSE_BUILD_DTABLE_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
begin
   result := ((FSE_BUILD_DTABLE_WKSP_SIZE(maxTableLog, maxSymbolValue) + sizeof(int32) - 1) div sizeof(uint32))
end;

function FSE_DECOMPRESS_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
begin
   result := (FSE_DTABLE_SIZE_Uint32(maxTableLog) + FSE_BUILD_DTABLE_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue))
end;
function FSE_DECOMPRESS_WKSP_SIZE(maxTableLog, maxSymbolValue:int32):int32;
begin
   result := (FSE_DECOMPRESS_WKSP_SIZE_Uint32(maxTableLog, maxSymbolValue) * sizeof(uint32))
end;
function FSE_BLOCKBOUND(size:int32):int32;
begin
  result := (size + ((size) shr 7) + 4 { fse states } + sizeof(int32) { bitContainer });
end;
function FSE_COMPRESSBOUND(size:int32):int32;
begin
result := (FSE_NCOUNTBOUND + FSE_BLOCKBOUND(size)); { Macro version, useful for static allocation }
end;
{ It is possible to statically allocate FSE CTable/DTable as a table of FSE_CTable/FSE_DTable using below macros }
function FSE_CTABLE_SIZE_Uint32(maxTableLog, maxSymbolValue:int32):int32;
begin
result := (1 + (1 shl ((maxTableLog)-1)) + (((maxSymbolValue)+1)*2));
end;
function FSE_DTABLE_SIZE_Uint32(maxTableLog:int32):int32;
begin
result := (1 + (1 shl (maxTableLog)));
end;

{ or use the size to malloc() space directly. Pay attention to alignment ions though }
function FSE_CTABLE_SIZE(maxTableLog, maxSymbolValue:int32):int32;
begin
result := (FSE_CTABLE_SIZE_Uint32(maxTableLog, maxSymbolValue) * sizeof(FSE_CTable));
end;
function FSE_DTABLE_SIZE(maxTableLog:int32):int32;
begin
result := (FSE_DTABLE_SIZE_Uint32(maxTableLog) * sizeof(FSE_DTable));
end;
procedure FSE_initCState(statePtr:pFSE_CState_t; const ct:pFSE_CTable);
var
  ptr:pbyte;
  u16ptr:puint16;
  tableLog:Uint32;
begin
  ptr      := pbyte(ct);
  u16ptr   := puint16(ptr);
  tableLog := puint16(ptr)^;
  statePtr^.value := int32(1) shl tableLog;
  statePtr^.stateTable := pbyte(u16ptr+2);
  if tableLog<>0 then
    statePtr^.symbolTT := pbyte(ct + 1 + (1 shl (tableLog-1)))
  else
    statePtr^.symbolTT := pbyte(ct + 1 + 1);
  statePtr^.stateLog := tableLog;
end;
{! FSE_initCState2() :
*   Same as FSE_initCState(), but the first symbol to include (which will be the last to be read)
*   uses the smallest state value possible, saving the cost of this symbol }
procedure FSE_initCState2(statePtr:pFSE_CState_t; ct:pFSE_CTable; symbol:Uint32);
var
  symbolTT:FSE_symbolCompressionTransform;
  stateTable:pWord;
  nbBitsOut:Uint32;
begin
  FSE_initCState(statePtr, ct);
  symbolTT         := (pFSE_symbolCompressionTransform(statePtr^.symbolTT))[symbol];
  stateTable       := pWord(statePtr^.stateTable);
  nbBitsOut        := Uint32((symbolTT.deltaNbBits + (1 shl 15))  shr  16);
  statePtr^.value  := (nbBitsOut  shl  16) - symbolTT.deltaNbBits;
  statePtr^.value  := stateTable[(statePtr^.value  shr  nbBitsOut) + symbolTT.deltaFindState];
end;

procedure FSE_encodeSymbol(bitC:pBIT_CStream_t;statePtr:pFSE_CState_t; symbol:uint32);
var
  symbolTT:FSE_symbolCompressionTransform;
  stateTable:pWord;
  nbBitsOut:Uint32;
  idx: int32;
begin
  symbolTT   := (pFSE_symbolCompressionTransform(statePtr^.symbolTT))[symbol];
  stateTable := pWord(statePtr^.stateTable);
  nbBitsOut  := Uint32((statePtr^.value + symbolTT.deltaNbBits)  shr  16);
  BIT_addBits(bitC, statePtr^.value, nbBitsOut);
  idx := int32(statePtr^.value shr nbBitsOut) + symbolTT.deltaFindState;
  if (stateTable = nil) or (idx < 0) or (idx > 65535) then
  begin
    //log(stderr, 'FSE_encodeSymbol FATAL: stateTable=', PtrUInt(stateTable),
    //        ' symbol=', symbol, ' value=', statePtr^.value,
    //        ' nbBitsOut=', nbBitsOut, ' deltaFindState=', symbolTT.deltaFindState,
    //        ' idx=', idx);
    exit;
  end;
  statePtr^.value := stateTable[idx];
end;
procedure BIT_flushBits(bitC:pBIT_CStream_t);
var
  nbBytes:int32;
begin
    nbBytes := bitC^.bitPos shr 3;
    assert(bitC^.bitPos < sizeof(bitC^.bitContainer) * 8);
    assert(bitC^.ptr <= bitC^.endPtr);
    MEM_writeLEST(bitC^.ptr, bitC^.bitContainer);
    bitC^.ptr :=bitC^.ptr + nbBytes;
    if (bitC^.ptr > bitC^.endPtr) then
      bitC^.ptr := bitC^.endPtr;
    bitC^.bitPos :=bitC^.bitPos and 7;
    bitC^.bitContainer :=bitC^.bitContainer  shr (nbBytes*8);
end;
procedure FSE_flushCState(bitC:pBIT_CStream_t; statePtr:pFSE_CState_t);
begin
  BIT_addBits(bitC, statePtr^.value, statePtr^.stateLog);
  BIT_flushBits(bitC);
end;


{ FSE_getMaxNbBits() :
 * Approximate maximum cost of a symbol, in bits.
 * Fractional get rounded up (i.e : a symbol with a normalized frequency of 3 gives the same result as a frequency of 2)
 * note 1 : assume symbolValue is valid (<= maxSymbolValue)
 * note 2 : if freq[symbolValue]==0, @return a fake cost of tableLog+1 bits }
function FSE_getMaxNbBits(symbolTTPtr:pbyte; symbolValue:Uint32):uint32;
var
  symbolTT:pFSE_symbolCompressionTransform;
begin
  symbolTT := pFSE_symbolCompressionTransform(symbolTTPtr);
  result := (symbolTT[symbolValue].deltaNbBits + ((1 shl 16)-1))  shr  16;
end;

{ FSE_bitCost() :
 * Approximate symbol cost, as fractional value, using fixed-point format (accuracyLog fractional bits)
 * note 1 : assume symbolValue is valid (<= maxSymbolValue)
 * note 2 : if freq[symbolValue]==0, @return a fake cost of tableLog+1 bits }
function FSE_bitCost(symbolTTPtr:pbyte;tableLog, symbolValue, accuracyLog:Uint32):Uint32;
var
  symbolTT:pFSE_symbolCompressionTransform;
  minNbBits:Uint32;
  threshold:Uint32;
  tableSize,deltaFromThreshold,normalizedDeltaFromThreshold,bitMultiplier:Uint32;
begin
  symbolTT := pFSE_symbolCompressionTransform(symbolTTPtr);
  minNbBits := symbolTT[symbolValue].deltaNbBits  shr  16;
  threshold := (minNbBits+1)  shl  16;

  tableSize                    := 1  shl  tableLog;
  deltaFromThreshold           := threshold - (symbolTT[symbolValue].deltaNbBits + tableSize);
  normalizedDeltaFromThreshold := (deltaFromThreshold  shl  accuracyLog)  shr  tableLog;   { linear interpolation (very approximate) }
  bitMultiplier                := 1  shl  accuracyLog;
  result := (minNbBits+1)*bitMultiplier - normalizedDeltaFromThreshold;
end;
procedure FSE_initDState(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t;dt:pFSE_DTable);
var
  ptr:pbyte;
  DTableH:pFSE_DTableHeader;
begin
    ptr := pbyte(dt);
    DTableH := pFSE_DTableHeader(ptr);
    DStatePtr^.state := BIT_readBits(bitD, DTableH^.tableLog);
    BIT_reloadDStream(bitD);
    DStatePtr^.table := pbyte(dt + 1);
end;

function FSE_peekSymbol(DStatePtr:pFSE_DState_t):byte;
var
  DInfo:FSE_decode_t;
begin
  DInfo  := (pFSE_decode_t(DStatePtr^.table))[DStatePtr^.state];
  result := DInfo.symbol;
end;

procedure FSE_updateState(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t);
var
  DInfo:FSE_decode_t;
  nbBits:Uint32;
  lowBits:PtrUInt;
begin
    DInfo   := (pFSE_decode_t(DStatePtr^.table))[DStatePtr^.state];
    nbBits  := DInfo.nbBits;
    if nbBits > 0 then lowBits := BIT_readBitsFast(bitD, nbBits) else lowBits := 0;
    DStatePtr^.state := DInfo.newState + lowBits;
end;

function FSE_decodeSymbol(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t):byte;
var
  DInfo:FSE_decode_t;
  nbBits:Uint32;
  symbol:byte;
  lowBits:PtrUInt;
begin
    DInfo   := (pFSE_decode_t(DStatePtr^.table))[DStatePtr^.state];
    nbBits  := DInfo.nbBits;
    symbol  := DInfo.symbol;
    if nbBits > 0 then
      lowBits := BIT_readBitsFast(bitD, nbBits)
    else
      lowBits := 0;
    DStatePtr^.state := DInfo.newState + lowBits;
    result := symbol;
end;

{! FSE_decodeSymbolFast() :
    unsafe, only works if no symbol has a probability > 50% }
function FSE_decodeSymbolFast(DStatePtr:pFSE_DState_t; bitD:pBIT_DStream_t):byte;
var
  DInfo:FSE_decode_t;
  nbBits:Uint32;
  symbol:byte;
  lowBits:PtrUInt;
begin
    DInfo   := (pFSE_decode_t(DStatePtr^.table))[DStatePtr^.state];
    nbBits  := DInfo.nbBits;
    symbol  := DInfo.symbol;
    if nbBits > 0 then lowBits := BIT_readBitsFast(bitD, nbBits) else lowBits := 0;

    DStatePtr^.state := DInfo.newState + lowBits;
    result := symbol;
end;

function FSE_endOfDState(DStatePtr:pFSE_DState_t):uint32;
begin
    result := ord(DStatePtr^.state = 0);
end;

end.
