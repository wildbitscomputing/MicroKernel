; K2/Jr2 SPI flash instance
; Copyright 2026 Wildbits Computing Company
; Copyright 2024 <stef@c256foenix.com>
; SPDX-License-Identifier: GPL-3.0-only

            .cpu        "w65c02"

            .namespace  platform
spi_flash   .namespace

layout      .namespace

; Use a zero-size struct to provide `REGION.start`/`.end`/`.size` notation.
; A `.virtual` block is not an option because it cannot represent the SPI
; flash's 24-bit address space in the W65C02 build.
region      .struct start_addr, end_addr
start       = \start_addr
end         = \end_addr
size        = end - start + 1
            .ends

; K2/Jr2 SPI splash layout
MACHINE_SERIAL  .dstruct region, $00000000, $0000001f
MACHINE_NAME    .dstruct region, $00000020, $0000003f
STARTUP_BANNER  .dstruct region, $00000040, $000001ff
LAYOUT_REVISION .dstruct region, $00000200, $00000200
SPLASH_PALETTE  .dstruct region, $00001000, $000013ff
SPLASH_RASTER   .dstruct region, $00002000, $00014bff
LCD_RASTER      .dstruct region, $00016000, $0003b7ff

            .endn

            .section kmem
available           .byte ?
has_machine_info    .byte ?
            .send

            .section    global

controller  .hardware.spi_flash $dd60, 2048

init:
            ; Initialize the availability & machine info flags
            stz     available
            stz     has_machine_info

            phx
            jsr     get_board
            bcs     _out
            and     #board_feature.SPI_FLASH
            beq     _out

            inc     available

            .select_region LAYOUT_REVISION
            jsr     platform.spi_flash.begin_transfer
            bcs     _out

          ; $ff in LAYOUT_REVISION denotes an uninitialized flash region
          ; predating the introduction of the machine info block; all future
          ; revisions are expected to be backward compatible with the current
          ; layout
            jsr     platform.spi_flash.get
            cmp     #$ff
            beq     +
            inc     has_machine_info

          + jsr     platform.spi_flash.end_transfer

            plx
            clc
            rts

_out:       plx
_unsupported:
            sec
            rts

; Convenience macro for selecting a predefined flash region as the source of
; the next transfer, e.g. `.select_region STARTUP_BANNER`
select_region .macro region
            lda     #<platform.spi_flash.layout.\region.start
            sta     platform.spi_flash.src
            lda     #>platform.spi_flash.layout.\region.start
            sta     platform.spi_flash.src+1
            lda     #((platform.spi_flash.layout.\region.start >> 16) & $ff)
            sta     platform.spi_flash.src+2

            lda     #<platform.spi_flash.layout.\region.size
            sta     platform.spi_flash.count
            lda     #>platform.spi_flash.layout.\region.size
            sta     platform.spi_flash.count+1
            .endm

begin_transfer:
          ; Forward to the controller implementation if available
            lda     available
            beq     init._unsupported
            jmp     controller.begin_transfer

read_chunk:
          ; Forward to the controller implementation if available
            lda     available
            beq     init._unsupported
            jmp     controller.read_chunk

get_queued  .macro
          ; Return the next byte from the FIFO buffer without checking whether
          ; it is empty. The caller must ensure that at least one byte is
          ; queued.
            lda     platform.spi_flash.controller.FIFO_OUT
            .endm

; Direct aliases
get                     = controller.get
wait_queued_count_hi    = controller.wait_queued_count_hi
end_transfer            = controller.end_transfer
flush                   = controller.flush
src                     = controller.src
count                   = controller.count
dest                    = controller.dest

            .send

            .endn
            .endn
