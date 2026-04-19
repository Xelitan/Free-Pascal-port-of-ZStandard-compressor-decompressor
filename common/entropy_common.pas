unit entropy_common;
{$mode objfpc}{$H+}
interface
uses error_private,       { ERR_*, ERROR }  
    fse,{ FSE_MIN_TABLELOG }  
    huf,{ HUF_TABLELOG_ABSOLUTEMAX }
    sysutils,zstd,bitstream,fse_decompress;
function FSE_versionNumber():uint32;
function FSE_isError(code:int32 ):uint32;
function FSE_getErrorName(code:int32 ):string;
function HUF_isError(code:int32 ):uint32;
function HUF_getErrorName(code:int32 ):string;
function FSE_ctz(val:Uint32 ):Uint32;
function FSE_readNCount(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize:int32):int32;
function FSE_readNCount_bmi2(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize,bmi2:int32):int32;
function FSE_readNCount_body(normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
                           headerBuffer:pbyte;  hbSize:int32):int32;
function HUF_readStats(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;srcSize:int32 ):int32;
function HUF_readStats_body(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                   nbSymbolsPtr, tableLogPtr:pUint32;
                   src:pbyte;  srcSize:int32;
                   workSpace:pbyte;  wkspSize,bmi2:int32):int32;
function HUF_readStats_body_default(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize:int32):int32;
function HUF_readStats_body_bmi2(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize:int32):int32;
function HUF_readStats_wksp(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize,bmi2:int32):int32;

implementation
{===   Version   ===}
function FSE_versionNumber():uint32;
begin 
  result := 1;
end;


{===   Error Management   ===}
function FSE_isError(code:int32 ):uint32; 
begin 
  result :=  ERR_isError(code); 
end;
function FSE_getErrorName(code:int32 ):string;
begin 
  result := ERR_getErrorName(code); 
end;

function HUF_isError(code:int32 ):uint32; 
begin 
  result := ERR_isError(code); 
end;
function HUF_getErrorName(code:int32 ):string; 
begin 
  result :=  ERR_getErrorName(code); 
end;


{-**************************************************************
*  FSE NCount encoding-decoding
***************************************************************}
function  FSE_ctz(val:Uint32 ):Uint32;
begin
  { Software version }
  result := 0;
  while ((val  and  1) = 0) do
  begin
      val :=val  shr  1;
      inc(result);
  end;
end;

function FSE_readNCount_body(normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
                           headerBuffer:pbyte;  hbSize:int32):int32;
var
  istart,iend,ip:pbyte;
  nbBits,remaining,threshold,bitCount,previous0:integer;
  bitStream,bytenum,maxSV1,charnum:Uint32;
  buffer:array [0..7] of byte;
  countSize:int32;
  repeats,lmax,count:integer;
begin
    istart := pbyte(headerBuffer);
    iend   := istart + hbSize;
    ip     := istart;
    bytenum := 0;
    charnum := 0;
    maxSV1 := maxSVPtr^ + 1;
    previous0 := 0;

    if (hbSize < 8) then
    begin
        { This function only works when hbSize >= 8 }
        fillbyte(buffer,8,0);
        move(headerBuffer^,buffer,  hbSize);
        begin   
          countSize := FSE_readNCount(normalizedCounter, maxSVPtr, tableLogPtr,buffer, sizeof(buffer));
          if (FSE_isError(countSize)<>0) then
            exit(countSize);
          if (countSize > hbSize) then
            exit(ERROR(corruption_detected));
          exit(countSize);
        end;
    end;

    { init }
    fillbyte(normalizedCounter^, ( maxSVPtr^+1) * sizeof(normalizedCounter[0]), 0);   { all symbols not present in NCount have a frequency of 0 }
    bitStream := puint32(ip)^;
    nbBits := (bitStream  and  $F) + FSE_MIN_TABLELOG;   { extract tableLog }
    if (nbBits > FSE_TABLELOG_ABSOLUTE_MAX) then
      exit(ERROR(tableLog_tooLarge));
    bitStream :=bitStream  shr  4;
    bitCount := 4;
    tableLogPtr^ := nbBits;
    remaining := (1 shl nbBits)+1;
    threshold := 1 shl nbBits;
    inc(nbBits);

    while true do
    begin
        if (previous0<>0) then
        begin
            { Count the number of repeats. Each time the
             * 2-bit repeat code is 0b11 there is another
             * repeat.
             * Avoid UB by setting the high bit to 1.
             }
            repeats := FSE_ctz(not bitStream  or  $80000000)  shr  1;
            while (repeats >= 12) do
            begin
                charnum :=charnum + 3 * 12;
                if (ip <= iend-7) then
                begin
                  ip :=ip + 3;
                end 
                else 
                begin
                  bitCount :=bitCount - integer(8 * (iend - 7 - ip));
                  bitCount :=bitCount  and 31;
                  ip       := iend - 4;
                end;
                bitStream := puint32(ip)^  shr  bitCount;
                repeats   := FSE_ctz(not bitStream  or  $80000000)  shr  1;
            end;
            charnum :=charnum + 3 * repeats;
            bitStream  :=bitStream  shr  (2 * repeats);
            bitCount :=bitCount + 2 * repeats;

            { Add the final repeat which isn't 0b11. }
            charnum :=charnum + bitStream  and  3;
            bitCount :=bitCount + 2;

            { This is an error, but break and return an error
             * at the end, because returning out of a loop makes
             * it harder for the compiler to optimize.
             }
            if (charnum >= maxSV1) then
              break;

            { We don't need to set the normalized count to 0
             * because we already memset the whole buffer to 0.
             }

            if ((ip <= iend-7)  or  (ip + (bitCount shr 3) <= iend-4)) then
            begin
                ip :=ip + bitCount shr 3;
                bitCount :=bitCount  and  7;
            end 
            else 
            begin
                bitCount :=bitCount - integer(8 * (iend - 4 - ip));
                bitCount :=bitCount  and  31;
                ip := iend - 4;
            end;
            bitStream := puint32(ip)^  shr  bitCount;
        end;

    lmax := (2*threshold-1) - remaining;

    if ((bitStream  and  (threshold-1)) < Uint32(lmax)) then
    begin
        count := bitStream  and  (threshold-1);
        bitCount :=bitCount + nbBits-1;
    end
    else
    begin
        count := bitStream  and  (2*threshold-1);
        if (count >= threshold) then
          count :=count - lmax;
        bitCount :=bitCount + nbBits;
    end;

    dec(count);   { extra accuracy }
    { When it matters (small blocks), this is a
     * predictable branch, because we don't use -1.
     }
    if (count >= 0) then
    begin
      remaining :=remaining - count;
    end
    else
    begin
      remaining :=remaining + count;
    end;
    normalizedCounter[charnum] := int16(count);
    inc(charnum);
    previous0 := ord(count = 0);

    if (remaining < threshold) then
    begin
        { This branch can be folded into the
         * threshold update condition because we
         * know that threshold > 1.
         }
        if (remaining <= 1) then
          break;
        nbBits := BIT_highbit32(remaining) + 1;
        threshold := 1  shl  (nbBits - 1);
    end;
    if (charnum >= maxSV1) then
      break;

    if ((ip <= iend-7)  or  (ip + (bitCount shr 3) <= iend-4)) then
    begin
        ip :=ip + bitCount shr 3;
        bitCount :=bitCount  and  7;
    end
    else
    begin
        bitCount :=bitCount - integer(8 * (iend - 4 - ip));
        bitCount :=bitCount  and  31;
        ip := iend - 4;
    end;
    bitStream := MEM_readLE32(ip)  shr  bitCount;
    end;
    if (remaining <> 1) then
      exit(ERROR(corruption_detected));
    { Only possible when there are too many zeros. }
    if (charnum > maxSV1) then
      exit(ERROR(maxSymbolValue_tooSmall));
    if (bitCount > 32) then
      exit(ERROR(corruption_detected));
    maxSVPtr^ := charnum-1;

    ip :=ip + (bitCount+7) shr 3;
    result := ip-istart;
end;

{ Avoids the FORCE_INLINE of the _body() function. }
function  FSE_readNCount_body_default(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize:int32):int32;
begin
    result := FSE_readNCount_body(normalizedCounter, maxSVPtr, tableLogPtr, headerBuffer, hbSize);
end;

function FSE_readNCount_body_bmi2(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize:int32):int32;
begin
    result := FSE_readNCount_body(normalizedCounter, maxSVPtr, tableLogPtr, headerBuffer, hbSize);
end;


function FSE_readNCount_bmi2(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize,bmi2:int32):int32;
begin
  result :=  FSE_readNCount_body_bmi2(normalizedCounter, maxSVPtr, tableLogPtr, headerBuffer, hbSize);
end;

function FSE_readNCount(
        normalizedCounter:pint16; maxSVPtr, tableLogPtr:puint32;
        headerBuffer:pbyte;  hbSize:int32):int32;
begin
    result :=  FSE_readNCount_bmi2(normalizedCounter, maxSVPtr, tableLogPtr, headerBuffer, hbSize, { bmi2 } 0);
end;


{! HUF_readStats() :
    Read compact Huffman tree, saved by HUF_writeCTable().
    `huffWeight` is destination buffer.
    `rankStats` is assumed to be a table of at least HUF_TABLELOG_MAX Uint32.
    @return : size read from `src` , or an error Code .
    Note : Needed by HUF_readCTable() and HUF_readDTableX?() .
}
function HUF_readStats(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;srcSize:int32 ):int32;
var
  //wksp:array [0..HUF_READ_STATS_WORKSPACE_SIZE_Uint32-1] of Uint32;
  wksp:pbyte;
begin
  wksp:=allocmem(HUF_READ_STATS_WORKSPACE_SIZE_Uint32*sizeof(Uint32));
  result :=  HUF_readStats_wksp(huffWeight, hwSize, rankStats, nbSymbolsPtr, tableLogPtr, src, srcSize, wksp, HUF_READ_STATS_WORKSPACE_SIZE_Uint32*sizeof(Uint32), { bmi2 } 0);
  freemem(wksp);
end;

function HUF_readStats_body(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                   nbSymbolsPtr, tableLogPtr:pUint32;
                   src:pbyte;  srcSize:int32;
                   workSpace:pbyte;  wkspSize,bmi2:int32):int32;
var
  total,rest,verif,lastWeight,weightTotal,n,tableLog:Uint32;
  iSize,oSize:int32;
  ip:pbyte;
begin
    ip := src;

    if (srcSize=0) then
      exit(ERROR(srcSize_wrong));
    iSize := ip[0];
    { ZSTD_memset(huffWeight, 0, hwSize);   }{ is not necessary, even though some analyzer complain ... }

    if (iSize >= 128) then
    begin  { special header }
      oSize := iSize - 127;
      iSize := ((oSize+1) div 2);
      if (iSize+1 > srcSize) then 
        exit(ERROR(srcSize_wrong));
      if (oSize >= hwSize) then 
        exit(ERROR(corruption_detected));
      ip :=ip + 1;
      n:=0;
      while  n<oSize do
      begin
        huffWeight[n]   := ip[n div 2]  shr  4;
        huffWeight[n+1] := ip[n div 2]  and  15;
        n:=n+2;
      end;
    end
    else  
    begin   { header compressed with FSE (normal case) }
      if (iSize+1 > srcSize) then
        exit( ERROR(srcSize_wrong));
      { max (hwSize-1) values decoded, as last one is implied }
      oSize := FSE_decompress_wksp_bmi2(huffWeight, hwSize-1, ip+1, iSize, 6, workSpace, wkspSize, bmi2);
      if (FSE_isError(oSize)<>0) then
        exit( oSize);
    end;

    { collect weight stats }
    fillbyte(rankStats^, (HUF_TABLELOG_MAX + 1) * sizeof(Uint32), 0);
    weightTotal := 0;
 
    for n:=0 to oSize -1 do
    begin
      if (huffWeight[n] >= HUF_TABLELOG_MAX) then
        exit(ERROR(corruption_detected));
      inc(rankStats[huffWeight[n]]);
      weightTotal :=weightTotal + (1  shl  huffWeight[n])  shr  1;
    end;   

    if (weightTotal = 0) then
      exit(ERROR(corruption_detected));

    { get last non-nil symbol weight (implied, total must be 2^n) }   
    tableLog := BIT_highbit32(weightTotal) + 1;
    if (tableLog > HUF_TABLELOG_MAX) then
      exit(ERROR(corruption_detected));
    
    tableLogPtr^ := tableLog;
    { determine last weight }
    total := 1  shl  tableLog;
    rest  := total - weightTotal;
    verif := 1  shl  BIT_highbit32(rest);
    lastWeight := BIT_highbit32(rest) + 1;
    if (verif <> rest) then
      exit(ERROR(corruption_detected));    { last value must be a clean power of 2 }
    huffWeight[oSize] := BYTE(lastWeight);
    inc(rankStats[lastWeight]);

    { check tree construction validity }
    if ((rankStats[1] < 2)  or  ((rankStats[1]  and  1)<>0)) then
      exit(ERROR(corruption_detected));   { by construction : at least 2 elts of rank 1, must be even }

    { results }
    nbSymbolsPtr^ := Uint32(oSize+1);
    result := iSize+1;
end;

{ Avoids the FORCE_INLINE of the _body() function. }
function HUF_readStats_body_default(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize:int32):int32;
begin
  result :=  HUF_readStats_body(huffWeight, hwSize, rankStats, nbSymbolsPtr, tableLogPtr, src, srcSize, workSpace, wkspSize, 0);
end;


function HUF_readStats_body_bmi2(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize:int32):int32;
begin
  result := HUF_readStats_body(huffWeight, hwSize, rankStats, nbSymbolsPtr, tableLogPtr, src, srcSize, workSpace, wkspSize, 1);
end;


function HUF_readStats_wksp(huffWeight:pbyte;  hwSize:int32; rankStats:pUint32;
                     nbSymbolsPtr, tableLogPtr:pUint32;
                     src:pbyte;  srcSize:int32;
                     workSpace:pbyte;  wkspSize,bmi2:int32):int32;
begin
    { bmi2 variant is identical to default - always use default }
    result := HUF_readStats_body_bmi2(huffWeight, hwSize, rankStats, nbSymbolsPtr, tableLogPtr, src, srcSize, workSpace, wkspSize);
end;
end.
