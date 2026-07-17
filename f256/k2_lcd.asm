; This file is part of the TinyCore MicroKernel for the Foenix F256K2.
; Copyright 2024 <stef@c256foenix.com>
; Copyright 2026 Wildbits Computing Company

            .cpu    "w65c02"

            .namespace  platform
k2lcd       .namespace

            .section    kmem
rows_remaining .word   ?
            .send

            .section    global

; Memory-mapped LCD interface registers
reg         .namespace
CMD         = $DD40     ; Command register
DATA        = $DD41     ; Command parameter/data register

; Pixel data; always write in pairs, otherwise the state machine will lock!
PIX_LO      = $DD42     ; {G[2:0], B[4:0]}
PIX_HI      = $DD43     ; {R[4:0], G[5:3]}

CTRL        = $DD44     ; Control register
            .endn

ctrl_bit    .namespace
RST         = $10       ; 0 to reset (RSTn)
BACKLIGHT   = $20       ; 1 = ON, 0 = OFF
            .endn

init                                ; *** IMPORTANT -> If there is no LCD and if passes the Tests, the machine will hang, you need to have a LCD Installed ***
            jsr     get_board
            bcs     _out
            and     #(board_feature.SPI_FLASH | board_feature.LCD)
            cmp     #(board_feature.SPI_FLASH | board_feature.LCD)
            bne     _out

          ; Release reset but keep backlight OFF during drawing
            lda     #ctrl_bit.RST
            sta     reg.CTRL

            jsr     LCD_1_69_Init           ; Init the LCD
            jsr     Splash_LCD_Download     ; Read the splash raster from the SPI flash and feed the display
            bcs     _out

          ; Turn on backlight after image is ready
            lda     #ctrl_bit.RST | ctrl_bit.BACKLIGHT
            sta     reg.CTRL

_out:
            rts

; ST7789V display controller commands
command     .namespace
NOP         = $00   ; No operation
SWRESET     = $01   ; Software reset
RDDID       = $04   ; Read display ID
RDDST       = $09   ; Read display status
RDDPM       = $0A   ; Read display power mode
RDDMADCTL   = $0B   ; Read display MADCTL
RDDCOLMOD   = $0C   ; Read display pixel format
RDDIM       = $0D   ; Read display image mode
RDDSM       = $0E   ; Read display signal mode
RDDSDR      = $0F   ; Read display self-Diagnostic result
SLPIN       = $10   ; Sleep in
SLPOUT      = $11   ; Sleep out
PTLON       = $12   ; Partial mode on
NORON       = $13   ; Normal display mode on
INVOFF      = $20   ; Display inversion off
INVON       = $21   ; Display inversion on
GAMSET      = $26   ; Gamma set
DISPOFF     = $28   ; Display off
DISPON      = $29   ; Display on
CASET       = $2A   ; Column address set
RASET       = $2B   ; Row address set
RAMWR       = $2C   ; Memory write
PTLAR       = $30   ; Partial start/end address set
VSCRDEF     = $33   ; Vertical scrolling definition
TEOFF       = $34   ; Tearing effect line off
TEON        = $35   ; Tearing effect line on
MADCTL      = $36   ; Memory data access control
VSCRSADD    = $37   ; Vertical scrolling start address
IDMOFF      = $38   ; Idle mode off
IDMON       = $39   ; Idle mode on
COLMOD      = $3A   ; Interface pixel format
RAMWRC      = $3C   ; Memory write continue
TESCAN      = $44   ; Set tear scanline
WRDISBV     = $51   ; Write display brightness
WRCTRLD     = $53   ; Write CTRL display
WRCACE      = $55   ; Write content adaptive brightness control and color enhancement
WRCABCMB    = $5E   ; Write CABC minimum brightness
RDCABCMB    = $5F   ; Read CABC minimum brightness
RDABCSDR    = $68   ; Read automatic brightness control self-diagnostic result
RAMCTRL     = $B0   ; RAM control
RGBCTRL     = $B1   ; RGB control
PORCTRL     = $B2   ; Porch control
FRCTRL1     = $B3   ; Frame rate control 1 (in partial mode/idle color)
PARCTRL     = $B5   ; Partial mode control
GCTRL       = $B7   ; Gate control
GTADJ       = $B8   ; Gate on timing adjustment
DGMEN       = $BA   ; Digital gamma enable
VCOMS       = $BB   ; VCOMS setting
LCMCTRL     = $C0   ; LCM control
IDSET       = $C1   ; ID code setting
VDVVRHEN    = $C2   ; VDV and VRH command enable
VRHS        = $C3   ; VRH set
VDVS        = $C4   ; VDV set
VCMOFSET    = $C5   ; VCOMS offset set
FRCTRL2     = $C6   ; Frame rate control in normal mode
CABCCTRL    = $C7   ; CABC control
REGSEL1     = $C8   ; Register value selection 1
REGSEL2     = $CA   ; Register value selection 2
PWMFRSEL    = $CC   ; PWM frequency selection
PWCTRL1     = $D0   ; Power control 1
VAPVANEN    = $D2   ; Enable VAP/VAN signal output
RDID1       = $DA   ; Read ID1
RDID2       = $DB   ; Read ID2
RDID3       = $DC   ; Read ID3
CMD2EN      = $DF   ; Command 2 enable
PVGAMCTRL   = $E0   ; Positive voltage gamma control
NVGAMCTRL   = $E1   ; Negative voltage gamma control
DGMLUTR     = $E2   ; Digital gamma look-up table for red
DGMLUTB     = $E3   ; Digital gamma look-up table for blue
GATECTRL    = $E4   ; Gate control
SPI2EN      = $E7   ; SPI2 enable
PWCTRL2     = $E8   ; Power control 2
EQCTRL      = $E9   ; Equalize time control
PROMCTRL    = $EC   ; Program control
PROMEN      = $FA   ; Program mode enable
NVMSET      = $FC   ; NVM setting
PROMACT     = $FE   ; Program action
            .endn

lcd_cmd     .macro cmd, data
          ; LCD command start
            lda     #command.\cmd
            sta     reg.CMD

    .if len(\data) < 5
            .if len(\data) > 0
          ; Short data sequence, emit inline
            lda     #\data[0]
            sta     reg.DATA
            .endif
            .for i in range(1, len(\data))
            .if \data[i] == \data[i - 1]
                sta     reg.DATA
            .else
                lda     #\data[i]
                sta     reg.DATA
            .endif
            .endfor
    .else
          ; Long data sequence, emit from an embedded table; clobbers X
            ldx     #0
          - lda     +,x
            sta     reg.DATA
            inx
            cpx     #len(\data)
            bne     -
            bra     ++

          ; Embedded data table
          + .for i in range(0, len(\data))
            .byte   \data[i]
            .endfor

          +
            .endif
          ; LCD command end
            .endmacro

LCD_1_69_Init
          ; ST7789V requires waiting for 120ms after releasing reset before sending SLPOUT
            .platform.cpu.wait_ms   120

          ; Turn off sleep mode
            .lcd_cmd    SLPOUT, []

          ; Wait 5ms for supply voltages and clock circuits to stabilize
            .platform.cpu.wait_ms   5

          ; LCD raster format: top-to-bottom, left-to-right, RGB
            .lcd_cmd    MADCTL, [$00]

          ; Set pixel format to 16 bit/pixel
            .lcd_cmd    COLMOD, [$05]

          ; Set scan timing intervals (aka porch control, ST7789V defaults)
            .lcd_cmd    PORCTRL, [$0C, $0C, $00, $33, $33]

          ; Set gate control voltages (VGH=13.26V VGL=-10.43, ST7789V default)
            .lcd_cmd    GCTRL, [$35]

          ; Set VCOM voltage to 1.425V
            .lcd_cmd    VCOMS, [$35]

          ; LCM control settings (ST7789V default)
            .lcd_cmd    LCMCTRL, [$2C]

          ; Enable VDVS and VRHS commands
            .lcd_cmd    VDVVRHEN, [$01, $FF]

          ; Set VAP=4.5V, VAN=-4.5V
            .lcd_cmd    VRHS, [$13]

          ; Set VDV=0V (ST7789V default)
            .lcd_cmd    VDVS, [$20]

          ; Set frame rate to 60Hz
            .lcd_cmd    FRCTRL2, [$0F]

          ; Set power levels (AVDD=6.8V, AVCL=-4.8V, VDDS=2.3V)
            .lcd_cmd    PWCTRL1, [$A4, $A1]

          ; Positive-polarity gamma curve
            .lcd_cmd    PVGAMCTRL, [$F0, $00, $04, $04, $04, $05, $29, $33, $3E, $38, $12, $12, $28, $30]

          ; Negative-polarity gamma curve
            .lcd_cmd    NVGAMCTRL, [$F0, $07, $0A, $0D, $0B, $07, $28, $33, $3E, $36, $14, $14, $29, $32]

          ; Enable display polarity inversion
            .lcd_cmd    INVON, []

          ; Display on
            .lcd_cmd    DISPON, []

            rts


LCD_WIDTH               = 240
LCD_HEIGHT              = 320
LCD_BYTES_PER_PIXEL     = 2
LCD_ROW_SIZE            = LCD_WIDTH * LCD_BYTES_PER_PIXEL
LCD_LAST_ROW            = platform.spi_flash.layout.LCD_RASTER.end - LCD_ROW_SIZE + 1

.cerror LCD_ROW_SIZE * LCD_HEIGHT != platform.spi_flash.layout.LCD_RASTER.size, "LCD image size does not match the corresponding flash region data"

Splash_LCD_Download:
          ; Setup the LCD windows to go write into; in our case, it is the
          ; whole memory (240x320)

          ; Set column address window to [0, 239]
            .lcd_cmd    CASET, [$00, $00, $00, $EF]

          ; Set row address window to [0, 319]
            .lcd_cmd    RASET, [$00, $00, $01, $3F]

          ; Tell the LCD to expect raster data
            .lcd_cmd    RAMWR, []

          ; The raster is stored bottom-up. Start at its last row and walk
          ; backward one 480-byte row at a time.
            lda     #<LCD_LAST_ROW
            sta     platform.spi_flash.src
            lda     #>LCD_LAST_ROW
            sta     platform.spi_flash.src+1
            lda     #((LCD_LAST_ROW >> 16) & $ff)
            sta     platform.spi_flash.src+2

            lda     #<LCD_ROW_SIZE
            sta     platform.spi_flash.count
            lda     #>LCD_ROW_SIZE
            sta     platform.spi_flash.count+1

            lda     #<LCD_HEIGHT
            sta     rows_remaining
            lda     #>LCD_HEIGHT
            sta     rows_remaining+1

_main_loop:
            jsr     Splash_LCD_Read_A_Line
            bcs     _out

            lda     rows_remaining
            bne     +
            dec     rows_remaining+1
          + dec     rows_remaining

            lda     rows_remaining
            ora     rows_remaining+1
            beq     _out

          ; Advance to the preceding row in the bottom-up raster
            sec
            lda     platform.spi_flash.src
            sbc     #<LCD_ROW_SIZE
            sta     platform.spi_flash.src

            lda     platform.spi_flash.src+1
            sbc     #>LCD_ROW_SIZE
            sta     platform.spi_flash.src+1

            lda     platform.spi_flash.src+2
            sbc     #0
            sta     platform.spi_flash.src+2
            bra     _main_loop

_out:
            rts

; Transfer a single raster line from the SPI flash to the LCD
Splash_LCD_Read_A_Line:
          ; Start a row transfer
            jsr     platform.spi_flash.begin_transfer
            bcs     _out

          ; Wait until at least 256 bytes have been queued in the FIFO buffer
            lda     #1
            jsr     platform.spi_flash.wait_queued_count_hi
            ldx     #LCD_WIDTH

          ; Copy LCD_WIDTH pixels (LCD_ROW_SIZE bytes) to the LCD while the
          ; SPI controller continues filling the FIFO. At a 12 MHz CPU clock,
          ; the producer-to-consumer rate ratio is approximately 5:1.
          - .platform.spi_flash.get_queued
            sta     reg.PIX_LO
            .platform.spi_flash.get_queued
            sta     reg.PIX_HI
            dex
            bne     -

          ; Return the controller to idle
            jsr     platform.spi_flash.end_transfer
            clc
_out:
            rts

            .send
            .endn
            .endn
