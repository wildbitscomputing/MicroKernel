; This file is part of the TinyCore MicroKernel for the Foenix F256.
; Copyright 2026 Wildbits Computing Company
; SPDX-License-Identifier: GPL-3.0-only

            .cpu "w65c02"
user_irq    .namespace

record      .struct
bank        .byte ?
extension   .byte ?         ; slot-5 extension bits, already shifted
handler     .word ?         ; high byte zero means unregistered
size        .ends

            .section kmem
raster      .dstruct record
via         .dstruct record
mask0       .byte ?         ; sources excluded from the ordinary event path
mask1       .byte ?
saved_mask0 .byte ?         ; monitor saves only the registered mask bits
saved_mask1 .byte ?
            .send

; All code stays above $E000 while slot 5 is temporarily replaced. In
; particular, neither the indirect-call stub nor its return may live there.
            .section global
init
            stz raster.handler+1
            stz via.handler+1
            stz mask0
            stz mask1
            stz saved_mask0
            stz saved_mask1
            rts

; IRQ.Control enters through the kernel gate: LUT0 and I/O page 0.
; The gate preserves X; preserve Y here on success and on every error path.
control
            phy
            jsr operation
            ply
            rts

operation
            lda kernel.user.irq.operation
            cmp #kernel.IRQ.REGISTER
            beq register
            cmp #kernel.IRQ.UNREGISTER
            beq _unregister
            lda #kernel.IRQ.INVALID
            sec
            rts
_unregister
            jmp unregister

; X = record offset (0 or 4), Y = hardware IRQ number.
select
            ldx #0
            lda kernel.user.irq.source
            cmp #irq.line
            beq _ok
            ldx #record.size
            cmp #irq.via
            bne _invalid
_ok        tay
            clc
            rts
_invalid   lda #kernel.IRQ.INVALID
            sec
            rts

register
            php
            sei
            jsr select
            bcs _error
            lda platform.nmi_in_progress
            bne _busy
            lda irq.irqs,y
            bne _busy                   ; a kernel driver owns this source
            lda raster.handler+1,x
            bne _busy                   ; explicit unregister before replacing
            lda kernel.user.irq.handler+1
            cmp #$a0
            bcc _invalid
            cmp #$c0
            bcs _invalid
            lda kernel.user.irq.extension
            cmp #4
            bcs _invalid
            asl a
            asl a
            sta raster.extension,x
            lda kernel.user.irq.bank
            sta raster.bank,x
            lda kernel.user.irq.handler
            sta raster.handler,x
            lda kernel.user.irq.handler+1
            sta raster.handler+1,x

          ; Discard stale controller status and enable only this source.
          ; The application must quiesce/configure the peripheral first.
            cpx #0
            bne _via
            lda #$02
            sta mask0
            sta INT_PENDING_REG0
            eor #$ff
            and INT_MASK_REG0
            sta INT_MASK_REG0
            bra _ok
_via       lda #$20
            sta mask1
            sta INT_PENDING_REG1
            eor #$ff
            and INT_MASK_REG1
            sta INT_MASK_REG1
_ok        plp
            lda #0
            clc
            rts
_invalid   lda #kernel.IRQ.INVALID
            bra _error
_busy      lda #kernel.IRQ.BUSY
_error     plp
            sec
            rts

unregister
            php
            sei
            jsr select
            bcs _error
            lda raster.handler+1,x
            beq _missing
            jsr remove
            plp
            lda #0
            clc
            rts
_missing   lda #kernel.IRQ.NOT_REGISTERED
_error     plp
            sec
            rts

; Interrupts disabled, I/O page 0. Leave the source masked and remove any
; latched controller request before releasing the descriptor.
remove
            cpx #0
            bne _via
            lda INT_MASK_REG0
            ora #$02
            sta INT_MASK_REG0
            lda #$02
            sta INT_PENDING_REG0
            stz mask0
            bra _done
_via       lda INT_MASK_REG1
            ora #$20
            sta INT_MASK_REG1
            lda #$20
            sta INT_PENDING_REG1
            stz mask1
_done      stz raster.handler+1,x
            rts

; Called in LUT0 on program return and before loading another program.
clear
            php
            sei
            pha
            phx
            lda io_ctrl
            pha
            stz io_ctrl
            ldx #0
            lda raster.handler+1
            beq _via
            jsr remove
_via       ldx #record.size
            lda via.handler+1
            beq _done
            jsr remove
_done      pla
            sta io_ctrl
            plx
            pla
            plp
            rts

; One pass, raster then VIA, before an ordinary kernel device is serviced.
; A source that reasserts during its callback remains pending for another
; pass/IRQ. It must never fall through to the generic IRQ event handler.
dispatch
            lda mask0
            ora mask1
            beq _done
            lda platform.nmi_in_progress
            bne _done
            stz io_ctrl
            lda INT_MASK_REG0
            eor #$ff
            and INT_PENDING_REG0
            and mask0
            beq _via
            sta INT_PENDING_REG0
            ldx #0
            jsr invoke
_via       lda INT_MASK_REG1
            eor #$ff
            and INT_PENDING_REG1
            and mask1
            beq _done
            sta INT_PENDING_REG1
            ldx #record.size
            jsr invoke
_done      rts

; Keep the kernel's ZP/stack. Save the entire extension byte so all other
; slots survive, including interrupted kernel code using temporary maps.
; Callback: A = source, X/Y unspecified, I=1, D=0, I/O page 0, RTS to return.
invoke
            php
            lda #$80
            sta mmu_ctrl
            lda mmu+5
            pha
            lda mmu_ext4_7
            pha
            and #$f3
            ora raster.extension,x
            sta mmu_ext4_7
            lda raster.bank,x
            sta mmu+5
            stz mmu_ctrl
            lda #irq.line
            cpx #0
            beq _call
            lda #irq.via
_call      jsr indirect
            stz io_ctrl
            lda #$80
            sta mmu_ctrl
            pla
            sta mmu_ext4_7
            pla
            sta mmu+5
            stz mmu_ctrl
            plp
            rts
indirect   jmp (raster.handler,x)

; Pause callbacks while the monitor borrows application memory. Preserve
; only owned mask bits, so monitor changes to other sources survive.
suspend
            stz io_ctrl
            lda INT_MASK_REG0
            and mask0
            sta saved_mask0
            lda INT_MASK_REG0
            ora mask0
            sta INT_MASK_REG0
            lda INT_MASK_REG1
            and mask1
            sta saved_mask1
            lda INT_MASK_REG1
            ora mask1
            sta INT_MASK_REG1
            rts

resume
            php
            sei
            stz io_ctrl
            lda mask0
            sta INT_PENDING_REG0
            eor #$ff
            and INT_MASK_REG0
            sta INT_MASK_REG0
            lda saved_mask0
            and mask0
            ora INT_MASK_REG0
            sta INT_MASK_REG0
            lda mask1
            sta INT_PENDING_REG1
            eor #$ff
            and INT_MASK_REG1
            sta INT_MASK_REG1
            lda saved_mask1
            and mask1
            ora INT_MASK_REG1
            sta INT_MASK_REG1
            plp
            rts

            .send
            .endn
