; This file is part of the TinyCore MicroKernel for the Foenix F256.
; Copyright 2022, 2023 Jessie Oberreuter <Gadget@HackwrenchLabs.com>.
; SPDX-License-Identifier: GPL-3.0-only

; The main kernel code receives its various memory and buffer pools from
; hardware specific startup code like this.
;
; On the Jr, MMU0 is reserved for the micro-kernel.  Doing so
; reduces the IRQ overhead.

; The SDCard's F_SD_WP_i and F_SD_CD_i are located @ $D6A0
; Bit[7] = F_SD_WP_i
; Bit[6] = F_SD_CD_i

            .cpu    "w65c02"

*           = $0000     ; Kernel Direct-Page
mmu_ctrl    .byte       ?
io_ctrl     .byte       ?
reserved    .fill       6
mmu         .fill       8
fat32       .fill       32  ; MMU LUT full-view.
            .dsection   dp
            .cerror * > $00ef, "Out of dp space."

*           = $0100     ; Just beyond the FPGA registers
Stack       .fill       256
            .dsection   pages
            .dsection   kmem    ; ragged
            .align      256
Buffers     .fill       0

            .namespace  kernel
            .virtual    $20f0
user        .dstruct    kernel.args_t
            .endv
            .endn

*           = $4000     ; Kernel tables start here
            .dsection   tables
Strings     .dsection   strings ; aligned
            .align      256
magic2      .byte       <MAGIC
            .dsection   kernel
            .dsection   kernel2
            .cerror * >= $8000, "Out of kernel space."

*           = $8000     ; Fat32 starts here
fat_base
            .dsection   fat32_code
            .cerror * >= $c000, "Out of kernel space."

*           = $e000 ; Kernel code starts here.
            .dsection   startup
            .dsection   global
            .cerror * > $feff, "Out of global space."


*           = $ffe0
            .word   0                   ; ffe0 816 reserved
            .word   0                   ; ffe2 816 reserved
            .word   platform.hw_cop     ; ffe4 816 native COP
            .word   platform.hw_brk     ; ffe6 816 native BRK
            .word   platform.hw_abort   ; ffe8 816 native ABORT
            .word   platform.hw_nmi     ; ffea 816 native NMI
            .word   0                   ; ffec 816 reserved
            .word   platform.hw_int     ; ffee 816 native IRQ

*           = $fff4 ; Hardware vectors.
            .word   platform.hw_cop     ; fff4 COP
wait_upload bra     wait_upload         ; fff6 Not used on 6502
            .word   platform.hw_abort   ; fff8 65816 emulation ABORT
            .word   platform.hw_nmi     ; fffa NMI
            .word   platform.hw_reset   ; fffc RESET
            .word   platform.hw_irq     ; fffe IRQ/BRK

            .section    fat32_code
            .binary     "../fat32.bin"
            .send

platform    .namespace

            .section    dp
irq_io      .byte       ?   ; io_ctrl when an IRQ fires.
irq_mmu     .byte       ?   ; mmu_ctrl when an IRQ fires.
nmi_saved_sp  .byte     ?   ; victim SP at NMI (low byte; high is $01 in emu)
nmi_saved_mmu .byte     ?   ; victim mmu_ctrl (active LUT) at NMI
nmi_saved_io  .byte     ?   ; victim io_ctrl at NMI
nmi_saved_slot5 .byte   ?   ; (unused since Task1) legacy LUT0 slot-5 save
nmi_in_progress .byte   ?   ; non-zero while a handler is active (nested guard)
nmi_ptr       .word     ?   ; (unused since Task1) legacy header entry pointer
nmi_orig_slot4 .byte    ?   ; victim LUT slot-4 bank displaced by the handler
nmi_orig_slot5 .byte    ?   ; victim LUT slot-5 bank displaced by the handler
nmi_save2     .byte     ?   ; LUT0 slot-2 saved during the flash->RAM copy
nmi_save4     .byte     ?   ; LUT0 slot-4 saved during the flash->RAM copy
nmi_src       .word     ?   ; flash->RAM copy source pointer
nmi_dst       .word     ?   ; flash->RAM copy dest pointer
nmi_fillb     .byte     ?   ; fill byte for screen clear
            .send

            .section    startup     ; The following is ALWAYS at $E000
signature   .null      "KERNEL"
magic       .byte       <MAGIC
paul_date   .null       DATE_STR
            .align      32

hw_reset:

        sei

      ; Always switch to the startup code in flash
      ; RAM and ROM should always be identical here.
        lda     #$80
        sta     mmu_ctrl
        lda     #$7f
        sta     mmu+7

      ; If DIP1 is off, continue with the flash kernel
        stz     io_ctrl
        lda     $d670   ; Read Jr dip switch register.
        eor     #$ff    ; Values are inverted.
        bit     #1
        beq     _start

      ; Check for a RAM kernel
        ldy     #$0c    ; $01:6000 / $13:6000 -- doesn't cross I/O memory
        sty     mmu+1
        ldx     #0
_loop   lda     $2000,x
        cmp     signature,x
        bne     _start
        inx
        cpx     #6
        bne     _loop

      ; Signature found, switch to the RAM kernel at $E000
        sty     mmu+7

_start
    ; Below this line, kernels may be different

      ; If this is a 65816, switch pin 3 from an input
      ; (for PHI0-out) to a 1 output (for ABORTB-in).
        .cpu    "65816"
        clc
        xce
        bcc     +
        sec
        xce
        stz     io_ctrl
        lda     #$03
        sta     $d6b0
+      .cpu    "w65c02"

      ; Allocate physical slot 6 for our ZP; this will
      ; allow us to create a more typical mapping for
      ; process zero.
        lda     #6
        sta     mmu+0

      ; Pre-mount the user process's ZP ($00) at $2000.
        stz     mmu+1

      ; fat32 BSS is the RAM under $E000
      ;  lda     #7
      ;  sta     mmu+2

      ; 2,3,4,5 are the blocks preceeding the kernel
        lda     mmu+7
        sec
        sbc     #4
        sta     mmu+2
        inc     a
        sta     mmu+3
        inc     a
        sta     mmu+4
        inc     a
        sta     mmu+5

      ; 6 is the kernel's ZP
        lda     mmu+0
        sta     mmu+6

      ; Copy the map to MMU1
        ldx     #0
_copy   lda     mmu,x           ; Read from MMU0
        ldy     #%10_01_0000    ; edit MMU1
        sty     mmu_ctrl
        sta     mmu,x           ; Store to MMU1
        ldy     #%10_00_0000    ; edit MMU0
        sty     mmu_ctrl
        inx
        cpx     #8
        bne     _copy

      ; Change slot 1 in MMU1 to point to FAT32's RAM.
        ldy     #%10_01_0000    ; edit MMU1
        sty     mmu_ctrl
        lda     #7
        sta     mmu+1
        ldy     #%10_00_0000    ; edit MMU1
        sty     mmu_ctrl

      ; Kernel already installed at 7.
      ; Re-lock the MMU
        stz     mmu_ctrl

      ; Zero the stack page for ease of debugging.
        ldx     #0
_zero   stz     Stack,x
        inx
        bne     _zero

      ; Initialize the stack pointer
        ldx     #$ff
        txs

      ; Initialize the SPI flash so we can read its startup data
        jsr     spi_flash.init

      ; Initialize the console
        jsr     console.init    ; Can now trash font in $a000
        jsr     console.welcome
        stz     io_ctrl

      ; Check for mismatched kernel halves
        lda     magic2
        cmp     magic
        bne     upload

      ; Init LCD (if there is one)
        jsr     k2lcd.init

      ; Init the IRQs and enable
        jsr     irq.init

      ; Export a page pool -- merge with kernel start.
        lda     #>Buffers
        jsr     kernel.page.init

      ; Clear the NMI nested-break guard (dp RAM is uninitialized at power-on).
        stz     nmi_in_progress

      ; Start the kernel
        jmp     kernel.init

upload
_write      ldy     #0
_loop       lda     _msg,y
            beq     _out
            jsr     puts
            iny
            bra     _loop
_out        bra     _out
_msg        .null   "Upload."


hardware_init
        jsr     platform.iec.IOINIT
        jsr     clock.init
        jsr     keyboard.init
        jsr     serial.init
        jsr     audio.init
        jsr     hardware.iec.init   ; The kernel driver, NOT the hw.
        jsr     hardware.fat32.init
        rts

nmi:
break:
sys_exit:
        lda     #2
        sta     $1
        lda     $c002
        inc     a
        sta     $c002
        jmp     sys_exit

yield
        wai
        rts

VIA_IFR      = $DC0D            ; 65C22 VIA Interrupt Flag Register
VIA_IER      = $DC0E            ; 65C22 VIA Interrupt Enable Register

NMI_MON_BANK = $4a              ; monitor flash block 0 ($40 + CSV 0a); block 1 = $4b
NMI_RAM_LO   = $3e              ; reserved RAM bank -> victim slot 4 ($8000): image block 0
NMI_RAM_HI   = $3f              ; reserved RAM bank -> victim slot 5 ($A000): image block 1
NMI_TEXT_BANK = $3c             ; reserved RAM bank: saved victim text page
NMI_COLR_BANK = $3d             ; reserved RAM bank: saved victim color page
NMI_SCR_CLEAR = $10             ; cleared color attribute (FG=white, BG=black)
MACHINE_ID_REG = $d6a7
JR2_MID        = $18
JR2_SYSRQ_CTRL = $d6b6          ; bit 7: sticky SysRq NMI cause, W1C

hw_nmi:
      ; NMI dispatch: freeze the victim, gate on Foenix, copy the handler's
      ; flash bank into the reserved RAM bank, map that RAM bank into the
      ; VICTIM LUT's slot 5, and run the handler there (so it sees the victim's
      ; memory directly); then restore slot 5 and resume the victim exactly.
        pha                     ; A -> victim stack
        phx                     ; X -> victim stack
        phy                     ; Y -> victim stack
        tsx                     ; X = victim SP
        lda     mmu_ctrl        ; A = victim active LUT
        stz     mmu_ctrl        ; -> kernel LUT (LUT0)
        ldy     nmi_in_progress
        beq     +
        jmp     nmi_reenter
+
        sta     nmi_saved_mmu
        stx     nmi_saved_sp
      ; JR2 has only a PS/2 keyboard, so it cannot satisfy the K2 optical
      ; Foenix-key state test below. Its FPGA instead latches the physical
      ; SysRq NMI cause in $D6B6 bit 7. Accept and acknowledge only that cause;
      ; an IEC NMI must not enter the monitor accidentally.
        lda     MACHINE_ID_REG
        and     #$1f
        cmp     #JR2_MID
        bne     _nmi_gate_k2
        lda     JR2_SYSRQ_CTRL
        bmi     _nmi_ack_sysrq
        jmp     nmi_not_ours
_nmi_ack_sysrq
        ora     #$80            ; W1C cause while preserving HDMI bit 0
        sta     JR2_SYSRQ_CTRL
        bra     _nmi_ours
_nmi_gate_k2
        lda     @w platform.k2_kbd.state+0
        and     #$20
        beq     _nmi_ours
        jmp     nmi_not_ours    ; Foenix not held -> ignore
_nmi_ours
      ; Decline a break INTO the monitor itself: it runs from reserved bank
      ; NMI_RAM_HI ($3f) in slot 5, so freezing it would clobber its own RAM
      ; during the flash->RAM copy and could not be resumed. If the victim's
      ; slot 5 is that bank, ignore the NMI and resume it untouched.
        jsr     nmi_edit_vlut
        lda     mmu+5
        stz     mmu_ctrl            ; active LUT0, edit off
        cmp     #NMI_RAM_HI
        bne     _nmi_notmon
        jmp     nmi_not_ours
_nmi_notmon
        lda     #1
        sta     nmi_in_progress
        lda     io_ctrl
        sta     nmi_saved_io

      ; c2: save the victim's text+color screen and clear it for the monitor
        jsr     nmi_save_screen

      ; --- save the victim's original slot-4 and slot-5 banks ---
        jsr     nmi_edit_vlut   ; edit-enable the victim's LUT
        lda     mmu+4
        sta     nmi_orig_slot4  ; victim's original $8000 bank
        lda     mmu+5
        sta     nmi_orig_slot5  ; victim's original $A000 bank
        stz     mmu_ctrl        ; active LUT0, edit off

      ; --- copy the 2 handler flash blocks -> RAM_LO/RAM_HI (16 KB) ---
      ; LUT0 slot2 ($4000) = flash source, slot4 ($8000) = RAM dest window.
        lda     #$80
        sta     mmu_ctrl        ; edit LUT0
        lda     mmu+2
        sta     nmi_save2
        lda     mmu+4
        sta     nmi_save4
        stz     mmu_ctrl
      ; block 0: flash NMI_MON_BANK -> RAM_LO
        lda     #$80
        sta     mmu_ctrl
        lda     #NMI_MON_BANK
        sta     mmu+2
        lda     #NMI_RAM_LO
        sta     mmu+4
        stz     mmu_ctrl
        jsr     nmi_copy8k
      ; poke the victim's slot-4 bank into the RAM image's reserved header byte
      ; (offset 9); RAM_LO is mapped at LUT0 slot4 ($8000), so that is $8009.
        lda     nmi_orig_slot4
        sta     $8009
      ; block 1: flash NMI_MON_BANK+1 -> RAM_HI
        lda     #$80
        sta     mmu_ctrl
        lda     #NMI_MON_BANK+1
        sta     mmu+2
        lda     #NMI_RAM_HI
        sta     mmu+4
        stz     mmu_ctrl
        jsr     nmi_copy8k
      ; restore LUT0 slots 2 and 4
        lda     #$80
        sta     mmu_ctrl
        lda     nmi_save2
        sta     mmu+2
        lda     nmi_save4
        sta     mmu+4
        stz     mmu_ctrl

      ; --- map the RAM handler into the VICTIM LUT slots 4+5 ---
        jsr     nmi_edit_vlut
        lda     #NMI_RAM_LO
        sta     mmu+4
        lda     #NMI_RAM_HI
        sta     mmu+5
        stz     mmu_ctrl        ; active LUT0, edit off

      ; --- enter the handler under the victim LUT (fixed entry $8100) ---
        ldy     nmi_saved_sp    ; Y = victim SP
        ldx     nmi_orig_slot5  ; X = victim's original slot-5 bank
        lda     nmi_saved_mmu
        sta     mmu_ctrl        ; active -> victim LUT
        jsr     $8100           ; do_entry_break; RTSs back (still victim LUT)
        stz     mmu_ctrl        ; active -> LUT0

      ; --- restore the victim LUT slots 4+5 ---
        jsr     nmi_edit_vlut
        lda     nmi_orig_slot4
        sta     mmu+4
        lda     nmi_orig_slot5
        sta     mmu+5
        stz     mmu_ctrl

      ; c2: restore the victim's text+color screen
        jsr     nmi_restore_screen

      ; --- inject a Foenix-key RELEASE for the resumed program ---
      ; The victim cached the Foenix PRESS before the break but never saw the
      ; release (the monitor consumed it), so it still thinks Foenix is held.
      ; Queue a synthetic release so its next NextEvent clears that state.
        jsr     kernel.event.alloc
        bcs     _nmi_noinject
        lda     #0
        sta     kernel.event.entry.key.ascii,y
        lda     #LMETA
        sta     kernel.event.entry.key.raw,y
        lda     #$80                    ; META flag (no ASCII)
        sta     kernel.event.entry.key.flags,y
        lda     #kernel.event.key.RELEASED
        sta     kernel.event.entry.type,y
        jsr     kernel.event.enque
_nmi_noinject

      ; --- un-stick a free-running VIA timer IRQ ---
      ; A program clocking itself off the VIA T1 in continuous mode (ACR bit6)
      ; clears the T1 flag by reading T1C-L in its own IRQ handler. While frozen
      ; that never happened, so the T1 flag is still set and the VIA IRQ line is
      ; held low; with the edge-triggered interrupt controller no further VIA
      ; IRQs would ever latch and the victim's frame loop would hang. If the VIA
      ; has an enabled pending interrupt, clear its flags so the line releases
      ; and the next timeout produces a fresh edge. No-op if the victim isn't
      ; using the VIA (IER/IFR read is harmless).
        stz     $1                      ; io page 0 -> VIA registers
        lda     VIA_IFR
        and     VIA_IER                 ; only sources the victim enabled
        and     #$7f                    ; ignore bit 7 (IRQ summary)
        beq     _nmi_no_via
        lda     #$7f
        sta     VIA_IFR                 ; write 1s to clear all VIA flags
_nmi_no_via
      ; fall into nmi_resume

      ; nmi_resume: restore victim io/LUT/SP/regs and RTI back exactly.
nmi_resume
        stz     nmi_in_progress
        ldx     nmi_saved_sp
        lda     nmi_saved_io
        sta     io_ctrl
        lda     nmi_saved_mmu
        sta     mmu_ctrl        ; victim LUT (active)
        txs
        ply
        plx
        pla
        rti

      ; nmi_edit_vlut: set mmu_ctrl to EDIT the victim's LUT (from nmi_saved_mmu
      ; active-LUT bits), leaving active LUT = 0 (kernel) so our code/stack/dp
      ; stay valid. Uses A.
nmi_edit_vlut
        lda     nmi_saved_mmu
        and     #$03
        asl     a
        asl     a
        asl     a
        asl     a
        ora     #$80
        sta     mmu_ctrl
        rts

      ; nmi_copy8k: copy 8 KB from LUT0 slot2 ($4000, flash source) to LUT0 slot4
      ; ($8000, RAM dest). Callers map the banks into those slots first.
nmi_copy8k
        stz     nmi_src
        stz     nmi_dst
        lda     #$40
        sta     nmi_src+1       ; src = $4000 (LUT0 slot 2)
        lda     #$80
        sta     nmi_dst+1       ; dst = $8000 (LUT0 slot 4)
        ldx     #$20            ; 32 pages of $100 = 8 KB
_nc     ldy     #0
_nc1    lda     (nmi_src),y
        sta     (nmi_dst),y
        iny
        bne     _nc1
        inc     nmi_src+1
        inc     nmi_dst+1
        dex
        bne     _nc
        rts

      ; ---- Screen save / restore (c2) ---------------------------------------
      ; Runs under LUT0. Saves the victim's text + color pages into reserved
      ; RAM banks and clears the screen for the monitor; restores on exit.
      ; The 80x60 text/color screens are 4800 bytes each at $C000 (io page 2
      ; = text, io page 3 = color); a reserved bank is mapped into LUT0 slot 4
      ; ($8000) as the copy buffer.

      ; nmi_cp4800: copy 4800 bytes (nmi_src)->(nmi_dst).
nmi_cp4800
        ldx     #18             ; 18 full pages
_cp0    ldy     #0
_cp1    lda     (nmi_src),y
        sta     (nmi_dst),y
        iny
        bne     _cp1
        inc     nmi_src+1
        inc     nmi_dst+1
        dex
        bne     _cp0
        ldy     #0              ; + 192 bytes = 4800
_cp2    lda     (nmi_src),y
        sta     (nmi_dst),y
        iny
        cpy     #192
        bne     _cp2
        rts

      ; nmi_fill4800: fill 4800 bytes at $C000 with nmi_fillb (current io page).
nmi_fill4800
        stz     nmi_dst
        lda     #$c0
        sta     nmi_dst+1
        ldx     #18
_fl0    ldy     #0
_fl1    lda     nmi_fillb
        sta     (nmi_dst),y
        iny
        bne     _fl1
        inc     nmi_dst+1
        dex
        bne     _fl0
        ldy     #0
_fl2    lda     nmi_fillb
        sta     (nmi_dst),y
        iny
        cpy     #192
        bne     _fl2
        rts

      ; map bank A into LUT0 slot 4 ($8000), saving the displaced bank
nmi_map4
        pha
        lda     #$80
        sta     mmu_ctrl        ; edit LUT0
        lda     mmu+4
        sta     nmi_save4
        pla
        sta     mmu+4
        stz     mmu_ctrl
        rts
nmi_unmap4
        lda     #$80
        sta     mmu_ctrl
        lda     nmi_save4
        sta     mmu+4
        stz     mmu_ctrl
        rts

      ; nmi_save_screen: save text->$3d, color->$3e, clear screen + home cursor
nmi_save_screen
        lda     #NMI_TEXT_BANK
        jsr     nmi_map4        ; $3d -> slot 4 ($8000)
        lda     #2
        sta     io_ctrl         ; text page at $C000
        stz     nmi_src
        lda     #$c0
        sta     nmi_src+1       ; src = $C000
        stz     nmi_dst
        lda     #$80
        sta     nmi_dst+1       ; dst = $8000
        jsr     nmi_cp4800
        lda     #NMI_COLR_BANK
        jsr     nmi_map4        ; $3e -> slot 4 (nmi_save4 reused; ok, sequential)
        lda     #3
        sta     io_ctrl         ; color page at $C000
        stz     nmi_src
        lda     #$c0
        sta     nmi_src+1
        stz     nmi_dst
        lda     #$80
        sta     nmi_dst+1
        jsr     nmi_cp4800
        jsr     nmi_unmap4
      ; clear text (spaces) + color (attr), home the hardware cursor
        lda     #2
        sta     io_ctrl
        lda     #$20
        sta     nmi_fillb
        jsr     nmi_fill4800
        lda     #3
        sta     io_ctrl
        lda     #NMI_SCR_CLEAR
        sta     nmi_fillb
        jsr     nmi_fill4800
        lda     #2
        sta     io_ctrl         ; leave text page selected
        rts                     ; cursor is homed by the monitor (after it saves
                                ; the victim's cursor regs in its c1 block)

      ; nmi_restore_screen: restore text from $3d, color from $3e
nmi_restore_screen
        lda     #NMI_TEXT_BANK
        jsr     nmi_map4
        lda     #2
        sta     io_ctrl
        stz     nmi_src
        lda     #$80
        sta     nmi_src+1       ; src = $8000 ($3d)
        stz     nmi_dst
        lda     #$c0
        sta     nmi_dst+1       ; dst = $C000 (text)
        jsr     nmi_cp4800
        lda     #NMI_COLR_BANK
        jsr     nmi_map4
        lda     #3
        sta     io_ctrl
        stz     nmi_src
        lda     #$80
        sta     nmi_src+1
        stz     nmi_dst
        lda     #$c0
        sta     nmi_dst+1
        jsr     nmi_cp4800
        jsr     nmi_unmap4
        rts

      ; Not our modifier combo: save area is valid (we are the outer handler);
      ; restore victim LUT/SP/regs without any slot changes.
nmi_not_ours
        ldx     nmi_saved_sp
        lda     nmi_saved_mmu
        sta     mmu_ctrl
        txs
        ply
        plx
        pla
        rti

      ; Re-entry while a handler is active: A still = victim LUT, X still =
      ; victim SP (save area untouched). Restore and RTI back into the handler.
nmi_reenter
      ; A second SysRq while the monitor is already active is declined above.
      ; Acknowledge its sticky JR2 cause here so a later IEC NMI cannot be
      ; mistaken for that old key press. Preserve A, which holds the victim LUT.
        pha
        lda     MACHINE_ID_REG
        and     #$1f
        cmp     #JR2_MID
        bne     _nmi_reenter_restore
        lda     JR2_SYSRQ_CTRL
        bpl     _nmi_reenter_restore
        ora     #$80
        sta     JR2_SYSRQ_CTRL
_nmi_reenter_restore
        pla
        sta     mmu_ctrl
        txs
        ply
        plx
        pla
        rti

hw_cop: rti     ; 816 extention; ignore for now.
hw_brk: rti     ; 816 extention; ignore for now.
hw_int: rti     ; 816 IRQ; ignore for now (could save/irq/restore)

hw_abort:
    ; 816 extension.
        rti

hw_irq:
        pha
        phx
        phy

      ; Save MMU state and switch to the kernel's MMU table.
        lda     mmu_ctrl    ; Get the current mmu state.
        stz     mmu_ctrl    ; Switch to the kernel's mmu table.

hw_swi
        pha

      ; Save the io state.
        lda     io_ctrl
        pha

        jsr     irq.dispatch            ; May request kernel services.

      ; Don't start the kernel service if it's already running.
        lda     kernel.thread.running   ; True if kernel service is already running.
        bne     hw_rti

      ; Don't start the kernel service if it hasn't been requested.
        lda     kernel.thread.start     ; True if kernel service is requested.
        beq     hw_rti

      ; Run the kernel service.
        sta     kernel.thread.running   ; Mark the service as running.
        stz     kernel.thread.start     ; Any requests after this point are new.
        cli                             ; Re-enable interrupts.
        jsr     kernel.thread.service   ; Run the service.
        stz     kernel.thread.running   ; Mark the service as no longer running.

hw_rti
        pla
        sta     io_ctrl

        pla
        sta     mmu_ctrl

        ply
        plx
        pla
        rti

puts        jmp     platform.console.puts

board_feature .namespace
SPI_FLASH   = 1 << 0
LCD         = 1 << 1
            .endn

board       .struct     id, codec, feat=0, feat_detect=0
mid             .byte   \id
codec_init      .byte   \codec
static_features .byte   \feat
feature_detect  .word   \feat_detect
size        .ends

boards      .dstruct    board, $02, %00000011  ; jr/mmu
_2          .dstruct    board, $12, %00010011  ; k/mmu
_3          .dstruct    board, $22, %00011101, board_feature.SPI_FLASH ; jr2/mmu
_4          .dstruct    board, $11, %00011111, board_feature.SPI_FLASH, k2_feature_detect ; k2/mmu
boards_end  = * - boards

get_board
    ; OUT: X -> offset in boards table
    ;      A -> effective feature mask
    ;      Carry -> clear on success, set if unknown board
            clc
            ldx     #0
          - lda     boards.mid,x
            eor     $d6a7   ; MID
            and     #$3f
            beq     _found
            txa
            adc     #board.size
            tax
            cpx     #boards_end
            bne -
          ; `cpx` sets the Carry for us
            rts

_found:   ; Check if the board has an associated feature detection procedure
            lda     boards.feature_detect,x
            ora     boards.feature_detect+1,x
            beq +

          ; Jump to the feature detection proc
            jmp     (boards.feature_detect,x)

          + lda     boards.static_features,x
            rts

k2_feature_detect
          ; Load the statically declared features
            lda     boards.static_features,x

          ; If bit 7 is set, we have a mechanical keyboard and no LCD
            bit     platform.k2_kbd.OPT_KBD_STAT
            bmi     +
            ora     #board_feature.LCD

          + clc
            rts

        .send
        .endn

