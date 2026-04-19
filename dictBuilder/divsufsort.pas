unit divsufsort;
{$mode objfpc}{$H+}

interface
uses math,sysutils;
const
  ALPHABET_SIZE=256;
  SS_INSERTIONSORT_THRESHOLD=8;
  BUCKET_A_SIZE=ALPHABET_SIZE;
  BUCKET_B_SIZE=(ALPHABET_SIZE * ALPHABET_SIZE);
  SS_BLOCKSIZE=32767;
  SS_MISORT_STACKSIZE=16;
  SS_SMERGE_STACKSIZE=32;
  TR_INSERTIONSORT_THRESHOLD=8;
  TR_STACKSIZE=64;

{- Private Functions -}

  lg_table:array[0..255] of int32= (
 -1,0,1,1,2,2,2,2,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,
  5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
  6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
  6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7
  );
  sqq_table:array[0..255] of int32= (
  0,  16,  22,  27,  32,  35,  39,  42,  45,  48,  50,  53,  55,  57,  59,  61,
 64,  65,  67,  69,  71,  73,  75,  76,  78,  80,  81,  83,  84,  86,  87,  89,
 90,  91,  93,  94,  96,  97,  98,  99, 101, 102, 103, 104, 106, 107, 108, 109,
110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126,
128, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142,
143, 144, 144, 145, 146, 147, 148, 149, 150, 150, 151, 152, 153, 154, 155, 155,
156, 157, 158, 159, 160, 160, 161, 162, 163, 163, 164, 165, 166, 167, 167, 168,
169, 170, 170, 171, 172, 173, 173, 174, 175, 176, 176, 177, 178, 178, 179, 180,
181, 181, 182, 183, 183, 184, 185, 185, 186, 187, 187, 188, 189, 189, 190, 191,
192, 192, 193, 193, 194, 195, 195, 196, 197, 197, 198, 199, 199, 200, 201, 201,
202, 203, 203, 204, 204, 205, 206, 206, 207, 208, 208, 209, 209, 210, 211, 211,
212, 212, 213, 214, 214, 215, 215, 216, 217, 217, 218, 218, 219, 219, 220, 221,
221, 222, 222, 223, 224, 224, 225, 225, 226, 226, 227, 227, 228, 229, 229, 230,
230, 231, 231, 232, 232, 233, 234, 234, 235, 235, 236, 236, 237, 237, 238, 238,
239, 240, 240, 241, 241, 242, 242, 243, 243, 244, 244, 245, 245, 246, 246, 247,
247, 248, 248, 249, 249, 250, 250, 251, 251, 252, 252, 253, 253, 254, 254, 255
);

function divbwt(T,U:pbyte; A:pint32; n:int32;  num_indexes:pbyte;  indexes:pint32; openMP:int32):int32;
implementation
procedure SWAP(var a, b:int32);overload;
var
  t:int32;
begin  
  t := a; 
  a := b; 
  b := t;
end;
procedure SWAP(var a, b:pint32);overload;
var
  t:pint32;
begin  
  t := a; 
  a := b; 
  b := t;
end;
function ss_ilg(n:int32):int32; 
begin
  if (n  and  $ff00)<>0 then
    result := 8 + lg_table[(n  shr  8)  and  $ff]
  else
    result := 0 + lg_table[(n  shr  0)  and  $ff];
end;

function ss_isqrt(x:int32):int32;
var
  y,e:int32;
begin
  if(x >= (SS_BLOCKSIZE * SS_BLOCKSIZE)) then
  begin 
    exit(SS_BLOCKSIZE); 
  end;
  if (x  and  $ffff0000)<>0 then
  begin
    if (x  and  $ff000000)<>0 then
    begin
      e :=24 + lg_table[(x  shr  24)  and  $ff];
    end
    else
    begin
      e :=16 + lg_table[(x  shr  16)  and  $ff];
    end; 
  end
  else
  begin
    if (x  and  $0000ff00)<>0 then
    begin
      e :=8 + lg_table[(x  shr   8)  and  $ff];
    end
    else
    begin
      e :=0 + lg_table[(x  shr   0)  and  $ff];
    end;
  end;
  if(e >= 16) then
  begin
    y := sqq_table[x  shr  ((e - 6) - (e  and  1))]  shl  ((e  shr  1) - 7);
    if(e >= 24) then
    begin 
      y := (y + 1 + x div y)  shr  1; 
    end;
    y := (y + 1 + x div y)  shr  1;
  end 
  else 
  if(e >= 8) then
  begin
    y := (sqq_table[x  shr  ((e - 6) - (e  and  1))]  shr  (7 - (e  shr  1))) + 1;
  end 
  else 
  begin
    exit(sqq_table[x]  shr  4);
  end;
  if (x < (y * y)) then
    result := y - 1
  else
    result := y;
end;


{---------------------------------------------------------------------------}

{ Compares two suffixes. }
function ss_compare(T:pbyte;p1,p2:pint32;depth:int32):int32;
var
  U1, U2, U1n, U2n:pbyte;
begin
  U1  := T + depth + p1^;
  U2  := T + depth + p2^;
  U1n := T + p1 [1] + 2;
  U2n := T + p2 [1] + 2;
  while (U1 < U1n)  and (U2 < U2n) and  (U1^ = U2^) do
  begin
    inc(U1); 
    inc(U2);
  end;
  if U1 < U1n then
  begin
    if U2 < U2n then
      result:=U1^ - U2^
    else
      result:=1;
  end
  else
  begin
    if U2 < U2n then
      result:=-1
    else
      result:=0;
  end;
end;


{---------------------------------------------------------------------------}


procedure ss_insertionsort(T:pbyte; PA,first, last:pint32;depth:int32);
var
  i,j:pint32;
  lt,r:int32;
  pi,pfirst:PtrUInt;
begin
  pfirst := PtrUint(first);
  for  pi := PtrUInt(last - 2) downto pfirst do
  begin
    lt := i^;
  	j := i + 1;
  	r := ss_compare(T, PA + lt, PA + j^, depth);
    while  (0 < r) do 
    begin
      repeat 
       j[ - 1] := j^; 
       inc(j);
      until not ((PtrUint(j) < PtrUint(last)) and (j^ < 0));
      if(last <= j) then
      begin 
      	break; 
      end;
      r := ss_compare(T, PA + lt, PA + j^, depth)
    end;
    if(r = 0) then
    begin 
    	j^ := not j^; 
    end;
    j [- 1] := lt;
    dec(i);
  end;
end;

{---------------------------------------------------------------------------}

procedure ss_fixdown(Td:pbyte;PA,SA:pint32; i,size:int32);
var
j,k,v,c,d,e:int32;
begin
	v := SA[i]; 
	c := Td[PA[v]];
        j := 2;
  while((j * i + 1) < size) do
  begin
    k := j;
    inc(j);
    d := Td[PA[SA[k]]];

    e := Td[PA[SA[j]]];
    if (d < e) then
    begin 
    	k := j; 
    	d := e; 
    end;
    if (d <= c) then
    begin 
    	break; 
    end;
    SA[i] := SA[k];
    i := k;
  end;
  SA[i] := v;
end;

{ Simple top-down heapsort. }
procedure ss_heapsort(Td:pbyte;PA, SA:pint32; size:int32);
var
  i, m,t:int32;
begin

  m := size;
  if((size mod 2) = 0) then
  begin
    dec(m);
    if(Td[PA[SA[m div 2]]] < Td[PA[SA[m]]]) then
    begin 
    	SWAP(SA[m], SA[m div 2]); 
    end;
  end;

  for i := m div 2 - 1 downto 0  do
  begin 
  	ss_fixdown(Td, PA, SA, i, m); 
  end;
  if ((size mod 2) = 0) then
  begin 
    SWAP(SA[0], SA[m]); 
    ss_fixdown(Td, PA, SA, 0, m); 
  end;
  for i := m - 1 downto 1 do
  begin
    t := SA[0]; 
    SA[0] := SA[i];
    ss_fixdown(Td, PA, SA, 0, i);
    SA[i] := t;
  end;
end;


{---------------------------------------------------------------------------}

{ Returns the median of three elements. }
function ss_median3(Td:pbyte; PA, v1, v2, v3:pint32):pint32;
var
	t:pint32;
begin
  
  if(Td[PA[v1^]] > Td[PA[v2^]]) then
  begin 
  	SWAP(v1, v2); 
  end;
  if(Td[PA[v2^]] > Td[PA[v3^]]) then
  begin
    if(Td[PA[v1^]] > Td[PA[v3^]]) then
    begin 
    	exit(v1); 
    end
    else 
    begin 
    	exit(v3); 
    end;
  end;
  result := v2;
end;

{ Returns the median of five elements. }

function ss_median5(Td:pbyte; PA,v1, v2, v3, v4, v5:pint32):pint32;
var
	t:pint32;
begin
  if(Td[PA[v2^]] > Td[PA[v3^]]) then
  begin 
  	SWAP(v2, v3); 
  end;
  if(Td[PA[v4^]] > Td[PA[v5^]]) then
  begin 
  	SWAP(v4, v5); 
  end;
  if(Td[PA[v2^]] > Td[PA[v4^]]) then
  begin 
  	SWAP(v2, v4); 
  	SWAP(v3, v5);
  end;
  if(Td[PA[v1^]] > Td[PA[v3^]]) then
  begin 
  	SWAP(v1, v3); 
  end;
  if(Td[PA[v1^]] > Td[PA[v4^]]) then
  begin 
  	SWAP(v1, v4); 
  	SWAP(v3, v5); 
  end;
  if(Td[PA[v3^]] > Td[PA[v4^]]) then
  begin 
  	exit(v4); 
  end;
  exit(v3);
end;

{ Returns the pivot element. }

function ss_pivot(Td:pbyte; PA, first, last:pint32):pint32;
var
  middle:pint32;
  t:int32;
begin
  t := last - first;
  middle := first + t div 2;

  if(t <= 512) then
  begin
    if(t <= 32) then
    begin
      exit(ss_median3(Td, PA, first, middle, last - 1));
    end 
    else 
    begin
      t :=t  shr  2;
      exit(ss_median5(Td, PA, first, first + t, middle, last - 1 - t, last - 1));
    end;
  end;
  t      := t  shr  3;
  first  := ss_median3(Td, PA, first, first + t, first + (t  shl  1));
  middle := ss_median3(Td, PA, middle - t, middle, middle + t);
  last   := ss_median3(Td, PA, last - 1 - (t  shl  1), last - 1 - t, last - 1);
  result := ss_median3(Td, PA, first, middle, last);
end;


{---------------------------------------------------------------------------}

{ Binary partition for substrings. }

function ss_partition(PA,first,last:pint32;depth:int32):pint32;
var
	a, b:pint32;
	t:int32;
begin
  a := first - 1;
  b := last;
  while(true) do
  begin
  	inc(a);
    while((ptruint(a) < ptruint(b)) and ((PA[a^] + depth) >= (PA[a^ + 1] + 1))) do
    begin 
    	a^ := not a^;
    	inc(a);
    end;
    dec(b);
    while((ptruint(a) < ptruint(b)) and ((PA[b^] + depth) <  (PA[b^ + 1] + 1))) do dec(b);
    if(ptruint(b) <= ptruint(a)) then
    begin 
    	break; 
    end;
    t := not b^;
    b^ := a^;
    a^ := t;
  end;
  if(ptruint(first) < ptruint(a)) then
  begin 
  	first^ := not first^; 
  end;
  result := a;
end;

{ Multikey introsort for medium size groups. }
procedure ss_mintrosort(T:pbyte; PA,first,last:pint32;depth:int32);
type
  stacktemp=record
  	a,b:pint32;
  	c,d:int32;
  end;
var 
  stack:array[0..SS_MISORT_STACKSIZE] of stacktemp;
  Td:pbyte;
  a, b, c, d, e, f:pint32;
  s, lt,ssize,limit,v,x:int32;
  procedure STACK_PUSH(a,b:pint32;c,d:int32);
  begin
      stack[ssize].a := a; 
      stack[ssize].b := b;
      stack[ssize].c := c; 
      stack[ssize].d := d;
      inc(ssize);
  end;
  procedure STACK_POP(var a,b:pint32;var c,d:int32);
  begin
    assert(0 <= ssize);
    if(ssize = 0) then
    begin 
      exit; 
    end;
    dec(ssize);
    a := stack[ssize].a; 
    b := stack[ssize].b;
    c := stack[ssize].c; 
    d := stack[ssize].d;
  end;
begin
	x := 0;
	ssize := 0;
	limit := ss_ilg(last - first);
  while (true) do
  begin
    if ((last - first) <= SS_INSERTIONSORT_THRESHOLD) then
    begin
      if (1 < (last - first)) then
      begin 
      	ss_insertionsort(T, PA, first, last, depth); 
      end;
      STACK_POP(first, last, depth, limit);
      continue;
    end;

    Td := T + depth;
    if (limit = 0) then
    begin
    	ss_heapsort(Td, PA, first, last - first); 
    end;
    dec(limit);
    if(limit < 0) then
    begin
    	a := first + 1;
    	v := Td[PA[first^]];
      while (ptruint(a) < ptruint(last)) do
      begin
        x := Td[PA[a^]];
        if (x <> v) then
        begin
          if (1 < (a - first)) then
          begin 
          	break; 
          end;
          v := x;
          first := a;
        end;
        inc(a);
      end;
      if (Td[PA[first^] - 1] < v) then
      begin
        first := ss_partition(PA, first, a, depth);
      end;
      if (ptruint(a - first) <= ptruint(last - a)) then
      begin
        if (1 < ptruint(a - first)) then
        begin
          STACK_PUSH(a, last, depth, -1);
          last  := a; 
          depth :=depth + 1; 
          limit := ss_ilg(a - first);
        end
        else 
        begin
          first := a; 
          limit := -1;
        end;
      end 
      else 
      begin
        if (1 < (last - a)) then
        begin
          STACK_PUSH(first, a, depth + 1, ss_ilg(a - first));
          first := a; 
          limit := -1;
        end 
        else 
        begin
          last := a; 
          depth :=depth + 1; 
          limit := ss_ilg(a - first);
        end;
      end;
      continue;
    end;

    { choose pivot }
    a := ss_pivot(Td, PA, first, last);
    v := Td[PA[a^]];
    SWAP(first^, a^);

    { partition }
    b := first;
    inc(b);
    x := Td[PA[b^]];
    while ( (ptruint(b) < ptruint(last)) and (x = v)) do
    begin
    	inc(b);
    	x := Td[PA[b^]]; 
    end;
    a := b;
    if ((ptruint(a) < ptruint(last)) and (x < v)) then
    begin
    	inc(b);
    	x := Td[PA[b^]];
      while ((ptruint(b) < ptruint(last)) and (x <= v)) do
      begin
        if(x = v) then
        begin 
        	SWAP(b^, a^); 
        	inc(a); 
        end;
      	inc(b);
      	x := Td[PA[b^]];
      end;
    end;
    c := last;
    dec(c);
    x := Td[PA[c^]];
    while( (ptruint(b) < ptruint(c)) and ( x = v)) do
    begin 
    	dec(c); 
    	x := Td[PA[c^]];
    end;
    d := c;
    if((ptruint(b) < ptruint(d)) and (x > v)) then
    begin
      dec(c);
      x := Td[PA[c^]];
      while((ptruint(b) < ptruint(c)) and (x >= v)) do
      begin
        if (x = v) then
        begin 
        	SWAP(c^, d^); 
        	dec(d); 
        end;
        dec(c);
        x := Td[PA[c^]];
      end;
    end;
    while(ptruint(b) < ptruint(c)) do
    begin
      SWAP(b^, c^);
      inc(b);
      x := Td[PA[b^]];
      while( (ptruint(b) < ptruint(c)) and (x <= v)) do
      begin
        if (x = v) then
        begin 
        	SWAP(b^, a^); 
        	inc(a); 
        end;
        inc(b);
        x := Td[PA[b^]];
      end;
      dec(c);
      x := Td[PA[c^]];
      while((ptruint(b) < ptruint(c)) and (x >= v)) do
      begin
        if(x = v) then
        begin 
        	SWAP(c^, d^); 
        	dec(d); 
        end;
        dec(c);
        x := Td[PA[c^]];
      end;
    end;

    if(a <= d) then
    begin
      c := b - 1;
      s := a - first;
      lt := b - a;
      if (s > lt) then
      begin 
      	s := lt; 
      end;
      e := first;
      f := b - s;
      while (0 < s) do 
      begin 
      	SWAP(e^, f^);
      	dec(s); 
      	inc(e); 
      	inc(f); 
      end;
      s := d - c;
      lt := last - d - 1;
      if(s > lt) then
      begin 
      	s := lt;
      end;
      e := b; 
      f := last - s;
      while( 0 < s) do
      begin 
      	SWAP(e^, f^);
      	dec(s); 
      	inc(e); 
      	inc(f); 
      end;

      a := first + (b - a); 
      c := last - (d - c);
      if (v <= Td[PA[a^] - 1]) then
      	b := a 
      else
      	b := ss_partition(PA, a, c, depth);

      if ((a - first) <= (last - c)) then
      begin
        if ((last - c) <= (c - b)) then
        begin
          STACK_PUSH(b, c, depth + 1, ss_ilg(c - b));
          STACK_PUSH(c, last, depth, limit);
          last := a;
        end
        else 
        if ((a - first) <= (c - b)) then
        begin
          STACK_PUSH(c, last, depth, limit);
          STACK_PUSH(b, c, depth + 1, ss_ilg(c - b));
          last := a;
        end
        else 
        begin
          STACK_PUSH(c, last, depth, limit);
          STACK_PUSH(first, a, depth, limit);
          first := b; 
          last := c; 
          depth :=depth + 1; 
          limit := ss_ilg(c - b);
        end;
      end
      else 
      begin
        if ((a - first) <= (c - b)) then
        begin
          STACK_PUSH(b, c, depth + 1, ss_ilg(c - b));
          STACK_PUSH(first, a, depth, limit);
          first := c;
        end
        else 
        if ((last - c) <= (c - b)) then 
        begin
          STACK_PUSH(first, a, depth, limit);
          STACK_PUSH(b, c, depth + 1, ss_ilg(c - b));
          first := c;
        end
        else 
        begin
          STACK_PUSH(first, a, depth, limit);
          STACK_PUSH(c, last, depth, limit);
          first := b; 
          last := c; 
          depth :=depth + 1; 
          limit := ss_ilg(c - b);
        end;
      end;
    end
    else 
    begin
      limit :=limit + 1;
      if (Td[PA[first^] - 1] < v) then
      begin
        first := ss_partition(PA, first, last, depth);
        limit := ss_ilg(last - first);
      end;
      depth :=depth + 1;
    end;
  end;
end;

{---------------------------------------------------------------------------}


procedure ss_blockswap(a, b:pint32; n:int32);
var
	t:int32;
begin
  while(0 < n) do
  begin
    t := a^;
    a^ := b^;
    b^ := t;
    dec(n);
    inc(a);
    inc(b);
  end;
end;


procedure ss_rotate(first,middle,last:pint32);
var
  a, b:pint32;
  l, r, t:int32;
begin
  l := middle - first; 
  r := last - middle;
  while((0 < l) and (0 < r)) do
  begin
    if(l = r) then
    begin 
    	ss_blockswap(first, middle, l); 
    	break; 
    end;
    if(l < r) then
    begin
      a := last - 1; 
      b := middle - 1;
      t := a^;
      repeat
        a^ := b^;
        dec(a);
        b^ := a^;
        dec(b);
        if(b < first) then
        begin
          a^ := t;
          last := a;
          r :=r - l + 1;
          if (r <= l) then
          begin 
          	break; 
          end;
          a :=a - 1; 
          b := middle - 1;
          t := a^;
        end;
      until false;
    end
    else 
    begin
      a := first; 
      b := middle;
      t := a^;
      repeat
        a^ := b^;
        inc(a);
        b^ := a^;
        inc(b);
        if(last <= b) then
        begin
          a^ := t;
          first := a + 1;
          l :=l - r + 1;
          if (l <= r) then
          begin 
          	break; 
          end;
          a :=a + 1; 
          b := middle;
          t := a^;
        end;
      until false;
    end;
  end;
end;


{---------------------------------------------------------------------------}

procedure ss_inplacemerge(T:pbyte;PA,first,middle, last:pint32;depth:int32);
var
  a, b,p:pint32;
  x,len, half,q, r:int32;
begin
  while true do
  begin
    if((last - 1)^ < 0) then
    begin 
    	x := 1; 
    	p := PA + not (last - 1)^; 
    end
    else
    begin 
    	x := 0; 
    	p := PA + (last - 1)^; 
    end;
    a := first;
    len := middle - first;
    half := len  shr  1;
    r := -1;
		while (0 < len) do
		begin
      b := a + half;
      if (0 <= b^) then
      	q := ss_compare(T, PA +  b^, p, depth)
      else
      	q := ss_compare(T, PA + not b^, p, depth);
      if (q < 0) then
      begin
        a := b + 1;
        half := half - (len  and  1) xor 1;
      end
      else 
      begin
        r := q;
      end;
      len := half; 
      half:=half  shr  1;
    end;
    if (a < middle) then
    begin
      if (r = 0) then
      begin 
      	a^ := not a^; 
      end;
      ss_rotate(a, middle, last);
      last := last - (middle - a);
      middle := a;
      if (first = middle) then
      begin 
      	break; 
      end;
    end;
    dec(last);
    if (x <> 0) then
    begin 
    	while(last^ < 0) do
    	begin
    	 dec(last); 
    	end; 
    end;
    if (middle = last) then
    begin 
    	break; 
    end;
  end;
end;


{---------------------------------------------------------------------------}

{ Merge-forward with internal buffer. }
procedure ss_mergeforward(T:pbyte;PA,first, middle, last,buf:pint32;depth:int32);
var
  a, b, c, bufend:pint32;
  lt,r:int32; 
begin

  bufend := buf + (middle - first) - 1;
  ss_blockswap(buf, first, middle - first);
  a := first;
  lt := a^;
  b := buf;
  c := middle;
  while( true) do
  begin
    r := ss_compare(T, PA + b^, PA + c^, depth);
    if(r < 0) then
    begin
      repeat
        a^ := b^;
        inc(a);
        if(bufend <= b) then
        begin 
        	bufend^ := lt;
        	exit; 
        end;
        b^ := a^;
        inc(b);
      until not (b^ < 0);
    end
    else 
    if(r > 0) then
    begin
      repeat
        a^ := c^;
        inc(a^);
        inc(a);
        c^ := a^;
        inc(c);
        if(last <= c) then
        begin
          while (b < bufend) do
          begin 
          	a^ := b^;
          	inc(a);
          	b^ := a^;
          	inc(b); 
          end;
          a^ := b^; 
          b^ := lt;
          exit;
        end;
      until not (c^ < 0);
    end
    else 
    begin
      c^ := not c^;
      repeat
        a^ := b^;
        inc(a);
        if (bufend <= b) then
        begin 
        	bufend^ := lt; 
        	exit; 
        end;
        b^ := a^;
        inc(b);
      until not (b^ < 0);

      repeat
        a^ := c^;
        inc(a); 
        c^ := a^;
        inc(b);
        if(last <= c) then
        begin
          while (b < bufend) do
          begin 
          	a^ := b^;
          	inc(a); 
          	b^ := a^;
          	inc(b); 
          end;
          a^ := b^; 
          b^ := lt;
          exit;
        end;
      until not (c^ < 0);
    end;
  end;
end;

{ Merge-backward with internal buffer. }
procedure ss_mergebackward(T:pbyte; PA,first,middle, last,buf:pint32; depth:int32);
var
  p1, p2:pint32;
  a, b, c, bufend:pint32;
  lt,r,x:int32;
begin
  bufend := buf + (last - middle) - 1;
  ss_blockswap(buf, middle, last - middle);

  x := 0;
  if (bufend^ < 0) then
  begin 
  	p1 := PA + not bufend^;
  	x  := x  or 1; 
  end
  else                  
  begin 
  	p1 := PA +  bufend^; 
  end;
  if((middle - 1)^ < 0) then
  begin 
  	p2 := PA + not (middle - 1)^; 
  	x  := x  or  2; 
  end
  else                  
  begin 
  	p2 := PA + (middle - 1)^; 
  end;
  a := last - 1;
  lt := a^;
  b := bufend;
  c := middle - 1;
  while true do
  begin
    r := ss_compare(T, p1, p2, depth);
    if(0 < r) then
    begin
      if(x  and  1)<>0 then
      begin
        repeat
          a^ := b^;
          dec(a^);
          b^ := a^;
          dec(b^);
        until not (b^ < 0);
        x :=x xor 1;
      end;
      a^ := b^;
      dec(a^);
      if(b <= buf) then
      begin
        buf^ := lt;
        break;
      end;
      b^ := a^;
      dec(b^);
      if(b^ < 0) then
      begin
        p1 := PA + not b^;
        x  :=x  or  1;
      end
      else
      begin
        p1 := PA +  b^;
      end;
    end
    else 
    if(r < 0) then
    begin
      if(x  and  2)<>0 then
      begin 
      	repeat 
      		a^ := c^;
      		dec(a);  
      		c^ := a^;
      		dec(c); 
      	until not (c^ < 0); 
      	x :=x xor 2; 
      end;
      a^ := c^;
      dec(a); 
      c^ := a^;
      dec(c); 
      if (c < first) then
      begin
        while(buf < b) do
        begin 
        	a^ := b^;
        	dec(a); 
        	b^ := a^;
        	dec(b); 
        end;
        a^ := b^; 
        b^ := lt;
        break;
      end;
      if (c^ < 0) then
      begin 
      	p2 := PA + not c^;
      	x  :=x  or  2; 
      end
      else       
      begin 
      	p2 := PA +  c^; 
      end;
    end 
    else 
    begin
      if (x  and  1)<>0 then
      begin 
      	repeat 
      		a^ := b^;
      		dec(a); 
      		b^ := a^;
      		dec(b); 
      	until not (b^ < 0);
      	x :=x xor 1; 
      end;
      a^ := not b^;
      dec(a);
      if (b <= buf) then
      begin 
      	buf^ := lt; 
      	break; 
      end;
      b^ := a^;
      dec(b);
      if(x  and  2)<>0 then
      begin 
      	repeat
      		a^ := c^;
      		dec(a); 
      		c^ := a^;
      		dec(c); 
      	until not (c^ < 0); 
      	x :=x xor 2; 
      end;
      a^ := c^;
      dec(a);
      c^ := a^;
      dec(c);
      if(c < first) then
      begin
        while(buf < b) do
        begin 
        	a^ := b^;
        	dec(a); 
        	b^ := a^;
        	dec(b); 
        end;
        a^ := b^; 
        b^ := lt;
        break;
      end;
      if (b^ < 0) then
      begin 
      	p1 := PA + not b^; 
      	x  := x  or  1; 
      end
      else       
      begin 
      	p1 := PA +  b^; 
      end;
      if(c^ < 0) then
      begin 
      	p2 := PA + not c^;
      	x  :=x  or  2; 
      end
      else       
      begin 
      	p2 := PA +  c^; 
      end;
    end;
  end;
end;

{ D and C based merge. }

procedure ss_swapmerge(T:pbyte;PA,first,middle, last,buf:pint32; bufsize, depth:int32);
type
	stacktemp=record
	 a, b, c:pint32; 
	 d:int32; 
	end; 
var
  stack:array[0..SS_SMERGE_STACKSIZE] of stacktemp;
  l, r, lm, rm:pint32;
  m, len, half:int32;
  ssize:int32;
  check, next:int32;
  procedure STACK_PUSH(a,b,c:pint32;d:int32);
  begin
      stack[ssize].a := a; 
      stack[ssize].b := b;
      stack[ssize].c := c; 
      stack[ssize].d := d;
      inc(ssize);
  end;
  procedure STACK_POP(var a,b,c:pint32;var d:int32);overload;
  begin
    assert(0 <= ssize);
    if(ssize = 0) then
    begin 
      exit; 
    end;
    dec(ssize);
    a := stack[ssize].a; 
    b := stack[ssize].b;
    c := stack[ssize].c; 
    d := stack[ssize].d;
  end;
  function GETIDX(a:int32):int32;
  begin
    if 0<=a then
      result := a
    else
      result := not a;
  end;
  procedure MERGE_CHECK(a, b:pint32; c:int32);
  begin
     if(((c  and  1)<>0)  or 
        (((c  and  2)<>0) and (ss_compare(T, PA + GETIDX((a - 1)^), PA + a^, depth) = 0))) then
     begin
       a^ := not a^;
     end;
     if(((c  and  4)<>0) and ((ss_compare(T, PA + GETIDX((b - 1)^), PA + b^, depth) = 0))) then
     begin
       b^ := not b^;
     end;
  end;
begin

	check := 0;
	ssize := 0;
  while true do
  begin
    if ((last - middle) <= bufsize) then
    begin
      if ((first < middle) and (middle < last)) then
      begin
        ss_mergebackward(T, PA, first, middle, last, buf, depth);
      end;
      MERGE_CHECK(first, last, check);
      STACK_POP(first, middle, last, check);
      continue;
    end;

    if ((middle - first) <= bufsize) then
    begin
      if(first < middle) then
      begin
        ss_mergeforward(T, PA, first, middle, last, buf, depth);
      end;
      MERGE_CHECK(first, last, check);
      STACK_POP(first, middle, last, check);
      continue;
    end;
		m := 0; 
		len := MIN(middle - first, last - middle); 
		half := len  shr  1;
    while(0 < len) do
    begin
      if(ss_compare(T, PA + GETIDX((middle + m + half)^),PA + GETIDX((middle - m - half - 1)^), depth) < 0) then
      begin
        m    := m + half + 1;
        half := half - (len  and  1) xor 1;
      end;
      len := half; 
      half:= half  shr 1;
    end;

    if (0 < m) then
    begin
      lm := middle - m; 
      rm := middle + m;
      ss_blockswap(lm, middle, m);
      r := middle;
      l := r; 
      next := 0;
      if(rm < last) then
      begin
        if(rm^ < 0) then
        begin
          rm^ := not rm^;
          if(first < lm) then
          begin 
          	while(l^ < 0) do 
          	begin 
          		dec(l);
          	end; 
          	next  :=next  or  4; 
          end;
          next  :=next  or  1;
        end 
        else 
        if (first < lm) then
        begin
          while(r^ < 0)  do
          begin
          	inc(r); 
          end;
          next  :=next  or  2;
        end;
      end;

      if ((l - first) <= (last - r)) then
      begin
        STACK_PUSH(r, rm, last, (next  and  3)  or  (check  and  4));
        middle := lm; 
        last := l; 
        check := (check  and  3)  or  (next  and  4);
      end 
      else 
      begin
        if ((next  and  2)<>0) and ((r = middle)) then
        begin 
        	next :=next xor 6; 
        end;
        STACK_PUSH(first, lm, l, (check  and  3)  or  (next  and  4));
        first := r; 
        middle := rm; 
        check := (next  and  3)  or  (check  and  4);
      end;
    end 
    else 
    begin
      if(ss_compare(T, PA + GETIDX((middle - 1)^), PA + middle^, depth) = 0) then
      begin
        middle^ := not middle^;
      end;
      MERGE_CHECK(first, last, check);
      STACK_POP(first, middle, last, check);
    end;
  end;
end;


{---------------------------------------------------------------------------}

{ Substring sort }

procedure sssort(T:pbyte; PA,first,last,buf:pint32;bufsize,depth, n, lastsuffix:int32);
var
  a,b,middle,curbuf:pint32;
  i,j, k, curbufsize, limit:int32;
  PAi:array[0..1] of int32;
begin


  if	(lastsuffix <> 0) then
  begin 
  	inc(first); 
  end;

  limit := ss_isqrt(last - first);
  if ((bufsize < SS_BLOCKSIZE) and
      (bufsize < (last - first)) and
      (bufsize < limit)) then
  begin
    if(SS_BLOCKSIZE < limit) then
    begin 
    	limit := SS_BLOCKSIZE; 
    end;
    middle := last - limit;
    buf := middle ; 
    bufsize := limit;
  end
  else 
  begin
    middle := last; 
    limit := 0;
  end;
  a := first; 
  i := 0;
  while( SS_BLOCKSIZE < (middle - a)) do
  begin
    ss_mintrosort(T, PA, a, a + SS_BLOCKSIZE, depth);
    curbufsize := last - (a + SS_BLOCKSIZE);
    curbuf := a + SS_BLOCKSIZE;
    if(curbufsize <= bufsize) then
    begin 
    	curbufsize := bufsize; 
    	curbuf := buf; 
    end;
    b := a; 
    k := SS_BLOCKSIZE; 
    j := i;
    while( j  and  1)<>0 do
    begin
      ss_swapmerge(T, PA, b - k, b, b + k, curbuf, curbufsize, depth);
      b :=b - k; 
      k :=k  shl  1; 
      j :=j  shr  1;
    end;
    a := a + SS_BLOCKSIZE; 
    inc(i);
  end;
  ss_mintrosort(T, PA, a, middle, depth);
  k := SS_BLOCKSIZE;
  while( i <> 0 ) do
  begin
    if (i  and  1)<>0 then
    begin
      ss_swapmerge(T, PA, a - k, a, middle, buf, bufsize, depth);
      a :=a - k;
    end;
    k :=k  shl  1; 
    i :=i  shr  1;
  end;
  if(limit <> 0) then
  begin
    ss_mintrosort(T, PA, middle, last, depth);
    ss_inplacemerge(T, PA, first, middle, last, depth);
  end;


  if (lastsuffix <> 0) then
  begin
    { Insert last type B* suffix. }
     PAi[0] := PA[(first - 1)^]; 
     PAi[1] := n - 2;
    a := first; 
    i := (first - 1)^;
    while ((a < last) and ((a^ < 0)  or  (0 < ss_compare(T,  @PAi[0], PA + a^, depth)))) do
  	begin
      (a - 1)^ := a^;
      inc(a);
    end;
    (a - 1)^ := i;
  end;
end;


{---------------------------------------------------------------------------}


function tr_ilg(n:int32):int32;
begin
	if (n  and  $ffff0000)<>0 then
	begin
		if (n  and  $ff000000)<>0 then
		begin
			result:=24 + lg_table[(n  shr  24)  and  $ff];
		end
		else
		begin
			result:=16 + lg_table[(n  shr  16)  and  $ff];
		end;
	end
	else
	begin
		if (n  and  $0000ff00)<>0 then
		begin
			result:=8 + lg_table[(n  shr   8)  and  $ff];
		end
		else
		begin
			result:=0 + lg_table[(n  shr   0)  and  $ff];
		end;
	end;
end;


{---------------------------------------------------------------------------}

{ Simple insertionsort for small size groups. }
procedure tr_insertionsort(ISAd, first,last:pint32);
var
  a, b:pint32;
  t, r:int32; 
begin
	a := first + 1;
  while ( a < last) do
  begin
  	t := a^; 
  	b := a - 1;
        r := ISAd[t] - ISAd[b^];
    while( 0 > r) do
    begin
      repeat
      	(b + 1)^ := b^;
      	dec(b);
      until not ((first <= b) and (b^ < 0));
      if(b < first) then
      begin 
      	break; 
      end;
    end;
    if (r = 0) then
    begin 
    	b^ := not b^; 
    end;
    (b + 1)^ := t;
    inc(a);
  end;
end;


{---------------------------------------------------------------------------}

procedure tr_fixdown(ISAd, SA:pint32; i,size:int32);
var
  j, k:int32;
  v:int32;
  c, d, e:int32;
begin
	v := SA[i];
	c := ISAd[v];
        j := 2 * i + 1;
  while(j < size) do
  begin
  	k := j;
  	inc(j);
    d := ISAd[SA[k]];
    e := ISAd[SA[j]] ;
    if (d < e) then
    begin 
    	k := j; 
    	d := e; 
    end;
    if(d <= c) then
    begin 
    	break; 
    end;
    SA[i] := SA[k]; 
    i := k
  end;
  SA[i] := v;
end;

{ Simple top-down heapsort. }

procedure tr_heapsort(const ISAd, SA:pint32; size:int32);
var
  i,m:int32;
  t:int32; 
begin
  m := size;
  if ((size mod 2) = 0) then
  begin
    dec(m);
    if (ISAd[SA[m div 2]] < ISAd[SA[m]]) then
    begin 
    	SWAP(SA[m], SA[m div 2]); 
    end;
  end;
	i := m div 2 - 1;
  while( 0 <= i) do 
  begin 
  	tr_fixdown(ISAd, SA, i, m);
  	dec(i); 
  end;
  if ((size mod 2) = 0) then
  begin 
  	SWAP(SA[0], SA[m]); 
  	tr_fixdown(ISAd, SA, 0, m); 
  end;
  i := m - 1;
  while( 0 < i) do
  begin
    t := SA[0];
    SA[0] := SA[i];
    tr_fixdown(ISAd, SA, 0, i);
    SA[i] := t;
    dec(i);
  end;
end;


{---------------------------------------------------------------------------}

{ Returns the median of three elements. }
function tr_median3(ISAd, v1, v2, v3:pint32):pint32;
begin
  if(ISAd[v1^] > ISAd[v2^]) then
  begin 
  	SWAP(v1, v2); 
  end;
  if(ISAd[v2^] > ISAd[v3^]) then
  begin
    if (ISAd[v1^] > ISAd[v3^]) then
    begin 
    	exit(v1); 
    end
    else 
    begin 
    	exit(v3);  
    end;
  end;
  result := v2;
end;

{ Returns the median of five elements. }
function tr_median5(ISAd,v1, v2, v3, v4, v5:pint32):pint32;
begin
  if (ISAd[v2^] > ISAd[v3^]) then
  begin
  	 SWAP(v2, v3); 
  end;
  if (ISAd[v4^] > ISAd[v5^]) then
  begin
  	 SWAP(v4, v5); 
  end;
  if (ISAd[v2^] > ISAd[v4^]) then
  begin
  	 SWAP(v2, v4); 
  	 SWAP(v3, v5); 
  end;
  if (ISAd[v1^] > ISAd[v3^]) then
  begin
  	 SWAP(v1, v3); 
  end;
  if (ISAd[v1^] > ISAd[v4^]) then
  begin
  	 SWAP(v1, v4); 
  	 SWAP(v3, v5); 
  end;
  if (ISAd[v3^] > ISAd[v4^]) then
  begin
  	exit(v4); 
  end;
  result := v3;
end;

{ Returns the pivot element. }
function tr_pivot(ISAd, first,last:pint32):pint32;
var
  middle:pint32;
  t:int32;
begin
  t := last - first;
  middle := first + t div 2;

  if (t <= 512) then
  begin
    if(t <= 32) then
    begin
      exit(tr_median3(ISAd, first, middle, last - 1));
    end
    else
    begin
      t :=t  shr  2;
      exit(tr_median5(ISAd, first, first + t, middle, last - 1 - t, last - 1));
    end;
  end;
  t:= t  shr  3;
  first  := tr_median3(ISAd, first, first + t, first + (t  shl  1));
  middle := tr_median3(ISAd, middle - t, middle, middle + t);
  last   := tr_median3(ISAd, last - 1 - (t  shl  1), last - 1 - t, last - 1);
  result := tr_median3(ISAd, first, middle, last);
end;


{---------------------------------------------------------------------------}
type
ptrbudget_t=^trbudget_t;
trbudget_t=record
  chance:int32;
  remain:int32;
  incval:int32;
  count: int32;
end;

procedure trbudget_init(budget:ptrbudget_t; chance, incval:int32); 
begin
  budget^.chance := chance;
  budget^.incval := incval;
  budget^.remain := budget^.incval;
end;

function trbudget_check(budget:ptrbudget_t; size:int32):int32;
begin
  if(size <= budget^.remain) then
  begin 
  	budget^.remain :=budget^.remain - size; 
  	exit(1); 
  end;
  if(budget^.chance = 0) then
  begin 
  	budget^.count :=budget^.count + size; 
  	exit(0); 
  end;
  budget^.remain :=budget^.remain + budget^.incval - size;
  budget^.chance :=budget^.chance - 1;
  result := 1;
end;


{---------------------------------------------------------------------------}
type
ppint32=^pint32;
procedure tr_partition(ISAd,first, middle, last:pint32;pa,pb:ppint32; v:int32);
var
  a, b, c, d, e, f:pint32;
  t, s:int32;
  x:int32;
begin
	x:=0;
	b := middle - 1;
	inc(b);
	x := ISAd[b^];
  while( (b < last) and (x = v)) do
  begin
  	inc(b);
  	x := ISAd[b^]; 
  end;
  a := b;
  if((a < last) and (x < v)) then
  begin
  	inc(b);
  	x := ISAd[b^];
        inc(b);
    while((b < last) and (x <= v)) do
    begin
      if(x = v) then
      begin 
      	SWAP(b^, a^); 
      	inc(a); 
      end;
    end;
  end;
  c := last;
  dec(c);
  x := ISAd[c^];
  while ( (b < c) and (x = v)) do
  begin
    dec(c);
  	x := ISAd[c^];
  end;
  d := c;
  if ((b < d) and (x > v)) then
  begin
    dec(c);
  	x := ISAd[c^];
    while ( (b < c) and ( x >= v)) do
    begin
      if (x = v) then
      begin 
      	SWAP(c^, d^); 
      	dec(d); 
      end;
      dec(c);
    	x := ISAd[c^];
    end;
  end;
  while ( b < c) do
  begin
    SWAP(b^, c^);
    inc(b);
    x := ISAd[b^];
    while((b < c) and (x <= v)) do
    begin
      if (x = v) then
      begin 
      	SWAP(b^, a^); 
      	inc(a); 
      end;
      inc(b);
      x := ISAd[b^];
    end;
    dec(c);
    x := ISAd[c^];
    while((b < c) and (x >= v)) do
    begin
      if(x = v) then
      begin 
      	SWAP(c^, d^); 
      	dec(d); 
      end;
      dec(c);
      x := ISAd[c^];
    end;
  end;

  if(a <= d) then
  begin
    c := b - 1;
    s := a - first;
    t := b - a;
    if (s > t) then
    begin 
    	s := t; 
    end;
    e := first;
    f := b - s;
    while(0 < s) do
    begin 
    	SWAP(e^, f^);
    	dec(s); 
    	inc(e); 
    	inc(f);
    end;
    s := d - c;
    t := last - d - 1;
    if (s > t) then 
    begin 
    	s := t; 
    end;
    e := b;
    f := last - s;
    while (  0 < s )  do
    begin 
    	SWAP(e^, f^);
    	dec(s); 
    	inc(e); 
    	inc(f);
    end;
    first :=first + (b - a);
    last :=last - (d - c);
  end;
  pa^ := first;
  pb^ := last;
end;

procedure tr_copy(ISA, SA,first, a, b, last:pint32;depth:int32);
var
  c, d, e:pint32;
  s, v:int32;
begin
  { sort suffixes of middle partition
     by using sorted order of suffixes of left and right partition. }

  v := b - SA - 1;
  c := first;
  d := a - 1;
  while(c <= d) do
  begin
  	s := c^ - depth;
    if ((0 <= s) and (ISA[s] = v)) then
    begin
    	inc(d);
      d^ := s;
      ISA[s] := d - SA;
    end;
    inc(c);
  end;
  c := last - 1;
  e := d + 1;
  d := b;
  while (e < d) do
  begin
  	s := c^ - depth;
    if ((0 <= s) and (ISA[s] = v)) then
    begin
    	dec(d);
      d^ := s;
      ISA[s] := d - SA;
    end;
    dec(c);
  end;
end;

procedure tr_partialcopy(ISA, SA,first, a, b, last:pint32; depth:int32);
var
  c, d, e:pint32;
  s, v:int32;
  rank, lastrank, newrank :int32;
begin
	newrank := -1;
  v := b - SA - 1;
  lastrank := -1;
  c := first;
  d := a - 1;
  while ( c <= d) do
  begin
  	s := c^ - depth;
    if ((0 <= s) and (ISA[s] = v)) then
    begin
    	inc(d);
      d^ := s;
      rank := ISA[s + depth];
      if (lastrank <> rank) then
      begin 
      	lastrank := rank; 
      	newrank := d - SA; 
      end;
      ISA[s] := newrank;
    end;
    inc(C);
  end;

  lastrank := -1;
  e := d;
  while( first <= e) do
  begin
    rank := ISA[e^];
    if(lastrank <> rank) then
    begin 
    	lastrank := rank; 
    	newrank := e - SA; 
    end;
    if(newrank <> rank) then
    begin 
    	ISA[e^] := newrank; 
    end;
    dec(e);
  end;

  lastrank := -1;
  c := last - 1; 
  e := d + 1; 
  d := b;
  while( e < d) do
  begin
  	s := c^ - depth;
    if ((0 <= s) and (ISA[s] = v)) then
    begin
    	dec(d);
      d^ := s;
      rank := ISA[s + depth];
      if(lastrank <> rank) then
      begin 
      	lastrank := rank; 
      	newrank := d - SA; 
      end;
      ISA[s] := newrank;
    end;
    dec(e);
  end;
end;

procedure tr_introsort(ISA, ISAd,SA, first,last:pint32;budget:ptrbudget_t );
type
 stacktemp=record 
 	a, b, c:pint32; 
 	d, e:int32; 
 end;
var
  stack:array [0..TR_STACKSIZE] of stacktemp;
  a, b, c:pint32;
  v, x :int32;
  incr :int32;
  limit, next:int32;
  ssize, trlink:int32;
  procedure STACK_PUSH5(a, b, c:pint32; d, e:int32);
  begin
    assert(ssize < SS_SMERGE_STACKSIZE);
    stack[ssize].a := a; 
    stack[ssize].b := b;
    stack[ssize].c := c; 
    stack[ssize].d := d; 
    stack[ssize].e := e;
    inc(ssize);
  end;
  procedure STACK_POP5(var a, b, c:pint32;var d, e:int32);
  begin
    assert(0 <= ssize);
    if(ssize = 0) then
    begin 
      exit; 
    end;
    dec(ssize);
    a := stack[ssize].a; 
    b := stack[ssize].b;
    c := stack[ssize].c; 
    d := stack[ssize].d; 
    e := stack[ssize].e;
  end;
begin
  x := 0;
  trlink := -1;
	ssize := 0; 
	limit := tr_ilg(last - first) ;
        incr := ISAd - ISA;
  while(true) do
  begin

    if (limit < 0) then
    begin
      if (limit = -1) then
      begin
        { tandem repeat partition }
        tr_partition(ISAd - incr, first, first, last,  @a,  @b, last - SA - 1);

        { update ranks }
        if(a < last) then
        begin
        	c := first; 
        	v := a - SA - 1;
          while( c < a) do
          begin 
          	ISA[c^] := v;
          	inc(c); 
          end;
        end;
        if(b < last) then
        begin
        	c := a; 
        	v := b - SA - 1;
          while( c < b) do 
          begin 
          	ISA[c^] := v;
          	inc(c); 
          end;
        end;

        { push }
        if(1 < (b - a)) then
        begin
          STACK_PUSH5(nil, a, b, 0, 0);
          STACK_PUSH5(ISAd - incr, first, last, -2, trlink);
          trlink := ssize - 2;
        end;
        if((a - first) <= (last - b)) then
        begin
          if(1 < (a - first)) then
          begin
            STACK_PUSH5(ISAd, b, last, tr_ilg(last - b), trlink);
            last := a; 
            limit := tr_ilg(a - first);
          end
          else 
          if(1 < (last - b)) then
          begin
            first := b; 
            limit := tr_ilg(last - b);
          end
          else 
          begin
            STACK_POP5(ISAd, first, last, limit, trlink);
          end;
        end
        else 
        begin
          if(1 < (last - b)) then
          begin
            STACK_PUSH5(ISAd, first, a, tr_ilg(a - first), trlink);
            first := b; 
            limit := tr_ilg(last - b);
          end
          else 
          if(1 < (a - first)) then
          begin
            last := a; 
            limit := tr_ilg(a - first);
          end
          else
          begin
            STACK_POP5(ISAd, first, last, limit, trlink);
          end;
        end;
      end
      else 
      if(limit = -2) then
      begin
        { tandem repeat copy }
        dec(ssize);
        a := stack[ssize].b; 
        b := stack[ssize].c;
        if (stack[ssize].d = 0) then
        begin
          tr_copy(ISA, SA, first, a, b, last, ISAd - ISA);
        end
        else 
        begin
          if(0 <= trlink) then
          begin 
          	stack[trlink].d := -1; 
          end;
          tr_partialcopy(ISA, SA, first, a, b, last, ISAd - ISA);
        end;
        STACK_POP5(ISAd, first, last, limit, trlink);
      end
      else 
      begin
        { sorted partition }
        if (0 <= first^) then
        begin
          a := first;
          repeat 
          	ISA[a^] := a - SA;
          	inc(a); 
          until not ((a < last) and (0 <= a^));
          first := a;
        end;
        if(first < last) then
        begin
          a := first; 
          repeat 
            a^ := not a^; 
            inc(a);
          until not(a^ < 0);
          if (ISA[a^] <> ISAd[a^]) then
          	next := tr_ilg(a - first + 1)
          else
          	next := -1;
          inc(a);
          if (a < last) then
          begin 
          	b := first; 
          	v := a - SA - 1;
          	while ( b < a) do
          	begin 
          		ISA[b^] := v;
          		inc(b);
          	end; 
          end;

          { push }
          if (trbudget_check(budget, a - first)<>0) then
          begin
            if ((a - first) <= (last - a)) then
            begin
              STACK_PUSH5(ISAd, a, last, -3, trlink);
              ISAd :=ISAd + incr;  
              last := a; 
              limit := next;
            end
            else 
            begin
              if(1 < (last - a)) then
              begin
                STACK_PUSH5(ISAd + incr, first, a, next, trlink);
                first := a; 
                limit := -3;
              end
              else 
              begin
                ISAd :=ISAd + incr;
                last := a; 
                limit := next;
              end;
            end;
          end
          else 
          begin
            if(0 <= trlink) then
            begin 
            	stack[trlink].d := -1; 
            end;
            if(1 < (last - a)) then
            begin
              first := a;
              limit := -3;
            end
            else 
            begin
              STACK_POP5(ISAd, first, last, limit, trlink);
            end;
          end;
        end
        else 
        begin
          STACK_POP5(ISAd, first, last, limit, trlink);
        end;
      end;
      continue;
    end;

    if ((last - first) <= TR_INSERTIONSORT_THRESHOLD) then
    begin
      tr_insertionsort(ISAd, first, last);
      limit := -3;
      continue;
    end;

    if (limit = 0) then
    begin
    	dec(limit);
      tr_heapsort(ISAd, first, last - first);
      a := last - 1;
      while ( first < a) do
      begin
        x := ISAd[a^];
        b := a - 1;
        while( (first <= b) and (ISAd[b^] = x)) do
        begin 
        	b^ := not b^;
                dec(b);
        end;
        a := b;
      end;
      limit := -3;
      continue;
    end
    else
    begin
    	dec(limit);
    end;

    { choose pivot }
    a := tr_pivot(ISAd, first, last);
    SWAP(first^, a^);
    v := ISAd[first^];

    { partition }
    tr_partition(ISAd, first, first + 1, last,  @a,  @b, v);
    if((last - first) <> (b - a)) then
    begin
    	if (ISA[a^] <> v) then
      	next :=  tr_ilg(b - a)
     else
     		next := -1;

      { update ranks }
      c := first; 
      v := a - SA - 1;
      while ( c < a) do
      begin 
      	ISA[c^] := v;
      	inc(c); 
      end;
      if (b < last) then
      begin
      	c := a; 
      	v := b - SA - 1;
      	while ( c < b) do
      	begin 
      		ISA[c^] := v;
      		inc(c);
      	end; 
      end;

      { push }
      if ((1 < (b - a)) and ((trbudget_check(budget, b - a))<>0)) then
      begin
        if ((a - first) <= (last - b)) then
        begin
          if ((last - b) <= (b - a)) then
          begin
            if (1 < (a - first)) then
            begin
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              STACK_PUSH5(ISAd, b, last, limit, trlink);
              last := a;
            end
            else 
            if (1 < (last - b)) then
            begin
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              first := b;
            end
            else 
            begin
              ISAd :=ISAd + incr; 
              first := a; 
              last := b; 
              limit := next;
            end;
          end
          else 
          if ((a - first) <= (b - a)) then
          begin
            if (1 < (a - first)) then
            begin
              STACK_PUSH5(ISAd, b, last, limit, trlink);
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              last := a;
            end
            else 
            begin
              STACK_PUSH5(ISAd, b, last, limit, trlink);
              ISAd :=ISAd + incr; 
              first := a; 
              last := b; 
              limit := next;
            end;
          end
          else 
          begin
            STACK_PUSH5(ISAd, b, last, limit, trlink);
            STACK_PUSH5(ISAd, first, a, limit, trlink);
            ISAd :=ISAd + incr; 
            first := a; 
            last := b; 
            limit := next;
          end;
        end
        else 
        begin
          if ((a - first) <= (b - a)) then
          begin
            if (1 < (last - b)) then
            begin
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              STACK_PUSH5(ISAd, first, a, limit, trlink);
              first := b;
            end
            else 
            if (1 < (a - first)) then
            begin
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              last := a;
            end
            else 
            begin
              ISAd :=ISAd + incr; 
              first := a; 
              last := b; 
              limit := next;
            end;
          end
          else 
          if ((last - b) <= (b - a)) then
          begin
            if (1 < (last - b)) then
            begin
              STACK_PUSH5(ISAd, first, a, limit, trlink);
              STACK_PUSH5(ISAd + incr, a, b, next, trlink);
              first := b;
            end
            else 
            begin
              STACK_PUSH5(ISAd, first, a, limit, trlink);
              ISAd :=ISAd + incr; 
              first := a; 
              last := b; 
              limit := next;
            end;
          end
          else 
          begin
            STACK_PUSH5(ISAd, first, a, limit, trlink);
            STACK_PUSH5(ISAd, b, last, limit, trlink);
            ISAd :=ISAd + incr; 
            first := a; 
            last := b; 
            limit := next;
          end;
        end;
      end
      else 
      begin
        if ((1 < (b - a)) and (0 <= trlink)) then
        begin 
        	stack[trlink].d := -1;
        end;
        if ((a - first) <= (last - b)) then
        begin
          if(1 < (a - first)) then
          begin
            STACK_PUSH5(ISAd, b, last, limit, trlink);
            last := a;
          end
          else
          if (1 < (last - b)) then
          begin
            first := b;
          end
          else
          begin
            STACK_POP5(ISAd, first, last, limit, trlink);
          end;
        end
        else
        begin
          if (1 < (last - b)) then
          begin
            STACK_PUSH5(ISAd, first, a, limit, trlink);
            first := b;
          end
          else 
          if (1 < (a - first)) then
          begin
            last := a;
          end
          else 
          begin
            STACK_POP5(ISAd, first, last, limit, trlink);
          end;
        end;
      end;
    end
    else
    begin
      if (trbudget_check(budget, last - first)<>0) then
      begin
        limit := tr_ilg(last - first);
        ISAd :=ISAd + incr;
      end
      else
      begin
        if (0 <= trlink) then
        begin
        	stack[trlink].d := -1; 
        end;
        STACK_POP5(ISAd, first, last, limit, trlink);
      end;
    end;
  end;
end;



{---------------------------------------------------------------------------}

{ Tandem repeat sort }
procedure trsort(ISA, SA:pint32; n, depth:int32);
var
  ISAd:pint32;
  first,last:pint32;
  budget:trbudget_t;
  t, skip, unsorted:int32;
begin

  trbudget_init( @budget, tr_ilg(n) * 2 div 3, n);
{  trbudget_init( and budget, tr_ilg(n) * 3 / 4, n); }
	ISAd := ISA + depth;
  while( -n < SA^) do 
  begin
    first := SA;
    skip := 0;
    unsorted := 0;
    repeat
      t := first^;
      if (t < 0) then
      begin 
      	first :=first - t; 
      	skip  :=skip + t; 
      end
      else 
      begin
        if (skip <> 0) then
        begin 
        	(first + skip)^ := skip; 
        	skip := 0; 
        end;
        last := SA + ISA[t] + 1;
        if(1 < (last - first)) then
        begin
          budget.count := 0;
          tr_introsort(ISA, ISAd, SA, first, last,  @budget);
          if(budget.count <> 0) then
          begin 
          	unsorted :=unsorted + budget.count; 
          end
          else 
          begin 
          	skip := first - last; 
          end;
        end
        else 
        if((last - first) = 1) then
        begin
          skip := -1;
        end;
        first := last;
      end;
    until not (first < (SA + n));
    if(skip <> 0) then
    begin 
    	(first + skip)^ := skip; 
    end;
    if(unsorted = 0) then
    begin 
    	break; 
    end;
    ISAd :=ISAd + (ISAd - ISA) ;
  end;
end;


{---------------------------------------------------------------------------}

{ Sorts suffixes of type B*. }
function sort_typeBstar(T:pbyte; SA,bucket_A, bucket_B:pint32;n, openMP:int32):int32;
var
  PAb, ISAb, buf:pint32;
  i, j, k, lt, m, bufsize:int32;
  c0, c1:int32; 
begin

  { Initialize bucket arrays. }
  for i := 0 to BUCKET_A_SIZE-1 do
  begin
  	bucket_A[i] := 0; 
  end;
  for i := 0 to BUCKET_B_SIZE-1 do
  begin 
  	bucket_B[i] := 0; 
  end;

  { Count the number of occurrences of the first one or two characters of each
     type A, B and B* suffix. Moreover, store the beginning position of all
     type B* suffixes into the array SA. }
  i := n - 1; 
  m := n; 
  c0 := T[n - 1];
  while( 0 <= i ) do
  begin
    { type A suffix. }
    repeat
      c1 := c0;
      inc(bucket_A[c1]);
    	dec(i);
        c0 := T[i];
    until not((0 <= i) and (c0 >= c1));
    if(0 <= i) then
    begin
      { type B* suffix. }
      inc(bucket_B[(c0  shl  8)  or  c1]);
      dec(m);
      SA[m] := i;
      { type B suffix. }
      dec(i); 
      c1 := c0;
      c0 := T[i];
      while ( (0 <= i) and ( c0 <= c1)) do
      begin
        inc(bucket_B[(c1  shl  8)  or  c0]);
        dec(i); 
        c1 := c0;
      end;
    end;
  end;
  m := n - m;
{
note:
  A type B* suffix is lexicographically smaller than a type B suffix that
  begins with the same first two characters.
}

  { Calculate the index of start/end point32:of each bucket. }
  c0 := 0; 
  i := 0; 
  j := 0;
  while( c0 < ALPHABET_SIZE) do
  begin
    lt := i + bucket_A[c0];
    bucket_A[c0] := i + j; { start point32:}
    i := lt + bucket_B[(c0  shl  8)  or  c0];
    for c1 := c0 + 1 to ALPHABET_SIZE-1 do
    begin
      j :=j + bucket_B[(c0  shl  8)  or  c1];
      bucket_B[(c0  shl  8)  or  c1] := j; { end point32:}
      i :=i + bucket_B[(c1  shl  8)  or  c0];
    end;
    inc(c0);
  end;

  if(0 < m) then
  begin
    { Sort the type B* suffixes by their first two characters. }
    PAb := SA + n - m; 
    ISAb := SA + m;
    for i := m - 2 downto 0 do
    begin
      lt := PAb[i]; 
      c0 := T[lt]; 
      c1 := T[lt + 1];
      dec(bucket_B[(c0  shl  8)  or  c1]);
      SA[bucket_B[(c0  shl  8)  or  c1]] := i;
    end;
    lt := PAb[m - 1]; 
    c0 := T[lt]; 
    c1 := T[lt + 1];
    dec(bucket_B[(c0  shl  8)  or  c1]);
    SA[bucket_B[(c0  shl  8)  or  c1]] := m - 1;

    { Sort the type B* substrings using sssort. }
    buf := SA + m; 
    bufsize := n - (2 * m);
    j := m;
    for c0 := ALPHABET_SIZE - 2 downto 1 do
    begin
      for c1 := ALPHABET_SIZE - 1 downto c0-1  do
      begin
        i := bucket_B[(c0  shl  8)  or  c1];
        if(1 < (j - i)) then
        begin
          sssort(T, PAb, SA + i, SA + j,
                 buf, bufsize, 2, n, ord((SA + i)^ = (m - 1)));
        end;
        j := i;
      end;
    end;

    { Compute ranks of type B* substrings. }
    i := m - 1;
    while  i>=0 do
    begin
      if (0 <= SA[i]) then
      begin
        j := i;
        repeat 
        	ISAb[SA[i]] := i;
        	dec(i); 
        until not((0 <= i) and (0 <= SA[i]));
        SA[i + 1] := i - j;
        if (i <= 0) then
        begin 
        	break; 
        end;
      end;
      j := i;
      repeat 
      	SA[i] := not SA[i];
      	ISAb[SA[i]] := j;
      	dec(i); 
      until not (SA[i] < 0);
      ISAb[SA[i]] := j;
    end;

    { Construct the inverse suffix array of type B* suffixes using trsort. }
    trsort(ISAb, SA, m, 1);

    { Set the sorted order of tyoe B* suffixes. }
    i := n - 1; 
    j := m; 
    c0 := T[n - 1];
    while( 0 <= i ) do
    begin
    	dec(i);
    	c1 := c0;
    	c0 := T[i];
      while (  (0 <= i) and ((c0) >= c1)) do
      begin
      	dec(i);
      	c1 := c0;
      	c0 := T[i];
      end;
      if(0 <= i) then
      begin
        lt := i;
      	dec(i);
      	c1 := c0;
      	c0 := T[i];
        while ((0 <= i) and (c0 <= c1)) do
        begin
        	dec(i);
        	c1 := c0;
        	c0 := T[i]
        end;
        dec(j);
        if  ((lt = 0)  or  (1 < (lt - i))) then
        	SA[ISAb[j]] := lt
        else
        	SA[ISAb[j]] := not lt;
      end;
    end;

    { Calculate the index of start/end point of each bucket. }
    bucket_B[(ALPHABET_SIZE - 1  shl  8)  or  ALPHABET_SIZE - 1]:=n; { end point}
    c0 := ALPHABET_SIZE - 2; 
    k := m - 1;
    while( 0 <= c0 ) do
    begin
      i := bucket_A[c0 + 1] - 1;
      for c1 := ALPHABET_SIZE - 1 downto c0-1 do
      begin
        lt := i - bucket_B[(c1  shl  8)  or  c0];
        bucket_B[(c1  shl  8)  or  c0] := i; { end point}

        { Move all type B* suffixes to the correct position. }
        i := lt;
        j := bucket_B[(c0  shl  8)  or  c1];
        while (j <= k) do
				begin 
					SA[i] := SA[k];
					dec(i); 
					dec(k); 
				end;
      end;
      bucket_B[(c0  shl  8)  or  (c0+1)] := i - bucket_B[(c0  shl  8)  or  c0] + 1; { start point}
      bucket_B[(c0  shl  8)  or  c0] := i; { end point}
      dec(c0);
    end;
  end;

  result := m;
end;

{ Constructs the suffix array by using the sorted order of type B* suffixes. }
procedure construct_SA(T:pbyte; SA,bucket_A, bucket_B:pint32;n, m:int32);
var
  i, j, k:pint32;
  c0, c1, c2,s:int32; 
begin
  if(0 < m) then
  begin
    { Construct the sorted order of type B suffixes by using
       the sorted order of type B* suffixes. }
    for c1 := ALPHABET_SIZE - 2 downto 0  do
    begin
      { Scan the suffix array from right to left. }
      i := SA + bucket_B[(c1  shl  8)  or  (c1+1)];
      j := SA + bucket_A[c1 + 1] - 1;
      k := nil; 
      c2 := -1;
      while(i <= j) do
      begin
        s := j^;
        if(0 < s) then
        begin
          assert(T[s] = c1);
          assert(((s + 1) < n) and (T[s] <= T[s + 1]));
          assert(T[s - 1] <= T[s]);
          j^ := not s;
          c0 := T[--s];
          if ((0 < s) and (T[s - 1] > c0)) then
          begin 
          	s := not s;
          end;
          if(c0 <> c2) then
          begin
            if(0 <= c2) then
            begin 
            	bucket_B[(c1  shl  8)  or  c2] := k - SA; 
            end;
            c2 := c0;
            k := SA + bucket_B[(c1  shl  8)  or  c2];
          end;
          assert(k < j); assert(k <> nil);
          k^ := s;
          dec(k);
        end
        else
        begin
          assert(((s = 0) and (T[s] = c1))  or  (s < 0));
          j^ := not s;
        end;
        dec(j);
      end;
    end;
  end;

  { Construct the suffix array by using
     the sorted order of type B suffixes. }
  c2 := T[n - 1];
  k := SA + bucket_A[c2];
  if (T[n - 2] < c2) then
  	k^ := not (n - 1)
  else
  	k^ := (n - 1);
  inc(k);
  { Scan the suffix array from left to right. }
  i := SA; 
  j := SA + n;
  while ( i < j) do
  begin
    s := i^;
    if(0 < s) then
    begin
      assert(T[s - 1] >= T[s]);
      dec(s);
      c0 := T[s];
      if ((s = 0)  or  (T[s - 1] < c0)) then
      begin 
      	s := not s; 
      end;
      if(c0 <> c2) then
      begin
        bucket_A[c2] := k - SA;
        c2 := c0;
        k := SA + bucket_A[c2];
      end;
      assert(i < k);
      k^ := s;
      inc(k);
    end
    else
    begin
      assert(s < 0);
      i^ := not s;
    end;
    inc(i);
  end;
end;

{ Constructs the burrows-wheeler transformed string directly
   by using the sorted order of type B* suffixes. }
function construct_BWT(T:pbyte; SA,bucket_A, bucket_B:pint32;n, m:int32):int32;
var
  i, j, k, orig:pint32;
  s:int32;
  c0, c1, c2:int32;
begin

  if(0 < m) then
  begin
    { Construct the sorted order of type B suffixes by using
       the sorted order of type B* suffixes. }
    for c1 := ALPHABET_SIZE - 2 downto 0 do
    begin
      { Scan the suffix array from right to left. }
      i := SA + bucket_B[(c1  shl  8)  or  (c1+1)];
      j := SA + bucket_A[c1 + 1] - 1; 
      k := nil; 
      c2 := -1;
      while (i <= j) do 
      begin
        s := j^;
        if(0 < s) then
        begin
          assert(T[s] = c1);
          assert(((s + 1) < n) and (T[s] <= T[s + 1]));
          assert(T[s - 1] <= T[s]);
          c0 := T[--s];
          j^ := not c0;
          if ((0 < s) and (T[s - 1] > c0)) then
          begin 
          	s := not s;
          end;
          if (c0 <> c2) then
          begin
            if (0 <= c2) then
            begin 
            	bucket_B[(c1  shl  8)  or  c2] := k - SA; 
            end;
            c2 := c0;
            k := SA + bucket_B[(c1  shl  8)  or  c0];
          end;
          assert(k < j); assert(k <> nil);
          k^ := s;
          dec(k);
        end
        else 
        if (s <> 0) then
        begin
          j^ := not s;
        end 
        else 
        begin
          assert(T[s] = c1);
        end;
        dec(j);
      end;
    end;
  end;

  { Construct the BWTed string by using
     the sorted order of type B suffixes. }
  c2 := T[n - 1];
  k := SA + bucket_A[c2];
  if (T[n - 2] < c2) then
  	k^ :=  not (T[n - 2])
  else
  	k^ :=   (n - 1);
  inc(k);
  { Scan the suffix array from left to right. }
  i := SA; 
  j := SA + n; 
  orig := SA;
  while ( i < j) do
  begin
  	s := i^;
    if(0 < s) then
    begin
      assert(T[s - 1] >= T[s]);
      dec(s);
      c0 := T[s];
      i^ := c0;
      if ((0 < s) and (T[s - 1] < c0)) then
      begin 
      	s := not (T[s - 1]); 
      end;
      if(c0 <> c2) then
      begin
        bucket_A[c2] := k - SA;
        c2 := c0;
        k := SA + bucket_A[c2];
      end;
      assert(i < k);
      k^ := s;
      inc(k);
    end
    else
    if(s <> 0) then
    begin
      i^ := not s;
    end
    else 
    begin
      orig := i;
    end;
    inc(i);
  end;

  result := orig - SA;
end;

{ Constructs the burrows-wheeler transformed string directly
   by using the sorted order of type B* suffixes. }
function construct_BWT_indexes(T:pbyte; SA,bucket_A, bucket_B:pint32;n,m:int32;num_indexes:pbyte; indexes:pint32):int32;
var
  i, j, k, orig:pint32;
  c0, c1, c2,s:int32;
  lmod:int32;
begin
	lmod:= n div 8;
  lmod  := lmod  or lmod  shr  1;  lmod  :=lmod  or  lmod  shr  2;
  lmod  := lmod  or lmod  shr  4;  lmod  :=lmod  or  lmod  shr  8;
  lmod  := lmod  or lmod  shr  16; lmod  :=lmod  shr  1;

  num_indexes^ := byte((n - 1) div (lmod + 1));

  if(0 < m) then
  begin
    { Construct the sorted order of type B suffixes by using
       the sorted order of type B* suffixes. }
    for c1 := ALPHABET_SIZE - 2 downto 0 do
    begin
      { Scan the suffix array from right to left. }
      i := SA + bucket_B[(c1  shl  8)  or  (c1+1)];
      j := SA + bucket_A[c1 + 1] - 1; 
      k := nil; 
      c2 := -1;
      while(i <= j) do
      begin
        s := j^;
        if(0 < s) then
        begin
          assert(T[s] = c1);
          assert(((s + 1) < n) and (T[s] <= T[s + 1]));
          assert(T[s - 1] <= T[s]);

          if ((s  and  lmod) = 0) then
          	indexes[s div (lmod + 1) - 1] := j - SA;

          c0 := T[s];
          dec(s);
          j^ := not (c0);
          if((0 < s) and (T[s - 1] > c0)) then
          begin 
          	s := not s; 
          end;
          if(c0 <> c2) then
          begin
            if(0 <= c2) then
            begin 
            	bucket_B[(c1  shl  8)  or  c2] := k - SA; 
            end;
            c2 := c0;
            k := SA + bucket_B[(c1  shl  8)  or  c2];
          end;
          assert(k < j); assert(k <> nil);
          k^ := s;
          dec(k);
        end
        else 
        if(s <> 0) then
        begin
          j^ := not s;
        end
        else 
        begin
          assert(T[s] = c1);
        end;
        dec(j);
      end;
    end;
  end;

  { Construct the BWTed string by using
     the sorted order of type B suffixes. }
  c2 := T[n - 1];
  k := SA + bucket_A[c2];
  if (T[n - 2] < c2) then
  begin
    if (((n - 1)  and  lmod) = 0) then
    	indexes[(n - 1) div (lmod + 1) - 1] := k - SA;
    k^ := not (T[n - 2]);
    inc(k);
  end
  else 
  begin
    k^ := n - 1;
    inc(k);
  end;

  { Scan the suffix array from left to right. }
  j := SA + n; 
  orig := SA;
  i := SA;
  while i< j do
  begin
    s := i^;
    if(0 < s) then
    begin
      assert(T[s - 1] >= T[s]);

      if ((s  and  lmod) = 0) then
      	indexes[s div (lmod + 1) - 1] := i - SA;
      dec(s);
      c0 := T[s];
      i^ := c0;
      if(c0 <> c2) then
      begin
        bucket_A[c2] := k - SA;
        c2 := c0;
        k := SA + bucket_A[c2];
      end;
      assert(i < k);
      if ((0 < s) and (T[s - 1] < c0)) then
      begin
          if ((s  and  lmod) = 0) then
          	indexes[s div (lmod + 1) - 1] := k - SA;
          k^ := not(T[s - 1]);
          inc(k);
      end
      else
      begin
        k^ := s;
        inc(k);
      end;
    end
    else 
    if(s <> 0) then
    begin
      i^ := not s;
    end
    else 
    begin
      orig := i;
    end;
  end;

  result := orig - SA;
end;


{---------------------------------------------------------------------------}

{- Function -}

function divsufsort(T:pbyte; SA:pint32; n,openMP:int32):int32;
var
  bucket_A, bucket_B:pint32;
  m,err:int32;
 
begin
	err := 0;

  { Check arguments. }
  if ((T = nil)  or  (SA = nil)  or  (n < 0)) then
  begin 
  	exit(-1); 
  end
  else 
  if(n = 0) then
  begin 
  	exit(0); 
  end
  else
  if(n = 1) then
  begin 
  	SA[0] := 0; 
  	exit(0); 
  end
  else 
  if(n = 2) then
  begin 
  	m := ord(T[0] < T[1]); 
  	SA[m xor 1] := 0;
  	SA[m] := 1; 
  	exit(0); 
  end;

  bucket_A := allocmem(BUCKET_A_SIZE * sizeof(int32));
  bucket_B := allocmem(BUCKET_B_SIZE * sizeof(int32));

  { Suffixsort. }
  if((bucket_A <> nil) and (bucket_B <> nil)) then
  begin
    m := sort_typeBstar(T, SA, bucket_A, bucket_B, n, openMP);
    construct_SA(T, SA, bucket_A, bucket_B, n, m);
  end 
  else 
  begin
    err := -2;
  end;

  freemem(bucket_B);
  freemem(bucket_A);

  result := err;
end;

function divbwt(T,U:pbyte; A:pint32; n:int32;  num_indexes:pbyte;  indexes:pint32; openMP:int32):int32;
var
  B:pint32;
  bucket_A, bucket_B:pint32;
  m, pidx, i:int32;
begin

  { Check arguments. }
  if ((T = nil)  or  (U = nil)  or  (n < 0)) then
  begin 
  	exit(-1); 
  end
  else 
  if(n <= 1) then
  begin 
  	if(n = 1) then
  	begin 
  		U[0] := T[0]; 
  	end; 
  	exit(n); 
  end;
	B := A;
  if (B = nil) then
  begin 
  	B := allocmem(int32(n + 1) * sizeof(int32)); 
  end;
  bucket_A := allocmem(BUCKET_A_SIZE * sizeof(int32));
  bucket_B := allocmem(BUCKET_B_SIZE * sizeof(int32));

  { Burrows-Wheeler Transform. }
  if((B <> nil) and (bucket_A <> nil) and (bucket_B <> nil)) then
  begin
    m := sort_typeBstar(T, B, bucket_A, bucket_B, n, openMP);

    if (num_indexes = nil)  or  (indexes = nil) then
    begin
        pidx := construct_BWT(T, B, bucket_A, bucket_B, n, m);
    end
    else 
    begin
        pidx := construct_BWT_indexes(T, B, bucket_A, bucket_B, n, m, num_indexes, indexes);
    end;

    { Copy to output string. }
    U[0] := T[n - 1];
    for i := 0 to pidx -1 do
    begin 
    	U[i + 1] := B[i]; 
    end;
    for i :=i + 1 to  n-1 do
    begin 
    	U[i] := B[i]; 
    end;
    pidx :=pidx + 1;
  end
  else 
  begin
    pidx := -2;
  end;

  freemem(bucket_B);
  freemem(bucket_A);
  if(A = nil) then
  begin 
  	freemem(B); 
  end;

  result := pidx;
end;
end.
