unit zdict;
{$mode objfpc}{$H+}
interface
uses fse,           { FSE_normalizeCount, FSE_writeNCount }
    huf,           { HUF_buildCTable, HUF_writeCTable }
    zstd_internal, { includes zstd.h }
    xxhash,        { XXH64 }
    zstd,math,
    zstd_compress_internal; { ZSTD_loadCEntropy() }

const
{-**************************************
*  Tuning parameters
***************************************}
  ZDICT_CONTENTSIZE_MIN = 128;
  MINRATIO= 4;   { minimum nb of apparition to be selected in dictionary }
  ZDICT_MAX_SAMPLES_SIZE:uint32 = (2000  shl  20);
  ZDICT_MIN_SAMPLES_SIZE:uint32 = (ZDICT_CONTENTSIZE_MIN * MINRATIO);


{-**************************************
*  Compiler Options
***************************************}
{ Unix Large Files support (>4GB) }
  _FILE_OFFSET_BITS =64;
{-*************************************
*  Constants
**************************************}
//#define KB *(1  shl 10)
//#define MB *(1  shl 20)
//#define GB *(1U shl 30)

  DICTLISTSIZE_DEFAULT =10000;
  NOISELENGTH =32;

  g_selectivity_default:Uint32 = 9;
  OFFCODE_MAX =30;  { only applicable to first block }
  LLIMIT =64;          { heuristic determined experimentally }
  MINMATCHLENGTH =7;   { heuristic determined experimentally }
  MAXREPOFFSET =1024;
  ZDICT_DICTSIZE_MIN    =256;
type
pdictItem=^dictItem;
pEStats_ress_t=^EStats_ress_t;
poffsetCount_t=^offsetCount_t;
pZDICT_params_t=^ZDICT_params_t;
pZDICT_cover_params_t=^ZDICT_cover_params_t;
pZDICT_fastCover_params_t=^ZDICT_fastCover_params_t;
pZDICT_legacy_params_t=^ZDICT_legacy_params_t;

  dictItem=record
    pos:Uint32 ;
    length:Uint32;
    savings:Uint32;
  end;

  EStats_ress_t=record
      dict:pZSTD_CDict;    { dictionary }
      zc:pZSTD_CCtx;     { working context }
      workPlace:pbyte;   { must be ZSTD_BLOCKSIZE_MAX allocated }
  end;
  
  offsetCount_t=record 
    offset, count:Uint32; 
  end;
  
  ZDICT_params_t=record
    compressionLevel:int32;   {< optimize for a specific zstd compression level; 0 means default }
    notificationLevel:uint32;  {< Write log to stderr; 0 = none (default); 1 = errors; 2 = progression; 3 = details; 4 = debug; }
    dictID:uint32;             {< force dictID value; 0 means auto mode (32-bits random value) }
  end;
{! ZDICT_cover_params_t:
 *  k and d are the only required parameters.
 *  For others, value 0 means default.
 }
  
  ZDICT_cover_params_t=record
      k:uint32;                  { Segment size : constraint: 0 < k : Reasonable range [16, 2048+] }
      d:uint32;                  { dmer size : constraint: 0 < d <= k : Reasonable range [6, 16] }
      steps:uint32;              { Number of steps : Only used for optimization : 0 means default (40) : Higher means more parameters checked }
      nbThreads:uint32;          { Number of threads : constraint: 0 < nbThreads : 1 means single-threaded : Only used for optimization : Ignored if ZSTD_MULTITHREAD is not defined }
      splitPoint:double;           { Percentage of samples used for training: Only used for optimization : the first nbSamples * splitPoint samples will be used to training, the last nbSamples * (1 - splitPoint) samples will be used for testing, 0 means default (1.0), 1.0 when all samples are used for both training and testing }
      shrinkDict:uint32;         { Train dictionaries to shrink in size starting from the minimum size and selects the smallest dictionary that is shrinkDictMaxRegression% worse than the largest dictionary. 0 means no shrinking and 1 means shrinking  }
      shrinkDictMaxRegression:uint32; { Sets shrinkDictMaxRegression so that a smaller dictionary can be at worse shrinkDictMaxRegression% worse than the max dict size dictionary. }
      zParams:ZDICT_params_t;
  end;
  
  ZDICT_fastCover_params_t=record
      k:uint32;                  { Segment size : constraint: 0 < k : Reasonable range [16, 2048+] }
      d:uint32;                  { dmer size : constraint: 0 < d <= k : Reasonable range [6, 16] }
      f:uint32;                  { log of size of frequency array : constraint: 0 < f <= 31 : 1 means default(20)}
      steps:uint32;              { Number of steps : Only used for optimization : 0 means default (40) : Higher means more parameters checked }
      nbThreads:uint32;          { Number of threads : constraint: 0 < nbThreads : 1 means single-threaded : Only used for optimization : Ignored if ZSTD_MULTITHREAD is not defined }
      splitPoint:double;           { Percentage of samples used for training: Only used for optimization : the first nbSamples * splitPoint samples will be used to training, the last nbSamples * (1 - splitPoint) samples will be used for testing, 0 means default (0.75), 1.0 when all samples are used for both training and testing }
      accel:uint32;              { Acceleration level: constraint: 0 < accel <= 10, higher means faster and less accurate, 0 means default(1) }
      shrinkDict:uint32;         { Train dictionaries to shrink in size starting from the minimum size and selects the smallest dictionary that is shrinkDictMaxRegression% worse than the largest dictionary. 0 means no shrinking and 1 means shrinking  }
      shrinkDictMaxRegression:uint32; { Sets shrinkDictMaxRegression so that a smaller dictionary can be at worse shrinkDictMaxRegression% worse than the max dict size dictionary. }
      zParams:ZDICT_params_t;
  end;
  
  ZDICT_legacy_params_t=record
      selectivityLevel:uint32;   { 0 means default; larger => select more => larger dictionary }
      zParams:ZDICT_params_t;
  end;
function ZDICT_isError(errorCode:int32):uint32; 
function ZDICT_finalizeDictionary(dictBuffer:pbyte;  dictBufferCapacity:int32;
                          customDictContent:pbyte; dictContentSize:int32;
                          samplesBuffer:pbyte;  samplesSizes:pint32;
                          nbSamples:uint32; params:ZDICT_params_t ):int32;
implementation
uses error_private,zstd_compressf,zstd_common,huf_compress,entropy_common,fse_compress,fastcover;

{-*************************************
*  Console display
**************************************}

procedure ZDICT_printHex(ptr:pbyte;length:int32);
var
  c:byte;
  u:int32 ;
begin
  for u:=0 to length-1 do 
  begin
    c := ptr[u];
    if (c<32)  or  (c>126) then
      c := byte('.');   { non-printable char }
    writeln(stdout, char(c));
  end;
end;


{-********************************************************
*  Helper functions
*********************************************************}
function ZDICT_isError(errorCode:int32):uint32; 
begin 
  result := ERR_isError(errorCode); 
end;

function ZDICT_getErrorName(errorCode:int32):string;
begin 
  result :=  ERR_getErrorName(errorCode); 
end;

function ZDICT_getDictID(dictBuffer:pbyte; dictSize:int32):uint32;
begin
    if (dictSize < 8) then
      exit(0);
    if (puint32(dictBuffer)[0] <> ZSTD_MAGIC_DICTIONARY) then
      exit(0);
    result := puint32(dictBuffer + 4)[0];
end;

function ZDICT_getDictHeaderSize(dictBuffer:pbyte; dictSize:int32):uint32;
var
  headerSize:int32 ;
  bs:pZSTD_compressedBlockState_t;
  wksp:pUint32;
begin
    if (dictSize <= 8)  or  (puint32(dictBuffer)[0] <> ZSTD_MAGIC_DICTIONARY) then
      exit(ERROR(dictionary_corrupted));

    begin   
      bs := pZSTD_compressedBlockState_t(allocmem(sizeof(ZSTD_compressedBlockState_t)));
      wksp := pUint32(allocmem(HUF_WORKSPACE_SIZE));
      if (bs=nil)  or  (wksp=nil) then
      begin
          headerSize := ERROR(memory_allocation);
      end 
      else 
      begin
          ZSTD_reset_compressedBlockState(bs);
          headerSize := ZSTD_loadCEntropy(bs, pbyte(wksp), dictBuffer, dictSize);
      end;

      freemem(bs);
      freemem(wksp);
    end;

    result := headerSize;
end;

{-********************************************************
*  Dictionary training functions
*********************************************************}
function ZDICT_NbCommonBytes(val:int32):uint32;
const
    {$IFDEF ENDIAN_LITTLE}
        {$IFDEF CPU64}
  DeBruijnBytePos:array [0..63] of int32 = ( 0, 0, 0, 0, 0, 1, 1, 2, 0, 3, 1, 3, 1, 4, 2, 7, 0, 2, 3, 6, 1, 5, 3, 5, 1, 3, 4, 4, 2, 5, 6, 7, 7, 0, 1, 2, 3, 3, 4, 6, 2, 6, 5, 5, 3, 4, 5, 6, 7, 1, 2, 4, 6, 4, 4, 5, 7, 2, 6, 5, 7, 6, 7, 7 );
        {$ENDIF}
         {$IFDEF CPU32} { 32 bits }
  DeBruijnBytePos:array [0..31] of int32 = (0, 0, 3, 0, 3, 1, 3, 0, 3, 2, 2, 1, 3, 2, 0, 1, 3, 3, 1, 2, 2, 2, 2, 0, 3, 1, 2, 0, 1, 0, 1, 1 );
         {$ENDIF}
    {$ENDIF}
var
  r,n32:uint32;
begin
    {$IFDEF ENDIAN_LITTLE}
        {$IFDEF CPU64}            
            result := DeBruijnBytePos[(Uint64(val  and  -int64(val)) * Uint64($0218A392CDABBD3F))  shr  58];
        {$ENDIF}
         {$IFDEF CPU32} { 32 bits }
            result := DeBruijnBytePos[(Uint32(val  and  -int32(val)) * Uint32($077CB531))  shr  27];
        {$ENDIF}
    {$ENDIF}
     {$IFDEF ENDIAN_BIG}  { Big Endian CPU }
        {$IFDEF CPU64}
            n32 := sizeof(int32)*4;   { calculate this way due to compiler complaining in 32-bits mode }
            if ((val shr n32)=0) then
            begin 
              r:=4; 
            end 
            else 
            begin 
              r:=0; 
              val :=val shr n32; 
            end;
            if ((val shr 16)=0) then
            begin 
              r+=2; 
              val :=val shr 8; 
            end 
            else 
            begin 
              val :=val shr 24; 
            end;
            r :=r + (not val);
            result := r;

        {$ENDIF}
        {$IFDEF CPU32} { 32 bits }
            if ((val shr 16)=0) then
            begin 
              r=2; 
              val:=val shr 8; 
            end 
            else 
            begin 
              r=0; 
              val:=val shr 24; 
            end;
            r :=r + (not val);
            result := r;
        {$ENDIF}   
    {$ENDIF}
end;


{! ZDICT_count() :
    Count the nb of common bytes between 2 pointers.
    Note : this function presumes end of buffer followed by noisy guard band.
}
function  ZDICT_count(pIn:pbyte; pMatch:pbyte):int32;
var
  diff:int32;
  pStart:pbyte;
begin
   pStart := pIn;
    while true do
    begin
        diff := pint32(pMatch)[0] xor pint32(pIn)[0];
        if (diff=0) then
        begin
            pIn    := pbyte(pIn+sizeof(int32));
            pMatch := pbyte(pMatch+sizeof(int32));
            continue;
        end;
        pIn := pbyte(pIn+ZDICT_NbCommonBytes(diff));
        exit(ptrint(pIn - pStart));
    end;
end;

procedure ZDICT_initDictItem(d:pdictItem);
begin
    d^.pos    := 1;
    d^.length := 0;
    d^.savings := Uint32(-1);
end;



function ZDICT_analyzePos(doneMarks:pbyte;suffix:pint32;  start:Uint32;buffer:pbyte;  minRatio,  notificationLevel:Uint32):dictItem;
var
  lengthList,cumulLength,savings:array [0..LLIMIT-1] of uint32;
  b:pbyte;
  maxLength,pos,u, patternEnd:int32;
  lend:Uint32;
  solution:dictItem;
  pattern16:Word;
  llength,i:int32;
  idx,mml,refinedStart,refinedEnd:Uint32;
  currentChar:BYTE;
  currentCount,currentID,id,selectedCount,selectedID:Uint32;
  p, pEnd, plength,testedPos:Uint32;
begin
    fillbyte(lengthList,LLIMIT,0);
    fillbyte(cumulLength,LLIMIT,0);
    fillbyte(savings,LLIMIT,0);
    b := buffer;
    maxLength := LLIMIT;
    pos := suffix[start];
    lend := start;

    { init }
    fillbyte(solution, sizeof(solution), 0);
    doneMarks[pos] := 1;

    { trivial repetition cases }
    if (   (MEM_read16(b+pos+0) = MEM_read16(b+pos+2))
        or (MEM_read16(b+pos+1) = MEM_read16(b+pos+3))
        or (MEM_read16(b+pos+2) = MEM_read16(b+pos+4)) ) then
    begin
        { skip and mark segment }
        pattern16 := MEM_read16(b+pos+4);
        patternEnd := 6;
        while (pWord(b+pos+patternEnd)[0] = pattern16) do
          patternEnd:=patternEnd+2 ;
        if (b[pos+patternEnd] = b[pos+patternEnd-1]) then
          inc(patternEnd);
        for u:=1 to patternEnd-1 do
            doneMarks[pos+u] := 1;
        exit(solution);
    end;

    { look forward }   
    repeat
        inc(lend);
        llength := ZDICT_count(b + pos, b + suffix[lend]);
    until (llength < MINMATCHLENGTH);

    { look backward }
    repeat
      llength := ZDICT_count(b + pos, b + suffix[start-1]);
      if (llength >=MINMATCHLENGTH) then
        dec(start);
    until(llength < MINMATCHLENGTH);

    { exit if not found a minimum nb of repetitions }
    if (lend-start < minRatio) then
    begin
        for idx:=start to lend-1 do
            doneMarks[suffix[idx]] := 1;
        exit(solution);
    end;

    refinedStart := start;
    refinedEnd   := lend;
    mml := MINMATCHLENGTH ;
    while true do
    begin
        currentChar   := 0;
        currentCount  := 0;
        currentID     := refinedStart;
        selectedCount := 0;
        selectedID    := currentID;
        for id :=refinedStart to refinedEnd-1 do
        begin
          if (b[suffix[id] + mml] <> currentChar) then
          begin
            if (currentCount > selectedCount) then
            begin
                selectedCount := currentCount;
                selectedID := currentID;
            end;
            currentID    := id;
            currentChar  := b[ suffix[id] + mml];
            currentCount := 0;
          end;
          inc(currentCount);
        end;
        if (currentCount > selectedCount) then
        begin  { for last }
            selectedCount := currentCount;
            selectedID    := currentID;
        end;

        if (selectedCount < minRatio) then
            break;
        refinedStart := selectedID;
        refinedEnd   := refinedStart + selectedCount;
        mml:=mml+1;
    end;

    { evaluate gain based on new dict }
    start := refinedStart;
    pos   := suffix[refinedStart];
    lend  := start;
    fillbyte(lengthList, sizeof(lengthList), 0);

    { look forward }
    repeat
        inc(lend);
        llength := ZDICT_count(b + pos, b + suffix[lend]);
        if (llength >= LLIMIT) then
          llength := LLIMIT-1;
        inc(lengthList[llength]);
    until (llength <MINMATCHLENGTH);

    { look backward }   
    llength := MINMATCHLENGTH;
    while ((llength >= MINMATCHLENGTH)  and  (start > 0)) do
    begin
      llength := ZDICT_count(b + pos, b + suffix[start - 1]);
      if (llength >= LLIMIT) then 
        llength := LLIMIT - 1;
      inc(lengthList[llength]);
      if (llength >= MINMATCHLENGTH) then
        dec(start);
    end;

    { largest useful length }
    fillbyte(cumulLength, sizeof(cumulLength), 0);
    cumulLength[maxLength-1] := lengthList[maxLength-1];
    for i:=int32(maxLength-2) downto 0 do
        cumulLength[i] := cumulLength[i+1] + lengthList[i];

    for i:=LLIMIT-1 downto MINMATCHLENGTH do
      if (cumulLength[i]>=minRatio) then
        break;
    maxLength := i;

    { reduce maxLength in case of final into repetitive data }
    idx := Uint32(maxLength);
    currentChar := b[pos + maxLength-1];
    while (b[pos+idx-2]=currentChar) do
      dec(idx);
    maxLength := idx;
    if (maxLength < MINMATCHLENGTH) then 
      exit(solution);   { skip : no long-enough solution }

        { calculate savings }
    savings[5] := 0;
    for i:=MINMATCHLENGTH to int32(maxLength) do
      savings[i] := savings[i-1] + (lengthList[i] * (i-3));

    solution.pos     := Uint32(pos);
    solution.length  := Uint32(maxLength);
    solution.savings := savings[maxLength];

    { mark positions done }
    for id:=start to lend-1 do
    begin
      testedPos := suffix[id];
      if (testedPos = pos) then
      begin
        plength := solution.length;
      end
      else 
      begin
        plength := Uint32(ZDICT_count(b+pos, b+testedPos));
        if (plength > solution.length) then
          plength := solution.length;
      end;
      pEnd := Uint32(testedPos + plength);
      for p:=testedPos to pEnd -1 do
          doneMarks[p] := 1;
    end;

    exit(solution);
end;


function isIncluded(bufin:pbyte; container:pbyte;llength:int32):int32;
var
  ip,into:pbyte;
  u:int32;
begin
    ip   := pbyte( bufin);
    into := pbyte( container);

    for u:=0 to llength-1 do
    begin  { works because end of buffer is a noisy guard band }
      if (ip[u] <> into[u]) then
        break;
    end;

    result := ord(u=llength);
end;

{! ZDICT_tryMerge() :
    check if dictItem can be merged, do it if possible
    @return : id of destination elt, 0 if not merged
}
function ZDICT_tryMerge(table:pdictItem; elt:dictItem; eltNbToSkip:Uint32; buffer:pbyte):Uint32;
var
  tableSize,eltEnd,u,addedLength:Uint32;
  buf:pbyte;
  addedLength2:int32;
begin
    tableSize := table^.pos;
    eltEnd    := elt.pos + elt.length;
    buf       := pbyte( buffer);

    { tail overlap }
    u:=1;
    while u<tableSize do
    begin
        if (u=eltNbToSkip) then
          continue;
        if ((table[u].pos > elt.pos) and (table[u].pos <= eltEnd)) then
        begin  { overlap, existing > new }
            { append }
            addedLength      := table[u].pos - elt.pos;
            table[u].length  := table[u].length + addedLength;
            table[u].pos     := elt.pos;
            table[u].savings := table[u].savings + elt.savings * addedLength div elt.length;   { rough approx }
            table[u].savings := table[u].savings + elt.length div 8;    { rough approx bonus }
            elt := table[u];
            { sort : improve rank }
            while ((u>1)  and (table[u-1].savings < elt.savings)) do
            begin
              table[u] := table[u-1];
              dec(u);
            end;
            table[u] := elt;
            exit(u);
        end;   
    end;

    { front overlap }
    u:=1;
    while u<tableSize do
    begin
        if (u=eltNbToSkip) then
          continue;

        if ((table[u].pos + table[u].length >= elt.pos)  and (table[u].pos < elt.pos)) then
        begin  { overlap, existing < new }
          { append }
          addedLength2     := int32(eltEnd) - (table[u].pos + table[u].length);
          table[u].savings :=table[u].savings + elt.length div 8;    { rough approx bonus }
          if (addedLength > 0) then
          begin   { otherwise, elt fully included into existing }
              table[u].length :=table[u].length + addedLength;
              table[u].savings:=table[u].savings + elt.savings * addedLength div elt.length;   { rough approx }
          end;
          { sort : improve rank }
          elt := table[u];
          while ((u>1)  and (table[u-1].savings < elt.savings)) do
          begin
              table[u] := table[u-1]; 
              dec(u);
          end;
          table[u] := elt;
          exit(u);
        end;

        if (pUint64(buf + table[u].pos)[0] = pUint64(buf + elt.pos + 1)[0]) then
        begin
          if (isIncluded(buf + table[u].pos, buf + elt.pos + 1, table[u].length)<>0) then
          begin
            addedLength2 := MAX( elt.length - table[u].length , 1 );
            table[u].pos := elt.pos;
            table[u].savings :=table[u].savings + Uint32(elt.savings * addedLength div elt.length);
            table[u].length := MIN(elt.length, table[u].length + 1);
            exit(u);
          end;
        end;
    end;

    exit(0);
end;


procedure ZDICT_removeDictItem(table:pdictItem; id:Uint32 );
var
  max,u:Uint32;
begin
    { convention : table[0].pos stores nb of elts }
    max := table[0].pos;
    if (id=0) then
      exit;   { protection, should never happen }
    for u:=id to max-2 do
        table[u] := table[u+1];
    dec(table^.pos);
end;


procedure ZDICT_insertDictItem(table:pdictItem; maxSize:Uint32; elt:dictItem; buffer:pbyte);
var
  mergeId,newMerge,current,nextElt:Uint32;
begin
  { merge if possible }
  mergeId := ZDICT_tryMerge(table, elt, 0, buffer);
  if (mergeId=0) then
  begin
      newMerge := 1;
      while (newMerge<>0) do
      begin
          newMerge := ZDICT_tryMerge(table, table[mergeId], mergeId, buffer);
          if (newMerge<>0) then
            ZDICT_removeDictItem(table, mergeId);
          mergeId := newMerge;
      end;
      exit;
  end;

  { insert }
  nextElt := table^.pos;
  if (nextElt >= maxSize) then
    nextElt := maxSize-1;
  current := nextElt-1;
  while (table[current].savings < elt.savings) do
  begin
      table[current+1] := table[current];
      dec(current);
  end;
  table[current+1] := elt;
  table^.pos := nextElt+1;
end;


function  ZDICT_dictSize(dictList:pdictItem):Uint32;
var
  u,dictSize:Uint32;
begin
    dictSize := 0;
    for u:=1 to dictList[0].pos-1 do
        dictSize :=dictSize + dictList[u].length;
    result := dictSize;
end;


function  ZDICT_trainBuffer_legacy(dictList:pdictItem; dictListSize:Uint32;
                            buffer:pbyte; bufferSize:int32 ;   { buffer must end with noisy guard band }
                            fileSizes:pint32;nbFiles,minRatio,notificationLevel:uint32):int32;
label _cleanup;
var
  suffix0,suffix:pint32;
  reverseSuffix,filePos:puint32;
  doneMarks:pbyte;
  displayClock,refreshRate:Uint64;
  divSuftSortResult,pos:int32;
  cursor:uint32;
  solution:dictItem;
begin
    suffix0 := allocmem((bufferSize+2)*sizeof(pint32));
    suffix  := suffix0+1;
    reverseSuffix := allocmem((bufferSize)*sizeof(puint32));
    doneMarks := allocmem((bufferSize+16)*sizeof(pbyte));   { +16 for overflow security }
    filePos := allocmem(nbFiles * sizeof(puint32));
    result := 0;
    displayClock := 0;
    refreshRate  := 1000 * 3 div 10;

    { init }
    if (suffix0=nil) or  (reverseSuffix=nil)  or  (doneMarks=nil)  or  (filePos=nil) then
    begin
        result := ERROR(memory_allocation);
        goto _cleanup;
    end;
    if (minRatio < MINRATIO) then
      minRatio := MINRATIO;
    fillbyte(doneMarks^, bufferSize+16, 0);

    { limit sample set size (divsufsort limitation)}
    while (bufferSize > ZDICT_MAX_SAMPLES_SIZE) do
    begin
      dec(nbFiles);
      bufferSize :=bufferSize - fileSizes[nbFiles];
    end;
    { sort }
       
    //divSuftSortResult := divsufsort(buffer, suffix, int32(bufferSize), 0); 怪怪
    if (divSuftSortResult <> 0) then
    begin 
      result := ERROR(GENERIC_ERROR); 
      goto _cleanup; 
    end;
    
    suffix[bufferSize] := int32(bufferSize);   { leads into noise }
    suffix0[0] := int32(bufferSize);           { leads into noise }
    { build reverse suffix sort }

    for pos:=0 to bufferSize-1 do
        reverseSuffix[suffix[pos]] := Uint32(pos);
    { note filePos tracks borders between samples.
       It's not used at this stage, but planned to become useful in a later update }
    filePos[0] := 0;
    for pos:=1 to nbFiles-1 do
        filePos[pos] := Uint32(filePos[pos-1] + fileSizes[pos-1]);
    cursor:=0;
    while (cursor < bufferSize) do
    begin
        if (doneMarks[cursor]<>0) then
        begin 
          inc(cursor); 
          continue; 
        end;
        solution := ZDICT_analyzePos(doneMarks, suffix, reverseSuffix[cursor], buffer, minRatio, notificationLevel);
        if (solution.length=0) then
        begin 
          inc(cursor); 
          continue; 
        end;
        ZDICT_insertDictItem(dictList, dictListSize, solution, buffer);
        cursor :=cursor + solution.length;
    end;

_cleanup:
    freemem(suffix0);
    freemem(reverseSuffix);
    freemem(doneMarks);
    freemem(filePos);
end;


procedure ZDICT_fillNoise(buffer:pbyte;llength:int32);
var
  p:int32;
  prime1,prime2,acc:uint32;
begin
    prime1 := uint32(2654435761);
    prime2 := uint32(2246822519);
    acc := prime1;
    for p:=0 to llength-1 do
    begin
      acc :=acc * prime2;
      buffer[p] := byte(acc  shr  21);
    end;
end;




procedure ZDICT_countEStats(esr:EStats_ress_t; params:pZSTD_parameters;
                              countLit,offsetcodeCount,matchlengthCount,litlengthCount,repOffsets:puint32;
                              src:pbyte;  srcSize:int32;
                              notificationLevel:Uint32);
var
  blockSizeMax,cSize,errorCode,i,j:int32;
  seqStorePtr:pseqStore_t;
  bytePtr,codePtr:pbyte;
  nbSeq,u,offset1,offset2:Uint32;
  seq:pseqDef;
begin
  blockSizeMax := MIN (ZSTD_BLOCKSIZE_MAX, 1  shl  params^.cParams.windowLog);
  if (srcSize > blockSizeMax) then
    srcSize := blockSizeMax;   { protection vs large samples }
  begin   
    errorCode := ZSTD_compressBegin_usingCDict(esr.zc, esr.dict);
    if (ZSTD_isError(errorCode)<>0) then
    begin 
      //DISPLAYLEVEL(1, 'warning : ZSTD_compressBegin_usingCDict failed \n'); 
      exit; 
    end;

  end;
  cSize := ZSTD_compressBlock(esr.zc, esr.workPlace, ZSTD_BLOCKSIZE_MAX, src, srcSize);
  if (ZSTD_isError(cSize)<>0) then
  begin 
    //DISPLAYLEVEL(3, 'warning : could not compress sample size %u \n', (unsigned)srcSize); 
    exit; 
  end;

  if (cSize<>0) then
  begin  { if == 0; block is not compressible }
    seqStorePtr := ZSTD_getSeqStore(esr.zc);

    { literals stats }
    bytePtr:=seqStorePtr^.litStart;
    i:=ptrint(seqStorePtr^.litStart);
    j:=ptrint(seqStorePtr^.lit);
    for i := i to j-1 do
    begin
        inc(countLit[bytePtr^]);
        inc(bytePtr);
    end;


    { seqStats } 
    nbSeq := Uint32(seqStorePtr^.sequences - seqStorePtr^.sequencesStart);
    ZSTD_seqToCodes(seqStorePtr);

    codePtr := seqStorePtr^.ofCode;
    for u:=0 to nbSeq-1 do 
      inc(offsetcodeCount[codePtr[u]]);

    codePtr := seqStorePtr^.mlCode;
    for u:=0 to nbSeq-1 do  
      inc(matchlengthCount[codePtr[u]]);

    codePtr := seqStorePtr^.llCode;
    for u:=0 to nbSeq-1 do  
      inc(litlengthCount[codePtr[u]]);


    if (nbSeq >= 2) then
    begin { rep offsets }
        seq := seqStorePtr^.sequencesStart;
        offset1 := seq[0].offset - 3;
        offset2 := seq[1].offset - 3;
        if (offset1 >= MAXREPOFFSET) then
          offset1 := 0;
        if (offset2 >= MAXREPOFFSET) then
          offset2 := 0;
        repOffsets[offset1] :=repOffsets[offset1] + 3;
        repOffsets[offset2] :=repOffsets[offset2] + 1;
    end;
  end;
end;

function ZDICT_totalSampleSize(fileSizes:pint32; nbFiles:uint32):int32;
var
  u:uint32;
begin
    result:=0;
    for u:=0 to nbFiles-1 do 
      result :=result + fileSizes[u];
end;

procedure ZDICT_insertSortCount( table:array of offsetCount_t; val:int32; count:Uint32 );
var
  u:Uint32;
  tmp:offsetCount_t;
begin
    table[ZSTD_REP_NUM].offset := val;
    table[ZSTD_REP_NUM].count  := count;
    for u:=ZSTD_REP_NUM downto 1 do
    begin
        if (table[u-1].count >= table[u].count) then
          break;
        tmp := table[u-1];
        table[u-1] := table[u];
        table[u] := tmp;
    end;
end;

{ ZDICT_flatLit() :
 * rewrite `countLit` to contain a mostly flat but still compressible distribution of literals.
 * necessary to avoid generating a non-compressible distribution that HUF_writeCTable() cannot encode.
 }
procedure ZDICT_flatLit(countLit:puint32 );
var
  u:int32;
begin
    for u:=1 to 255 do 
      countLit[u] := 2;
    countLit[0]   := 4;
    countLit[253] := 1;
    countLit[254] := 1;
end;


function ZDICT_analyzeEntropy(dstBuffer:pbyte; maxDstSize:int32;
                                   compressionLevel:int32;
                                   srcBuffer:pbyte; fileSizes:pint32; nbFiles:uint32;
                                  dictBuffer:pbyte; dictBufferSize:int32;
                                   notificationLevel:uint32 ):int32;
label _cleanup;
var
  countLit:array[0..255] of uint32;
  offcodeCount:array[0..OFFCODE_MAX] of uint32;
  offcodeNCount:array[0..OFFCODE_MAX] of smallint;
  offcodeMax:Uint32;
  matchLengthCount:array[0..MaxML] of uint32;
  matchLengthNCount:array[0..MaxML] of smallint;
  litLengthCount:array[0..MaxLL] of uint32;
  litLengthNCount:array[0..MaxLL] of smallint;
  repOffset:array[0..MAXREPOFFSET] of uint32;
  bestRepOffset:array[0..ZSTD_REP_NUM] of offsetCount_t;
  esr:EStats_ress_t;
  params:ZSTD_parameters;
  u,huffLog,Offlog,mlLog,llLog,total:Uint32;
  pos,errorCode,eSize,totalSrcSize,averageSampleSize,maxNbBits,offset,hhSize,ohSize,mhSize:int32;
  dstPtr:pbyte;
  hufTable: array[0..255] of HUF_CElt;
  lhSize:int32;
begin

    offcodeMax := ZSTD_highbit32(Uint32(dictBufferSize + 128 *1024));
    fillbyte(esr,sizeof(esr),0);
    huffLog := 11; 
    Offlog  := OffFSELog; 
    mlLog   := MLFSELog; 
    llLog   := LLFSELog; 
    pos   := 0;
    eSize := 0;
    totalSrcSize      := ZDICT_totalSampleSize(fileSizes, nbFiles);
    averageSampleSize := totalSrcSize div (nbFiles + ord(nbFiles = 0));
    dstPtr := dstBuffer;

    { init }
    if (offcodeMax>OFFCODE_MAX) then
    begin 
      eSize := ERROR(dictionaryCreation_failed); 
      goto _cleanup; 
    end;   { too large dictionary }
    for u:=0 to 255 do
      countLit[u] := 1;   { any character must be described }
    for u:=0 to offcodeMax do
      offcodeCount[u] := 1;
    for u:=0 to MaxML do
      matchLengthCount[u] := 1;
    for u:=0 to MaxLL do
      litLengthCount[u] := 1;
    fillbyte(repOffset, sizeof(repOffset), 0);
    repOffset[1] := 1;
    repOffset[4] := 1;
    repOffset[8] := 1;
    fillbyte(bestRepOffset, sizeof(bestRepOffset), 0);
    if (compressionLevel=0) then
      compressionLevel := ZSTD_CLEVEL_DEFAULT;
    params := ZSTD_getParams(compressionLevel, averageSampleSize, dictBufferSize);

    esr.dict := ZSTD_createCDict_advanced(dictBuffer, dictBufferSize, ZSTD_dlm_byRef, ZSTD_dct_rawContent, params.cParams, ZSTD_defaultCMem);
    esr.zc := ZSTD_createCCtx();
    esr.workPlace := allocmem(ZSTD_BLOCKSIZE_MAX);
    if (esr.dict=nil)  or  (esr.zc=nil)  or  (esr.workPlace=nil) then
    begin
        eSize := ERROR(memory_allocation);
        goto _cleanup;
    end;

    { collect stats on all samples }
    for u:=0 to nbFiles-1 do
    begin
        ZDICT_countEStats(esr,  @params,
                          countLit, offcodeCount, matchLengthCount, litLengthCount, repOffset,
                         pbyte(srcBuffer + pos), fileSizes[u],
                          notificationLevel);
        pos :=pos + fileSizes[u];
    end;

    { analyze, build stats, starting with literals } 
    maxNbBits := HUF_buildCTable (hufTable, countLit, 255, huffLog);
    if (HUF_isError(maxNbBits)<>0) then
    begin
        eSize := maxNbBits;
        goto _cleanup;
    end;
    if (maxNbBits=8) then
    begin  { not compressible : will fail on HUF_writeCTable() }
        ZDICT_flatLit(countLit);  { replace distribution by a fake 'mostly flat but still compressible' distribution, that HUF_writeCTable() can encode }
        maxNbBits := HUF_buildCTable (hufTable, countLit, 255, huffLog);
    end;
    huffLog := Uint32(maxNbBits);


    { looking for most common first offsets }
    for offset:=1 to MAXREPOFFSET-1 do
        ZDICT_insertSortCount(bestRepOffset, offset, repOffset[offset]);
    { note : the result of this phase should be used to better appreciate the impact on statistics }

    total:=0; 
    for u:=0 to offcodeMax do 
      total:=total+offcodeCount[u];
    errorCode := FSE_normalizeCount(@offcodeNCount[0], Offlog, offcodeCount, total, offcodeMax, { useLowProbCount } 1);
    if (FSE_isError(errorCode)<>0) then
    begin
        eSize := errorCode;
        goto _cleanup;
    end;
    Offlog := Uint32(errorCode);

    total:=0; 
    for u:=0 to MaxML do
      total:=total+matchLengthCount[u];
    
    errorCode := FSE_normalizeCount(@matchLengthNCount[0], mlLog, matchLengthCount, total, MaxML, { useLowProbCount } 1);
    if (FSE_isError(errorCode)<>0) then
    begin
        eSize := errorCode;
        goto _cleanup;
    end;
    mlLog := Uint32(errorCode);

    total:=0; 
    for u:=0 to MaxML do 
      total:=total+litLengthCount[u];
    errorCode := FSE_normalizeCount(@litLengthNCount[0], llLog, litLengthCount, total, MaxLL, { useLowProbCount } 1);
    if (FSE_isError(errorCode)<>0) then
    begin
        eSize := errorCode;
        goto _cleanup;
    end;
    llLog := Uint32(errorCode);

    { write result to buffer }
 
    hhSize := HUF_writeCTable(dstPtr, maxDstSize, hufTable, 255, huffLog);
    if (HUF_isError(hhSize)<>0) then
    begin
        eSize := hhSize;
        goto _cleanup;
    end;
    dstPtr :=dstPtr + hhSize;
    maxDstSize :=maxDstSize - hhSize;
    eSize :=eSize + hhSize;
 
    ohSize := FSE_writeNCount(dstPtr, maxDstSize, @offcodeNCount[0], OFFCODE_MAX, Offlog);
    if (FSE_isError(ohSize)<>0) then
    begin
        eSize := ohSize;
        goto _cleanup;
    end;
    dstPtr :=dstPtr + ohSize;
    maxDstSize :=maxDstSize - ohSize;
    eSize :=eSize + ohSize;
 
    mhSize := FSE_writeNCount(dstPtr, maxDstSize, @matchLengthNCount[0], MaxML, mlLog);
    if (FSE_isError(mhSize)<>0) then
    begin
        eSize := mhSize;
        goto _cleanup;
    end;
    dstPtr :=dstPtr + mhSize;
    maxDstSize :=maxDstSize - mhSize;
    eSize :=eSize + mhSize;
 
    lhSize := FSE_writeNCount(dstPtr, maxDstSize, @litLengthNCount[0], MaxLL, llLog);
    if (FSE_isError(lhSize)<>0) then
    begin
        eSize := lhSize;
        goto _cleanup;
    end;
    dstPtr :=dstPtr + lhSize;
    maxDstSize :=maxDstSize - lhSize;
    eSize :=eSize + lhSize;

    if (maxDstSize<12) then
    begin
        eSize := ERROR(dstint32ooSmall);
        goto _cleanup;
    end;
    { at this stage, we don't use the result of 'most common first offset',
       as the impact of statistics is not properly evaluated }
  {$ifdef ENDIAN_LITTLE}
    move(bestRepOffset[0].offset,dstPtr[0],sizeof(bestRepOffset[0].offset));
    move(bestRepOffset[1].offset,dstPtr[4],sizeof(bestRepOffset[0].offset));
    move(bestRepOffset[2].offset,dstPtr[8],sizeof(bestRepOffset[0].offset));
  {$endif}
  {$ifdef ENDIAN_BIG}
    move(SwapEndian(bestRepOffset[0].offset),dstPtr[0],sizeof(bestRepOffset[0].offset));
    move(SwapEndian(bestRepOffset[1].offset),dstPtr[4],sizeof(bestRepOffset[0].offset));
    move(SwapEndian(bestRepOffset[2].offset),dstPtr[8],sizeof(bestRepOffset[0].offset));
  {$endif}
   eSize :=eSize + 12;
_cleanup:
    ZSTD_freeCDict(esr.dict);
    //ZSTD_freeCCtx(esr.zc);
    freemem(esr.workPlace);

    result := eSize;
end;



function ZDICT_finalizeDictionary(dictBuffer:pbyte;  dictBufferCapacity:int32;
                          customDictContent:pbyte; dictContentSize:int32;
                          samplesBuffer:pbyte;  samplesSizes:pint32;
                          nbSamples:uint32; params:ZDICT_params_t ):int32;
const
  HBUFFSIZE=256;
var
  hSize,compressionLevel,eSize,dictSize:int32 ;
  notificationLevel:uint32 ;
  header:array[0..HBUFFSIZE-1] of BYTE;
  randomID:Uint64;
  compliantID,dictID:Uint32;
  dictEnd:pbyte;
begin
  if (params.compressionLevel = 0) then
    compressionLevel  := ZSTD_CLEVEL_DEFAULT
  else
    compressionLevel  := params.compressionLevel;
  notificationLevel := params.notificationLevel;

  { check conditions }
  if (dictBufferCapacity < dictContentSize) then 
    exit(ERROR(dstint32ooSmall));
  if (dictContentSize < ZDICT_CONTENTSIZE_MIN) then 
    exit(ERROR(srcSize_wrong));
  if (dictBufferCapacity < ZDICT_DICTSIZE_MIN) then 
    exit(ERROR(dstint32ooSmall));

    { dictionary header }
    hSize:=ZSTD_MAGIC_DICTIONARY;
    move(hsize,header, sizeof(int32));
 
    randomID := XXH64(customDictContent, dictContentSize, 0);
    compliantID := (randomID mod ((1 shl 31)-32768)) + 32768;
    if params.dictID<>0 then
      dictID :=params.dictID
    else
      dictID := compliantID;
    move(dictID,header[4],sizeof(Uint32));
    hSize := 8;

    { entropy tables }
 
    eSize := ZDICT_analyzeEntropy(@header[hSize], HBUFFSIZE-hSize,
                                  compressionLevel,
                                  samplesBuffer, samplesSizes, nbSamples,
                                  customDictContent, dictContentSize,
                                  notificationLevel);
    if (ZDICT_isError(eSize)<>0) then 
      exit(eSize);
    hSize :=hSize + eSize;

    { copy elements in final buffer ; note : src and dst buffer can overlap }
    if (hSize + dictContentSize > dictBufferCapacity) then
      dictContentSize := dictBufferCapacity - hSize;

    dictSize := hSize + dictContentSize;
    dictEnd := dictBuffer + dictSize;
    move(customDictContent,dictEnd[ - dictContentSize],  dictContentSize);
    move(header,dictBuffer,  hSize);
    exit(dictSize);

end;


function  ZDICT_addEntropyTablesFromBuffer_advanced(
        dictBuffer:pbyte;  dictContentSize,  dictBufferCapacity:int32;
        samplesBuffer:pbyte;  samplesSizes:pint32; nbSamples:uint32;
        params:ZDICT_params_t ):int32;
var
  compressionLevel,hSize,eSize :int32;
  notificationLevel:uint32;
  randomID:Uint64;
  compliantID,dictID:Uint32;
  dictEnd:pbyte;
begin
  if (params.compressionLevel = 0) then
    compressionLevel  := ZSTD_CLEVEL_DEFAULT
  else
    compressionLevel  :=  params.compressionLevel;
  notificationLevel := params.notificationLevel;
  hSize := 8;

    { calculate entropy tables } 
    eSize := ZDICT_analyzeEntropy(dictBuffer+hSize, dictBufferCapacity-hSize,
                                  compressionLevel,
                                  samplesBuffer, samplesSizes, nbSamples,
                                  dictBuffer + dictBufferCapacity - dictContentSize, dictContentSize,
                                  notificationLevel);
    if (ZDICT_isError(eSize)<>0) then
      exit(eSize);
    hSize :=hSize + eSize;

    { add dictionary header (after entropy tables) }
    hSize:=ZSTD_MAGIC_DICTIONARY;
    move(hsize,dictBuffer, sizeof(int32) );
    randomID := XXH64(dictBuffer + dictBufferCapacity - dictContentSize, dictContentSize, 0);
    compliantID := (randomID mod ((1 shl 31)-32768)) + 32768;
    if params.dictID<>0 then
      dictID :=  params.dictID
    else
      dictID :=  compliantID;
    
    move(dictID,dictBuffer[4],sizeof(int32));

    if (hSize + dictContentSize < dictBufferCapacity) then
        move(dictBuffer[dictBufferCapacity - dictContentSize], dictBuffer[hSize],  dictContentSize);
    result := MIN(dictBufferCapacity, hSize+dictContentSize);
end;

{! ZDICT_trainFromBuffer_unsafe_legacy() :
*   Warning : `samplesBuffer` must be followed by noisy guard band.
*   @return : size of dictionary, or an error code which can be tested with ZDICT_isError()
}
function ZDICT_trainFromBuffer_unsafe_legacy(
                            dictBuffer:pbyte; maxDictSize:int32;
                            samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32;
                            params:ZDICT_legacy_params_t):int32;
var
  dictListSize,notificationLevel,u,nb,dictContentSize,pos,llength,printedLength,proposedSelectivity:Uint32;
  dictList:pdictItem;
  l,selectivity,minRep,targetDictSize,samplesBuffSize,dictSize,lmax,n,currentSize:uint32;
  ptr:pbyte;
begin
    dictListSize := MAX(MAX(DICTLISTSIZE_DEFAULT, nbSamples), Uint32(maxDictSize div 16));
    dictList := allocmem(dictListSize * sizeof(dictItem));
    if params.selectivityLevel = 0 then
      selectivity := g_selectivity_default
    else
      selectivity := params.selectivityLevel;
    if  (selectivity > 30) then
      minRep := MINRATIO
    else
      minRep := nbSamples  shr  selectivity;
    targetDictSize  := maxDictSize;
    samplesBuffSize := ZDICT_totalSampleSize(samplesSizes, nbSamples);
    dictSize  := 0;
    notificationLevel := params.zParams.notificationLevel;

    { checks }
    if (dictList=nil) then
      exit(ERROR(memory_allocation));
    if (maxDictSize < ZDICT_DICTSIZE_MIN) then
    begin 
      freemem(dictList); 
      exit(ERROR(dstint32ooSmall)); 
    end;   { requested dictionary size is too small }
    if (samplesBuffSize < ZDICT_MIN_SAMPLES_SIZE) then
    begin 
      freemem(dictList);
      exit(ERROR(dictionaryCreation_failed)); 
    end;   { not enough source to create dictionary }

    { init }
    ZDICT_initDictItem(dictList);

    { build dictionary }
    ZDICT_trainBuffer_legacy(dictList, dictListSize,
                       samplesBuffer, samplesBuffSize,
                       samplesSizes, nbSamples,
                       minRep, notificationLevel);

    { display best matches }
    if (params.zParams.notificationLevel>= 3) then 
    begin
        nb              := MIN(25, dictList[0].pos);
        dictContentSize := ZDICT_dictSize(dictList);

        for u:=1 to nb-1 do
        begin
            pos := dictList[u].pos;
            llength := dictList[u].length;
            printedLength := MIN(40, llength);
            if ((pos > samplesBuffSize)  or  ((pos + llength) > samplesBuffSize)) then
            begin
                freemem(dictList);
                exit(ERROR(GENERIC_ERROR));   { should never happen }
            end;
            ZDICT_printHex(pbyte(samplesBuffer+pos), printedLength);
        end;
    end; 


    { create dictionary } 
    dictContentSize := ZDICT_dictSize(dictList);
    if (dictContentSize < ZDICT_CONTENTSIZE_MIN) then
    begin 
      freemem(dictList); 
      exit(ERROR(dictionaryCreation_failed)); 
    end;   { dictionary content too small }
    if (dictContentSize < targetDictSize div 4) then
    begin
        //DISPLAYLEVEL(2, '!  warning : selected content significantly smaller than requested (%u < %u) \n', dictContentSize, (unsigned)maxDictSize);
        //if (samplesBuffSize < 10 * targetDictSize)
        //    DISPLAYLEVEL(2, '!  consider increasing the number of samples (total size : %u MB)\n', (unsigned)(samplesBuffSize shr 20));
        //if (minRep > MINRATIO) begin
        //    DISPLAYLEVEL(2, '!  consider increasing selectivity to produce larger dictionary (-s%u) \n', selectivity+1);
        //    DISPLAYLEVEL(2, '!  note : larger dictionaries are not necessarily better, test its efficiency on samples \n');
        //end;
    end;

    if ((dictContentSize > targetDictSize*3)  and (nbSamples > 2*MINRATIO)  and (selectivity>1)) then
    begin
        proposedSelectivity := selectivity-1;
        while ((nbSamples  shr  proposedSelectivity) <= MINRATIO) do
        begin 
          dec(proposedSelectivity); 
        end;
        //DISPLAYLEVEL(2, '!  note : calculated dictionary significantly larger than requested (%u > %u) \n', dictContentSize, (unsigned)maxDictSize);
        //DISPLAYLEVEL(2, '!  consider increasing dictionary size, or produce denser dictionary (-s%u) \n', proposedSelectivity);
        //DISPLAYLEVEL(2, '!  always test dictionary efficiency on real samples \n');
    end;

    { limit dictionary size } 
    lmax := dictList^.pos;   { convention : nb of useful elts within dictList }
    currentSize := 0;
    for n:=1 to lmax-1 do 
    begin
        currentSize :=currentSize + dictList[n].length;
        if (currentSize > targetDictSize) then
        begin 
          currentSize :=currentSize - dictList[n].length; 
          break; 
        end;
    end;
    dictList^.pos := n;
    dictContentSize := currentSize;

    { build dict content }
    ptr := dictBuffer + maxDictSize;
    for u:=1 to dictList^.pos-1 do 
    begin
        l := dictList[u].length;
        ptr :=ptr - l;
        if (ptr<dictBuffer) then
        begin 
          freemem(dictList); 
          exit(ERROR(GENERIC_ERROR)); 
        end;   { should not happen }
        move(samplesBuffer[dictList[u].pos],ptr[0],  l);
    end;

    dictSize := ZDICT_addEntropyTablesFromBuffer_advanced(dictBuffer, dictContentSize, maxDictSize,
                                                         samplesBuffer, samplesSizes, nbSamples,
                                                         params.zParams);

    { clean up }
    freemem(dictList);
    result := dictSize;
end;


{ ZDICT_trainFromBuffer_legacy() :
 * issue : samplesBuffer need to be followed by a noisy guard band.
 * work around : duplicate the buffer, and add the noise }
function ZDICT_trainFromBuffer_legacy(dictBuffer:pbyte; dictBufferCapacity:int32;
                              samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32;
                              params:ZDICT_legacy_params_t):int32;
var
  newBuff:pbyte;
  sBuffSize:int32;
begin
    sBuffSize := ZDICT_totalSampleSize(samplesSizes, nbSamples);
    if (sBuffSize < ZDICT_MIN_SAMPLES_SIZE) then
      exit(0);   { not enough content => no dictionary }

    newBuff := allocmem(sBuffSize + NOISELENGTH);
    if (newBuff=nil) then
      exit(ERROR(memory_allocation));

    move(samplesBuffer[0],newBuff[0],  sBuffSize);
    ZDICT_fillNoise(newBuff + sBuffSize, NOISELENGTH);   { guard band, for end of buffer condition }

    result :=ZDICT_trainFromBuffer_unsafe_legacy(dictBuffer, dictBufferCapacity, newBuff, samplesSizes, nbSamples, params);
    freemem(newBuff);
end;


function ZDICT_trainFromBuffer(dictBuffer:pbyte; dictBufferCapacity:int32;samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32):int32;
var
  params:ZDICT_fastCover_params_t;
begin
    fillbyte(params, sizeof(params), 0);
    params.d := 8;
    params.steps := 4;
    { Use default level since no compression level information is available }
    params.zParams.compressionLevel := ZSTD_CLEVEL_DEFAULT;
    result := ZDICT_optimizeTrainFromBuffer_fastCover(dictBuffer, dictBufferCapacity,
                                               samplesBuffer, samplesSizes, nbSamples,
                                                @params);
end;

function ZDICT_addEntropyTablesFromBuffer(dictBuffer:pbyte; dictContentSize, dictBufferCapacity:int32;
                                  samplesBuffer:pbyte; samplesSizes:pint32; nbSamples:uint32):int32;
var
  params:ZDICT_params_t ;
begin
    fillbyte(params, sizeof(params), 0);
    result :=  ZDICT_addEntropyTablesFromBuffer_advanced(dictBuffer, dictContentSize, dictBufferCapacity,
                                                     samplesBuffer, samplesSizes, nbSamples,
                                                     params);
end;
end.
