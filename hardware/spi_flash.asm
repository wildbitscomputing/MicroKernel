; SPI flash interface
; Copyright 2026 Wildbits Computing Company
; Copyright 2024 <stef@c256foenix.com>
; SPDX-License-Identifier: GPL-3.0-only

            .cpu    "w65c02"

            .namespace  hardware

spi_flash   .macro  BASE=$dd60, FIFO_SIZE=2048

            .virtual    \BASE

CTRL        .byte   ?   ; Control register
CMD         .byte   ?   ; Command register
SIZE_LO     .byte   ?   ; Write: transfer size
SIZE_HI     .byte   ?   ;
ADDR_LO     .byte   ?   ; Source address
ADDR_MID    .byte   ?   ;
ADDR_HI     .byte   ?   ;
            .byte   ?   ; Reserved
FIFO_OUT    .byte   ?   ; Memory-mapped FIFO read port

FIFO_COUNT_LO = SIZE_LO ; Read: number of queued, ready-to-read bytes
FIFO_COUNT_HI = SIZE_HI

            .endv

CTRL_START              = $01
CTRL_STATUS_FIFO_EMPTY  = $40
CTRL_STATUS_BUSY        = $80

CMD_READ    = $03

            .section    dp
src         .fill   3   ; 24-bit flash address
count       .word   ?   ; Byte count
dest        .word   ?   ; Memory destination for `read`
            .send

; `begin_transfer`/`get`/`get_queued`/`wait_queued_count_hi`/`end_transfer`
; provide a low-level streaming interface for consuming flash data one byte
; at a time

begin_transfer:
          ; Reject zero-length transfers (the hardware doesn't handle them
          ; gracefully)
            lda     count
            ora     count+1
            beq     _invalid_arg

          ; Reject transfers larger than the FIFO size; technically, since
          ; the output is FIFO-ed, larger transfers are theoretically possible
          ; as long as the CPU reads the data continuously as it's being
          ; fetched, but the controller currently does not pause the transfer
          ; when the FIFO is full. If that is fixed, this limit can be raised
          ; to the controller's transfer size limit (currently at 4096 bytes
          ; due to a separate 12-bit counter issue).
            lda     count+1
            cmp     #>\FIFO_SIZE
            bcc     +
            bne     _invalid_arg

            lda     count
            cmp     #<\FIFO_SIZE
            bcc     +
            bne     _invalid_arg

          ; Do not disturb an active transfer
          + lda     CTRL
            and     #(CTRL_STATUS_BUSY | CTRL_START)
            bne     _busy

          ; Require an empty FIFO
            lda     CTRL
            and     #CTRL_STATUS_FIFO_EMPTY
            beq     _dirty

          ; Init the registers
            lda     #CMD_READ
            sta     CMD

            lda     count
            sta     SIZE_LO
            lda     count+1
            sta     SIZE_HI

            lda     src
            sta     ADDR_LO
            lda     src+1
            sta     ADDR_MID
            lda     src+2
            sta     ADDR_HI

          ; Initiate transfer
            lda     #CTRL_START
            sta     CTRL

            clc
            rts

_invalid_arg:
_busy:
_dirty:
            sec
            rts

get:
          ; Return the next byte from the FIFO buffer. Blocks until data is
          ; available and therefore will hang if no transfer is active or if
          ; the caller reads beyond the requested byte count.
          - lda CTRL
            and     #CTRL_STATUS_FIFO_EMPTY
            bne     -

            lda     FIFO_OUT
            rts

wait_queued_count_hi:
          ; Wait until FIFO_COUNT_HI is at least A -- that is, until at
          ; least A 256-byte chunks are queued in the FIFO buffer
          - cmp     FIFO_COUNT_HI
            bcc     _ready
            beq     _ready
            bra     -
_ready:
            rts

end_transfer:
          ; End the transfer and return the controller to idle
          - lda     CTRL                    ; wait for the transfer to finish
            and     #CTRL_STATUS_BUSY
            bne     -

            stz     CTRL                    ; clear the CTRL_START bit
            rts

flush:
          ; Discard all remaining queued bytes; call `end_transfer` first to
          ; make sure the controller has stopped producing data
          - lda     CTRL
            and     #CTRL_STATUS_FIFO_EMPTY
            bne     _done

            lda     FIFO_OUT
            bra     -

_done:
            rts

; `read_chunk` is a convenience wrapper for copying a chunk of flash data
; no larger than `FIFO_SIZE` into a specific memory location

read_chunk:
          ; Copy the requested `count` flash bytes (<= `FIFO_SIZE`) into
          ;  memory at `dest`. Clears the carry on success and sets the carry
          ; on failure. On success, `count` is zero and `dest` points one byte
          ; past the copied data.
            jsr     begin_transfer
            bcs     _out

          ; We could stream the data byte-by-byte, but doing so would require
          ; a `CTRL_STATUS_FIFO_EMPTY` check in the copy loop. The 12 MHz
          ; CPU-side copy is already much slower than the SPI producer,
          ; so per-byte polling would likely cost more than the resulting
          ; concurrency would save.

          ; Wait for transaction start; avoids mistaking the delayed BUSY
          ; status for completion
          - lda     CTRL
            and     #CTRL_STATUS_FIFO_EMPTY
            bne     -

          ; Wait until all the data is in the FIFO buffer
            jsr     end_transfer

_copy:
          ; All requested bytes are now queued, so no status check is needed
            lda     FIFO_OUT
            sta     (dest)

            inc     dest
            bne     +
            inc     dest+1

          + lda     count
            bne     +
            dec     count+1
          + dec     count

            lda     count
            ora     count+1
            bne     _copy

            clc
_out:
            rts

            .endm
            .endn
