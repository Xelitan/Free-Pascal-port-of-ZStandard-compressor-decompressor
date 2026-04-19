unit divsufsortutils;
{$mode objfpc}{$H+}

interface
uses math,sysutils,divsufsort;
implementation
{- Private Function -}
{ Binary search for inverse bwt. }
function binarysearch_lower(A:pint32;  size,  value:int32):int32;
var
  half, i:int32;
begin
  i := 0;
  half := size shr 1;
  while ( 0 < size ) do
  begin
    if (A[i + half] < value) then
    begin
      i := i + half + 1;
      half :=half - (size and 1) xor 1;
    end;
    size := half; 
    half :=half shr 1;
  end;
  result := i;
end;
{- Functions -}
{ Burrows-Wheeler transform. }
function bw_transform(const T, U:pbyte; SA:pint32; n:int32; idx:pint32):int32;
var
  A:pint32;
  c, i, j, p, lt:int32; 
begin

  { Check arguments. }
  if ((T = nil) or (U = nil) or (n < 0) or (idx = nil)) then 
  begin 
    exit(-1); 
  end;
  if(n <= 1) then
  begin
    if(n = 1) then
    begin 
      U[0] := T[0]; 
    end;
    idx^ := n;
    exit(0);
  end;
  A := SA;
  if(A = nil) then
  begin
    i := divbwt(T, U, nil, n,nil,nil,0);
    if(0 <= i) then
    begin 
      idx^ := i; 
      i := 0; 
    end;
    exit(ptrint(i));
  end;
  { BW transform. }
  if (T = U) then
  begin
    lt := n;
    j := 0;
    for i := 0 to  n-1 do
    begin
      p := lt - 1;
      lt := A[i];
      if (0 <= p) then
      begin
        c := T[j];
        if (j <= p) then
        U[j] :=  T[p] 
        else
        U[j] := A[p];
        A[j] := c;
        inc(j);
      end
      else 
      begin
        idx^ := i;
      end;
    end;
    p := lt - 1;
    if(0 <= p) then
    begin
      c := T[j];
      if (j <= p) then
      U[j] :=  T[p] 
      else
      U[j] :=  A[p];
      A[j] := c;
    end
    else
    begin
      idx^ := i;
    end;
  end
  else
  begin
    U[0] := T[n - 1];
    i := 0;
    while  (A[i] <> 0) do
    begin 
      U[i + 1] := T[A[i] - 1];
      inc(i); 
    end;
    idx^ := i + 1;
    for i:=i+1 to n-1 do
    begin 
      U[i] := T[A[i] - 1]; 
    end;
  end;
  if(SA = nil) then
  begin
    { Deallocate memory. }
    freemem(A);
  end;
  exit(0);
end;
{ Inverse Burrows-Wheeler transform. }
function inverse_bw_transform(const T, U:pbyte; A:pint32;n,  idx:int32):int32;
var
  bigC:array [0..ALPHABET_SIZE-1] of int32;
  bigD:array [0..ALPHABET_SIZE-1] of byte;
  B:pint32;
  i, p:int32;
  c, d:int32; 
begin
  { Check arguments. }
  if((T = nil) or (U = nil) or (n < 0) or (idx < 0) or
     (n < idx) or ((0 < n) and (idx = 0))) then
  begin
    exit(-1);
  end;
  if(n <= 1) then
  begin 
    exit(0); 
  end;
  B := A;
  if(B = nil) then
  begin
    { Allocate n*sizeof(saidx_t) bytes of memory. }
    B := allocmem(n * sizeof(int32));
    if( B = nil) then
    begin 
      exit(-2); 
    end;
  end;
  { Inverse BW transform. }
  for c := 0 to ALPHABET_SIZE-1 do
  begin 
    bigC[c] := 0; 
  end;
  for i := 0 to n-1 do
  begin 
    inc(bigC[T[i]]); 
  end;
  d := 0; 
  i := 0;
  for c := 0  to  ALPHABET_SIZE-1 do 
  begin
    p := bigC[c];
    if (0 < p) then
    begin
      bigC[c] := i;
      bigD[d] := c;
      inc(d);
      i :=i + p;
    end;
  end;
  for i := 0 to idx-1 do
  begin 
    B[bigC[T[i]]] := i;
    inc(bigC[T[i]]); 
  end;
  for i:=i to  n-1 do 
  begin 
    B[bigC[T[i]]] := i + 1;
    inc(bigC[T[i]]); 
  end;
  for c := 0 to d-1 do
  begin 
    bigC[c] := bigC[bigD[c]]; 
  end;
  p := idx;
  for i := 0  to n-1 do
  begin
    U[i] := bigD[binarysearch_lower(bigC, d, p)];
    p := B[p - 1];
  end;
  if(A = nil) then
  begin
    { Deallocate memory. }
    freemem(B);
  end;
  exit(0);
end;
{ Checks the suffix array SA of the string T. }
function sufcheck(const T:pbyte; const SA:pint32;
          n,  verbose:int32):int32; 
var
  bigC:array [0..ALPHABET_SIZE-1] of int32;
  i, p, q, lt:int32;
  c:int32;
begin
  if (verbose<>0) then
  begin 
    //log(stderr, 'sufcheck: '); 
  end;
  { Check arguments. }
  if((T = nil) or (SA = nil) or (n < 0)) then
  begin
    if(verbose<>0) then
    begin 
      //log(stderr, 'Invalid arguments.\n'); 
    end;
    exit(-1);
  end;
  if(n = 0) then
  begin
    if(verbose<>0) then
    begin 
      //log(stderr, 'Done.\n'); 
    end;
    exit(0);
  end;
  { check range: [0..n-1] }
  for i := 0 to n-1 do
  begin
    if ((SA[i] < 0) or (n <= SA[i])) then
    begin
      if (verbose<>0) then
      begin
        //log(stderr, 'Out of the range [0,%ld].\n'+
        //                '  SA[%ld]:=%ld\n',
        //                n - 1, i, SA[i]);
      end;
      exit(-2);
    end;
  end;
  { check first characters. }
  for i := 1 to n-1 do
  begin
    if (T[SA[i - 1]] > T[SA[i]]) then
    begin
      if(verbose<>0) then
      begin
        //log(stderr, 'Suffixes in wrong order.\n'+
        //                '  T[SA[%ld]:=%ld]:=%d'+
        //                ' > T[SA[%ld]:=%ld]:=%d\n',
        //                i - 1, SA[i - 1], T[SA[i - 1]], i, SA[i], T[SA[i]]);
      end;
      exit(-3);
    end;
  end;
  { check suffixes. }
  for i := 0 to ALPHABET_SIZE-1 do
  begin 
    bigC[i] := 0; 
  end;
  for i := 0 to n-1 do
  begin 
    inc(bigC[T[i]]); 
  end;
  p := 0;
  for i := 0 to ALPHABET_SIZE-1 do
  begin
    lt := bigC[i];
    bigC[i] := p;
    p :=p + lt;
  end;
  q := bigC[T[n - 1]];
  bigC[T[n - 1]] :=bigC[T[n - 1]] + 1;
  for i := 0 to n-1 do
  begin
    p := SA[i];
    if(0 < p) then
    begin
      c := T[p];
      dec(p);
      lt := bigC[c];
    end
    else 
    begin
      p := n - 1;
      c := T[p];
      lt := q;
    end;
    if ((lt < 0) or (p <> SA[lt])) then
    begin
      if(verbose<>0) then
      begin
        //if (0 <= lt) then
        //log(stderr, 'Suffix in wrong position.\n'+
         //               '  SA[%ld]:=%ld or\n'+
        //                '  SA[%ld]:=%ld\n',
         //               lt,  SA[lt] , i, SA[i])
        //else
        //log(stderr, 'Suffix in wrong position.\n'+
        //                '  SA[%ld]:=%ld or\n'+
        //                '  SA[%ld]:=%ld\n',
        //                lt,  -1, i, SA[i]);
      end;
      exit(-4);
    end;
    if(lt <> q) then
    begin
      inc(bigC[c]);
      if((n <= bigC[c]) or (T[SA[bigC[c]]] <> c)) then
      begin 
        bigC[c] := -1; 
      end;
    end;
  end;
  if(1 <= verbose) then
  begin 
    //log(stderr, 'Done.\n'); 
  end;
  exit(0);
end;

function _compare(const T:pbyte; Tsize:int32;const P:pbyte; Psize:int32;
         suf:int32; match:pint32):int32;
var
  i, j:int32;
  r:int32;
begin
  i := suf + match^; 
  j := match^; 
  r := 0;
  r := T[i] - P[j];
  while((i < Tsize) and (j < Psize) and (r = 0)) do
  begin
    inc(i); 
    inc(j); 
  end;
  match^ := j;
  if (r = 0) then
  result :=-ord(j <> Psize)
  else
  result := r;
end;
{ Search for the pattern P in the string T. }

function sa_search(const T:pbyte; Tsize:int32;const P:pbyte; Psize:int32;
          const SA:pint32;  SAsize:int32;idx:pint32):int32; 
var
  size, lsize, rsize, half:int32;
  match, lmatch, rmatch:int32;
  llmatch, lrmatch, rlmatch, rrmatch:int32;
  i, j, k:int32;
  r:int32;
begin

  if (idx <> nil) then
  begin 
    idx^ := -1; 
  end;
  if((T = nil) or (P = nil) or (SA = nil) or
     (Tsize < 0) or (Psize < 0) or (SAsize < 0)) then
  begin 
    exit(-1); 
  end;
  if((Tsize = 0) or (SAsize = 0)) then
  begin 
    exit(0); 
  end;
  if(Psize = 0) then
  begin 
    if(idx <> nil) then
    begin 
      idx^ := 0; 
    end; 
    exit(SAsize); 
  end;
  i :=0; 
  j :=0; 
  k :=0; 
  lmatch := 0; 
  rmatch := 0; 
  size := SAsize; 
  half := size shr 1;
  while(0 < size) do
  begin
    match := MIN(lmatch, rmatch);
    r := _compare(T, Tsize, P, Psize, SA[i + half], @match);
    if(r < 0) then
    begin
      i :=i + half + 1;
      half :=half - (size and 1) xor 1;
      lmatch := match;
    end 
    else 
    if(r > 0) then
    begin
      rmatch := match;
    end 
    else 
    begin
      lsize := half; 
      j := i; 
      rsize := size - half - 1; 
      k := i + half + 1;
      { left part }
      llmatch := lmatch; 
      lrmatch := match; 
      half := lsize shr 1;
      while (0 < lsize) do
      begin
        lmatch := MIN(llmatch, lrmatch);
        r := _compare(T, Tsize, P, Psize, SA[j + half], @lmatch);
        if(r < 0) then
        begin
          j :=j + half + 1;
          half :=half - (lsize and 1) xor 1;
          llmatch := lmatch;
        end 
        else 
        begin
          lrmatch := lmatch;
        end;
        lsize := half; 
        half  :=half shr 1;
      end;
      { right part }
      rlmatch := match; 
      rrmatch := rmatch; 
      half := rsize shr 1;
      while (0 < rsize) do
      begin
        rmatch := MIN(rlmatch, rrmatch);
        r := _compare(T, Tsize, P, Psize, SA[k + half], @rmatch);
        if(r <= 0) then
        begin
          k :=k + half + 1;
          half :=half - (rsize and 1) xor 1;
          rlmatch := rmatch;
        end
        else 
        begin
          rrmatch := rmatch;
        end;
        rsize := half; 
        half  :=half shr 1;
      end;
      break;
    end;
    size := half; 
    half :=half shr 1;
  end;
  if (idx <> nil) then
  begin
    if (0 < (k - j)) then 
      idx^ := j
    else
      idx^ := i; 
  end;
  result := k - j;
end;
{ Search for the character c in the string T. }

function sa_simplesearch(const T:pbyte;  Tsize:int32;const SA:pint32; SAsize:int32;c:int32; idx:pint32):int32;
var
  size, lsize, rsize, half:int32;
  i, j, k, p:int32;
  r:int32;
begin
  if (idx <> nil) then
  begin 
    idx^ := -1;
  end;
  if ((T = nil) or (SA = nil) or (Tsize < 0) or (SAsize < 0)) then
  begin 
    exit(-1); 
  end;
  if((Tsize = 0) or (SAsize = 0)) then
  begin 
    exit(0); 
  end;
  i := 0; 
  j := 0;
  k := 0; 
  size := SAsize; 
  half := size shr 1;
  while (0 < size) do
  begin
    p := SA[i + half];
    if (p < Tsize) then
      r :=  T[p] - c
    else
      r :=  -1;
    if(r < 0) then
    begin
      i :=i + half + 1;
      half :=half - (size and 1) xor 1;
    end
    else 
    if(r = 0) then
    begin
      lsize := half;
      j := i; 
      rsize := size - half - 1; 
      k := i + half + 1;
      { left part }
      half := lsize shr 1;
      while (0 < lsize) do
      begin
        p := SA[j + half];
        if (p < Tsize) then
        r :=  T[p] - c
        else
        r := -1;
        if(r < 0) then
        begin
          j :=j + half + 1;
          half :=half - (lsize and 1) xor 1;
        end;
        lsize := half; 
        half :=half shr 1;
      end;
      { right part }
      half := rsize shr 1;
      while(0 < rsize) do
      begin
        p := SA[k + half];
        if (p < Tsize) then
          r :=  T[p] - c 
        else
          r := -1;
        if(r <= 0) then
        begin
          k :=k + half + 1;
          half :=half - (rsize and 1) xor 1;
        end;
        rsize := half;
        half :=half shr 1;
      end;
      break;
    end;
    size := half; 
    half :=half shr 1;
  end;
  if(idx <> nil) then
  begin
    if (0 < (k - j)) then 
      idx^ :=  j 
    else
      idx^ :=  i; 
  end;
  result := k - j;
end;
end.
