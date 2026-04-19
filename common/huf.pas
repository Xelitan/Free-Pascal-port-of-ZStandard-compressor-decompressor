unit huf;
{$mode objfpc}{$H+}
interface
uses sysutils,fse;
const
  HUF_BLOCKSIZE_MAX =(128 * 1024);
  HUF_WORKSPACE_SIZE =((6  shl  10) + 256);
  HUF_WORKSPACE_SIZE_Uint32 =(HUF_WORKSPACE_SIZE / sizeof(Uint32));
  HUF_WORKSPACE_SIZE_Uint32_1 = 1599;
  HUF_TABLELOG_MAX          = 12;      { max runtime value of tableLog (due to static allocation); can be modified up to HUF_ABSOLUTEMAX_TABLELOG }
  HUF_TABLELOG_DEFAULT      = 11;      { default tableLog value when none specified }
  HUF_SYMBOLVALUE_MAX       =255;
  HUF_TABLELOG_ABSOLUTEMAX  = 15;  { absolute limit of HUF_MAX_TABLELOG. Beyond that value, code does not work }
  { HUF buffer bounds }
  HUF_CTABLEBOUND =129;

  {$DEFINE HUF_BLOCKBOUND(size) (size + (size shr 8) + 8)}   { only true when incompressible is pre-filtered with fast heuristic }
  {$DEFINE HUF_COMPRESSBOUND(size) (HUF_CTABLEBOUND + HUF_BLOCKBOUND(size))}   { Macro version, useful for static allocation }

{ static allocation of HUF's Compression Table }

{$define HUF_CTABLE_SIZE_Uint32(maxSymbolValue)   ((maxSymbolValue)+1)}   { Use tables of Uint32, for proper alignment }
{$define HUF_CTABLE_SIZE(maxSymbolValue)       (HUF_CTABLE_SIZE_Uint32(maxSymbolValue) * sizeof(Uint32))}
{$define HUF_CREATE_STATIC_CTABLE(name, maxSymbolValue) HUF_CElt name[HUF_CTABLE_SIZE_Uint32(maxSymbolValue)]} { no final ; }

{ static allocation of HUF's DTable }
{$define HUF_DTABLE_SIZE(maxTableLog)   (1 + (1 shl (maxTableLog)))}
{$define HUF_CREATE_STATIC_DTABLEX1(DTable, maxTableLog) HUF_DTable DTable[HUF_DTABLE_SIZE((maxTableLog)-1)] = begin ((Uint32)((maxTableLog)-1) * $01000001) end;}
{$define HUF_CREATE_STATIC_DTABLEX2(DTable, maxTableLog) HUF_DTable DTable[HUF_DTABLE_SIZE(maxTableLog)] = begin ((Uint32)(maxTableLog) * $01000001) end;}
{* HUF_buildCTable_wksp() :
 *  Same as HUF_buildCTable(), but using externally allocated scratch buffer.
 * `workSpace` must be aligned on 4-bytes boundaries, and its size must be >= HUF_CTABLE_WORKSPACE_SIZE.
 }
HUF_CTABLE_WORKSPACE_SIZE_Uint32 = (2*HUF_SYMBOLVALUE_MAX +1 +1);
HUF_CTABLE_WORKSPACE_SIZE = (HUF_CTABLE_WORKSPACE_SIZE_Uint32 * 4);
type
  HUF_DTable=Uint32;
  { this is a private definition, just exposed for allocation and strict aliasing purpose. never EVER access its members directly }
  pHUF_CElt=^HUF_CElt;
  HUF_CElt=packed record
    val:Word;
    nbBits:byte;
    pad:byte;     { padding to match C sizeof(HUF_CElt)=4 }
  end;   { typedef'd to HUF_CElt, must be 4 bytes }
  pHUF_repeat=^HUF_repeat;
  HUF_repeat=(
     HUF_repeat_none,  {*< Cannot use the previous table }
     HUF_repeat_check, {*< Can use the previous table but it must be checked. Note : The previous table must have been constructed by HUF_compressbegin1, 4end;X_repeat }
     HUF_repeat_valid  {*< Can use the previous table and it is assumed to be valid }
  ); 
function HUF_READ_STATS_WORKSPACE_SIZE_Uint32:int32;
function HUF_READ_STATS_WORKSPACE_SIZE:int32;
implementation
function HUF_READ_STATS_WORKSPACE_SIZE_Uint32:int32;
begin
  result := FSE_DECOMPRESS_WKSP_SIZE_Uint32(6, HUF_TABLELOG_MAX-1);
end;
function HUF_READ_STATS_WORKSPACE_SIZE:int32;
begin
  result := (HUF_READ_STATS_WORKSPACE_SIZE_Uint32 * sizeof(uint32));
 end;  
end.
