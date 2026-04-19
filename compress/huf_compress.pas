unit huf_compress;
{$mode objfpc}{$H+}
interface
uses
bitstream,fse_compress,entropy_common,
hist,zstd,
fse,        { header compression }
huf,
error_private;


{ **************************************************************
*  Error Management
***************************************************************}
//#define HUF_isError ERR_isError
//#define HUF_STATIC_ASSERT(c) DEBUG_STATIC_ASSERT(c)   { use only *after* variable declarations }
{* HUF_buildCTable_wksp() :
 *  Same as HUF_buildCTable(), but using externally allocated scratch buffer.
 *  `workSpace` must be aligned on 4-bytes boundaries, and be at least as large as sizeof(HUF_buildCTable_wksp_tables).
 }

const
 RANK_POSITION_TABLE_SIZE = 32;
 MAX_FSE_TABLELOG_FOR_HUFF_HEADER = 6;
 STARTNODE = HUF_SYMBOLVALUE_MAX+1;
type
  pHUF_compress_tables_t=^HUF_compress_tables_t;
  pHUF_buildCTable_wksp_tables=^HUF_buildCTable_wksp_tables;
  prankPos=^rankPos;
  pnodeElt=^nodeElt;
  nodeElt=record
      count:Uint32;
      parent:int16;
      byte:BYTE;
      nbBits:BYTE;
  end;
  rankPos=record
      base:Uint32;
      curr:Uint32;
  end;
HUF_nbStreams_e=( HUF_singleStream, HUF_fourStreams );
huffNodeTable = array [0..HUF_CTABLE_WORKSPACE_SIZE_Uint32-1] of nodeElt;
HUF_buildCTable_wksp_tables=record
  huffNodeTbl:huffNodeTable;
  rankPosition: array[0..RANK_POSITION_TABLE_SIZE-1] of rankPos;
end;
HUF_compress_tables_t=record
     count:array [0..HUF_SYMBOLVALUE_MAX ] of uint32;
     CTable:array[0..HUF_SYMBOLVALUE_MAX ] of HUF_CElt;
     buildCTable_wksp:HUF_buildCTable_wksp_tables;
end;

function HUF_compress1X_repeat (dst:pbyte;dstSize:int32;const src:pbyte;srcSize:int32;
  maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32;
  hufTable:pHUF_CElt; lrepeat:pHUF_repeat;  preferRepeat,  bmi2:int32):int32;
function HUF_compress4X_repeat (dst:pbyte;dstSize:int32;
                      const src:pbyte;srcSize:int32;
                      maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32;
                      hufTable:pHUF_CElt; lrepeat:pHUF_repeat;  preferRepeat,  bmi2:int32):int32;
function HUF_getNbBits(symbolTable:pbyte;  symbolValue:Uint32):Uint32;
function HUF_validateCTable(const CTable:pHUF_CElt; const count:puint32; maxSymbolValue:uint32):int32;
function HUF_optimalTableLog(maxTableLog:uint32;srcSize:int32;maxSymbolValue:uint32):uint32;
function HUF_buildCTable_wksp (tree:pHUF_CElt; const count:puint32; maxSymbolValue:Uint32;  maxNbBits:Uint32;workSpace:pbyte;wkspSize:int32):int32;
function HUF_estimateCompressedSize(const CTable:pHUF_CElt; const count:puint32; maxSymbolValue:uint32):int32;
function HUF_writeCTable (dst:pbyte;maxDstSize:int32;const CTable:pHUF_CElt;  maxSymbolValue,  huffLog:uint32):int32;
function HUF_readCTable(CTable:pHUF_CElt; maxSymbolValuePtr:puint32; const src:pbyte;srcSize:int32; hasZeroWeights:puint32):int32;
function HUF_compress1X_usingCTable(dst:pbyte;dstSize:int32; const src:pbyte;srcSize:int32; const CTable:pHUF_CElt):int32;
function HUF_compress4X_usingCTable(dst:pbyte;dstSize:int32; const src:pbyte;srcSize:int32; const CTable:pHUF_CElt):int32;
function HUF_buildCTable (tree:pHUF_CElt; const count:puint32;  maxSymbolValue,  maxNbBits:uint32):uint32;
implementation
{ **************************************************************
*  Utils
***************************************************************}
function HUF_optimalTableLog(maxTableLog:uint32;srcSize:int32;maxSymbolValue:uint32):uint32;
begin
    result := FSE_optimalTableLog_internal(maxTableLog, srcSize, maxSymbolValue, 1);
end;


{ *******************************************************
*  HUF : Huffman block compression
********************************************************}
{ HUF_compressWeights() :
 * Same as FSE_compress(), but dedicated to huff0's weights compression.
 * The use case needs much less stack memory.
 * Note : all elements within weightTable are supposed to be <= HUF_TABLELOG_MAX.
 }

function HUF_compressWeights (dst:pbyte;dstSize:int32; const weightTable:pbyte;wtSize:int32):int32;
var
  ostart,op,oend:pbyte;
  maxSymbolValue,tableLog,maxCount:uint32;
  scratchBuffer:array [0..29] of Uint32;
  CTable:array [0..58] of FSE_CTable;
  count: array [0..HUF_TABLELOG_MAX] of uint32;
  norm:array [0..HUF_TABLELOG_MAX] of int16;
  err,hSize,cSize:int32;
begin
    ostart := dst;
    op := ostart;
    oend := ostart + dstSize;
    maxSymbolValue := HUF_TABLELOG_MAX;
    tableLog := MAX_FSE_TABLELOG_FOR_HUFF_HEADER;

    { init conditions }
    if (wtSize <= 1) then
      exit(0);  { Not compressible }

    { Scan input and build symbol stats }
    maxCount := HIST_count_simple(@count[0],  @maxSymbolValue, weightTable, wtSize);   { never fails }
        if (maxCount = wtSize) then
          exit(1);   { only a single symbol in src : rle }
        if (maxCount = 1) then
          exit(0);        { each symbol present maximum once :=> not compressible }
    

    tableLog := FSE_optimalTableLog(tableLog, wtSize, maxSymbolValue);
    err:= FSE_normalizeCount(@norm[0], tableLog, @count[0], wtSize, maxSymbolValue, { useLowProbCount } 0);
    if (ERR_isError(err)<>0) then
      exit(err);

    { Write table description header }
    hSize:=FSE_writeNCount(op, int32(oend-op), @norm[0], maxSymbolValue, tableLog);
    if (ERR_isError(hSize)<>0) then
      exit(hSize);
    op :=op + hSize;

    { Compress }
    err:=FSE_buildCTable_wksp(@CTable[0], @norm[0], maxSymbolValue, tableLog, @scratchBuffer[0], sizeof(scratchBuffer));
    if (ERR_isError(err)<>0) then
      exit(err);
    cSize:=FSE_compress_usingCTable(op, int32(oend - op), weightTable, wtSize, @CTable[0]);
    if (ERR_isError(cSize)<>0) then
      exit(hSize);
      if (cSize = 0) then
        exit(0);   { not enough space for compressed data }
      op :=op + cSize;

    result := int32(op-ostart);
end;


{! HUF_writeCTable() :
    `CTable` : Huffman tree to save, using huf representation.
    @return : size of saved CTable }
function HUF_writeCTable (dst:pbyte;maxDstSize:int32;const CTable:pHUF_CElt;  maxSymbolValue,  huffLog:uint32):int32;
var
  op:pbyte;
  n:uint32;
  bitsToWeight: array[0..HUF_TABLELOG_MAX] of BYTE;   { precomputed conversion table }
  huffWeight: array[0..HUF_SYMBOLVALUE_MAX-1] of BYTE;
  hSize:int32;
begin
    op := dst;

     { check conditions }
    if (maxSymbolValue > HUF_SYMBOLVALUE_MAX) then
      exit(ERROR(maxSymbolValue_tooLarge));

    { convert to weight }
    bitsToWeight[0] := 0;
    for n:=1 to huffLog do
        bitsToWeight[n] := BYTE(huffLog + 1 - n);
    for n:=0 to maxSymbolValue-1 do
        huffWeight[n] := bitsToWeight[CTable[n].nbBits];

    { attempt weights compression by FSE }
       
    hSize:=HUF_compressWeights(op+1, maxDstSize-1, huffWeight, maxSymbolValue);
    if ERR_isError(hSize)<>0 then
       exit(hSize);
    if ((hSize>1)  and  (hSize < maxSymbolValue/2)) then
    begin   { FSE compressed }
        op[0] := BYTE(hSize);
        exit(hSize+1);
    end;

    { write raw values as 4-bits (max : 15) }
    if (maxSymbolValue > (256-128)) then
      exit(ERROR(GENERIC_ERROR));   { should not happen : likely means source cannot be compressed }
    if (((maxSymbolValue+1)/2) + 1 > maxDstSize) then
      exit(ERROR(dstint32ooSmall));   { not enough space within dst buffer }
    op[0] := BYTE(128 {special case} + (maxSymbolValue-1));
    huffWeight[maxSymbolValue] := 0;   { to be sure it doesn't cause msan issue in final combination }
    n:=0;
    while( n<maxSymbolValue) do
    begin
        op[(n div 2)+1] := BYTE((huffWeight[n]  shl  4) + huffWeight[n+1]);
        n:=n+2;
    end;
    result := ((maxSymbolValue+1) div 2) + 1;
end;


function HUF_readCTable(CTable:pHUF_CElt; maxSymbolValuePtr:puint32; const src:pbyte;srcSize:int32; hasZeroWeights:puint32):int32;
var
  tableLog,nbSymbols,nextRankStart,n,curr,w:Uint32;
  huffWeight:array [0..HUF_SYMBOLVALUE_MAX] of byte;   { init not required, even though some static analyzer may complain }
  rankVal:array [0..HUF_TABLELOG_ABSOLUTEMAX] of Uint32;   { large enough for values from 0 to 16 }
  min:word;
  readSize:int32;
  nbPerRank,valPerRank:array [0..HUF_TABLELOG_MAX+1] of uint16;
begin
    tableLog := 0;
    nbSymbols := 0;

    { get symbol weights }
    readSize:=HUF_readStats(huffWeight, HUF_SYMBOLVALUE_MAX+1, rankVal,  @nbSymbols,  @tableLog, src, srcSize);
    hasZeroWeights^ := ord(rankVal[0] > 0);

    { check result }
    if (tableLog > HUF_TABLELOG_MAX) then
       exit(ERROR(tableLog_tooLarge));
    if (nbSymbols > maxSymbolValuePtr^+1) then
     exit(ERROR(maxSymbolValue_tooSmall));

    { Prepare base value per rank }
    nextRankStart := 0;
    for n:=1 to tableLog do
    begin
        curr := nextRankStart;
        nextRankStart :=nextRankStart + (rankVal[n]  shl  (n-1));
        rankVal[n] := curr;
    end;

    { fill nbBits }
     
    for n:=0 to nbSymbols-1 do 
    begin
      w := huffWeight[n];
      CTable[n].nbBits := BYTE(tableLog + 1 - w)  and  -ord(w <> 0);
    end;

    { fill val }

    fillbyte(nbPerRank,sizeof(nbPerRank),0);
    fillbyte(valPerRank,sizeof(nbPerRank),0);
    
    for n:=0 to nbSymbols-1 do
      inc(nbPerRank[CTable[n].nbBits]); 
    
    { determine stating value per rank }
    valPerRank[tableLog+1] := 0;   { for w=0 }

    for n:=tableLog downto 1 do
    begin  { start at n:=tablelog <^. w:=1 }
        valPerRank[n] := min;     { get starting value within each rank }
        min :=min + nbPerRank[n];
        min :=min shr 1;
    end;
    { assign value within rank, symbol order }
    for n:=0 to nbSymbols-1 do
    begin 
      CTable[n].val := valPerRank[CTable[n].nbBits];
      inc(valPerRank[CTable[n].nbBits]); 
    end;

    maxSymbolValuePtr^ := nbSymbols - 1;
    result := readSize;
end;

function HUF_getNbBits(symbolTable:pbyte;  symbolValue:Uint32):Uint32;
var
  table:pHUF_CElt;
begin
    table := pHUF_CElt(symbolTable);
    assert(symbolValue <= HUF_SYMBOLVALUE_MAX);
    result := table[symbolValue].nbBits;
end;

{*
 * HUF_setMaxHeight():
 * Enforces maxNbBits on the Huffman tree described in huffNode.
 *
 * It sets all nodes with nbBits > maxNbBits to be maxNbBits. Then it adjusts
 * the tree to so that it is a valid canonical Huffman tree.
 *
 * @pre               The sum of the ranks of each symbol = 2^largestBits,
 *                    where largestBits = huffNode[lastNonnil].nbBits.
 * @post              The sum of the ranks of each symbol = 2^largestBits,
 *                    where largestBits is the return value <= maxNbBits.
 *
 * @param huffNode    The Huffman tree modified in place to enforce maxNbBits.
 * @param lastNonnil The symbol with the lowest count in the Huffman tree.
 * @param maxNbBits   The maximum allowed number of bits, which the Huffman tree
 *                    may not respect. After this function the Huffman tree will
 *                    respect maxNbBits.
 * @return            The maximum number of bits of the Huffman tree after adjustment,
 *                    necessarily no more than maxNbBits.
 }
function HUF_setMaxHeight(huffNode:pnodeElt;  lastNonnil,  maxNbBits:Uint32):Uint32;
var
  largestBits,baseCost:Uint32;
  totalCost,n:int32;
  noSymbol,currentNbBits,nBitsToDecrease,highPos,lowPos,highTotal,lowTotal:Uint32;
  rankLast:array [0..HUF_TABLELOG_MAX+1] of Uint32;
  pos:int32;
begin
    largestBits := huffNode[lastNonnil].nbBits;
    { early exit : no elt > maxNbBits, so the tree is already valid. }
    if (largestBits <= maxNbBits) then
      exit(largestBits);

    { there are several too large elements (at least >= 2) }
 
    totalCost := 0;
    baseCost := 1  shl  (largestBits - maxNbBits);
    n := int32(lastNonnil);

    { Adjust any ranks > maxNbBits to maxNbBits.
     * Compute totalCost, which is how far the sum of the ranks is
     * we are over 2^largestBits after adjust the offending ranks.
     }
    while (huffNode[n].nbBits > maxNbBits) do
    begin
        totalCost :=totalCost + baseCost - (1  shl  (largestBits - huffNode[n].nbBits));
        huffNode[n].nbBits := BYTE(maxNbBits);
        dec(n);
    end;
    { n stops at huffNode[n].nbBits <= maxNbBits }
    assert(huffNode[n].nbBits <= maxNbBits);
    { n end at index of smallest symbol using < maxNbBits }
    while (huffNode[n].nbBits = maxNbBits) do
      dec(n);

    { renorm totalCost from 2^largestBits to 2^maxNbBits
     * note : totalCost is necessarily a multiple of baseCost }
    assert((totalCost  and  (baseCost - 1)) = 0);
    totalCost  :=totalCost  shr (largestBits - maxNbBits);
    assert(totalCost > 0);

        { repay normalized cost }
  noSymbol := $F0F0F0F0;

  { Get pos of last (smallest := lowest cum. count) symbol per rank }
  fillbyte(rankLast, sizeof(rankLast), $F0);
  currentNbBits := maxNbBits;
  
  for pos:=n downto 0 do 
  begin
    if (huffNode[pos].nbBits >= currentNbBits) then
      continue;
    currentNbBits := huffNode[pos].nbBits;   { < maxNbBits }
    rankLast[maxNbBits-currentNbBits] := Uint32(pos);
  end;
  
  while (totalCost > 0) do
  begin
      { Try to reduce the next power of 2 above totalCost because we
       * gain back half the rank.
       }
      nBitsToDecrease := BIT_highbit32(Uint32(totalCost)) + 1;
      while ( nBitsToDecrease > 1) do
      begin
          highPos := rankLast[nBitsToDecrease];
          lowPos := rankLast[nBitsToDecrease-1];
          if (highPos = noSymbol) then
            continue;
          { Decrease highPos if no symbols of lowPos or if it is
           * not cheaper to remove 2 lowPos than highPos.
           }
          if (lowPos = noSymbol) then
            break;
          highTotal := huffNode[highPos].count;
          lowTotal := 2 * huffNode[lowPos].count;
          if (highTotal <= lowTotal) then
            break;
          dec(nBitsToDecrease);
      end;
      { only triggered when no more rank 1 symbol left :=> find closest one (note : there is necessarily at least one !) }
      assert((rankLast[nBitsToDecrease] <> noSymbol)  or  (nBitsToDecrease = 1));
      { HUF_MAX_TABLELOG test just to please gcc 5+; but it should not be necessary }
      while ((nBitsToDecrease<=HUF_TABLELOG_MAX)  and (rankLast[nBitsToDecrease] = noSymbol)) do
          inc(nBitsToDecrease);
      assert(rankLast[nBitsToDecrease] <> noSymbol);
      { Increase the number of bits to gain back half the rank cost. }
      totalCost :=totalCost -(1  shl  (nBitsToDecrease-1));
      inc(huffNode[rankLast[nBitsToDecrease]].nbBits);
  
      { Fix up the new rank.
       * If the new rank was empty, this symbol is now its smallest.
       * Otherwise, this symbol will be the largest in the new rank so no adjustment.
       }
      if (rankLast[nBitsToDecrease-1] = noSymbol) then
          rankLast[nBitsToDecrease-1] := rankLast[nBitsToDecrease];
      { Fix up the old rank.
       * If the symbol was at position 0, meaning it was the highest weight symbol in the tree,
       * it must be the only symbol in its rank, so the old rank now has no symbols.
       * Otherwise, since the Huffman nodes are sorted by count, the previous position is now
       * the smallest node in the rank. If the previous position belongs to a different rank,
       * then the rank is now empty.
       }
      if (rankLast[nBitsToDecrease] = 0) then   { special case, reached largest symbol }
          rankLast[nBitsToDecrease] := noSymbol
      else 
      begin
          dec(rankLast[nBitsToDecrease]);
          if (huffNode[rankLast[nBitsToDecrease]].nbBits <> maxNbBits-nBitsToDecrease) then
              rankLast[nBitsToDecrease] := noSymbol;   { this rank is now empty }
      end;
  end;   { while (totalCost > 0) }

  { If we've removed too much weight, then we have to add it back.
   * To avoid overshooting again, we only adjust the smallest rank.
   * We take the largest nodes from the lowest rank 0 and move them
   * to rank 1. There's guaranteed to be enough rank 0 symbols because
   * TODO.
   }
  while (totalCost < 0) do
  begin  { Sometimes, cost correction overshoot }
      { special case : no rank 1 symbol (using maxNbBits-1);
       * let's create one from largest rank 0 (using maxNbBits).
       }
      if (rankLast[1] = noSymbol) then
      begin
          while (huffNode[n].nbBits = maxNbBits) do
            dec(n);
          dec(huffNode[n+1].nbBits);
          assert(n >= 0);
          rankLast[1] := Uint32(n+1);
          inc(totalCost);
          continue;
      end;
      dec(huffNode[ rankLast[1] + 1 ].nbBits);
      inc(rankLast[1]);
      inc(totalCost);
  end;
     { repay normalized cost }
    { there are several too large elements (at least >= 2) }

  result := maxNbBits;
end;

{*
 * HUF_sort():
 * Sorts the symbols [0, maxSymbolValue] by count[symbol] in decreasing order.
 *
 * @param[out] huffNode       Sorted symbols by decreasing count. Only members `.count` and `.byte` are filled.
 *                            Must have (maxSymbolValue + 1) entries.
 * @param[in]  count          Histogram of the symbols.
 * @param[in]  maxSymbolValue Maximum symbol value.
 * @param      rankPosition   This is a scratch workspace. Must have RANK_POSITION_TABLE_SIZE entries.
 }
procedure HUF_sort(huffNode:pnodeElt; const count:puint32; maxSymbolValue:Uint32; rankPosition:prankPos);
var
  n,maxSymbolValue1,c,r,pos:int32;
  lowerRank:Uint32;
begin
  maxSymbolValue1 := int32(maxSymbolValue) + 1;

    { Compute base and set curr to base.
     * For symbol s let lowerRank := BIT_highbit32(count[n]+1) and rank := lowerRank + 1.
     * Then 2^lowerRank <= count[n]+1 <= 2^rank.
     * We attribute each symbol to lowerRank's base value, because we want to know where
     * each rank begins in the output, so for rank R we want to count ranks R+1 and above.
     }
    fillbyte(rankPosition^, sizeof(rankPos) * RANK_POSITION_TABLE_SIZE, 0);
    for n := 0 to maxSymbolValue1-1 do 
    begin
      lowerRank := BIT_highbit32(count[n] + 1);
      inc(rankPosition[lowerRank].base);
    end;
    assert(rankPosition[RANK_POSITION_TABLE_SIZE - 1].base = 0);
    for n := RANK_POSITION_TABLE_SIZE - 1 downto 1 do 
    begin
        rankPosition[n-1].base :=rankPosition[n-1].base + rankPosition[n].base;
        rankPosition[n-1].curr := rankPosition[n-1].base;
    end;
    { Sort }
    for n := 0 to maxSymbolValue1 -1 do 
    begin
        c := count[n];
        r := BIT_highbit32(c+1) + 1;
        pos := rankPosition[r].curr;
        inc(rankPosition[r].curr);
        { Insert into the correct position in the rank.
         * We have at most 256 symbols, so this insertion should be fine.
         }
        while ((pos > rankPosition[r].base)  and (c > huffNode[pos-1].count)) do
        begin
            huffNode[pos] := huffNode[pos-1];
            dec(pos);
        end;
        huffNode[pos].count := c;
        huffNode[pos].byte  := BYTE(n);
    end;
end;

{ HUF_buildTree():
 * Takes the huffNode array sorted by HUF_sort() and builds an unlimited-depth Huffman tree.
 *
 * @param huffNode        The array sorted by HUF_sort(). Builds the Huffman tree in this array.
 * @param maxSymbolValue  The maximum symbol value.
 * @return                The smallest node in the Huffman tree (by count).
 }
function HUF_buildTree(huffNode:pnodeElt; maxSymbolValue:Uint32):int32;
var
  huffNode0:pnodeElt;
  nonnilRank,lowS,lowN,nodeNb,n,nodeRoot:int32;
  n1,n2:int32;
begin
    huffNode0 := huffNode - 1;
    nodeNb := STARTNODE;
    { init for parents }
    nonnilRank := int32(maxSymbolValue);
    while (huffNode[nonnilRank].count = 0) do
      dec(nonnilRank);
    lowS := nonnilRank; 
    nodeRoot := nodeNb + lowS - 1; 
    lowN := nodeNb;
    huffNode[nodeNb].count := huffNode[lowS].count + huffNode[lowS-1].count;
    huffNode[lowS-1].parent := int16(nodeNb);
    huffNode[lowS].parent := huffNode[lowS-1].parent;
    inc(nodeNb); 
    lowS:=lowS-2;
    for n:=nodeNb to nodeRoot do
      huffNode[n].count := Uint32(uint32(1) shl 30);
    huffNode0[0].count := Uint32(uint32(1) shl 31);  { fake entry, strong barrier }

  
    { create parents }
    while (nodeNb <= nodeRoot) do
    begin
      if (huffNode[lowS].count < huffNode[lowN].count) then
      begin
        n1 := lowS;
        dec(lowS);
        n2 := lowS ;
        dec(lowS);
      end
      else
      begin
        n1 := lowN;
        inc(lowN);
        n2 := lowN;
        inc(lowN);
      end;
      huffNode[nodeNb].count := huffNode[n1].count + huffNode[n2].count;
      huffNode[n2].parent := word(nodeNb);
      huffNode[n1].parent := huffNode[n2].parent;
      inc(nodeNb);
    end;

    { distribute weights (unlimited tree height) }
    huffNode[nodeRoot].nbBits := 0;
    for n:=nodeRoot-1 downto STARTNODE do
        huffNode[n].nbBits := huffNode[ huffNode[n].parent ].nbBits + 1;
    for n:=0 to nonnilRank do
        huffNode[n].nbBits := huffNode[ huffNode[n].parent ].nbBits + 1;

    result := nonnilRank;
end;

{*
 * HUF_buildCTableFromTree():
 * Build the CTable given the Huffman tree in huffNode.
 *
 * @param[out] CTable         The output Huffman CTable.
 * @param      huffNode       The Huffman tree.
 * @param      nonnilRank    The last and smallest node in the Huffman tree.
 * @param      maxSymbolValue The maximum symbol value.
 * @param      maxNbBits      The exact maximum number of bits used in the Huffman tree.
 }
procedure HUF_buildCTableFromTree(CTable:pHUF_CElt; huffNode:pnodeElt; nonnilRank:int32; maxSymbolValue,maxNbBits:Uint32);
var
  n,alphabetSize:int32;
  nbPerRank,valPerRank:array [0..HUF_TABLELOG_MAX] of word;
  min:word;
begin
    { fill result into ctable (val, nbBits) }
    fillbyte(nbPerRank,sizeof(nbPerRank),0);
    fillbyte(valPerRank,sizeof(nbPerRank),0);
    alphabetSize := int32(maxSymbolValue + 1);
    for n:=0 to nonnilRank do
        inc(nbPerRank[huffNode[n].nbBits]);
    { determine starting value per rank }
    min := 0;
    for n:=int32(maxNbBits) downto 1 do
    begin
        valPerRank[n] := min;      { get starting value within each rank }
        min :=min + nbPerRank[n];
        min :=min  shr  1;
    end;
    for n:=0 to alphabetSize-1 do
        CTable[huffNode[n].byte].nbBits := huffNode[n].nbBits;   { push nbBits per symbol, symbol order }
    for n:=0 to alphabetSize-1 do
    begin
        CTable[n].val := valPerRank[CTable[n].nbBits];   { assign value within rank, symbol order }
        inc(valPerRank[CTable[n].nbBits]);
    end;
end;

function HUF_buildCTable_wksp (tree:pHUF_CElt; const count:puint32; maxSymbolValue:Uint32;  maxNbBits:Uint32;workSpace:pbyte;wkspSize:int32):int32;
var
  wksp_tables:pHUF_buildCTable_wksp_tables;
  huffNode0,huffNode:pnodeElt;
  nonnilRank:int32;
begin
    wksp_tables := pHUF_buildCTable_wksp_tables(workSpace);
    huffNode0 := wksp_tables^.huffNodeTbl;
    huffNode := huffNode0+1;

    { safety checks }
    if ((int32(workSpace)  and  3) <> 0) then//怪怪
      exit(ERROR(GENERIC_ERROR));  { must be aligned on 4-bytes boundaries }
    if (wkspSize < sizeof(HUF_buildCTable_wksp_tables)) then
      exit(ERROR(workSpace_tooSmall));
    if (maxNbBits = 0) then
      maxNbBits := HUF_TABLELOG_DEFAULT;
    if (maxSymbolValue > HUF_SYMBOLVALUE_MAX) then
      exit(ERROR(maxSymbolValue_tooLarge));
    fillbyte(huffNode0^, sizeof(huffNodeTable), 0);

    { sort, decreasing order }
    HUF_sort(huffNode, count, maxSymbolValue, wksp_tables^.rankPosition);

    { build tree }
    nonnilRank := HUF_buildTree(huffNode, maxSymbolValue);

    { enforce maxTableLog }
    maxNbBits := HUF_setMaxHeight(huffNode, Uint32(nonnilRank), maxNbBits);
    if (maxNbBits > HUF_TABLELOG_MAX) then
      exit(ERROR(GENERIC_ERROR));   { check fit into table }

    HUF_buildCTableFromTree(tree, huffNode, nonnilRank, maxSymbolValue, maxNbBits);

    result := maxNbBits;
end;

function HUF_estimateCompressedSize(const CTable:pHUF_CElt; const count:puint32; maxSymbolValue:uint32):int32;
var
  nbBits,s:int32;
begin
    nbBits := 0;
    for s := 0 to int32(maxSymbolValue) do 
    begin
        nbBits :=nbBits + CTable[s].nbBits * count[s];
    end;
    result := nbBits  shr  3;
end;

function HUF_validateCTable(const CTable:pHUF_CElt; const count:puint32; maxSymbolValue:uint32):int32;
var
  bad,s:int32; 
begin
  bad := 0;

  for s := 0 to int32(maxSymbolValue) do
  begin
    bad  := ord((bad<>0)  or  ((count[s] <> 0)  and  (CTable[s].nbBits = 0)));
  end;
  result :=  ord(bad=0);
end;

function HUF_compressBound(size:int32):int32; 
begin 
  result := HUF_COMPRESSBOUND(size); 
end;

procedure HUF_encodeSymbol(bitCPtr:pBIT_CStream_t; symbol:Uint32; const CTable:pHUF_CElt);
begin
    BIT_addBitsFast(bitCPtr, CTable[symbol].val, CTable[symbol].nbBits);
end;

function HUF_compress1X_usingCTable_internal_body(dst:pbyte;dstSize:int32;
  const src:pbyte;srcSize:int32;const CTable:pHUF_CElt):int32;
var
  ip,ostart,oend,op:pbyte;
  n,initErr:int32;
  bitC:BIT_CStream_t;
begin
    ip := src;
    ostart := dst;
    oend := ostart + dstSize;
    op := ostart;

    { init }
    if (dstSize < 8) then
      exit(0);   { not enough space to compress }
    initErr := BIT_initCStream( @bitC, op, int32(oend-op));
    if (HUF_isError(initErr)<>0) then
      exit(0); 

    n := srcSize  and  not 3;  { join to mod 4 }
    case (srcSize  and  3) of
        3 : 
        begin
            HUF_encodeSymbol( @bitC, ip[n+ 2], CTable);
            if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*4+7) then
               BIT_flushBits(@bitC);
            { fall-through to case 2 }
            HUF_encodeSymbol( @bitC, ip[n+ 1], CTable);
             if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*2+7) then
                BIT_flushBits(@bitC);
            { fall-through to case 1 }
            HUF_encodeSymbol( @bitC, ip[n+ 0], CTable);
            BIT_flushBits( @bitC);
        end;
        2 :
        begin 
            HUF_encodeSymbol( @bitC, ip[n+ 1], CTable);
             if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*2+7) then
                BIT_flushBits(@bitC);
            { fall-through to case 1 }
            HUF_encodeSymbol( @bitC, ip[n+ 0], CTable);
            BIT_flushBits( @bitC);
        end;
        1 : 
        begin
            HUF_encodeSymbol( @bitC, ip[n+ 0], CTable);
            BIT_flushBits( @bitC);
        end;
        0 : ;
        else;
    end;

    while (n>0) do
    begin  { note : n and 3=0 at this stage }
        HUF_encodeSymbol( @bitC, ip[n- 1], CTable);
         if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*2+7) then
            BIT_flushBits(@bitC);
        HUF_encodeSymbol( @bitC, ip[n- 2], CTable);
         if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*4+7) then
            BIT_flushBits(@bitC);
        HUF_encodeSymbol( @bitC, ip[n- 3], CTable);
         if (sizeof(bitC.bitContainer)*8 < HUF_TABLELOG_MAX*2+7) then
            BIT_flushBits(@bitC);
        HUF_encodeSymbol( @bitC, ip[n- 4], CTable);
        BIT_flushBits( @bitC);
        n:=n-4;
    end;

    result := BIT_closeCStream( @bitC);
end;


function HUF_compress1X_usingCTable_internal_bmi2(dst:pbyte;dstSize:int32;
                                   const src:pbyte;srcSize:int32;
                                   const CTable:pHUF_CElt):int32;
begin
    result := HUF_compress1X_usingCTable_internal_body(dst, dstSize, src, srcSize, CTable);
end;

function HUF_compress1X_usingCTable_internal_default(dst:pbyte;dstSize:int32;
                                      const src:pbyte;srcSize:int32;
                                      const CTable:pHUF_CElt):int32;
begin
    result := HUF_compress1X_usingCTable_internal_body(dst, dstSize, src, srcSize, CTable);
end;

function HUF_compress1X_usingCTable_internal(dst:pbyte;dstSize:int32;
                              const src:pbyte;srcSize:int32;
                              const CTable:pHUF_CElt; const bmi2:int32):int32;
begin
    if (bmi2<>0) then
    begin
        exit(HUF_compress1X_usingCTable_internal_bmi2(dst, dstSize, src, srcSize, CTable));
    end;
    result := HUF_compress1X_usingCTable_internal_default(dst, dstSize, src, srcSize, CTable);
end;

function HUF_compress1X_usingCTable(dst:pbyte;dstSize:int32; const src:pbyte;srcSize:int32; const CTable:pHUF_CElt):int32;
begin
    result := HUF_compress1X_usingCTable_internal(dst, dstSize, src, srcSize, CTable, { bmi2 } 0);
end;


function HUF_compress4X_usingCTable_internal(dst:pbyte;dstSize:int32;
                              const src:pbyte;srcSize:int32;
                              const CTable:pHUF_CElt; bmi2:int32 ):int32;
var
  segmentSize,cSize:int32;
  ip,iend,ostart,oend,op:pbyte;
begin
    segmentSize := (srcSize+3) div 4;   { first 3 segments }
    ip := src;
    iend := ip + srcSize;
    ostart := dst;
    oend := ostart + dstSize;
    op := ostart;

    if (dstSize < 6 + 1 + 1 + 1 + 8) then
      exit(0);   { minimum space to compress successfully }
    if (srcSize < 12) then
      exit(0);   { no saving possible : too small input }
    op :=op + 6;   { jumpTable }

    assert(op <= oend);   
    cSize := HUF_compress1X_usingCTable_internal(op, int32(oend-op), ip, segmentSize, CTable, bmi2);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);
    if (cSize=0) then
      exit(0);
    assert(cSize <= 65535);
    MEM_writeLE16(ostart, Uint16(cSize));
    op :=op + cSize;

    ip :=ip + segmentSize;
    assert(op <= oend);
   
    cSize := HUF_compress1X_usingCTable_internal(op, int32(oend-op), ip, segmentSize, CTable, bmi2);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);
    if (cSize=0) then
      exit(0);
    assert(cSize <= 65535);
    MEM_writeLE16(ostart+2, Uint16(cSize));
    op :=op + cSize;


    ip :=ip + segmentSize;
    assert(op <= oend);
   
    cSize:=HUF_compress1X_usingCTable_internal(op, int32(oend-op), ip, segmentSize, CTable, bmi2);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);
    if (cSize=0) then
      exit(0);
    assert(cSize <= 65535);
    MEM_writeLE16(ostart+4, Uint16(cSize));
    op :=op + cSize;

    ip :=ip + segmentSize;
    assert(op <= oend);
    assert(ip <= iend);
   
    cSize := HUF_compress1X_usingCTable_internal(op, int32(oend-op), ip, int32(iend-ip), CTable, bmi2);
    if (ERR_isError(cSize)<>0) then
       exit(cSize);
    if (cSize=0) then 
      exit(0);
    op :=op + cSize;


    result := int32(op-ostart);
end;

function HUF_compress4X_usingCTable(dst:pbyte;dstSize:int32; const src:pbyte;srcSize:int32; const CTable:pHUF_CElt):int32;
begin
    result := HUF_compress4X_usingCTable_internal(dst, dstSize, src, srcSize, CTable, { bmi2 } 0);
end;



function HUF_compressCTable_internal(ostart, op, oend:pbyte;
  const src:pbyte;srcSize:int32;nbStreams:HUF_nbStreams_e; const CTable:pHUF_CElt; const bmi2:int32):int32;
var
  cSize:int32;
begin
  if (nbStreams=HUF_singleStream) then
    cSize := HUF_compress1X_usingCTable_internal(op, int32(oend - op), src, srcSize, CTable, bmi2)
  else
    cSize := HUF_compress4X_usingCTable_internal(op, int32(oend - op), src, srcSize, CTable, bmi2);
  if (HUF_isError(cSize)<>0) then
  begin 
    exit(cSize); 
  end;
  if (cSize=0) then
  begin 
    exit(0); 
  end;   { uncompressible }
  op :=op + cSize;
  { check compressibility }
  assert(op >= ostart);
  if (int32(op-ostart) >= srcSize-1) then
  begin 
    exit(0); 
  end;
  result := int32(op-ostart);
end;



{ HUF_compress_internal() :
 * `workSpace_align4` must be aligned on 4-bytes boundaries,
 * and occupies the same space as a table of HUF_WORKSPACE_SIZE_Uint32 unsigned }
function HUF_compress_internal (dst:pbyte;dstSize:int32;const src:pbyte;srcSize:int32;
  maxSymbolValue,  huffLog:uint32;nbStreams:HUF_nbStreams_e;
  workSpace_align4:pbyte; wkspSize:int32;
  oldHufTable:pHUF_CElt; lrepeat:pHUF_repeat; preferRepeat:int32;
  const bmi2:int32 ):int32;
var
  table:pHUF_compress_tables_t;
  ostart,oend,op:pbyte;
  maxBits,oldSize,newSize,largest,hSize:int32;
begin
    table := pHUF_compress_tables_t(workSpace_align4);
    ostart := dst;
    oend := ostart + dstSize;
    op := ostart;

    //HUF_STATIC_ASSERT(sizeof(HUF_compress_tables_t) <= HUF_WORKSPACE_SIZE);
    assert((int32(workSpace_align4)  and  3) = 0);   { must be aligned on 4-bytes boundaries }

    { checks  and  inits }
    if (wkspSize < HUF_WORKSPACE_SIZE) then
      exit(ERROR(workSpace_tooSmall));
    if (srcSize=0) then
      exit(0);  { Uncompressed }
    if (dstSize=0) then
      exit(0);  { cannot fit anything within dst budget }
    if (srcSize > HUF_BLOCKSIZE_MAX) then
      exit(ERROR(srcSize_wrong));   { current block size limit }
    if (huffLog > HUF_TABLELOG_MAX) then
      exit(ERROR(tableLog_tooLarge));
    if (maxSymbolValue > HUF_SYMBOLVALUE_MAX) then
      exit(ERROR(maxSymbolValue_tooLarge));
    if (maxSymbolValue=0) then
      maxSymbolValue := HUF_SYMBOLVALUE_MAX;
    if (huffLog=0) then
      huffLog := HUF_TABLELOG_DEFAULT;

    { Heuristic : If old table is valid, use it for small inputs }
    if (preferRepeat<>0)  and  (lrepeat<>nil) and  (lrepeat^ = HUF_repeat_valid) then
    begin
        exit(HUF_compressCTable_internal(ostart, op, oend,src, srcSize,
                                           nbStreams, oldHufTable, bmi2));
    end;

    { Scan input and build symbol stats }
   
    largest := HIST_count_wksp (table^.count,  @maxSymbolValue, src, srcSize, workSpace_align4, wkspSize);
    if (ERR_isError(largest)<>0) then
      exit(largest);
    if (largest = srcSize) then
    begin 
      ostart^ := (src)[0]; 
      exit(1); 
    end;   { single symbol, rle }
    if (largest <= (srcSize  shr  7)+4) then
      exit(0);   { heuristic : probably not compressible enough }


    { Check validity of previous table }
    if ( lrepeat<>nil) and  (lrepeat^ = HUF_repeat_check)
       and  (HUF_validateCTable(oldHufTable, table^.count, maxSymbolValue)=0) then
    begin
        lrepeat^ := HUF_repeat_none;
    end;
    { Heuristic : use existing table for small inputs }
    if (preferRepeat<>0)  and  (lrepeat<>nil)  and  (lrepeat^ <> HUF_repeat_none) then
    begin
        exit(HUF_compressCTable_internal(ostart, op, oend,src, srcSize,
                                           nbStreams, oldHufTable, bmi2));
    end;

    { Build Huffman Tree }
    huffLog := HUF_optimalTableLog(huffLog, srcSize, maxSymbolValue);
    maxBits := HUF_buildCTable_wksp(table^.CTable, table^.count,maxSymbolValue, huffLog,
                                             @table^.buildCTable_wksp, sizeof(table^.buildCTable_wksp));
    if (ERR_isError(maxBits)<>0) then
     exit(maxBits);
    huffLog := Uint32(maxBits);
    { Zero unused symbols in CTable, so we can check it for validity }
    fillbyte(table^.CTable[maxSymbolValue + 1],
           sizeof(table^.CTable) - ((maxSymbolValue + 1) * sizeof(HUF_CElt)), 0);
    

    { Write table description header }
   
    hSize := HUF_writeCTable (op, dstSize, table^.CTable, maxSymbolValue, huffLog);
    if (ERR_isError(hSize)<>0) then
       exit(hSize);
    { Check if using previous huffman table is beneficial }
    if (lrepeat<>nil)  and  (lrepeat^ <> HUF_repeat_none) then
    begin
        oldSize := HUF_estimateCompressedSize(oldHufTable, table^.count, maxSymbolValue);
        newSize := HUF_estimateCompressedSize(table^.CTable, table^.count, maxSymbolValue);
        if (oldSize <= hSize + newSize)  or  (hSize + 12 >= srcSize) then
        begin
            exit(HUF_compressCTable_internal(ostart, op, oend,src, srcSize,nbStreams, oldHufTable, bmi2));
        end;   
    end;

    { Use the new huffman table }
    if (hSize + 12 >= srcSize) then
    begin 
      exit(0); 
    end;
    op :=op + hSize;
    if (lrepeat<>nil) then
    begin 
      lrepeat^ := HUF_repeat_none; 
    end;
    if (oldHufTable<>nil) then
        move( table^.CTable, oldHufTable^,sizeof(table^.CTable));  { Save new table }

    result := HUF_compressCTable_internal(ostart, op, oend,src, srcSize,nbStreams, table^.CTable, bmi2);
end;


function HUF_compress1X_wksp (dst:pbyte;dstSize:int32;const src:pbyte;srcSize:int32;
  maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32):int32;
begin
    result := HUF_compress_internal(dst, dstSize, src, srcSize,
                                 maxSymbolValue, huffLog, HUF_singleStream,
                                 workSpace, wkspSize,
                                 nil, nil, 0, 0 {bmi2});
end;

function HUF_compress1X_repeat (dst:pbyte;dstSize:int32;const src:pbyte;srcSize:int32;
  maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32;
  hufTable:pHUF_CElt; lrepeat:pHUF_repeat;  preferRepeat,  bmi2:int32):int32;
begin
    result := HUF_compress_internal(dst, dstSize, src, srcSize,
                                 maxSymbolValue, huffLog, HUF_singleStream,
                                 workSpace, wkspSize, hufTable,
                                 lrepeat, preferRepeat, bmi2);
end;

{ HUF_compress4X_repeat():
 * compress input using 4 streams.
 * provide workspace to generate compression tables }
function HUF_compress4X_wksp (dst:pbyte;dstSize:int32;const src:pbyte;srcSize:int32;
  maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32):int32;
begin
    result := HUF_compress_internal(dst, dstSize, src, srcSize,
                                 maxSymbolValue, huffLog, HUF_fourStreams,
                                 workSpace, wkspSize,
                                 nil, nil, 0, 0 {bmi2});
end;

{ HUF_compress4X_repeat():
 * compress input using 4 streams.
 * re-use an existing huffman compression table }
function HUF_compress4X_repeat (dst:pbyte;dstSize:int32;
                      const src:pbyte;srcSize:int32;
                      maxSymbolValue,  huffLog:uint32;workSpace:pbyte;  wkspSize:int32;
                      hufTable:pHUF_CElt; lrepeat:pHUF_repeat;  preferRepeat,  bmi2:int32):int32;
begin
    result := HUF_compress_internal(dst, dstSize, src, srcSize,
                                 maxSymbolValue, huffLog, HUF_fourStreams,
                                 workSpace, wkspSize,
                                 hufTable, lrepeat, preferRepeat, bmi2);
end;

{* HUF_buildCTable() :
 * @return : maxNbBits
 *  Note : count is used before tree is written, so they can safely overlap
 }
function HUF_buildCTable (tree:pHUF_CElt; const count:puint32;  maxSymbolValue,  maxNbBits:uint32):uint32;
var
  workspace:HUF_buildCTable_wksp_tables;
begin
    result := HUF_buildCTable_wksp(tree, count, maxSymbolValue, maxNbBits,  @workspace, sizeof(workspace));
end;

function HUF_compress1X (dst:pbyte;dstSize:int32;
                 const src:pbyte;srcSize:int32;
                 maxSymbolValue,  huffLog:uint32):int32;
var
  workSpace:array [0..HUF_WORKSPACE_SIZE_Uint32_1] of uint32;
begin
    result := HUF_compress1X_wksp(dst, dstSize, src, srcSize, maxSymbolValue, huffLog, @workSpace[0], sizeof(workSpace));
end;

function HUF_compress2 (dst:pbyte;dstSize:int32;
                const src:pbyte;srcSize:int32;
                maxSymbolValue,  huffLog:uint32):int32;
var
  workSpace:array [0..HUF_WORKSPACE_SIZE_Uint32_1] of uint32;
begin
    result := HUF_compress4X_wksp(dst, dstSize, src, srcSize, maxSymbolValue, huffLog, @workSpace[0], sizeof(workSpace));
end;

function HUF_compress (dst:pbyte;maxDstSize:int32; const src:pbyte;srcSize:int32):int32;
begin
    result := HUF_compress2(dst, maxDstSize, src, srcSize, 255, HUF_TABLELOG_DEFAULT);
end;
end.
