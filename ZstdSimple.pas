unit ZstdSimple;
//ZSTD by Yann Collet/Facebook.
//https://github.com/facebook/zstd
//Free Pascal port by Xelitan
//www.xelitan.com
//License: BSD
//Not yet ported: multi-threaded compression (`zstdmt_compress`), legacy format support
{$mode objfpc}{$H+}

interface

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, xxhash, error_private, zstd,zstd_internal, zstd_common,
  entropy_common, algoutil, cover, divsufsort, divsufsortutils, sysutils,
  zstd_compressf, ZSTD_DECOMPRESSf, huf, zstd_compress_internal;

function ZStd(const Uncompressed: AnsiString): AnsiString;
function UnZSTD(const Compressed: AnsiString): AnsiString;
function ZstdCompressFile(const infilename,outfilename:string):integer;
function ZstdDecompressFile(const infilename,outfilename:string):integer;

implementation

function ZStd(const Uncompressed: AnsiString): AnsiString;
var Len: Int64;
    ResSize,ResSizeFin: Int32;
    cctx: pZSTD_CCtx;
begin
  Len := Length(Uncompressed);
  ResSize := ZSTD_compressBound(Len);
  SetLength(Result, ResSize);

  try
    cctx := ZSTD_createCCtx();
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1);
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, 1);
    ResSizeFin := ZSTD_compress2(cctx, @Result[1], ResSize, @UnCompressed[1], Len);
  finally
    ZSTD_freeCCtx(cctx);
  end;
  if ZSTD_isError(ResSizeFin)<>0 then Exit('');

  SetLength(Result, ResSizeFin);
end;

function UnZSTD(const Compressed: AnsiString): AnsiString;
var Len: Int64;
    ResLen, ResLenFin: Int32;
begin
  try
    Len := Length(Compressed);

    ResLen := ZSTD_getFrameContentSize(@Compressed[1], Len);

    if ResLen = ZSTD_CONTENTSIZE_ERROR then Exit(''); //not ZSTD
    if ResLen = ZSTD_CONTENTSIZE_UNKNOWN then Exit(''); //orig.size unknown

    SetLength(Result, ResLen);

    ResLenFin := ZSTD_decompress(@Result[1], ResLen, @Compressed[1], Len);
  except
    Exit('');
  end;

  if ZSTD_isError(ResLenFin)<>0 then Exit(''); //ZSTD_getErrorName(ResLenSize));
  SetLength(Result, ResLenFin);
end;

function ZstdCompressFile(const infilename,outfilename:string):integer;
var
  infile,outfile:integer;
  f:file of byte;
  fsize:int64;
  inbuffer,cbuffer:pbyte;
  i:integer;
  cBuffSize,cSize:int32;
  cctx: pZSTD_CCtx;
begin
  result := 0;
  assignfile(f,infilename);
  reset(f);
  fsize:=filesize(f);
  closefile(f);
  inbuffer:=allocmem(fsize);
  try
    infile:=FileOpen(infilename,fmOpenRead);
    if infile=-1 then
      exit(-1);
    i:=FileRead(infile,inbuffer^,fsize);
    fileclose(infile);
    cBuffSize:=ZSTD_compressBound(fsize);
    cbuffer:=allocmem(cBuffSize);
    try
      cctx := ZSTD_createCCtx();
      if cctx = nil then
      begin
        //log(stderr, 'ZSTD_createCCtx failed');
        exit(-3);
      end;
      try
        { enable checksum like the zstd CLI does by default }
        ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1);
        ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, 1);
        cSize := ZSTD_compress2(cctx, cbuffer, cBuffSize, inbuffer, fsize);
      finally
        ZSTD_freeCCtx(cctx);
      end;
      if ZSTD_isError(cSize)<>0 then
      begin
        //log(stderr,'Compression error: ',ZSTD_getErrorName(cSize));
        exit(-3);
      end;
      outfile:=FileCreate(outfilename,fmShareDenyWrite);
      if outfile=-1 then
         exit(-2);
      i:=filewrite(outfile,cbuffer^,cSize);
      fileclose(outfile);
      if i<>cSize then
         exit(-4);
      //log('Compressed: ', fsize, ' -> ', cSize, ' bytes');
    finally
      freemem(cbuffer);
    end;
  finally
    freemem(inbuffer);
  end;
end;

function ZstdDecompressFile(const infilename,outfilename:string):integer;
var
  infile,outfile:integer;
  f:file of byte;
  cSize,rSize:int64;
  inbuffer,rbuffer:pbyte;
  i:integer;
  dSize:int32;
begin
  result := 0;
  assignfile(f,infilename);
  reset(f);
  cSize:=filesize(f);
  closefile(f);
  inbuffer:=allocmem(cSize);
  try
    infile:=FileOpen(infilename,fmOpenRead);
    if infile=-1 then
      exit(-1);
    i:=FileRead(infile,inbuffer^,cSize);
    fileclose(infile);
    rSize:=ZSTD_getFrameContentSize(inbuffer,cSize);
    //writeln(stderr, 'getFrameContentSize returned: ', rSize, ' (cSize=', cSize, ')');
    if rSize = ZSTD_CONTENTSIZE_ERROR then
    begin
      //log(stderr,infilename,' is not compressed by zstd!');
      exit(-5);
    end;
    if rSize = ZSTD_CONTENTSIZE_UNKNOWN then
    begin
      //log(stderr,infilename,' original size unknown!');
      exit(-6);
    end;
    rbuffer:=allocmem(rSize);
    try
      dSize := ZSTD_decompress(rbuffer, rSize, inbuffer, cSize);
      if ZSTD_isError(dSize)<>0 then  { BUG FIX: was checking cSize instead of dSize }
      begin
        //log(stderr,'Decompression error: ',ZSTD_getErrorName(dSize));
        exit(-3);
      end;
      if dSize <> rSize then
      begin
        writeln(stderr,' Impossible because zstd will check this condition!');
        exit(-7);
      end;
      outfile:=FileCreate(outfilename,fmShareDenyWrite);
      if outfile=-1 then
         exit(-2);
      i:=filewrite(outfile,rbuffer^,rSize);
      if i<>rSize then
         exit(-4);
      fileclose(outfile);
      //log('Decompressed: ', cSize, ' -> ', rSize, ' bytes');
    finally
      freemem(rbuffer);
    end;
  finally
    freemem(inbuffer);
  end;
end;


end.
