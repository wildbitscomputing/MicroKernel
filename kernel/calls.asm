; This file is part of the TinyCore MicroKernel for the Foenix F256.
; Copyright 2022, 2023 Jessie Oberreuter <Gadget@HackwrenchLabs.com>.
; SPDX-License-Identifier: GPL-3.0-only

            .cpu    "r65c02"

            .namespace  kernel

mkapi       .macro  CALL
            lda     #kernel.gates.\CALL
            bra     call_gate
            .endm

mkcall      .macro  ADDR
            jmp     \ADDR
            nop
            .endm

*           = $ff00

            .mkcall kernel.next_event
            .mkcall kernel.read_data
            .mkcall kernel.read_ext
            .mkcall platform.yield
            .mkcall kernel.putchar
            .mkcall kernel.flash.start_by_number
            .mkcall kernel.flash.start_by_name
            .mkcall kernel.chdir
            
            .mkapi  BlockDevice.List
            .mkapi  BlockDevice.GetName
            .mkapi  BlockDevice.GetSize
            .mkapi  BlockDevice.Read
            .mkapi  BlockDevice.Write
            .mkapi  BlockDevice.Format
            .mkapi  BlockDevice.Export

            .mkapi  FileSystem.List
            .mkapi  FileSystem.GetSize
            .mkapi  FileSystem.MkFS
            .mkapi  FileSystem.CheckFS
            .mkapi  FileSystem.Mount
            .mkapi  FileSystem.Unmount
            .mkapi  FileSystem.ReadBlock
            .mkapi  FileSystem.WriteBlock

            .mkapi  File.Open
            .mkapi  File.Read
            .mkapi  File.Write
            .mkapi  File.Close
            .mkapi  File.Rename
            .mkapi  File.Delete
            .mkapi  File.Seek

            .mkapi  Directory.Open
            .mkapi  Directory.Read
            .mkapi  Directory.Close
            .mkapi  Directory.MkDir
            .mkapi  Directory.RmDir

call_gate   .mkcall kernel.gate

            .mkapi  Net.GetIP
            .mkapi  Net.SetIP
            .mkapi  Net.GetDNS
            .mkapi  Net.SetDNS
            .mkapi  Net.SendICMP
            .mkcall kernel.socket_match

            .mkcall kernel.udp_init
            .mkcall kernel.udp_send
            .mkcall kernel.udp_recv
            
            .mkcall kernel.tcp_open
            .mkcall kernel.tcp_accept
            .mkcall kernel.tcp_reject
            .mkcall kernel.tcp_send
            .mkcall kernel.tcp_recv
            .mkcall kernel.tcp_close

            .mkapi  Display.Reset
            .mkcall kernel.screen_size
            .mkcall kernel.draw_text
            .mkapi  Display.DrawColumn

            .mkcall kernel.get_time
            .mkapi  Clock.SetTime
            .fill   12  ; 65816 vectors
            .mkapi  Clock.SetTimer

            .section    dp
user_mmu    .byte       ?
cwd_tmp     .byte       ?   ; temp for chdir (drive, ctx, page, etc.)
cwd_tmp2    .byte       ?   ; second temp
            .send

CWD_MAX_LEN = 63
CWD_BUF_SIZE = 64        ; CWD_MAX_LEN + 1 (null terminator)
CWD_NUM_DRIVES = 4

            .section    kmem
cwd_paths   .fill   CWD_NUM_DRIVES * CWD_BUF_SIZE
            .send

            .section    global

gates       .struct

NextEvent   .word   kernel.next_event
ReadData    .word   kernel.read_data
ReadExt     .word   kernel.read_ext
Yield       .word   platform.yield
Putch       .word   putchar
RunBlock    .word   dummy
RunNamed    .word   dummy
            .word   dummy

BlockDevice .namespace
List        .word   dummy
GetName     .word   dummy
GetSize     .word   dummy
Read        .word   dummy
Write       .word   dummy
Format      .word   dummy
Export      .word   dummy
            .endn

FileSystem  .namespace
List        .word   kernel.fs.get_drives
GetSize     .word   dummy
MkFS        .word   kernel.fs.mkfs
CheckFS     .word   dummy
Mount       .word   dummy
Unmount     .word   dummy
ReadBlock   .word   kernel.fs.read_block
WriteBlock  .word   kernel.fs.write_block
            .endn
            
File        .namespace
Open        .word   kernel.fs.open
Read        .word   kernel.fs.read
Write       .word   kernel.fs.write
Close       .word   kernel.fs.close
Rename      .word   kernel.fs.rename
Delete      .word   kernel.fs.delete
Seek        .word   kernel.fs.seek
            .endn
            
Directory   .namespace
Open        .word   kernel.fs.open_dir
Read        .word   kernel.fs.read
Close       .word   kernel.fs.close_dir
MkDir       .word   kernel.fs.mkdir
RmDir       .word   kernel.fs.rmdir      
            .endn

Net         .namespace

GetIP       .word   dummy
SetIP       .word   dummy
GetDNS      .word   dummy
SetDNS      .word   dummy
SendICMP    .word   dummy
Match       .word   dummy   ; Direct call

UDP         .namespace
Init        .word   kernel.udp_init
Send        .word   kernel.udp_send
Recv        .word   kernel.udp_recv
            .endn

TCP         .namespace            
Open        .word   dummy   ; Direct call
Accept      .word   dummy   ; Direct call
Reject      .word   dummy   ; Direct call
Send        .word   dummy   ; Direct call
Recv        .word   dummy   ; Direct call
Close       .word   dummy   ; Direct call
            .endn

            .endn

Display     .namespace
Reset       .word   platform.console.init
GetSize     .word   kernel.screen_size
DrawRow     .word   kernel.draw_text
DrawColumn  .word   dummy
            .endn

Clock       .namespace
GetTime     .word   kernel.get_time
SetTime     .word   dummy
            .fill   6       ; 65816 vectors.
SetTimer    .word   kernel.set_timer
            .endn

            .ends
gate
        phx     ; on their stack

        ldx     mmu_ctrl
        stz     mmu_ctrl
        phx     ; on our stack
        stx     user_mmu

        ldx     io_ctrl
        stz     io_ctrl
        phx

        tax
        jsr     _call

        plx
        stx     io_ctrl

        plx                 ; from our stack
        stx     mmu_ctrl    ; on their stack

        plx     ; from their stack
        ora     #0
        rts

_call   jmp     (_table,x)
_table  .dstruct    gates
        
dummy
        sec
        rts
        
putchar
        phx
        ldx     mmu_ctrl
        stz     mmu_ctrl
        jsr     platform.console.puts
        stx     mmu_ctrl
        plx
        rts

get_time
        lda     io_ctrl
        pha
        lda     #4
        sta     io_ctrl
        phy
        ldy     #0
_loop   lda     kernel.time+$C000,y
        sta     (kernel.args.buf),y
        iny
        cpy     #time_t.size
        bne     _loop
        ply
        pla
        sta     io_ctrl
        clc
        rts        

next_event
        phx
        phy

      ; Switch to kernel mode
        ldx     mmu_ctrl
        stz     mmu_ctrl

      ; Free the previous event.
        ldy     cur_event
        beq     _pop
        jsr     kernel.event.free

_pop
      ; Pop the next event into Y
        jsr     kernel.event.deque
        sty     cur_event

      ; Back to user mode
        stx     mmu_ctrl
        bcs     _out        ; No events

      ; Move event offset to X
        tya
        tax

        ldy     io_ctrl
        phy
        ldy     #4
        sty     io_ctrl
        
      ; Copy the data
        ldy     #0
_loop1
        lda     kernel.event.alias+1,x
        sta     (args.events.dest),y
        inx
        iny
        cpy     #7
        bne     _loop1       

        clc
        ply
        sty     io_ctrl
_out        
        ply
        plx
        rts      

read_data
        phx
        phy

        ldy     io_ctrl
        phy
        ldy     #4
        sty     io_ctrl

        ldy     args.recv.buflen

        ldx     $c000+kernel.cur_event
        lda     $c000+kernel.event.entry.buf,x
        sec
        beq     _done   ; TODO: return zero length copy

      ; Copy the data to the user's memory
        jsr     export_data        

_done
        ply
        sty     io_ctrl

        ply
        plx
        rts

read_ext
        phx
        phy

        ldy     io_ctrl
        phy
        ldy     #4
        sty     io_ctrl

        ldy     args.recv.buflen

        ldx     $c000+kernel.cur_event
        lda     $c000+kernel.event.entry.ext,x
        sec
        beq     _done   ; TODO: return zero length copy

      ; Copy the data to the user's memory
        jsr     export_data        

_done
        ply
        sty     io_ctrl
        ply
        plx
        rts

export_data
    ; A = buffer (page id)
    ; Y = length of data

        stz     args.ptr+0  ; Internal buffers are always aligned.
        ora     #$c0        ; Buffers are mapped under the io
        sta     args.ptr+1

_loop        
        dey
        lda     (args.ptr),y
        sta     (args.recv.buf),y
        tya     ; cheap zero test
        bne     _loop
        rts

import_data
    ; IN: A=page, user_mmu contains the user's mmu

        phy

      ; Switch to the user's map
        ldy     user_mmu
        sty     mmu_ctrl    ; Now on user's stack!

      ; Set up the dest pointer
        stz     args.ptr+0
        ora     #$c0
        sta     args.ptr+1
    
      ; Get the buffer size
        ldy     args.recv.buflen

      ; Bring in our memory under the I/O
        lda     #4
        sta     io_ctrl

      ; Copy the data
_loop   dey
        lda     (args.recv.buf),y
        sta     (args.ptr),y
        tya
        bne     _loop

      ; Return to the kernel's map and I/O
        stz     io_ctrl
        stz     mmu_ctrl

        ply
        clc
        rts

import_ext
    ; IN:   args.ptr+0 = size,
    ;       args.ptr+1 = page
    ;       user_mmu contains the user's mmu

        phy

      ; Switch to the user's map
        ldy     user_mmu
        sty     mmu_ctrl    ; Now on user's stack!

      ; Get the buffer size
        ldy     args.ptr+0  ; Redundant if we are trusting recv.ext

      ; Adjust the dest pointer
        stz     args.ptr+0
        lda     args.ptr+1  ; buffer in kernel memory
        ora     #$c0
        sta     args.ptr+1  ; Buffer in aliased kernel memory
    
      ; Bring in our memory under the I/O
        lda     #4
        sta     io_ctrl

      ; Copy the data
_loop   dey
        lda     (args.ext),y
        sta     (args.ptr),y
        tya
        bne     _loop

      ; Return to the kernel's map and I/O
        stz     io_ctrl
        stz     mmu_ctrl

        ply
        clc
        rts

screen_size
        lda     #80
        sta     kernel.args.display.x
        lda     #60
        sta     kernel.args.display.y
        clc
        rts

draw_text
    ; TODO: bounds checking, 40/80 mode?

        lda     args.display.buflen
        beq     _done

        phy

      ; Compute the start offset.
      ; TODO: replace with a lookup table
        stz     args.ptr+1
        lda     args.display.y
        asl     a
        asl     a
        rol     args.ptr+1
        adc     args.display.y
        bcc     _ok
        inc     args.ptr+1
_ok     asl     a
        rol     args.ptr+1
        asl     a
        rol     args.ptr+1
        asl     a
        rol     args.ptr+1
        asl     a
        rol     args.ptr+1
        adc     args.display.x
        sta     args.ptr+0

        lda     args.ptr+1
        adc     #$c0
        sta     args.ptr+1

      ; Save the map
        lda     io_ctrl
        pha

      ; Copy the text.
        lda     #2
        sta     $1
        ldy     #0
_loop   lda     (args.display.buf),y
        sta     (args.ptr),y
        iny
        cpy     args.display.buflen
        bne     _loop

      ; Copy the color.
        lda     #3
        sta     $1
        ldy     #0
_loop2  lda     (args.display.buf2),y
        sta     (args.ptr),y
        iny
        cpy     args.display.buflen
        bne     _loop2

      ; Restore the map
        pla
        sta     $1

        ply
_done
        clc
        rts

; ---------------------------------------------------------------
; CWD helper: call into the FAT32 library
; Same as hardware.fat32.call but available in this scope.
; ---------------------------------------------------------------
fat_call    .macro  name
            phx
            phy
            inc     mmu_ctrl
            jsr     hardware.fat32.fat.\name
            dec     mmu_ctrl
            ply
            plx
            .endm

; ---------------------------------------------------------------
; cwd_init
;
; Initialize CWD paths for all drives to "/".
; Called during kernel boot (from kernel.init).
; Must be called in kernel mode (mmu_ctrl=0).
; ---------------------------------------------------------------
cwd_init
        phx
        ; Zero all CWD buffers using two 128-byte passes
        ldx     #127
_zero1  stz     cwd_paths,x
        stz     cwd_paths+128,x
        dex
        bpl     _zero1
        ; Set each drive's CWD to "/"
        ldx     #0
_drive  lda     #'/'
        sta     cwd_paths,x
        txa
        clc
        adc     #CWD_BUF_SIZE
        tax
        bne     _drive              ; loops until X wraps to 0 (4*64=256=0)
        plx
        rts

; ---------------------------------------------------------------
; cwd_get_ptr
;
; Set args.ptr to point to the CWD buffer for drive A.
; IN:  A = drive number (0..CWD_NUM_DRIVES-1)
; OUT: args.ptr set to cwd_paths + A * CWD_BUF_SIZE
;      (Must be in kernel mode to dereference)
; Preserves X, Y.
; ---------------------------------------------------------------
cwd_get_ptr
        ; Multiply A by CWD_BUF_SIZE (64).
        ; A * 64 = A << 6.
        stz     args.ptr+1
        asl     a               ; *2
        asl     a               ; *4
        asl     a               ; *8
        asl     a               ; *16
        asl     a               ; *32
        rol     args.ptr+1
        asl     a               ; *64
        rol     args.ptr+1
        clc
        adc     #<cwd_paths
        sta     args.ptr+0
        lda     args.ptr+1
        adc     #>cwd_paths
        sta     args.ptr+1
        rts

; ---------------------------------------------------------------
; chdir
;
; Dual-purpose chdir/getcwd call at $FF1C.
;   buflen > 0: chdir  -- change to directory in buf/buflen
;   buflen = 0: getcwd -- copy CWD string to buf, set buflen
;
; Uses args.directory.open.drive for drive selection.
; Returns carry clear on success, carry set on error.
; ---------------------------------------------------------------
chdir
        phx
        phy

      ; Save user's MMU and switch to kernel mode (same as gate handler)
        ldx     mmu_ctrl
        stz     mmu_ctrl
        stx     user_mmu

      ; Read user args via $2000+ mirror (user ZP, now in kernel mode)
        lda     $2000+kernel.args.buflen
        sta     cwd_tmp2                        ; buflen (0=getcwd, >0=chdir)
        ldx     $2000+kernel.args.directory.open.drive
        stx     cwd_tmp                         ; drive number

      ; Check buflen: 0 = getcwd, >0 = chdir
        lda     cwd_tmp2
        beq     _getcwd

      ; --- CHDIR ---
        jsr     chdir_do_chdir
        bra     _restore

_getcwd
        jsr     chdir_do_getcwd

_restore
      ; Restore user's MMU (carry preserved)
        ldx     user_mmu
        stx     mmu_ctrl
        ply
        plx
        rts

; ---------------------------------------------------------------
; chdir_do_chdir
;
; Internal chdir implementation. Runs in kernel mode.
; Args read via $2000+ mirror (kernel mode).
; Returns carry clear on success, carry set on error.
; ---------------------------------------------------------------
chdir_do_chdir
      ; Validate drive number (already saved in cwd_tmp by caller)
        ldx     cwd_tmp
        cpx     #CWD_NUM_DRIVES
        bcc     _drive_ok
        sec
        rts
_drive_ok
      ; cwd_tmp = drive, cwd_tmp2 = path length (set by caller)

      ; Look up the drive's fs entry
        ldy     kernel.fs.entries,x
        bne     _dev_ok
        sec                     ; device not registered
        rts
_dev_ok
        lda     kernel.fs.entry.partition,y

      ; Allocate a fat32 context
        .fat_call ctx_alloc
        bcs     _ctx_ok
        sec
        rts
_ctx_ok
        pha                     ; save context on stack

      ; Set the context for this partition
        .fat_call ctx_set
        bcs     _set_ok
        jmp     chdir_free_ctx
_set_ok

      ; Allocate a kernel page for the path
        jsr     kernel.page.alloc_a
        bcs     chdir_free_ctx
        pha                     ; save page on stack

      ; Import the user's path to the kernel page
        ; import_data: A=page, user_mmu set
        jsr     import_data

      ; Null-terminate the path in the kernel page
        pla                     ; A = page
        pha                     ; keep it on stack
        stz     args.ptr+0
        ora     #$c0
        sta     args.ptr+1
        lda     #4              ; io_ctrl=4: kernel memory at $C000
        sta     io_ctrl
        ldy     cwd_tmp2        ; path length
        lda     #0
        sta     (args.ptr),y
        stz     io_ctrl         ; restore io_ctrl

      ; Set fat32 ptr to the path page
        pla                     ; A = page
        pha                     ; keep on stack
        .fat_call set_ptr

      ; Call fat32 chdir
        .fat_call dir_chdir
        bcs     _chdir_ok

      ; fat32 chdir failed
        pla                     ; page
        jsr     kernel.page.free
        jmp     chdir_free_ctx

_chdir_ok
      ; fat32 chdir succeeded -- update CWD string.
      ; The path is in the kernel page (accessible via slot 6 alias).
      ; We save the page in cwd_tmp2 (repurposed) and pass drive
      ; in A to the update routine.
        pla                     ; page number
        pha                     ; keep on stack for free later
        sta     cwd_tmp2        ; save page for update_cwd

        lda     cwd_tmp         ; drive number
        jsr     chdir_update_cwd

      ; Free the page (success path)
        pla                     ; page
        jsr     kernel.page.free
        pla                     ; context
        .fat_call ctx_free
        clc
        rts

chdir_free_ctx
        pla                     ; context
        .fat_call ctx_free
        sec
        rts

; ---------------------------------------------------------------
; chdir_update_cwd
;
; Update the stored CWD string for the given drive after a
; successful fat32 chdir.
;
; IN:  A = drive number
;      cwd_tmp2 = page number containing the user's path
;      (path is null-terminated in the kernel page)
;
; Runs in kernel mode. Uses kernel.dest as source pointer
; (path) and args.ptr as dest pointer (CWD buffer).
; cwd_tmp is used as the CWD write position throughout.
; ---------------------------------------------------------------
chdir_update_cwd
        phx

      ; Set up dest: CWD buffer for this drive
        jsr     cwd_get_ptr     ; args.ptr -> CWD buffer

      ; Set up source: the path in the kernel page
        lda     cwd_tmp2        ; page number
        stz     kernel.dest+0
        sta     kernel.dest+1   ; kernel.dest -> path at $xx00

      ; Find current CWD length (scan for null)
        ldy     #0
_len    lda     (args.ptr),y
        beq     _got_len
        iny
        cpy     #CWD_MAX_LEN
        bne     _len
_got_len
        sty     cwd_tmp         ; cwd_tmp = current CWD write position

      ; Check if path is absolute (starts with '/')
        ldy     #0
        lda     (kernel.dest),y
        cmp     #'/'
        bne     _relative

      ; Absolute path: reset CWD and skip leading /
        stz     cwd_tmp         ; CWD length = 0
        iny                     ; path position = 1

_relative
      ; Y = current position in source path
      ; cwd_tmp = current CWD write position

_next_comp
      ; Check for end of path (null terminator)
        lda     (kernel.dest),y
        bne     _has_comp
        jmp     _finalize
_has_comp

      ; Record component start in X
        tya
        tax                     ; X = component start

      ; Scan to next '/' or null
_scan   lda     (kernel.dest),y
        beq     _end_comp
        cmp     #'/'
        beq     _end_comp
        iny
        bra     _scan

_end_comp
      ; X = component start, Y = component end
      ; Component length = Y - X
        phy                     ; save end position
        tya
        stx     cwd_tmp2        ; save component start
        sec
        sbc     cwd_tmp2        ; A = component length
        beq     _skip_comp      ; empty component

      ; Check for ".." (length=2, both chars are '.')
        cmp     #2
        bne     _chk_dot
        ldy     cwd_tmp2        ; component start
        lda     (kernel.dest),y
        cmp     #'.'
        bne     _chk_dot_done
        iny
        lda     (kernel.dest),y
        cmp     #'.'
        bne     _chk_dot_done

      ; Handle ".." -- strip last component from CWD
        ldy     cwd_tmp         ; CWD length
        beq     _skip_comp      ; already at root
_strip  dey
        beq     _strip_set      ; reached beginning
        lda     (args.ptr),y
        cmp     #'/'
        bne     _strip
_strip_set
        sty     cwd_tmp         ; new CWD length
        bra     _skip_comp

_chk_dot
      ; Check for "." (length=1, char is '.')
        cmp     #1
        bne     _do_append
        ldy     cwd_tmp2
        lda     (kernel.dest),y
        cmp     #'.'
        beq     _skip_comp
_chk_dot_done

_do_append
      ; Append "/" + component to CWD
      ; cwd_tmp = CWD write position
      ; cwd_tmp2 = component start in path
      ; Stack top = component end position

      ; Append '/' separator before the component, but only
      ; if CWD is non-empty and doesn't already end with '/'.
      ; (Root "/" already ends with slash; after ".." to root,
      ; cwd_tmp=0 and we still need a leading slash.)
        ldy     cwd_tmp
        cpy     #CWD_MAX_LEN
        bcs     _trunc
        beq     _add_sep        ; empty = needs leading /
        dey
        lda     (args.ptr),y    ; peek at last char
        iny
        cmp     #'/'
        beq     _no_sep         ; root or similar, skip extra /
_add_sep
        lda     #'/'
        sta     (args.ptr),y
        iny
_no_sep

      ; Copy component bytes from path to CWD
      ; Y = CWD write position (also used for reading via swap)
      ; Use cwd_tmp2 as read index, Y as write index
        ldx     cwd_tmp2        ; X = read position in path
_copy
        cpy     #CWD_MAX_LEN
        bcs     _trunc

      ; Read byte from path using Y temporarily
        sty     cwd_tmp         ; save write pos
        txa
        tay                     ; Y = read pos
        lda     (kernel.dest),y ; read from path
        ldy     cwd_tmp         ; Y = write pos (clobbers flags)
        cmp     #0              ; is byte null?
        beq     _copy_done
        cmp     #'/'
        beq     _copy_done

      ; Write byte to CWD
        sta     (args.ptr),y    ; write to CWD buffer
        iny                     ; advance write pos
        inx                     ; advance read pos
        bra     _copy

_copy_done
        sty     cwd_tmp         ; save final CWD write position
        bra     _skip_comp

_trunc
        sty     cwd_tmp         ; truncated CWD write position
        ; fall through to skip

_skip_comp
      ; Restore end position from stack and advance past '/'
        ply                     ; Y = component end position
        lda     (kernel.dest),y
        cmp     #'/'
        bne     _to_next
        iny                     ; skip separator
_to_next
        jmp     _next_comp

_finalize
      ; Null-terminate the CWD
        ldy     cwd_tmp
        beq     _set_root
        lda     #0
        sta     (args.ptr),y
        plx
        rts

_set_root
        lda     #'/'
        sta     (args.ptr)
        ldy     #1
        lda     #0
        sta     (args.ptr),y
        plx
        rts

; ---------------------------------------------------------------
; chdir_do_getcwd
;
; Copy the stored CWD string for the given drive to the user's
; buffer and set buflen.
; Runs in kernel mode. Returns carry clear on success.
; ---------------------------------------------------------------
chdir_do_getcwd
      ; Drive already in cwd_tmp. We're in kernel mode.
      ; Copy CWD string from kernel memory to user's buffer.
      ;
      ; Strategy: write the $C0xx alias pointer into the USER's
      ; args.ptr via $2000+ mirror. Then switch to user mode with
      ; io_ctrl=4 so kernel memory is readable at $C000+.

        ldx     cwd_tmp
        cpx     #CWD_NUM_DRIVES
        bcc     _drive_ok
        sec
        rts
_drive_ok
      ; Get CWD buffer pointer in kernel space
        txa
        jsr     cwd_get_ptr         ; kernel args.ptr = cwd_paths + drive*64

      ; Write $C0xx alias pointer into USER's ZP via $2000+ mirror
        lda     args.ptr+0
        sta     $2000+kernel.args.ptr+0
        lda     args.ptr+1
        ora     #$c0                ; alias kernel memory at $C000
        sta     $2000+kernel.args.ptr+1

      ; Switch to user mode with io_ctrl=4
        lda     user_mmu
        sta     mmu_ctrl            ; now on user's ZP
        lda     #4
        sta     io_ctrl             ; kernel memory visible at $C000

      ; Copy CWD string: args.ptr = $C0xx alias, args.buf = user buffer
        ldy     #0
_copy   lda     (args.ptr),y        ; read from kernel CWD via $C0xx alias
        sta     (args.buf),y        ; write to user buffer
        beq     _done               ; null terminator = done
        iny
        cpy     #CWD_MAX_LEN
        bne     _copy
        lda     #0
        sta     (args.buf),y        ; force null terminate
_done
      ; Restore io_ctrl and back to kernel mode
        stz     io_ctrl
        stz     mmu_ctrl
        clc
        rts

            .send
            .endn
