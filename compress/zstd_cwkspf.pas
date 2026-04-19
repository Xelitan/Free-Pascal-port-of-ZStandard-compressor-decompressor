unit ZSTD_CWKSPF;
{$mode objfpc}{$H+}

interface
uses zstd_internal,zstd,zstd_common,error_private;
const
  ZSTD_CWKSP_ASAN_REDZONE_SIZE = 0;  { Only non-zero when using AddressSanitizer }

type
{-*************************************
*  Structures
**************************************}
ZSTD_cwksp_alloc_phase_e = (
    ZSTD_cwksp_alloc_objects,
    ZSTD_cwksp_alloc_buffers,
    ZSTD_cwksp_alloc_aligned
);

{*
 * Used to describe whether the workspace is statically allocated (and will not
 * necessarily ever be freed), or if it's dynamically allocated and we can
 * expect a well-formed caller to free this.
 }
ZSTD_cwksp_static_alloc_e=(
    ZSTD_cwksp_dynamic_alloc,
    ZSTD_cwksp_static_alloc
);

{*
 * Zstd fits all its internal datastructures into a single continuous buffer,
 * so that it only needs to perform a single OS allocation (or so that a buffer
 * can be provided to it and it can perform no allocations at all). This buffer
 * is called the workspace.
 *
 * Several optimizations complicate that process of allocating memory ranges
 * from this workspace for each internal datastructure:
 *
 * - These different internal datastructures have different setup requirements:
 *
 *   - The static objects need to be cleared once and can then be trivially
 *     reused for each compression.
 *
 *   - Various buffers don't need to be initialized at all--they are always
 *     written into before they're read.
 *
 *   - The matchstate tables have a unique requirement that they don't need
 *     their memory to be totally cleared, but they do need the memory to have
 *     some bound, i.e., a guarantee that all values in the memory they've been
 *     allocated is less than some maximum value (which is the starting value
 *     for the indices that they will then use for compression). When this
 *     guarantee is provided to them, they can use the memory without any setup
 *     work. When it can't, they have to clear the area.
 *
 * - These buffers also have different alignment requirements.
 *
 * - We would like to reuse the objects in the workspace for multiple
 *   compressions without having to perform any expensive reallocation or
 *   reinitialization work.
 *
 * - We would like to be able to efficiently reuse the workspace across
 *   multiple compressions **even when the compression parameters change** and
 *   we need to resize some of the objects (where possible).
 *
 * To attempt to manage this buffer, given these constraints, the ZSTD_cwksp
 * abstraction was created. It works as follows:
 *
 * Workspace Layout:
 *
 * [                        ... workspace ...                         ]
 * [objects][tables ... ^.] free space [<- ... aligned][<- ... buffers]
 *
 * The various objects that live in the workspace are divided into the
 * following categories, and are allocated separately:
 *
 * - Static objects: this is optionally the enclosing ZSTD_CCtx or ZSTD_CDict,
 *   so that literally everything fits in a single buffer. Note: if present,
 *   this must be the first object in the workspace, since ZSTD_customFreebeginCCtx,
 *   CDictend;() rely on a pointer comparison to see whether one or two frees are
 *   required.
 *
 * - Fixed size objects: these are fixed-size, fixed-count objects that are
 *   nonetheless 'dynamically' allocated in the workspace so that we can
 *   control how they're initialized separately from the broader ZSTD_CCtx.
 *   Examples:
 *   - Entropy Workspace
 *   - 2 x ZSTD_compressedBlockState_t
 *   - CDict dictionary contents
 *
 * - Tables: these are any of several different datastructures (hash tables,
 *   chain tables, binary trees) that all respect a common format: they are
 *   uint32_t arrays, all of whose values are between 0 and (nextSrc - base).
 *   Their sizes depend on the cparams.
 *
 * - Aligned: these buffers are used for various purposes that require 4 byte
 *   alignment, but don't require any initialization before they're used.
 *
 * - Buffers: these buffers are used for various purposes that don't require
 *   any alignment or initialization before they're used. This means they can
 *   be moved around at no cost for a new compression.
 *
 * Allocating Memory:
 *
 * The various types of objects must be allocated in order, so they can be
 * correctly packed into the workspace buffer. That order is:
 *
 * 1. Objects
 * 2. Buffers
 * 3. Aligned
 * 4. Tables
 *
 * Attempts to reserve objects of different types out of order will fail.
 }

ZSTD_cwksp=record
    workspace:pbyte;
    workspaceEnd:pbyte;

    objectEnd:pbyte;
    tableEnd:pbyte;
    tableValidEnd:pbyte;
    allocStart:pbyte;

    allocFailed:BYTE;
    workspaceOversizedDuration:int32;
    phase:ZSTD_cwksp_alloc_phase_e ;
    isStatic:ZSTD_cwksp_static_alloc_e ;
end;
pZSTD_cwksp=^ZSTD_cwksp;
function ZSTD_cwksp_available_space(ws:pZSTD_cwksp):int32;
procedure ZSTD_cwksp_init(ws:pZSTD_cwksp; start:pbyte; size:int32; isStatic:ZSTD_cwksp_static_alloc_e);
function ZSTD_cwksp_reserve_object(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
procedure ZSTD_cwksp_move(dst,src:pZSTD_cwksp);
function ZSTD_cwksp_check_available(ws:pZSTD_cwksp; additionalNeededSpace:int32):int32;
procedure ZSTD_cwksp_freemem(ws:pZSTD_cwksp; customMem:ZSTD_customMem );
function ZSTD_cwksp_owns_buffer(const ws:pZSTD_cwksp; ptr:pbyte ):int32;
function ZSTD_cwksp_sizeof(const ws:pZSTD_cwksp):int32;
function ZSTD_cwksp_alloc_size(size:int32):int32;
procedure ZSTD_cwksp_mark_tables_dirty(ws:pZSTD_cwksp);
function ZSTD_cwksp_reserve_failed(const ws:pZSTD_cwksp):int32;
procedure ZSTD_cwksp_clear_tables(ws:pZSTD_cwksp);
function ZSTD_cwksp_reserve_table(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
procedure ZSTD_cwksp_clean_tables(ws:pZSTD_cwksp);
function ZSTD_cwksp_reserve_aligned(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
procedure ZSTD_cwksp_bump_oversized_duration(ws:pZSTD_cwksp; additionalNeededSpace:int32);
function ZSTD_cwksp_check_wasteful(ws:pZSTD_cwksp; additionalNeededSpace:int32):int32;
function ZSTD_cwksp_create(ws:pZSTD_cwksp; size:int32; customMem:ZSTD_customMem ):int32;
procedure ZSTD_cwksp_clear(ws:pZSTD_cwksp);
function ZSTD_cwksp_reserve_buffer(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
function ZSTD_cwksp_used(const ws:pZSTD_cwksp):int32;
procedure ZSTD_cwksp_mark_tables_clean(ws:pZSTD_cwksp);
function ZSTD_cwksp_align(size,align:int32):int32;
implementation
{-*************************************
*  Functions
**************************************}

procedure ZSTD_cwksp_assert_internal_consistency(ws:pZSTD_cwksp); 
begin
    assert(ws^.workspace <= ws^.objectEnd);
    assert(ws^.objectEnd <= ws^.tableEnd);
    assert(ws^.objectEnd <= ws^.tableValidEnd);
    assert(ws^.tableEnd <= ws^.allocStart);
    assert(ws^.tableValidEnd <= ws^.allocStart);
    assert(ws^.allocStart <= ws^.workspaceEnd);
end;

{*
 * Align must be a power of 2.
 }
function ZSTD_cwksp_align(size,align:int32):int32;
var
  mask:int32;
begin
    mask := align - 1;
    assert((align and mask) = 0);
    result := (size + mask) and not mask;
end;

{*
 * Use this to determine how much space in the workspace we will consume to
 * allocate this object. (Normally it should be exactly the size of the object,
 * but under special conditions, like ASAN, where we pad each object, it might
 * be larger.)
 *
 * Since tables aren't currently redzoned, you don't need to call through this
 * to figure out how much space you need for the matchState tables. Everything
 * else is though.
 }
function ZSTD_cwksp_alloc_size(size:int32):int32; 
begin
    if (size = 0) then
        exit(0);
    result := size + 2 * ZSTD_CWKSP_ASAN_REDZONE_SIZE;
end;

procedure ZSTD_cwksp_internal_advance_phase(ws:pZSTD_cwksp; phase:ZSTD_cwksp_alloc_phase_e);
begin
    assert(phase >= ws^.phase);
    if (phase > ws^.phase) then
    begin
        if (ws^.phase < ZSTD_cwksp_alloc_buffers)  and 
                (phase >= ZSTD_cwksp_alloc_buffers) then
        begin
            ws^.tableValidEnd := ws^.objectEnd;
        end;
        if (ws^.phase < ZSTD_cwksp_alloc_aligned)  and 
                (phase >= ZSTD_cwksp_alloc_aligned) then
        begin
            { If unaligned allocations down from a too-large top have left us
             * unaligned, we need to realign our alloc ptr. Technically, this
             * can consume space that is unaccounted for in the neededSpace
             * calculation. However, I believe this can only happen when the
             * workspace is too large, and specifically when it is too large
             * by a larger margin than the space that will be consumed. }
            { TODO: cleaner, compiler warning friendly way to do this??? }
            ws^.allocStart := pbyte(ws^.allocStart) - (PtrUInt(ws^.allocStart) and (sizeof(Uint32)-1));
            if (ws^.allocStart < ws^.tableValidEnd) then
            begin
                ws^.tableValidEnd := ws^.allocStart;
            end;
        end;
        ws^.phase := phase;
    end;
end;

{*
 * Returns whether this object/buffer/etc was allocated in this workspace.
 }
function ZSTD_cwksp_owns_buffer(const ws:pZSTD_cwksp; ptr:pbyte ):int32;
begin
    result := ord((ptr <> nil)  and  (ws^.workspace <= ptr)  and  (ptr <= ws^.workspaceEnd));
end;

{*
 * Internal function. Do not use directly.
 }
function ZSTD_cwksp_reserve_internal(ws:pZSTD_cwksp; bytes:int32; phase:ZSTD_cwksp_alloc_phase_e):pbyte;
var
  alloc,bottom:pbyte; 
begin
  bottom := ws^.tableEnd;
  ZSTD_cwksp_internal_advance_phase(ws, phase);
  alloc := pbyte(ws^.allocStart) - bytes;

  if (bytes = 0) then
      exit(nil);

    { over-reserve space }
    alloc := pbyte(alloc) - 2 * ZSTD_CWKSP_ASAN_REDZONE_SIZE;


    //DEBUGLOG(5, 'cwksp: reserving %p %zd bytes, %zd bytes remaining',
    //    alloc, bytes, ZSTD_cwksp_available_space(ws) - bytes);
    ZSTD_cwksp_assert_internal_consistency(ws);
    assert(alloc >= bottom);
    if (alloc < bottom) then
    begin
        DEBUGLOG(4, ['cwksp: alloc failed!']);
        ws^.allocFailed := 1;
        exit(nil);
    end;
    if (alloc < ws^.tableValidEnd) then
    begin
        ws^.tableValidEnd := alloc;
    end;
    ws^.allocStart := alloc;


    { Move alloc so there's ZSTD_CWKSP_ASAN_REDZONE_SIZE unused space on
     * either size. }
    alloc := pbyte(alloc) + ZSTD_CWKSP_ASAN_REDZONE_SIZE;
    if (ws^.isStatic = ZSTD_cwksp_dynamic_alloc) then
    begin
        //__asan_unpoison_memory_region(alloc, bytes);
    end;


    result := alloc;
end;

{*
 * Reserves and returns unaligned memory.
 }
function ZSTD_cwksp_reserve_buffer(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
begin
    result := pbyte(ZSTD_cwksp_reserve_internal(ws, bytes, ZSTD_cwksp_alloc_buffers));
end;

{*
 * Reserves and returns memory sized on and aligned on sizeof(unsigned).
 }
function ZSTD_cwksp_reserve_aligned(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
begin
    assert((bytes and (sizeof(Uint32)-1)) = 0);
    result := ZSTD_cwksp_reserve_internal(ws, ZSTD_cwksp_align(bytes, sizeof(Uint32)), ZSTD_cwksp_alloc_aligned);
end;

{*
 * Aligned on sizeof(unsigned). These buffers have the special property that
 * their values remain constrained, allowing us to re-use them without
 * memset()-ing them.
 }
function ZSTD_cwksp_reserve_table(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
var
  phase:ZSTD_cwksp_alloc_phase_e;
  alloc,lend,top:pbyte;
begin
    phase := ZSTD_cwksp_alloc_aligned;
    alloc := ws^.tableEnd;
    lend := pbyte(alloc) + bytes;
    top := ws^.allocStart;

    //DEBUGLOG(5, 'cwksp: reserving %p table %zd bytes, %zd bytes remaining',
    //    alloc, bytes, ZSTD_cwksp_available_space(ws) - bytes);
    assert((bytes and (sizeof(UINT32)-1)) = 0);
    ZSTD_cwksp_internal_advance_phase(ws, phase);
    ZSTD_cwksp_assert_internal_consistency(ws);
    assert(lend <= top);
    if (lend > top) then
    begin
        DEBUGLOG(4, ['cwksp: table alloc failed!']);
        ws^.allocFailed := 1;
        exit(nil);
    end;
    ws^.tableEnd := lend;

    if (ws^.isStatic = ZSTD_cwksp_dynamic_alloc) then
    begin
        //__asan_unpoison_memory_region(alloc, bytes);
    end;

    result := alloc;
end;

{*
 * Aligned on sizeof(void*).
 }
function ZSTD_cwksp_reserve_object(ws:pZSTD_cwksp; bytes:int32 ):pbyte;
var
  roundedBytes:int32;
  alloc,lend:pbyte;
begin
    roundedBytes := ZSTD_cwksp_align(bytes, sizeof(pbyte));
    alloc := ws^.objectEnd;
    lend := alloc + roundedBytes;

    { over-reserve space }
    lend := lend + 2 * ZSTD_CWKSP_ASAN_REDZONE_SIZE;

    //DEBUGLOG(5,
    //    'cwksp: reserving %p object %zd bytes (rounded to %zd), %zd bytes remaining',
    //    alloc, bytes, roundedBytes, ZSTD_cwksp_available_space(ws) - roundedBytes);
    assert((PtrUInt(alloc) and (sizeof(pbyte)-1)) = 0);
    assert((bytes and (sizeof(pbyte)-1)) = 0);
    ZSTD_cwksp_assert_internal_consistency(ws);
    { we must be in the first phase, no advance is possible }
    if (ws^.phase <> ZSTD_cwksp_alloc_objects) or (lend > ws^.workspaceEnd) then
    begin
        DEBUGLOG(4, ['cwksp: object alloc failed!']);
        ws^.allocFailed := 1;
        exit(nil);
    end;
    ws^.objectEnd := lend;
    ws^.tableEnd := lend;
    ws^.tableValidEnd := lend;

    { Move alloc so there's ZSTD_CWKSP_ASAN_REDZONE_SIZE unused space on
     * either size. }
    alloc := alloc + ZSTD_CWKSP_ASAN_REDZONE_SIZE;
    if (ws^.isStatic = ZSTD_cwksp_dynamic_alloc) then
    begin
        //__asan_unpoison_memory_region(alloc, bytes);
    end;


    result := alloc;
end;

procedure ZSTD_cwksp_mark_tables_dirty(ws:pZSTD_cwksp);
var
  size:int32;
begin
    DEBUGLOG(4, ['cwksp: ZSTD_cwksp_mark_tables_dirty']);

    { To validate that the table re-use logic is sound, and that we don't
     * access table space that we haven't cleaned, we re-'poison' the table
     * space every time we mark it dirty. }
    size := pbyte(ws^.tableValidEnd) - pbyte(ws^.objectEnd);
    //assert(__msan_test_shadow(ws^.objectEnd, size) = -1);
    //__msan_poison(ws^.objectEnd, size);

    assert(ws^.tableValidEnd >= ws^.objectEnd);
    assert(ws^.tableValidEnd <= ws^.allocStart);
    ws^.tableValidEnd := ws^.objectEnd;
    ZSTD_cwksp_assert_internal_consistency(ws);
end;

procedure ZSTD_cwksp_mark_tables_clean(ws:pZSTD_cwksp);
begin
    DEBUGLOG(4, ['cwksp: ZSTD_cwksp_mark_tables_clean']);
    assert(ws^.tableValidEnd >= ws^.objectEnd);
    assert(ws^.tableValidEnd <= ws^.allocStart);
    if (ws^.tableValidEnd < ws^.tableEnd) then
    begin
        ws^.tableValidEnd := ws^.tableEnd;
    end;
    ZSTD_cwksp_assert_internal_consistency(ws);
end;

{*
 * Zero the part of the allocated tables not already marked clean.
 }
procedure ZSTD_cwksp_clean_tables(ws:pZSTD_cwksp);
var
  cleanSize: PtrInt;
begin
    DEBUGLOG(4, ['cwksp: ZSTD_cwksp_clean_tables']);
    assert(ws^.tableValidEnd >= ws^.objectEnd);
    assert(ws^.tableValidEnd <= ws^.allocStart);
    if (ws^.tableValidEnd < ws^.tableEnd) then
    begin
        cleanSize := pbyte(ws^.tableEnd) - pbyte(ws^.tableValidEnd);
        //log(stderr, 'cwksp_clean_tables: tableValidEnd=', PtrUInt(ws^.tableValidEnd),
        //        ' tableEnd=', PtrUInt(ws^.tableEnd),
        //        ' cleanSize=', cleanSize,
        //        ' ASAN_REDZONE=', ZSTD_CWKSP_ASAN_REDZONE_SIZE);
        if (ws^.tableValidEnd = nil) or (cleanSize <= 0) then
        begin
            //log(stderr, 'ERROR: invalid tableValidEnd or cleanSize!');
            exit;
        end;
        fillbyte(ws^.tableValidEnd^, cleanSize, 0);
    end;
    ZSTD_cwksp_mark_tables_clean(ws);
end;

{*
 * Invalidates table allocations.
 * All other allocations remain valid.
 }
procedure ZSTD_cwksp_clear_tables(ws:pZSTD_cwksp);
var
  size:int32;
begin
    DEBUGLOG(4, ['cwksp: clearing tables!']);


    { We don't do this when the workspace is statically allocated, because
     * when that is the case, we have no capability to hook into the end of the
     * workspace's lifecycle to unpoison the memory.
     }
    if (ws^.isStatic = ZSTD_cwksp_dynamic_alloc) then
    begin
        size := pbyte(ws^.tableValidEnd) - pbyte(ws^.objectEnd);
        //__asan_poison_memory_region(ws^.objectEnd, size);
    end;


    ws^.tableEnd := ws^.objectEnd;
    ZSTD_cwksp_assert_internal_consistency(ws);
end;

{*
 * Invalidates all buffer, aligned, and table allocations.
 * Object allocations remain valid.
 }
procedure ZSTD_cwksp_clear(ws:pZSTD_cwksp);
var
  size:int32;
begin
    DEBUGLOG(4, ['cwksp: clearing!']);


    { To validate that the context re-use logic is sound, and that we don't
     * access stuff that this compression hasn't initialized, we re-'poison'
     * the workspace (or at least the non-static, non-table parts of it)
     * every time we start a new compression. }
    size := pbyte(ws^.workspaceEnd) - pbyte(ws^.tableValidEnd);
    //__msan_poison(ws^.tableValidEnd, size);


    { We don't do this when the workspace is statically allocated, because
     * when that is the case, we have no capability to hook into the end of the
     * workspace's lifecycle to unpoison the memory.
     }
    if (ws^.isStatic = ZSTD_cwksp_dynamic_alloc) then
    begin
        size := pbyte(ws^.workspaceEnd) - pbyte(ws^.objectEnd);
        //__asan_poison_memory_region(ws^.objectEnd, size);
    end;

    ws^.tableEnd := ws^.objectEnd;
    ws^.allocStart := ws^.workspaceEnd;
    ws^.allocFailed := 0;
    if (ws^.phase > ZSTD_cwksp_alloc_buffers) then
    begin
        ws^.phase := ZSTD_cwksp_alloc_buffers;
    end;
    ZSTD_cwksp_assert_internal_consistency(ws);
end;

{*
 * The provided workspace takes ownership of the buffer [start, start+size).
 * Any existing values in the workspace are ignored (the previously managed
 * buffer, if present, must be separately freed).
 }
procedure ZSTD_cwksp_init(ws:pZSTD_cwksp; start:pbyte; size:int32; isStatic:ZSTD_cwksp_static_alloc_e); 
begin
    //DEBUGLOG(4, ['cwksp: init''ing workspace with  mod zd bytes', size]);
    assert((PtrUInt(start) and (sizeof(pbyte)-1)) = 0); { ensure correct alignment }
    ws^.workspace := start;
    ws^.workspaceEnd := start + size;
    ws^.objectEnd := ws^.workspace;
    ws^.tableValidEnd := ws^.objectEnd;
    ws^.phase := ZSTD_cwksp_alloc_objects;
    ws^.isStatic := isStatic;
    ZSTD_cwksp_clear(ws);
    ws^.workspaceOversizedDuration := 0;
    ZSTD_cwksp_assert_internal_consistency(ws);
end;

function ZSTD_cwksp_create(ws:pZSTD_cwksp; size:int32; customMem:ZSTD_customMem ):int32;
var
  workspace:pbyte;
begin
    workspace := ZSTD_customMalloc(size, customMem);
    if (workspace = nil) then
        exit(ERROR(memory_allocation));
    ZSTD_cwksp_init(ws, workspace, size, ZSTD_cwksp_dynamic_alloc);
    result := 0;
end;

procedure ZSTD_cwksp_freemem(ws:pZSTD_cwksp; customMem:ZSTD_customMem );
var
  ptr:pbyte;
begin
    ptr := ws^.workspace;
    //DEBUGLOG(4, 'cwksp: freeing workspace');
    fillbyte(ws^, sizeof(ZSTD_cwksp), 0);
    ZSTD_customfree(ptr, customMem);
end;

{*
 * Moves the management of a workspace from one cwksp to another. The src cwksp
 * is left in an invalid state (src must be re-init()'ed before its used again).
 }
procedure ZSTD_cwksp_move(dst,src:pZSTD_cwksp);
begin
    dst^ := src^;
    fillbyte(src^, sizeof(ZSTD_cwksp), 0);
end;

function ZSTD_cwksp_sizeof(const ws:pZSTD_cwksp):int32; 
begin
    result := int32(pbyte(ws^.workspaceEnd) - pbyte(ws^.workspace));
end;

function ZSTD_cwksp_used(const ws:pZSTD_cwksp):int32; 
begin
    result := int32(pbyte(ws^.tableEnd) - pbyte(ws^.workspace))
         + int32(pbyte(ws^.workspaceEnd) - pbyte(ws^.allocStart));
end;

function ZSTD_cwksp_reserve_failed(const ws:pZSTD_cwksp):int32; 
begin
    result := ws^.allocFailed;
end;

{-*************************************
*  Functions Checking Free Space
**************************************}

function ZSTD_cwksp_available_space(ws:pZSTD_cwksp):int32; 
begin
    result := int32(pbyte(ws^.allocStart) - pbyte(ws^.tableEnd));
end;

function ZSTD_cwksp_check_available(ws:pZSTD_cwksp; additionalNeededSpace:int32):int32; 
begin
    result := ord(ZSTD_cwksp_available_space(ws) >= additionalNeededSpace);
end;

function ZSTD_cwksp_check_too_large(ws:pZSTD_cwksp; additionalNeededSpace:int32):int32; 
begin
    result := ZSTD_cwksp_check_available(
        ws, additionalNeededSpace * ZSTD_WORKSPACETOOLARGE_FACTOR);
end;

function ZSTD_cwksp_check_wasteful(ws:pZSTD_cwksp; additionalNeededSpace:int32):int32; 
begin
    result := ord((ZSTD_cwksp_check_too_large(ws, additionalNeededSpace)<>0)
         and  (ws^.workspaceOversizedDuration > ZSTD_WORKSPACETOOLARGE_MAXDURATION));
end;

procedure ZSTD_cwksp_bump_oversized_duration(ws:pZSTD_cwksp; additionalNeededSpace:int32);
begin
    if (ZSTD_cwksp_check_too_large(ws, additionalNeededSpace)<>0) then
    begin
        inc(ws^.workspaceOversizedDuration);
    end
    else 
    begin
        ws^.workspaceOversizedDuration := 0;
    end;
end;
end.
