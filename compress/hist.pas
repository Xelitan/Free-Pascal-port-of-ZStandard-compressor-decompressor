unit hist;
{$mode objfpc}{$H+}
{ --- dependencies --- }
interface
uses sysutils,error_private,zstd;
const
  HIST_WKSP_SIZE_Uint32 = 1024;
  HIST_WKSP_SIZE    = (HIST_WKSP_SIZE_Uint32 * sizeof(int32)) ;
type
  HIST_checkInput_e = ( trustInput, checkMaxSymbolValue );
function HIST_count_wksp(count,maxSymbolValuePtr :puint32;source:pbyte;sourceSize :int32;
  workSpace:pbyte;workSpaceSize :int32):int32;
function HIST_count_simple(count,maxSymbolValuePtr :puint32;
  src:pbyte;srcSize:int32):uint32;
function HIST_countFast_wksp(count,maxSymbolValuePtr :puint32;source:pbyte;sourceSize :int32;
  workSpace:pbyte;workSpaceSize :int32):int32;

implementation
{ --- Error management --- }
function HIST_isError(code:int32):uint32;
begin 
  exit(ERR_isError(code)); 
end;

{-**************************************************************
 *  Histogram functions
 ***************************************************************}
function HIST_count_simple(count,maxSymbolValuePtr :puint32;
  src:pbyte;srcSize:int32):uint32;
var
  ip,lend:pbyte;
  maxSymbolValue,largestCount,s:uint32;
begin
    ip := src;
    lend := ip + srcSize;
    maxSymbolValue := maxSymbolValuePtr^;
    largestCount:=0;

    fillbyte(count^, (maxSymbolValue+1) * sizeof(Uint32), 0);
    if (srcSize=0) then
    begin 
      maxSymbolValuePtr^ := 0; 
      exit(0); 
    end;

    while (ip<lend) do
    begin
      assert( ip^ <= maxSymbolValue);
      inc(count[ip^]);
      inc(ip);
    end;

    while (count[maxSymbolValue]=0) do
      dec(maxSymbolValue);
    maxSymbolValuePtr^ := maxSymbolValue;

    
    for s:=0 to maxSymbolValue do
        if (count[s] > largestCount) then
          largestCount := count[s];

    exit(largestCount);
end;



{ HIST_count_parallel_wksp() :
 * store histogram into 4 intermediate tables, recombined at the end.
 * this design makes better use of OoO cpus,
 * and is noticeably faster when some values are heavily repeated.
 * But it needs some additional workspace for intermediate tables.
 * `workSpace` must be a Uint32 table of size >= HIST_WKSP_SIZE_Uint32.
 * @return : largest histogram frequency,
 *           or an error code (notably when histogram's alphabet is larger than *maxSymbolValuePtr) }
function HIST_count_parallel_wksp(count,maxSymbolValuePtr :puint32;
  source:pbyte;sourceSize :int32;check:HIST_checkInput_e;workSpace:puint32):int32;
var
  ip,iend:pbyte;
  countSize:int32;
  max:uint32;
  Counting1,Counting2,Counting3,Counting4:puint32;
  cached,c,s,maxSymbolValue:Uint32;
begin
    ip := source;
    iend := ip+sourceSize;
    countSize := (maxSymbolValuePtr^ + 1) * sizeof(uint32);
    max:=0;
    Counting1 := workSpace;
    Counting2 := Counting1 + 256;
    Counting3 := Counting2 + 256;
    Counting4 := Counting3 + 256;

    { safety checks }
    assert(maxSymbolValuePtr^ <= 255);
    if (sourceSize=0) then
    begin
        fillbyte(count^, countSize, 0);
        maxSymbolValuePtr^ := 0;
        exit(0);
    end;
    fillbyte(workSpace^, 4*256*sizeof(Uint32), 0);

    { by stripes of 16 bytes } 
    cached := MEM_read32(ip); 
    ip :=ip + 4;
    while (ip < iend-15) do
    begin
        c := cached; 
        cached := MEM_read32(ip); 
        ip :=ip + 4;
        inc(Counting1[BYTE(c)     ]);
        inc(Counting2[BYTE(c shr 8) ]);
        inc(Counting3[BYTE(c shr 16)]);
        inc(Counting4[       c shr 24 ]);
        c := cached; 
        cached := MEM_read32(ip); 
        ip :=ip + 4;
        inc(Counting1[BYTE(c)    ]);
        inc(Counting2[BYTE(c shr 8) ]);
        inc(Counting3[BYTE(c shr 16)]);
        inc(Counting4[       c shr 24 ]);
        c := cached; 
        cached := MEM_read32(ip); 
        ip :=ip + 4;
        inc(Counting1[BYTE(c)    ]);
        inc(Counting2[BYTE(c shr 8) ]);
        inc(Counting3[BYTE(c shr 16)]);
        inc(Counting4[       c shr 24 ]);
        c := cached; 
        cached := MEM_read32(ip); 
        ip :=ip + 4;
        inc(Counting1[BYTE(c)    ]);
        inc(Counting2[BYTE(c shr 8) ]);
        inc(Counting3[BYTE(c shr 16)]);
        inc(Counting4[       c shr 24 ]);
    end;
    ip:=ip-4;

    { finish last symbols }
    while (ip<iend) do
    begin
      inc(Counting1[ip^]);
      inc(ip)
    end;

    for s:=0 to 255 do 
    begin
        Counting1[s] :=Counting1[s] + Counting2[s] + Counting3[s] + Counting4[s];
        if (Counting1[s] > max) then
          max := Counting1[s];
    end;

     
    maxSymbolValue := 255;
    while (Counting1[maxSymbolValue]=0) do
      dec(maxSymbolValue);
    if (ord(check)<>0) and (maxSymbolValue > maxSymbolValuePtr^) then
      exit(ERROR(maxSymbolValue_tooSmall));
    maxSymbolValuePtr^ := maxSymbolValue;
    move(Counting1[0],count[0],  countSize);   { in case count  and  Counting1 are overlapping }
    result := max;
end;

{ HIST_countFast_wksp() :
 * Same as HIST_countFast(), but using an externally provided scratch buffer.
 * `workSpace` is a writable buffer which must be 4-bytes aligned,
 * `workSpaceSize` must be >= HIST_WKSP_SIZE
 }
function HIST_countFast_wksp(count,maxSymbolValuePtr :puint32;source:pbyte;sourceSize :int32;
  workSpace:pbyte;workSpaceSize :int32):int32;
begin
    if (sourceSize < 1500) then{ heuristic threshold }
        exit(HIST_count_simple(count, maxSymbolValuePtr, source, sourceSize));
    if (int32(workSpace)  and  3)<>0 then
      exit(ERROR(GENERIC_ERROR));  { must be aligned on 4-bytes boundaries }
    if (workSpaceSize < HIST_WKSP_SIZE) then
      exit(ERROR(workSpace_tooSmall));
    result := HIST_count_parallel_wksp(count, maxSymbolValuePtr, source, sourceSize, trustInput, pUint32(workSpace));
end;

{ HIST_count_wksp() :
 * Same as HIST_count(), but using an externally provided scratch buffer.
 * `workSpace` size must be table of >= HIST_WKSP_SIZE_Uint32 unsigned }
function HIST_count_wksp(count,maxSymbolValuePtr :puint32;source:pbyte;sourceSize :int32;
  workSpace:pbyte;workSpaceSize :int32):int32;
begin
    if (int32(workSpace)  and  3)<>0 then
      exit(ERROR(GENERIC_ERROR));  { must be aligned on 4-bytes boundaries }
    if (workSpaceSize < HIST_WKSP_SIZE) then
      exit(ERROR(workSpace_tooSmall));
    if (maxSymbolValuePtr^< 255) then
        exit(HIST_count_parallel_wksp(count, maxSymbolValuePtr, source, sourceSize, checkMaxSymbolValue, pUint32(workSpace)));
    maxSymbolValuePtr^:= 255;
    result := HIST_countFast_wksp(count, maxSymbolValuePtr, source, sourceSize, workSpace, workSpaceSize);
end;

{ fast variant (unsafe : won't check if src contains values beyond count[] limit) }
function HIST_countFast(count,maxSymbolValuePtr :puint32;source:pbyte;sourceSize :int32):int32;
var
  tmpCounters:array [0..HIST_WKSP_SIZE_Uint32] of uint32;
begin
    result := HIST_countFast_wksp(count, maxSymbolValuePtr, source, sourceSize, @tmpCounters[0], sizeof(tmpCounters));
end;

function HIST_count(count,maxSymbolValuePtr:puint32;src:pbyte;srcSize :int32):int32;
var
  tmpCounters:array [0..HIST_WKSP_SIZE_Uint32] of uint32;
begin
    result := HIST_count_wksp(count, maxSymbolValuePtr, src, srcSize, @tmpCounters[0], sizeof(tmpCounters));
end;
end.
