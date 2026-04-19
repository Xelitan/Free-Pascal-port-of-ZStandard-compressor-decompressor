unit xxHash;
{$mode objfpc}{$H+}

interface
uses sysutils;
const
  XXH_VERSION_MAJOR    =0;
  XXH_VERSION_MINOR    =6;
  XXH_VERSION_RELEASE  =2;
{$define XXH_VERSION_NUMBER  (XXH_VERSION_MAJOR *100*100 + XXH_VERSION_MINOR *100 + XXH_VERSION_RELEASE)}
  XXHASH_H_5627135585666179=1;
  g_one = 1;
  PRIME32_1 = 2654435761;            
  PRIME32_2 = 2246822519;            
  PRIME32_3 = 3266489917;            
  PRIME32_4 =  668265263;            
  PRIME32_5 =  374761393;            
                                                 
  PRIME64_1 =  Uint64(11400714785074694791);
  PRIME64_2 =  Uint64(14029467366897019727);
  PRIME64_3 =  Uint64(1609587929392839161);
  PRIME64_4 =  Uint64(9650029242287828579);
  PRIME64_5 =  Uint64(2870177450012600261);
type
  XXH_errorcode = (XXH_OK=0, XXH_ERROR) ;
  XXH_endianess = (XXH_bigEndian=0, XXH_littleEndian=1);
  XXH_alignment = (XXH_aligned, XXH_unaligned);
  pXXH32_state_s=^XXH32_state_s;
  pXXH64_state_s=^XXH64_state_s;

  XXH32_state_s =record
    total_len_32:uint32;
    large_len:uint32;
    v1:uint32;
    v2:uint32;
    v3:uint32;
    v4:uint32;
    mem32:array [0..3] of uint32;   { buffer defined as Uint32 for alignment }
    memsize:uint32;
    reserved:uint32;   { never read nor write, will be removed in a future version }
  end; { typedef'd to XXH32_state_t }

  XXH64_state_s  =record
       total_len:Uint64;
       v1:Uint64;
       v2:Uint64;
       v3:Uint64;
       v4:Uint64;
       mem64:array [0..3] of Uint64;   { buffer defined as Uint64 for alignment }
       memsize:uint32;
       reserved:array [0..1] of uint32;          { never read nor write, will be removed in a future version }
   end;   { typedef'd to XXH64_state_t }
{ **************************
*  Canonical representation
***************************}
{ Default result type for XXH functions are primitive unsigned 32 and 64 bits.
*  The canonical representation uses human-readable write convention, aka big-endian (large digits first).
*  These functions allow transformation of hash result into and from its canonical format.
*  This way, hash values can be written into a file / memory, and remain comparable on different systems and programs.
}
  pXXH32_canonical_t=^XXH32_canonical_t;
  XXH32_canonical_t = record
    digest:array [0..3] of byte; 
  end;
  pXXH64_canonical_t=^XXH64_canonical_t;
  XXH64_canonical_t = record
    digest:array [0..7] of byte; 
  end;
{ ****************************
*  Simple Hash Functions
*****************************}
 XXH32_hash_t = Uint32;
 XXH64_hash_t = Uint64;

 XXH32_state_t =XXH32_state_s ;   { incomplete type }
 pXXH32_state_t = ^XXH32_state_t;
 XXH64_state_t =XXH64_state_s ;   { incomplete type }
 pXXH64_state_t = ^XXH64_state_t;
function XXH_read32(memPtr:pbyte):Uint32;
function XXH_read64(memPtr:pbyte):Uint64;
function XXH_swap32 (x:Uint32):Uint32;
function XXH_swap64 (x:Uint64):Uint64;
function XXH_readLE32_align(ptr:pbyte; endian:XXH_endianess; align:XXH_alignment):Uint32;
function XXH_readLE32(ptr:pbyte;endian:XXH_endianess):Uint32;
function XXH_readBE32(ptr:pbyte):Uint32;
function XXH_readLE64_align(ptr:pbyte;endian:XXH_endianess; align:XXH_alignment):Uint64;
function XXH_readLE64(ptr:pbyte;endian:XXH_endianess):Uint64;
function XXH_readBE64(ptr:pbyte):Uint64;
function XXH32_round(seed, input:Uint32 ):Uint32;
function XXH32_endian_align(const input:pbyte; len:int32; seed:Uint32;endian:XXH_endianess;align:XXH_alignment):Uint32;
function XXH32(const input:pbyte; len:int32; seed:Uint32):uint32;
function XXH64_round( acc, input:Uint64):Uint64;
function XXH64_mergeRound(acc, val:Uint64):Uint64;
function XXH64_endian_align(input:pbyte;  len:int32;  seed:Uint64;  endian:XXH_endianess; align:XXH_alignment):Uint64;
function XXH64(input:pbyte;  len:int32; seed:Uint64):Uint64;
function XXH32_createState():pXXH32_state_t;
function XXH32_freeState(statePtr:pXXH32_state_t ):XXH_errorcode;
function XXH64_createState():pXXH64_state_t;
function XXH64_freeState(statePtr:pXXH64_state_t ):XXH_errorcode;
function XXH32_reset(statePtr:pXXH32_state_t; seed:uint32 ):XXH_errorcode;
function XXH64_reset(statePtr:pXXH64_state_t; seed:Uint64 ):XXH_errorcode;
function XXH32_update_endian (state:pXXH32_state_t ; const input:pbyte ; len:int32;endian:XXH_endianess):XXH_errorcode;
function XXH32_update (state_in:pXXH32_state_t; const input:pbyte ;len:int32):XXH_errorcode;
function XXH32_digest_endian (const state:pXXH32_state_t;endian:XXH_endianess):Uint32;
function XXH32_digest (const state_in:pXXH32_state_t):uint32;
function XXH64_update_endian (state:pXXH64_state_t; const input:pbyte; len:int32;endian:XXH_endianess):XXH_errorcode;
function XXH64_update (state_in:pXXH64_state_t; const input:pbyte ; len:int32 ):XXH_errorcode;
function XXH64_digest_endian (const state:pXXH64_state_t ;endian:XXH_endianess):Uint64;
function XXH64_digest(const state_in:pXXH64_state_t ):Uint64;
function XXH32_hashFromCanonical(const src:XXH32_canonical_t ):XXH32_hash_t;
function XXH64_hashFromCanonical(const src:pXXH64_canonical_t ):XXH64_hash_t;
procedure XXH32_copyState(dstState:pXXH32_state_t ; const srcState:pXXH32_state_t  );
procedure XXH64_copyState(dstState:pXXH64_state_t ; const srcState:pXXH64_state_t  );
procedure XXH32_canonicalFromHash(dst:pXXH32_canonical_t; hash:XXH32_hash_t );
procedure XXH64_canonicalFromHash(dst:pXXH64_canonical_t; hash:XXH64_hash_t );
implementation
{
 *  xxHash - Fast Hash algorithm
 *  Copyright (c) 2012-2020, Yann Collet, Facebook, Inc.
 *
 *  You can contact the author at :
 *  - xxHash homepage: http://www.xxhash.com
 *  - xxHash source repository : https://github.com/Cyan4973/xxHash
 * 
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 * You may select, at your option, one of the above-listed licenses.
}


{ *************************************
*  Tuning parameters
**************************************}
{!XXH_FORCE_MEMORY_ACCESS :
 * By default, access to unaligned memory is controlled by `memcpy()`, which is safe and portable.
 * Unfortunately, on some target/compiler combinations, the generated assembly is sub-optimal.
 * The below switch allow to select different access method for improved performance.
 * Method 0 (default) : use `memcpy()`. Safe and portable.
 * Method 1 : `__packed` statement. It depends on compiler extension (ie, not portable).
 *            This method is safe if your compiler supports it, and *generally* as fast or faster than `memcpy`.
 * Method 2 : direct access. This method doesn't depend on compiler but violate C standard.
 *            It can generate buggy code on targets which do not support unaligned memory accesses.
 *            But in some circumstances, it's the only known way to get the most performance (ie GCC + ARMv6)
 * See http://stackoverflow.com/a/32095106/646947 for details.
 * Prefer these methods in priority order (0 > 1 > 2)
 }

{!XXH_ACCEPT_nil_INPUT_POINTER :
 * If the input pointer is a nil pointer, xxHash default behavior is to trigger a memory access error, since it is a bad pointer.
 * When this option is enabled, xxHash output for nil input pointers will be the same as a nil-length input.
 * By default, this option is disabled. To enable it, uncomment below define :
 }
{ #define XXH_ACCEPT_nil_INPUT_POINTER 1 }

{!XXH_FORCE_NATIVE_FORMAT :
 * By default, xxHash library provides endian-independent Hash values, based on little-endian convention.
 * Results are therefore identical for little-endian and big-endian CPU.
 * This comes at a performance cost for big-endian CPU, since some swapping is required to emulate little-endian format.
 * Should endian-independence be of no importance for your application, you may set the #define below to 1,
 * to improve speed for Big-endian CPU.
 * This option has no impact on Little_Endian CPU.
 }

{!XXH_FORCE_ALIGN_CHECK :
 * This is a minor performance trick, only useful with lots of very small keys.
 * It means : check for aligned/unaligned input.
 * The check costs one initial branch per hash; set to 0 when the input data
 * is guaranteed to be aligned.
 }

{ portable and safe solution. Generally efficient.
 * see : http://stackoverflow.com/a/32095106/646947
 }

function XXH_read32(memPtr:pbyte):Uint32;
begin
  move(memPtr[0],result, sizeof(Uint32));
end;

function XXH_read64(memPtr:pbyte):Uint64;
begin
  move(memPtr[0],result, sizeof(Uint64));
end;



function XXH_rotl32(x,r:Uint32):Uint32;
begin
   result:=((x  shl  r)  or  (x  shr  (32 - r)));
end;
function XXH_rotl64(x,r:Uint64) :Uint64;
begin
   result:=((x  shl  r)  or  (x  shr  (64 - r)))
end;
//https://www.freepascal.org/docs-html/rtl/system/swapendian.html
//SwapEndian()
function XXH_swap32 (x:Uint32):Uint32;
begin
    result :=  ((x  shl  24)  and  $ff000000 )  or 
            ((x  shl   8)  and  $00ff0000 )  or 
            ((x  shr   8)  and  $0000ff00 )  or 
            ((x  shr  24)  and  $000000ff );
end;
function XXH_swap64 (x:Uint64):Uint64;
begin
 result :=  ((x  shl  56)  and  Uint64($ff00000000000000))  or 
            ((x  shl  40)  and  Uint64($00ff000000000000))  or 
            ((x  shl  24)  and  Uint64($0000ff0000000000))  or 
            ((x  shl  8)   and  Uint64($000000ff00000000))  or 
            ((x  shr  8)   and  Uint64($00000000ff000000))  or 
            ((x  shr  24)  and  Uint64($0000000000ff0000))  or 
            ((x  shr  40)  and  Uint64($000000000000ff00))  or 
            ((x  shr  56)  and  Uint64($00000000000000ff));
end;

{ ***************************
*  Memory reads
****************************}


function XXH_readLE32_align(ptr:pbyte; endian:XXH_endianess; align:XXH_alignment):Uint32;
begin
    if (align=XXH_unaligned) then
    begin
      if endian=XXH_littleEndian then
      begin
        result := XXH_read32(ptr);
      end
      else
      begin
        result := XXH_swap32(XXH_read32(ptr));
      end;
    end
    else
    begin
      if endian=XXH_littleEndian then
      begin
        result := pUint32(ptr)^; 
      end
      else
      begin
        result := XXH_swap32(pUint32(ptr)^);
      end;
    end;
end;

function XXH_readLE32(ptr:pbyte;endian:XXH_endianess):Uint32;
begin
    result := XXH_readLE32_align(ptr, endian, XXH_unaligned);
end;

function XXH_readBE32(ptr:pbyte):Uint32;
begin
  {$IFDEF ENDIAN_LITTLE}
    result :=  XXH_swap32(XXH_read32(ptr));
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
    result :=  XXH_read32(ptr);
  {$ENDIF} 
end;

function XXH_readLE64_align(ptr:pbyte;endian:XXH_endianess; align:XXH_alignment):Uint64;
begin
    if (align=XXH_unaligned) then
    begin
        if endian=XXH_littleEndian then 
          result := XXH_read64(ptr)
        else
          result := XXH_swap64(XXH_read64(ptr));
    end
    else
    begin
        if endian=XXH_littleEndian then
         result:= pUint64(ptr)^
        else
         result := XXH_swap64(pUint64(ptr)^);
    end;
end;

function XXH_readLE64(ptr:pbyte;endian:XXH_endianess):Uint64;
begin
    result := XXH_readLE64_align(ptr, endian, XXH_unaligned);
end;

function XXH_readBE64(ptr:pbyte):Uint64;
begin
  {$IFDEF ENDIAN_LITTLE}
    result :=  XXH_swap64(XXH_read64(ptr)) ;
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
    result :=   XXH_read64(ptr);
  {$ENDIF} 
end;


{ **************************
*  Utils
***************************}
procedure XXH32_copyState(dstState:pXXH32_state_t ; const srcState:pXXH32_state_t  );
begin
    move(srcState[0],dstState[0],  sizeof(XXH32_state_t));
end;

procedure XXH64_copyState(dstState:pXXH64_state_t ; const srcState:pXXH64_state_t  );
begin
    move(srcState[0], dstState[0], sizeof(XXH64_state_t));
end;


{ ***************************
*  Simple Hash Functions
****************************}

function XXH32_round(seed, input:Uint32 ):Uint32;
begin
    seed :=seed + input * PRIME32_2;
    seed := XXH_rotl32(seed, 13);
    seed :=seed * PRIME32_1;
    result := seed;
end;

function XXH32_endian_align(const input:pbyte; len:int32; seed:Uint32;endian:XXH_endianess;align:XXH_alignment):Uint32;
var
  p,bEnd,limit:pbyte;
  h32,v1,v2,v3,v4:Uint32;
begin
    p := input;
    bEnd := p + len;

    if (len>=16) then
    begin
        limit := bEnd - 16;
        v1 := seed + PRIME32_1 + PRIME32_2;
        v2 := seed + PRIME32_2;
        v3 := seed + 0;
        v4 := seed - PRIME32_1;

        repeat
            v1 := XXH32_round(v1, XXH_readLE32_align(p, endian, align)); 
            p:=p+4;
            v2 := XXH32_round(v2, XXH_readLE32_align(p, endian, align)); 
            p:=p+4;
            v3 := XXH32_round(v3, XXH_readLE32_align(p, endian, align)); 
            p:=p+4;
            v4 := XXH32_round(v4, XXH_readLE32_align(p, endian, align)); 
            p:=p+4;
        until (p>limit);

        h32 := XXH_rotl32(v1, 1) + XXH_rotl32(v2, 7) + XXH_rotl32(v3, 12) + XXH_rotl32(v4, 18);
    end 
    else 
    begin
        h32  := seed + PRIME32_5;
    end;

    h32 :=h32 + Uint32 (len);

    while (p+4<=bEnd) do
    begin
        h32 :=h32 + XXH_readLE32_align(p, endian, align) * PRIME32_3;
        h32 := XXH_rotl32(h32, 17) * PRIME32_4 ;
        p:=p+4;
    end;

    while (p<bEnd) do
    begin
        h32 :=h32 + p^ * PRIME32_5;
        h32 := XXH_rotl32(h32, 11) * PRIME32_1 ;
        p:=p+1;
    end;

    h32 :=h32 xor h32  shr  15;
    h32 :=h32 * PRIME32_2;
    h32 :=h32 xor h32  shr  13;
    h32 :=h32 * PRIME32_3;
    h32 :=h32 xor h32  shr  16;

    result := h32;
end;


function XXH32(const input:pbyte; len:int32; seed:Uint32):uint32;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH32_endian_align(input, len, seed, XXH_littleEndian, XXH_unaligned);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result := XXH32_endian_align(input, len, seed, XXH_bigEndian, XXH_unaligned);
  {$ENDIF}
end;


function XXH64_round( acc, input:Uint64):Uint64;
begin
    acc :=acc + input * PRIME64_2;
    acc := XXH_rotl64(acc, 31);
    acc :=acc * PRIME64_1;
    result := acc;
end;

function XXH64_mergeRound(acc, val:Uint64):Uint64;
begin
    val := XXH64_round(0, val);
    acc := acc xor val;
    acc := acc * PRIME64_1 + PRIME64_4;
    result := acc;
end;

function XXH64_endian_align(input:pbyte;  len:int32;  seed:Uint64;  endian:XXH_endianess; align:XXH_alignment):Uint64;
var
  p,bEnd,limit:pbyte;
  h64,v1,v2,v3,v4,k1:Uint64;
begin
    p := input;
    bEnd := p + len;
    limit := bEnd - 32;
    if (len>=32) then
    begin
        v1 := seed + PRIME64_1 + PRIME64_2;
        v2 := seed + PRIME64_2;
        v3 := seed + 0;
        v4 := seed - PRIME64_1;

        repeat
            v1 := XXH64_round(v1, XXH_readLE64_align(p, endian, align));
            p:=p+8;
            v2 := XXH64_round(v2, XXH_readLE64_align(p, endian, align));
            p:=p+8;
            v3 := XXH64_round(v3, XXH_readLE64_align(p, endian, align));
            p:=p+8;
            v4 := XXH64_round(v4, XXH_readLE64_align(p, endian, align));
            p:=p+8;
        until (p>limit);

        h64 := XXH_rotl64(v1, 1) + XXH_rotl64(v2, 7) + XXH_rotl64(v3, 12) + XXH_rotl64(v4, 18);
        h64 := XXH64_mergeRound(h64, v1);
        h64 := XXH64_mergeRound(h64, v2);
        h64 := XXH64_mergeRound(h64, v3);
        h64 := XXH64_mergeRound(h64, v4);
    end 
    else 
    begin
        h64  := seed + PRIME64_5;
    end;

    h64 :=h64 + Uint64(len);

    while (p+8<=bEnd) do
    begin
        k1 := XXH64_round(0, XXH_readLE64_align(p, endian, align));
        h64 :=h64 xor k1;
        h64 := XXH_rotl64(h64,27) * PRIME64_1 + PRIME64_4;
        p:=p+8;
    end;

    if (p+4<=bEnd) then
    begin
        h64 :=h64 xor Uint64(XXH_readLE32_align(p, endian, align)) * PRIME64_1;
        h64 := XXH_rotl64(h64, 23) * PRIME64_2 + PRIME64_3;
        p:=p+4;
    end;

    while (p<bEnd) do
    begin
        h64 :=h64 xor Uint64(p[0]) * PRIME64_5;
        h64 := XXH_rotl64(h64, 11) * PRIME64_1;
        p:=p+1;
    end;

    h64 :=h64 xor h64  shr  33;
    h64 :=h64 * PRIME64_2;
    h64 :=h64 xor h64  shr  29;
    h64 :=h64 * PRIME64_3;
    h64 :=h64 xor h64  shr  32;

    result := h64;
end;


function XXH64(input:pbyte;  len:int32; seed:Uint64):Uint64;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH64_endian_align(input, len, seed, XXH_littleEndian, XXH_unaligned);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result := XXH64_endian_align(input, len, seed, XXH_bigEndian, XXH_unaligned);
  {$ENDIF}
end;


{ **************************************************
*  Advanced Hash Functions
***************************************************}

function XXH32_createState():pXXH32_state_t;
begin
    result := pXXH32_state_t(allocmem(sizeof(XXH32_state_t)));
end;
function XXH32_freeState(statePtr:pXXH32_state_t ):XXH_errorcode;
begin
    freemem(statePtr);
    result := XXH_OK;
end;

function XXH64_createState():pXXH64_state_t;
begin
    result :=  pXXH64_state_t(allocmem(sizeof(XXH64_state_t)));
end;
function XXH64_freeState(statePtr:pXXH64_state_t):XXH_errorcode;
begin
    freemem(statePtr);
    result :=  XXH_OK;
end;


{** Hash feed **}

function XXH32_reset(statePtr:pXXH32_state_t; seed:uint32):XXH_errorcode;
var
  state:XXH32_state_t ;   { using a local state to memcpy() in order to avoid strict-aliasing warnings }
begin
    
    fillbyte(state, sizeof(XXH32_state_t)-4,0);   { do not write into reserved, for future removal }
    state.v1 := seed + PRIME32_1 + PRIME32_2;
    state.v2 := seed + PRIME32_2;
    state.v3 := seed + 0;
    state.v4 := seed - PRIME32_1;
    move(state ,statePtr^, sizeof(XXH32_state_t));
    result :=  XXH_OK;
end;


function XXH64_reset(statePtr:pXXH64_state_t; seed:Uint64 ):XXH_errorcode;
var
  state:XXH64_state_t;   { using a local state to memcpy() in order to avoid strict-aliasing warnings }
begin
    
    fillbyte(state, sizeof(XXH64_state_t)-8, 0);   { do not write into reserved, for future removal }
    state.v1 := seed + PRIME64_1 + PRIME64_2;
    state.v2 := seed + PRIME64_2;
    state.v3 := seed + 0;
    state.v4 := seed - PRIME64_1;
    move(state,statePtr^,sizeof(XXH64_state_t));
    result :=  XXH_OK;
end;


function XXH32_update_endian (state:pXXH32_state_t ; const input:pbyte ; len:int32;endian:XXH_endianess):XXH_errorcode;
var
  p,bEnd,limit:pbyte;
  p32:pUint32;
  v1,v2,v3,v4:Uint32;
begin
    p := input;
    bEnd := p + len;

    state^.total_len_32 :=state^.total_len_32 + uint32(len);
    state^.large_len    :=state^.large_len  or ord((len>=16)  or  (state^.total_len_32>=16));

    if (state^.memsize + len < 16) then
    begin   { fill in tmp buffer }
        move(input[0], pbyte(@state^.mem32[0])[state^.memsize],  len);
        state^.memsize :=state^.memsize + uint32(len);
        exit(XXH_OK);
    end;

    if (state^.memsize<>0) then
    begin   { some data left from previous update }
        move(input[0], pbyte(@state^.mem32[0])[state^.memsize],  16-state^.memsize);   
        p32 := @state^.mem32[0];
        state^.v1 := XXH32_round(state^.v1, XXH_readLE32(pbyte(p32), endian)); 
        inc(p32);
        state^.v2 := XXH32_round(state^.v2, XXH_readLE32(pbyte(p32), endian)); 
        inc(p32);
        state^.v3 := XXH32_round(state^.v3, XXH_readLE32(pbyte(p32), endian)); 
        inc(p32);
        state^.v4 := XXH32_round(state^.v4, XXH_readLE32(pbyte(p32), endian)); 
        inc(p32);
        p :=p + 16-state^.memsize;
        state^.memsize := 0;
    end;

    if (p <= bEnd-16) then
    begin
        limit := bEnd - 16;
        v1 := state^.v1;
        v2 := state^.v2;
        v3 := state^.v3;
        v4 := state^.v4;

        repeat
            v1 := XXH32_round(v1, XXH_readLE32(p, endian)); 
            p:=p+4;
            v2 := XXH32_round(v2, XXH_readLE32(p, endian)); 
            p:=p+4;
            v3 := XXH32_round(v3, XXH_readLE32(p, endian)); 
            p:=p+4;
            v4 := XXH32_round(v4, XXH_readLE32(p, endian)); 
            p:=p+4;
        until (p>limit);

        state^.v1 := v1;
        state^.v2 := v2;
        state^.v3 := v3;
        state^.v4 := v4;
    end;

    if (p < bEnd) then
    begin
        move(p[0],state^.mem32[0],  int32(bEnd-p));
        state^.memsize := uint32(bEnd-p);
    end;

    result := XXH_OK;
end;

function XXH32_update (state_in:pXXH32_state_t; const input:pbyte ;len:int32):XXH_errorcode;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH32_update_endian(state_in, input, len, XXH_littleEndian);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result := XXH32_update_endian(state_in, input, len, XXH_bigEndian);
  {$ENDIF}
end;



function XXH32_digest_endian (const state:pXXH32_state_t;endian:XXH_endianess):Uint32;
var
  p,bEnd:pbyte;
  h32:Uint32;
begin
     p   := pBYTE(@state^.mem32[0]);
    bEnd := pBYTE(@state^.mem32[0]) + state^.memsize;

    if (state^.large_len<>0) then
    begin
        h32 := XXH_rotl32(state^.v1, 1) + XXH_rotl32(state^.v2, 7) + XXH_rotl32(state^.v3, 12) + XXH_rotl32(state^.v4, 18);
    end 
    else 
    begin
        h32 := state^.v3 { == seed } + PRIME32_5;
    end;

    h32 :=h32 + state^.total_len_32;

    while (p+4<=bEnd) do
    begin
        h32 :=h32 + XXH_readLE32(p, endian) * PRIME32_3;
        h32 := XXH_rotl32(h32, 17) * PRIME32_4;
        p:=p+4;
    end;

    while (p<bEnd) do 
    begin
        h32 :=h32 + p^ * PRIME32_5;
        h32 := XXH_rotl32(h32, 11) * PRIME32_1;
        p:=p+1;
    end;

    h32 :=h32 xor h32  shr  15;
    h32 :=h32 * PRIME32_2;
    h32 :=h32 xor h32  shr  13;
    h32 :=h32 * PRIME32_3;
    h32 :=h32 xor h32  shr  16;

    result := h32;
end;


function XXH32_digest (const state_in:pXXH32_state_t):uint32;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH32_digest_endian(state_in, XXH_littleEndian);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result := XXH32_digest_endian(state_in, XXH_bigEndian);
  {$ENDIF}
end;



{ **** XXH64 **** }

function XXH64_update_endian (state:pXXH64_state_t; const input:pbyte; len:int32;endian:XXH_endianess):XXH_errorcode;
var
  p,bEnd,limit:pbyte;
  v1,v2,v3,v4:Uint64;
begin
    p := input;
    bEnd := p + len;

    state^.total_len :=state^.total_len + len;

    if (state^.memsize + len < 32) then
    begin  { fill in tmp buffer }
        if (input <> nil) then
        begin
            move(input[0], pbyte(@state^.mem64[0])[state^.memsize],  len);
        end;
        state^.memsize :=state^.memsize + Uint32(len);
        exit(XXH_OK);
    end;

    if (state^.memsize<>0) then
    begin   { tmp buffer is full }
        move(input[0], pbyte(@state^.mem64[0])[state^.memsize],  32-state^.memsize);
        state^.v1 := XXH64_round(state^.v1, XXH_readLE64(@state^.mem64[0], endian));
        state^.v2 := XXH64_round(state^.v2, XXH_readLE64(@state^.mem64[1], endian));
        state^.v3 := XXH64_round(state^.v3, XXH_readLE64(@state^.mem64[2], endian));
        state^.v4 := XXH64_round(state^.v4, XXH_readLE64(@state^.mem64[3], endian));
        p :=p + 32-state^.memsize;
        state^.memsize := 0;
    end;

    if (p+32 <= bEnd) then
    begin
        limit     := bEnd - 32;
        v1 := state^.v1;
        v2 := state^.v2;
        v3 := state^.v3;
        v4 := state^.v4;

        repeat
            v1 := XXH64_round(v1, XXH_readLE64(p, endian)); p:=p+8;
            v2 := XXH64_round(v2, XXH_readLE64(p, endian)); p:=p+8;
            v3 := XXH64_round(v3, XXH_readLE64(p, endian)); p:=p+8;
            v4 := XXH64_round(v4, XXH_readLE64(p, endian)); p:=p+8;
        until (p>limit);

        state^.v1 := v1;
        state^.v2 := v2;
        state^.v3 := v3;
        state^.v4 := v4;
    end;

    if (p < bEnd) then
    begin
        move(p[0],state^.mem64[0],  int32(bEnd-p));
        state^.memsize := uint32(bEnd-p);
    end;

    result := XXH_OK;
end;

function XXH64_update (state_in:pXXH64_state_t; const input:pbyte ; len:int32 ):XXH_errorcode;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH64_update_endian(state_in, input, len, XXH_littleEndian);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result :=  XXH64_update_endian(state_in, input, len, XXH_bigEndian);
  {$ENDIF}
end;



function XXH64_digest_endian (const state:pXXH64_state_t ;endian:XXH_endianess):Uint64;
var
  p,bEnd:pbyte;
  h64,v1,v2,v3,v4,k1:Uint64;
begin
    p := @state^.mem64[0];
    bEnd := pbyte(@state^.mem64[0]) + state^.memsize;

    if (state^.total_len >= 32) then
    begin
        v1 := state^.v1;
        v2 := state^.v2;
        v3 := state^.v3;
        v4 := state^.v4;

        h64 := XXH_rotl64(v1, 1) + XXH_rotl64(v2, 7) + XXH_rotl64(v3, 12) + XXH_rotl64(v4, 18);
        h64 := XXH64_mergeRound(h64, v1);
        h64 := XXH64_mergeRound(h64, v2);
        h64 := XXH64_mergeRound(h64, v3);
        h64 := XXH64_mergeRound(h64, v4);
    end 
    else 
    begin
        h64  := state^.v3 + PRIME64_5;
    end;

    h64 :=h64 + Uint64 (state^.total_len);

    while (p+8<=bEnd) do
    begin
        k1  := XXH64_round(0, XXH_readLE64(p, endian));
        h64 := h64 xor k1;
        h64 := XXH_rotl64(h64,27) * PRIME64_1 + PRIME64_4;
        p:=p+8;
    end;

    if (p+4<=bEnd) then
    begin
        h64 :=h64 xor Uint64(XXH_readLE32(p, endian)) * PRIME64_1;
        h64 := XXH_rotl64(h64, 23) * PRIME64_2 + PRIME64_3;
        p:=p+4;
    end;

    while (p<bEnd) do
    begin
        h64 :=h64 xor Uint64(p^) * PRIME64_5;
        h64 := XXH_rotl64(h64, 11) * PRIME64_1;
        p:=p+1;
    end;

    h64 :=h64 xor h64  shr  33;
    h64 :=h64 * PRIME64_2;
    h64 :=h64 xor h64  shr  29;
    h64 :=h64 * PRIME64_3;
    h64 :=h64 xor h64  shr  32;

    result := h64;
end;


function XXH64_digest(const state_in:pXXH64_state_t ):Uint64;
begin
  {$IFDEF ENDIAN_LITTLE}
        result := XXH64_digest_endian(state_in, XXH_littleEndian);
  {$ENDIF}
  {$IFDEF ENDIAN_BIG}
        result :=  XXH64_digest_endian(state_in, XXH_bigEndian);
  {$ENDIF}
end;


{ **************************
*  Canonical representation
***************************}

{! Default XXH result types are basic unsigned 32 and 64 bits.
*   The canonical representation follows human-readable write convention, aka big-endian (large digits first).
*   These functions allow transformation of hash result into and from its canonical format.
*   This way, hash values can be written into a file or buffer, and remain comparable across different systems and programs.
}

procedure XXH32_canonicalFromHash(dst:pXXH32_canonical_t; hash:XXH32_hash_t );
begin
  {$IFDEF ENDIAN_LITTLE}
  hash := XXH_swap32(hash);
  {$ENDIF}
  move(hash,dst^, sizeof(XXH32_canonical_t));
end;

procedure XXH64_canonicalFromHash(dst:pXXH64_canonical_t; hash:XXH64_hash_t );
begin
  {$IFDEF ENDIAN_LITTLE}
  hash := XXH_swap64(hash);
  {$ENDIF}
  move(hash,dst^, sizeof(XXH64_canonical_t));
end;

function XXH32_hashFromCanonical(const src:XXH32_canonical_t ):XXH32_hash_t;
begin
    result := XXH_readBE32(@src);
end;

function XXH64_hashFromCanonical(const src:pXXH64_canonical_t ):XXH64_hash_t;
begin
    result := XXH_readBE64(@src);
end;
end.
