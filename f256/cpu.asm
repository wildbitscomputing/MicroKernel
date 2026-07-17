; This file is part of the TinyCore MicroKernel for the Foenix F256.
; Copyright 2022, 2023 Jessie Oberreuter <Gadget@HackwrenchLabs.com>.
; Copyright 2026 Wildbits Computing Company
; SPDX-License-Identifier: GPL-3.0-only

            .cpu        "w65c02"

            .namespace  platform
cpu         .namespace


            .section    dp
self        .namespace
wait_count  .byte       ?
            .endn
            .send

; See comment blocks for `wait_20us` and below
WAIT_COUNT_6_3MHz   = 21
WAIT_COUNT_12_6MHz  = 47

            .section    global

init
          ; Initialize the `wait_count`
            lda     #WAIT_COUNT_6_3MHz
            jsr     is_2x
            bcc     +
            lda     #WAIT_COUNT_12_6MHz
          + sta     self.wait_count

            clc
            rts

is_2x
          ; The 7th bit of the machine ID indicates a 2x core; shift it into
          ; carry and return
            lda     $d6a7
            asl     a
            rts


; Wait for approximately but no less than 20 microseconds (including the caller's `jsr`)
wait_20us                                   ; [jsr] 6 cycles
            phx                             ; 3 cycles
            ldx     self.wait_count         ; 3 cycles
          - dex                             ; 2 cycles
            bne     -                       ; 2 + 1 if branch is taken
            plx                             ; 4 cycles
            rts                             ; 6 cycles
                                            ; = (21 + 5 * wait_count) cycles
;
; At 6.3 MHz:   1 cycle = 0.15873us
;               20us = 126 cycles
;               21 + 5 * wait_count = 126
;               5 * wait_count = 105
;               wait_count = 21

;
; At 12.6 MHz:  1 cycle = 0.07937us
;               20us = 252 cycles
;               21 + 5 * wait_count = 252
;               5 * wait_count = 231
;               wait_count = 46.2
;               use 47 to uphold the "no less than 20us" contract


wait_x_20us .macro x
            phx
            ldx     #\x
          - jsr     platform.cpu.wait_20us
            dex
            bne     -
            plx
            .endmacro

; Wait for approximately but no less than 100 microseconds
wait_100us
            .wait_x_20us    5
            rts

; Wait for approximately but no less than 1 ms
wait_1ms
            .wait_x_20us    50
            rts

; Wait for approximately but no less than `X` ms
wait_x_ms
          - jsr     wait_1ms
            dex
            bne     -
            rts

.namespace  self
; Wait for approximately but no less than `YX` ms; `Y` is a biased page count,
; not the raw high byte; see `wait_ms` for the encoding
wait_yx_ms
          - jsr     wait_1ms
            dex
            bne     -
            dey
            bne     -
            rts
.endn


; Wait for approximately but no less than the specified number of ms
wait_ms     .macro ms
            .cerror \ms <= 0, "Expected a positive number"
            .cerror \ms > $FF00, "Can't wait for longer than ", $FF00, " ms at a time"
        .if \ms > 255
            phx
            phy
            ldx     #<\ms
            ldy     #(>\ms) + ((<\ms) != 0 ? 1 : 0)
            jsr     platform.cpu.self.wait_yx_ms
            ply
            plx
        .else
            phx
            ldx     #\ms
            jsr     platform.cpu.wait_x_ms
            plx
        .endif
            .endmacro

; Wait for approximately but no less than 100 ms
wait_100ms
            .wait_ms    100
            rts

            .send

            .endn
            .endn
