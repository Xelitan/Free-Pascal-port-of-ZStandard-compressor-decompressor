unit bitstream;
{$mode objfpc}{$H+}
interface
uses error_private;
const 
  STREAM_ACCUMULATOR_MIN_32 = 25;
  STREAM_ACCUMULATOR_MIN_64 = 57;
  STREAM_ACCUMULATOR_MIN    = {$ifdef CPU64}57{$else}25{$endif}; //((Uint32)(MEM_32bits() ? STREAM_ACCUMULATOR_MIN_32 : STREAM_ACCUMULATOR_MIN_64))};
{=====    Local Constants   =====}
  BIT_mask:array [0..31] of uint32 = (
    0,          1,         3,         7,         $F,       $1F,
    $3F,       $7F,      $FF,      $1FF,     $3FF,     $7FF,
    $FFF,      $1FFF,    $3FFF,    $7FFF,    $FFFF,    $1FFFF,
    $3FFFF,    $7FFFF,   $FFFFF,   $1FFFFF,  $3FFFFF,  $7FFFFF,
    $FFFFFF,   $1FFFFFF, $3FFFFFF, $7FFFFFF, $FFFFFFF, $1FFFFFFF,
    $3FFFFFFF, $7FFFFFFF); { up to 31 bits }
  BIT_MASK_SIZE:integer= (sizeof(BIT_mask) div sizeof(BIT_mask[0]));
type
  pPtrUInt=^PtrUInt;
  pBIT_CStream_t=^BIT_CStream_t;
  pBIT_DStream_t=^BIT_DStream_t;

{-******************************************
*  bitStream encoding API (write forward)
*******************************************}
{ bitStream can mix input from multiple sources.
 * A critical property of these streams is that they encode and decode in **reverse** direction.
 * So the first bit sequence you add will be the last to be read, like a LIFO stack.
 }
  BIT_CStream_t=record
    bitContainer:PtrUInt;
    bitPos:uint32;
    startPtr:pbyte;
    ptr:pbyte;
    endPtr:pbyte;
  end;


{-********************************************
*  bitStream decoding API (read backward)
*********************************************}
  BIT_DStream_t=record
    bitContainer:PtrUInt;
    bitsConsumed:uint32;
    ptr:pbyte;
    start:pbyte;
    limitPtr:pbyte;
  end;

 BIT_DStream_status =( BIT_DStream_unfinished = 0,
               BIT_DStream_endOfBuffer = 1,
               BIT_DStream_completed = 2,
               BIT_DStream_overflow = 3 );  { result of BIT_reloadDStream() }
               { 1,2,4,8 would be better for bitmap combinations, but slows down performance a bit ... :( }
 
function BIT_highbit32 (val:Uint32 ):Uint32;
function BIT_initCStream(bitC:pBIT_CStream_t;startPtr:pbyte; dstCapacity:int32):int32;
procedure BIT_addBits(bitC:pBIT_CStream_t;value:PtrUInt; nbBits:uint32);
procedure BIT_addBitsFast(bitC:pBIT_CStream_t;value:PtrUInt; nbBits:uint32);
procedure BIT_flushBitsFast(bitC:pBIT_CStream_t);
function BIT_initDStream(bitD:pBIT_DStream_t; srcBuffer:pbyte;  srcSize:int32):int32;
function BIT_getUpperBits(bitContainer:PtrUInt; start:Uint32):PtrUInt;
function  BIT_getMiddleBits(bitContainer:PtrUInt ; start,nbBits:Uint32):PtrUInt;
function BIT_getLowerBits(bitContainer:PtrUInt ; nbBits:Uint32 ):PtrUInt;
function BIT_lookBits(bitD:pBIT_DStream_t; nbBits:Uint32):PtrUInt;
function BIT_lookBitsFast(const bitD:pBIT_DStream_t; nbBits:Uint32):PtrUInt;
procedure BIT_skipBits(bitD:pBIT_DStream_t ;nbBits:Uint32);
function BIT_readBits(bitD:pBIT_DStream_t ; nbBits:uint32 ):PtrUInt;
function BIT_readBitsFast(bitD:pBIT_DStream_t ; nbBits:uint32 ):PtrUInt;
function BIT_reloadDStreamFast(bitD:pBIT_DStream_t ):BIT_DStream_status;
function BIT_reloadDStream(bitD:pBIT_DStream_t ):BIT_DStream_status;
function BIT_endOfDStream(DStream:pBIT_DStream_t):uint32;
procedure MEM_writeLEST(memPtr:pbyte; val:PtrUInt );
function BIT_closeCStream(bitC:pBIT_CStream_t):int32;
implementation
{-**************************************************************
*  Internal functions
***************************************************************}
function BIT_highbit32 (val:Uint32 ):Uint32;
var
  DeBruijnClz:array [0..31] of uint32=( 0,  9,  1, 10, 13, 21,  2, 29,
 11, 14, 16, 18, 22, 25,  3, 30,
  8, 12, 20, 28, 15, 17, 24,  7,
 19, 27, 23,  6, 26,  5,  4, 31);
 v:Uint32;
begin
  { Software version }

  v := val;
  v :=v or v shr 1;
  v :=v or v shr 2;
  v :=v or v shr 4;
  v :=v or v shr 8;
  v :=v or v shr 16;
  result := DeBruijnClz[ Uint32 (v * $07C4ACDD) shr 27];
end;

procedure MEM_writeLEST(memPtr:pbyte; val:PtrUInt );
begin
    {$ifdef CPU64}
        PQWord(memPtr)^ := val;  { little-endian 64-bit write }
    {$else}
        PUint32(memPtr)^ := val; { little-endian 32-bit write }
    {$endif}
end;

{-**************************************************************
*  bitStream encoding
***************************************************************}
{! BIT_initCStream() :
 *  `dstCapacity` must be > sizeof(int32)
 *  @return : 0 if success,
 *            otherwise an error code (can be tested using ERR_isError()) }
function BIT_initCStream(bitC:pBIT_CStream_t;startPtr:pbyte; dstCapacity:int32):int32;
begin
    bitC^.bitContainer := 0;
    bitC^.bitPos       := 0;
    bitC^.startPtr     := pbyte(startPtr);
    bitC^.ptr          := bitC^.startPtr;
    bitC^.endPtr       := bitC^.startPtr + dstCapacity - sizeof(bitC^.bitContainer);
    if (dstCapacity <= sizeof(bitC^.bitContainer)) then
      exit(ERROR(dstint32ooSmall));
    result := 0;
end;

{! BIT_addBits() :
 *  can add up to 31 bits into `bitC`.
 *  Note : does not check for register overflow ! }
procedure BIT_addBits(bitC:pBIT_CStream_t;value:PtrUInt; nbBits:uint32);
begin
  assert(nbBits < BIT_MASK_SIZE);
  assert(nbBits + bitC^.bitPos < sizeof(bitC^.bitContainer)*8);
  bitC^.bitContainer :=bitC^.bitContainer or (value and BIT_mask[nbBits]) shl bitC^.bitPos;
  bitC^.bitPos :=bitC^.bitPos + nbBits;
end;

{! BIT_addBitsFast() :
 *  works only if `value` is _clean_,
 *  meaning all high bits above nbBits are 0 }
procedure BIT_addBitsFast(bitC:pBIT_CStream_t;value:PtrUInt; nbBits:uint32);
begin
    assert(nbBits + bitC^.bitPos < sizeof(bitC^.bitContainer)*8);
    bitC^.bitContainer :=bitC^.bitContainer or value shl bitC^.bitPos;
    bitC^.bitPos :=bitC^.bitPos + nbBits;
end;

{! BIT_flushBitsFast() :
 *  assumption : bitContainer has not overflowed
 *  unsafe version; does not check buffer overflow }
procedure BIT_flushBitsFast(bitC:pBIT_CStream_t);
var
  nbBytes:int32;
begin
    nbBytes := bitC^.bitPos shr 3;
    assert(bitC^.bitPos < sizeof(bitC^.bitContainer) * 8);
    assert(bitC^.ptr <= bitC^.endPtr);
    MEM_writeLEST(bitC^.ptr, bitC^.bitContainer);
    bitC^.ptr :=bitC^.ptr + nbBytes;
    bitC^.bitPos := bitC^.bitPos and 7;
    bitC^.bitContainer :=bitC^.bitContainer shr (nbBytes*8);
end;

{! BIT_flushBits() :
 *  assumption : bitContainer has not overflowed
 *  safe version; check for buffer overflow, and prevents it.
 *  note : does not signal buffer overflow.
 *  overflow will be revealed later on using BIT_closeCStream() }
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
    bitC^.bitContainer :=bitC^.bitContainer shr (nbBytes*8);
end;

{! BIT_closeCStream() :
 *  @return : size of CStream, in bytes,
 *            or 0 if it could not fit into dstBuffer }
function BIT_closeCStream(bitC:pBIT_CStream_t):int32;
begin
    BIT_addBitsFast(bitC, 1, 1);   { endMark }
    BIT_flushBits(bitC);
    if (bitC^.ptr >= bitC^.endPtr) then
       exit(0); { overflow detected }
    result := (bitC^.ptr - bitC^.startPtr) + ord(bitC^.bitPos > 0);
end;


{-********************************************************
*  bitStream decoding
*********************************************************}
{! BIT_initDStream() :
 *  Initialize a BIT_DStream_t.
 * `bitD` : a pointer to an already allocated BIT_DStream_t structure.
 * `srcSize` must be the *exact* size of the bitStream, in bytes.
 * @return : size of stream (== srcSize), or an errorCode if a problem is detected
 }
function BIT_initDStream(bitD:pBIT_DStream_t; srcBuffer:pbyte;  srcSize:int32):int32;
var
  lastByte:byte;
  i:integer;
begin
  if (srcSize < 1) then
  begin 
    fillbyte(bitD^, sizeof(BIT_DStream_t), 0); 
    exit(ERROR(srcSize_wrong));
  end;

  bitD^.start    := pbyte(srcBuffer);
  bitD^.limitPtr := bitD^.start + sizeof(bitD^.bitContainer);

  if (srcSize >=  sizeof(bitD^.bitContainer)) then
  begin  { normal case }
      bitD^.ptr   := pbyte(srcBuffer) + srcSize - sizeof(bitD^.bitContainer);
      bitD^.bitContainer := pPtrUInt(bitD^.ptr)^; 
      lastByte := pbyte(srcBuffer)[srcSize-1];
      if lastByte<>0 then
        bitD^.bitsConsumed := 8 - BIT_highbit32(lastByte)  { ensures bitsConsumed is always set }
      else
        bitD^.bitsConsumed :=  0;  { ensures bitsConsumed is always set }
      if (lastByte = 0) then
        exit(ERROR(GENERIC_ERROR)); { endMark not present }
  end
  else 
  begin
    bitD^.ptr   := bitD^.start;
    bitD^.bitContainer := pbyte(bitD^.start)[0];
    i:=srcSize;
    while i>1 do
    begin
      case i of
        7: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[6]) shl (sizeof(bitD^.bitContainer)*8 - 16);
                { fall-through }

        6: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[5]) shl (sizeof(bitD^.bitContainer)*8 - 24);
                { fall-through }

        5: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[4]) shl (sizeof(bitD^.bitContainer)*8 - 32);
                { fall-through }

        4: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[3]) shl 24;
                { fall-through }

        3: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[2]) shl 16;
                { fall-through }

        2: bitD^.bitContainer :=bitD^.bitContainer + PtrUInt((pbyte(srcBuffer))[1]) shl  8;
                { fall-through }

        else;
      end;
      dec(i);
    end;
  
    lastByte := pbyte(srcBuffer)[srcSize-1];
    if lastByte<>0 then
      bitD^.bitsConsumed := 8 - BIT_highbit32(lastByte)  { ensures bitsConsumed is always set }
    else
      bitD^.bitsConsumed :=  0;  { ensures bitsConsumed is always set }
    if (lastByte = 0) then
      exit(ERROR(corruption_detected));  { endMark not present }

    bitD^.bitsConsumed :=bitD^.bitsConsumed + Uint32(sizeof(bitD^.bitContainer) - srcSize)*8;
  end;

  result := srcSize;
end;

function BIT_getUpperBits(bitContainer:PtrUInt; start:Uint32):PtrUInt;
begin
  result :=  bitContainer shr start;
end;

function  BIT_getMiddleBits(bitContainer:PtrUInt ; start,nbBits:Uint32):PtrUInt;
begin
    result := sizeof(bitContainer)*8 - 1;
    { if start > regMask, bitstream is corrupted, and result is undefined }
    result := (bitContainer shr (start and result)) and BIT_mask[nbBits];
end;

function BIT_getLowerBits(bitContainer:PtrUInt ; nbBits:Uint32):PtrUInt;
begin
  result :=  bitContainer and BIT_mask[nbBits];
end;

{! BIT_lookBits() :
 *  Provides next n bits from local register.
 *  local register is not modified.
 *  On 32-bits, maxNbBits==24.
 *  On 64-bits, maxNbBits==56.
 * @return : value extracted }
function BIT_lookBits(bitD:pBIT_DStream_t; nbBits:Uint32):PtrUInt;
begin
    { arbitrate between double-shift and shift+mask }
    { if bitD^.bitsConsumed + nbBits > sizeof(bitD^.bitContainer)*8,
     * bitstream is likely corrupted, and result is undefined }
    result := BIT_getMiddleBits(bitD^.bitContainer, (sizeof(bitD^.bitContainer)*8) - bitD^.bitsConsumed - nbBits, nbBits);
end;

{! BIT_lookBitsFast() :
 *  unsafe version; only works if nbBits >= 1 }
function BIT_lookBitsFast(const bitD:pBIT_DStream_t; nbBits:Uint32):PtrUInt;
var
  regMask: PtrUInt;
begin
    regMask := sizeof(bitD^.bitContainer)*8 - 1;
    assert(nbBits >= 1);
    result := (bitD^.bitContainer shl (bitD^.bitsConsumed and regMask)) shr (((regMask+1)-nbBits) and regMask);
end;

procedure BIT_skipBits(bitD:pBIT_DStream_t ;nbBits:Uint32);
begin
  bitD^.bitsConsumed :=bitD^.bitsConsumed + nbBits;
end;

{! BIT_readBits() :
 *  Read (consume) next n bits from local register and update.
 *  Pay attention to not read more than nbBits contained into local register.
 * @return : extracted value. }
function BIT_readBits(bitD:pBIT_DStream_t ; nbBits:uint32 ):PtrUInt;
begin
    result := BIT_lookBits(bitD, nbBits);
    BIT_skipBits(bitD, nbBits);
end;

{! BIT_readBitsFast() :
 *  unsafe version; only works only if nbBits >= 1 }
function BIT_readBitsFast(bitD:pBIT_DStream_t ; nbBits:uint32 ):PtrUInt;
begin
    result := BIT_lookBitsFast(bitD, nbBits);
    BIT_skipBits(bitD, nbBits);
end;

{! BIT_reloadDStreamFast() :
 *  Similar to BIT_reloadDStream(), but with two differences:
 *  1. bitsConsumed <= sizeof(bitD^.bitContainer)*8 must hold!
 *  2. Returns BIT_DStream_overflow when bitD^.ptr < bitD^.limitPtr, at this
 *     point you must use BIT_reloadDStream() to reload.
 }
function BIT_reloadDStreamFast(bitD:pBIT_DStream_t ):BIT_DStream_status;
begin
    if (bitD^.ptr < bitD^.limitPtr) then
        exit(BIT_DStream_overflow);

    bitD^.ptr :=bitD^.ptr - bitD^.bitsConsumed shr 3;
    bitD^.bitsConsumed :=bitD^.bitsConsumed and 7;
    bitD^.bitContainer := pPtrUInt(bitD^.ptr)^;
    result := BIT_DStream_unfinished;
end;

{! BIT_reloadDStream() :
 *  Refill `bitD` from buffer previously set in BIT_initDStream() .
 *  This function is safe, it guarantees it will not read beyond src buffer.
 * @return : status of `BIT_DStream_t` internal register.
 *           when status == BIT_DStream_unfinished, internal register is filled with at least 25 or 57 bits }
function BIT_reloadDStream(bitD:pBIT_DStream_t ):BIT_DStream_status;
var
  nbBytes:Uint32; 
begin
    if (bitD^.bitsConsumed > (sizeof(bitD^.bitContainer)*8)) then  { overflow detected, like end of stream }
        exit(BIT_DStream_overflow);

    if (bitD^.ptr >= bitD^.limitPtr) then
    begin
        exit(BIT_reloadDStreamFast(bitD));
    end;
    if (bitD^.ptr = bitD^.start) then
    begin
        if (bitD^.bitsConsumed < sizeof(bitD^.bitContainer)*8) then
          exit(BIT_DStream_endOfBuffer);
        exit(BIT_DStream_completed);
    end;
    { start < ptr < limitPtr }

    nbBytes := bitD^.bitsConsumed shr 3;
    result := BIT_DStream_unfinished;
    if (bitD^.ptr - nbBytes < bitD^.start) then
    begin
        nbBytes := Uint32(bitD^.ptr - bitD^.start);  { ptr > start }
        result := BIT_DStream_endOfBuffer;
    end;
    bitD^.ptr :=bitD^.ptr - nbBytes;
    bitD^.bitsConsumed :=bitD^.bitsConsumed - nbBytes*8;
    bitD^.bitContainer := pPtrUInt(bitD^.ptr)^;   { reminder : srcSize > sizeof(bitD^.bitContainer), otherwise bitD^.ptr == bitD^.start }
end;

{! BIT_endOfDStream() :
 * @return : 1 if DStream has _exactly_ reached its end (all bits consumed).
 }
function BIT_endOfDStream(DStream:pBIT_DStream_t):uint32;
begin
  result := ord((DStream^.ptr = DStream^.start) and (DStream^.bitsConsumed = sizeof(DStream^.bitContainer)*8));
end;
end.
