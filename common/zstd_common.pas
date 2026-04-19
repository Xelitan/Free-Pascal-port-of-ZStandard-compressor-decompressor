unit zstd_common;
{$mode objfpc}{$H+}
interface
{-*************************************
*  Dependencies
**************************************}
uses
error_private,zstd,
zstd_internal;

procedure ZSTD_customfree(ptr:pbyte;customMem:ZSTD_customMem);
function ZSTD_customMalloc(size:int32;customMem:ZSTD_customMem):pbyte;
function ZSTD_customCalloc(size:int32;customMem:ZSTD_customMem):pbyte;
function ZSTD_isError(code:int32):uint32;
function ZSTD_getErrorName(code:int32):string;
function ZSTD_getErrorCode(code:int32) :ZSTD_ErrorCode;
implementation
{-****************************************
*  ZSTD Error Management
*****************************************}
{! ZSTD_isError() :
 *  tells if a return value is an error code
 *  symbol is required for external callers }
function ZSTD_isError(code:int32):uint32;
begin 
  result:= ERR_isError(code); 
end;

{! ZSTD_getErrorName() :
 *  provides error code string from function result (useful for debugging) }
function ZSTD_getErrorName(code:int32):string;
begin 
  result:= ERR_getErrorName(code); 
end;

{! ZSTD_getError() :
 *  convert a `int32` function result into a proper ZSTD_errorCode enum }
function ZSTD_getErrorCode(code:int32) :ZSTD_ErrorCode;
begin 
  result:= ERR_getErrorCode(code); 
end;

{! ZSTD_getErrorString() :
 *  provides error code string from enum }
function ZSTD_getErrorString(code:ZSTD_ErrorCode ):string;
begin 
  result:= ERR_getErrorString(code); 
end;



{=**************************************************************
*  Custom allocator
***************************************************************}
function ZSTD_customMalloc(size:int32;customMem:ZSTD_customMem):pbyte;
begin
    if (customMem.customAlloc<>nil) then
        exit(customMem.customAlloc(customMem.opaque, size));
    result:= allocmem(size);
end;

function ZSTD_customCalloc(size:int32;customMem:ZSTD_customMem):pbyte;
var
  ptr:pbyte;
begin
    if (customMem.customAlloc<>nil) then
    begin
        { calloc implemented as malloc+memset;
         * not as efficient as calloc, but next best guess for custom malloc }
        ptr := customMem.customAlloc(customMem.opaque, size);
        fillbyte(ptr^, size, 0);
        exit(ptr);
    end;
    result:= allocmem(size);
end;

procedure ZSTD_customfree(ptr:pbyte;customMem:ZSTD_customMem);
begin
    if (ptr<>nil) then
    begin
        if (customMem.customFree<>nil) then
            customMem.customfree(customMem.opaque, ptr)
        else
            freemem(ptr);
    end;
end;
end.
