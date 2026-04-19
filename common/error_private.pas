unit error_private;
{$mode objfpc}{$H+}
interface
uses sysutils;
type

  ZSTD_ErrorCode = (
    no_error = 0,
    GENERIC_error  = 1,
    prefix_unknown                = 10,
    version_unsupported           = 12,
    frameParameter_unsupported    = 14,
    frameParameter_windowTooLarge = 16,
    corruption_detected = 20,
    checksum_wrong      = 22,
    dictionary_corrupted      = 30,
    dictionary_wrong          = 32,
    dictionaryCreation_failed = 34,
    parameter_unsupported   = 40,
    parameter_outOfBound    = 42,
    tableLog_tooLarge       = 44,
    maxSymbolValue_tooLarge = 46,
    maxSymbolValue_tooSmall = 48,
    stage_wrong       = 60,
    init_missing      = 62,
    memory_allocation = 64,
    workSpace_tooSmall= 66,
    dstint32ooSmall = 70,
    srcSize_wrong    = 72,
    dstBuffer_nil   = 74,
    { following error codes are __NOT STABLE__, they can be removed or changed in future versions }
    frameIndex_tooLarge = 100,
    seekableIO          = 102,
    dstBuffer_wrong     = 104,
    srcBuffer_wrong     = 105,
    maxCode = 120  { never EVER use this value directly, it can change in future versions! Use ZSTD_isError() instead }
  );
  ERR_enum= ZSTD_ErrorCode ;
  function ERR_getErrorString(code:ERR_enum):string;
  function ERR_getErrorName(code:int32):string;
  function ERR_getErrorCode(code:int32):ERR_enum; 
  function ERR_isError(code:int32):uint32;
  function ERROR(e:ZSTD_ErrorCode):int32;
implementation
function ERROR(e:ZSTD_ErrorCode):int32;
begin
  result := -ord(e);
end;
function ERR_isError(code:int32):uint32;
begin
  result := ord(code < 0);
end;

function ERR_getErrorCode(code:int32):ERR_enum;
begin
  if (code >= 0) then
    result := ERR_enum(0)
  else
    result := ERR_enum(-code);
end;

{ check and forward error code }
//#define CHECK_V_F(e, f) int32 const e = f; if (ERR_isError(e)) return e
//#define CHECK_F(f)   begin CHECK_V_F(_var_err__, f); end;


function ERR_getErrorName(code:int32):string;
begin
    result := ERR_getErrorString(ERR_getErrorCode(code));
end;
function ERR_getErrorString(code:ERR_enum):string;
const
  notErrorCode:string = 'Unspecified error code';
begin 
    case ( code ) of
      no_error: exit('No error detected');
      GENERIC_error:  exit('Error (generic)');
      prefix_unknown: exit('Unknown frame descriptor');
      version_unsupported: exit('Version not supported');
      frameParameter_unsupported: exit('Unsupported frame parameter');
      frameParameter_windowTooLarge: exit('Frame requires too much memory for decoding');
      corruption_detected: exit('Corrupted block detected');
      checksum_wrong: exit('Restored data doesn''t match checksum');
      parameter_unsupported: exit('Unsupported parameter');
      parameter_outOfBound: exit('Parameter is out of bound');
      init_missing: exit('Context should be init first');
      memory_allocation: exit('Allocation error : not enough memory');
      workSpace_tooSmall: exit('workSpace buffer is not large enough');
      stage_wrong: exit('Operation not authorized at current processing stage');
      tableLog_tooLarge: exit('tableLog requires too much memory : unsupported');
      maxSymbolValue_tooLarge: exit('Unsupported max Symbol Value : too large');
      maxSymbolValue_tooSmall: exit('Specified maxSymbolValue is too small');
      dictionary_corrupted: exit('Dictionary is corrupted');
      dictionary_wrong: exit('Dictionary mismatch');
      dictionaryCreation_failed: exit('Cannot create Dictionary from provided samples');
      dstint32ooSmall: exit('Destination buffer is too small');
      srcSize_wrong: exit('Src size is incorrect');
      dstBuffer_nil: exit('Operation on nil destination buffer');
        { following error codes are not stable and may be removed or changed in a future version }
      frameIndex_tooLarge: exit('Frame index is too large');
      seekableIO: exit('An I/O error occurred when reading/seeking');
      dstBuffer_wrong: exit('Destination buffer is wrong');
      srcBuffer_wrong: exit('Source buffer is wrong');
      maxCode:exit( notErrorCode) ;
      else exit( notErrorCode);
    end;
end;
end.
