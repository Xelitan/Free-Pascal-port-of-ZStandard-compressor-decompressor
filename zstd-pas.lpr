program zstd-pas;
//ZSTD by Yann Collet/Facebook.
//https://github.com/facebook/zstd
//Free Pascal port by Xelitan
//www.xelitan.com
//License: BSD
//Not yet ported: multi-threaded compression (`zstdmt_compress`), legacy format support
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes
  { you can add units after this },xxhash,error_private,zstd,zstd_internal,zstd_common,entropy_common,algoutil
  ,cover,divsufsort,divsufsortutils,sysutils,zstd_compressf,ZSTD_DECOMPRESSf,huf,zstd_compress_internal,ZstdSimple;

var F: TFileStream;
    Str: String;
begin
  Str := ZStd('Hello World');
  F := TFileStream.Create('test7.zstd', fmCreate);
  F.Write(Str[1], Length(Str));
  F.Free;

  Str := UnZstd(ZStd('Hello World'));
  F := TFileStream.Create('test7.txt', fmCreate);
  F.Write(Str[1], Length(Str));
  F.Free;

  //writeln(stderr, 'sizeof(PtrUInt)=', SizeOf(PtrUInt), ' sizeof(Pointer)=', SizeOf(Pointer), ' sizeof(HUF_CElt)=', SizeOf(HUF_CElt));
  if ParamCount < 3 then
  begin
    writeln('Usage: test <c|d> <infile> <outfile>');
    writeln('  c = compress');
    writeln('  d = decompress');
    Halt(1);
  end;

  if ParamStr(1) = 'c' then
    Halt(compressFile(ParamStr(2), ParamStr(3)))
  else if ParamStr(1) = 'd' then
    Halt(decompressFile(ParamStr(2), ParamStr(3)))
  else
  begin
    writeln(stderr, 'Unknown command: ', ParamStr(1));
    Halt(1);
  end;
end.
