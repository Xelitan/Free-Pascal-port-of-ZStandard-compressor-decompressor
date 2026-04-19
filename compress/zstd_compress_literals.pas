unit ZSTD_COMPRESS_LITERALS;
{$mode objfpc}{$H+}
interface
uses error_private,zstd_internal,zstd,ZSTD_COMPRESS_internal,huf,huf_compress;
const
  COMPRESS_LITERALS_SIZE_MIN =63;
function ZSTD_noCompressLiterals (dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
function ZSTD_compressLiterals (prevHuf:pZSTD_hufCTables_t;
  nextHuf:pZSTD_hufCTables_t;strategy:ZSTD_strategy; disableLiteralCompression:int32;
  dst:pbyte; dstCapacity:int32;src:pbyte; srcSize:int32;
  entropyWorkspace:pbyte; entropyWorkspaceSize,bmi2:int32):int32;
function ZSTD_compressRleLiteralsBlock (dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
implementation
function ZSTD_noCompressLiterals (dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
var
  ostart:pbyte;
  flSize:Uint32;
begin
    ostart := dst;
    flSize := 1 + ord((srcSize>31)) + ord(srcSize>4095);

    if (srcSize + flSize > dstCapacity) then
       exit(ERROR(dstint32ooSmall));//, '');

    case (flSize) of
         1: { 2 - 1 - 5 }
            ostart[0] := BYTE(Uint32(symbolEncodingType_e.set_basic) + (srcSize shl 3));
         2: { 2 - 2 - 12 }
            MEM_writeLE16(ostart, Uint16(Uint32(symbolEncodingType_e.set_basic) + (1 shl 2) + (srcSize shl 4)));

         3: { 2 - 2 - 20 }
            MEM_writeLE32(ostart, Uint32(Uint32(symbolEncodingType_e.set_basic) + (3 shl 2) + (srcSize shl 4)));

          else   { not necessary : flSize is begin1,2,3end; }
            assert(false);
    end;

    move(src[0],ostart[flSize],  srcSize);
    ////log(3, 'Raw literals: %u ^. %u', Uint32(srcSize), Uint32(srcSize + flSize));
    result := srcSize + flSize;
end;

function ZSTD_compressRleLiteralsBlock (dst:pbyte; dstCapacity:int32; src:pbyte; srcSize:int32):int32;
var
  ostart:pbyte;
  flSize:Uint32;
begin
    ostart := dst;
    flSize := 1 + ord(srcSize>31) + ord(srcSize>4095);

    case(flSize) of
         1: { 2 - 1 - 5 }
            ostart[0] := BYTE(Uint32(set_rle) + (srcSize shl 3));

         2: { 2 - 2 - 12 }
            MEM_writeLE16(ostart, Uint16(Uint32(set_rle) + (1 shl 2) + (srcSize shl 4)));

         3: { 2 - 2 - 20 }
            MEM_writeLE32(ostart, Uint32(Uint32(set_rle) + (3 shl 2) + (srcSize shl 4)));

         else   { not necessary : flSize is begin1,2,3end; }
            assert(false);
    end;

    ostart[flSize] := src^;
    ////log(3, 'RLE literals: %u ^. %u', Uint32(srcSize), Uint32(flSize) + 1);
    result := flSize+1;
end;

function ZSTD_compressLiterals (prevHuf:pZSTD_hufCTables_t;
  nextHuf:pZSTD_hufCTables_t;strategy:ZSTD_strategy; disableLiteralCompression:int32;
  dst:pbyte; dstCapacity:int32;src:pbyte; srcSize:int32;
  entropyWorkspace:pbyte; entropyWorkspaceSize,bmi2:int32):int32;
var
  minGain,lhSize,cLitSize,minLitSize,preferRepeat:int32;
  ostart:pbyte;
  singleStream,lhc:Uint32;
  hType:symbolEncodingType_e;
  lrepeat:HUF_repeat;
begin
    minGain := ZSTD_minGain(srcSize, strategy);
    lhSize := 3 + ord(srcSize >= 1024) + ord(srcSize >= 16*1024);
    ostart := dst;
    singleStream := ord(srcSize < 256);
    hType := set_compressed;

    //log(3,'ZSTD_compressLiterals (disableLiteralCompression:=%i srcSize:=%u)',
    //            disableLiteralCompression, Uint32(srcSize));

    { Prepare nextEntropy assuming reusing the existing table }
    move(prevHuf^,nextHuf^,  sizeof(ZSTD_hufCTables_t));

    if (disableLiteralCompression<>0) then
        exit(ZSTD_noCompressLiterals(dst, dstCapacity, src, srcSize));

    { small ? don't even attempt compression (speed opt) }
    if (prevHuf^.repeatMode = HUF_repeat_valid) then
      minLitSize := 6
    else
      minLitSize := COMPRESS_LITERALS_SIZE_MIN;
    if (srcSize <= minLitSize) then
      exit(ZSTD_noCompressLiterals(dst, dstCapacity, src, srcSize));
    

    if (dstCapacity < lhSize+1) then
      exit(ERROR(dstint32ooSmall));// 'not enough space for compression');
    lrepeat := prevHuf^.repeatMode;
    if strategy < ZSTD_lazy then
      preferRepeat := ord(srcSize <= 1024)
    else
      preferRepeat :=  0;
    if (lrepeat = HUF_repeat_valid) and (lhSize = 3) then
      singleStream := 1;
    if singleStream<>0 then
      cLitSize := HUF_compress1X_repeat(
            ostart+lhSize, dstCapacity-lhSize, src, srcSize,
            HUF_SYMBOLVALUE_MAX, HUF_TABLELOG_DEFAULT, entropyWorkspace, entropyWorkspaceSize,
            pHUF_CElt(nextHuf^.CTable),  @lrepeat, preferRepeat, bmi2)
    else
        cLitSize := HUF_compress4X_repeat(
            ostart+lhSize, dstCapacity-lhSize, src, srcSize,
            HUF_SYMBOLVALUE_MAX, HUF_TABLELOG_DEFAULT, entropyWorkspace, entropyWorkspaceSize,
            pHUF_CElt(nextHuf^.CTable),  @lrepeat, preferRepeat, bmi2);
    if (lrepeat <> HUF_repeat_none) then
    begin
        { reused the existing table }
        //log(3, 'Reusing previous huffman table');
        hType := set_repeat;
    end;

    if (cLitSize=0)  or  (cLitSize >= srcSize - minGain)  or  (ERR_isError(cLitSize)<>0) then
    begin
        move(prevHuf^, nextHuf^, sizeof(ZSTD_hufCTables_t));
        exit(ZSTD_noCompressLiterals(dst, dstCapacity, src, srcSize));
    end;
    if (cLitSize=1) then
    begin
        move(prevHuf^, nextHuf^,  sizeof(ZSTD_hufCTables_t));
        exit(ZSTD_compressRleLiteralsBlock(dst, dstCapacity, src, srcSize));
    end;

    if (hType = set_compressed) then
    begin
        { using a newly constructed table }
        nextHuf^.repeatMode := HUF_repeat_check;
    end;

    { Build header }
    case (lhSize) of
     3: { 2 - 2 - 10 - 10 }
        begin 
          lhc := ord(hType) + (ord(singleStream = 0)  shl  2) + (Uint32(srcSize) shl 4) + (Uint32(cLitSize) shl 14);
          MEM_writeLE24(ostart, lhc);
        end;
     4: { 2 - 2 - 14 - 14 }
        begin 
          lhc := ord(hType) + (2  shl  2) + (Uint32(srcSize) shl 4) + (Uint32(cLitSize) shl 18);
          MEM_writeLE32(ostart, lhc);
        end;
     5: { 2 - 2 - 18 - 18 }
        begin
          lhc := ord(hType) + (3  shl  2) + (Uint32(srcSize) shl 4) + (Uint32(cLitSize) shl 22);
          MEM_writeLE32(ostart, lhc);
          ostart[4] := BYTE(cLitSize  shr  10);
        end;
      else  { not possible : lhSize is begin3,4,5end; }
        assert(false);
    end;
    //log(3, 'Compressed literals: %u ^. %u', Uint32(srcSize), (lhSize+cLitSize));
    result := lhSize+cLitSize;
end;
end.
