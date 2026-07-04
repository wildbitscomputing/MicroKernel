; This file is part of the TinyCore MicroKernel for the Foenix F256K2.
; Copyright 2024 <stef@c256foenix.com>.

            .cpu    "w65c02"

            .namespace  platform
k2lcd       .namespace

            .section    kmem
rows_remaining .word   ?
            .send

            ;.section    kernel
            .section    global

; F256K2 Splash LCD
LCD_CMD_CMD             = $DD40    ;Write Command Here
LCD_RST                 = $10      ; 0 to Reset (RSTn)
LCD_BL                  = $20      ; 1 = ON, 0 = OFF
; Read Only
LCD_TE                  = $40      ; Tear Enable
LCD_CMD_DTA             = $DD41    ;Write Data (For Command) Here
; Always Write in Pairs, otherwise the State Machine will Lock
LCD_PIX_LO              = $DD42    ; {G[2:0], B[4:0]}
LCD_PIX_HI              = $DD43    ; {R[4:0], G[5:3]}
LCD_CTRL_REG            = $DD44

LCD_WIDTH               = 240
LCD_HEIGHT              = 320
LCD_BYTES_PER_PIXEL     = 2
LCD_ROW_SIZE            = LCD_WIDTH * LCD_BYTES_PER_PIXEL
LCD_LAST_ROW            = platform.spi_flash.layout.LCD_RASTER.end - LCD_ROW_SIZE + 1

.cerror LCD_ROW_SIZE * LCD_HEIGHT != platform.spi_flash.layout.LCD_RASTER.size, "LCD image size does not match the corresponding flash region data"

init								; *** IMPORTANT -> If there is no LCD and if passes the Tests, the machine will hang, you need to have a LCD Installed ***
            jsr     get_board
            bcs     _out
            and     #(board_feature.SPI_FLASH | board_feature.LCD)
            cmp     #(board_feature.SPI_FLASH | board_feature.LCD)
            bne     _out

          ; Release reset but keep backlight OFF during drawing
            lda     #LCD_RST
            sta     LCD_CTRL_REG

			jsr 	LCD_1_69_Init			; Go Init the LCD
			jsr 	Splash_LCD_Download		; Go Get the SPI Flash Data and Feed the Display
            bcs     _out

          ; Turn on backlight after image is ready
            lda     #LCD_RST | LCD_BL
            sta     LCD_CTRL_REG

_out:
			rts

LCD_1_69_Init
			lda 	#$11
            sta 	LCD_CMD_CMD
			jsr 	WAIT_100ms
			jsr 	WAIT_100ms
			; 36 Command
			lda 	#$36	; Viewing Side
            sta 	LCD_CMD_CMD
			lda 	#$00	; Vertical - 70 8 = Invert Color
			sta 	LCD_CMD_DTA
			; 3A Command
			lda 	#$3A
            sta 	LCD_CMD_CMD
			lda 	#$05
			sta 	LCD_CMD_DTA
			; B2 Command
			lda 	#$B2
            sta 	LCD_CMD_CMD
			lda 	#$0C
			sta 	LCD_CMD_DTA
			sta 	LCD_CMD_DTA
			lda 	#$00
			sta 	LCD_CMD_DTA
			lda 	#$33
			sta 	LCD_CMD_DTA
			sta 	LCD_CMD_DTA
			; B7 Command
			lda 	#$B7
            sta 	LCD_CMD_CMD
			lda 	#$35
			sta 	LCD_CMD_DTA
			; BB Command
			lda 	#$BB
            sta 	LCD_CMD_CMD
			lda 	#$35
			sta 	LCD_CMD_DTA
			; C0 Command
			lda 	#$C0
            sta 	LCD_CMD_CMD
			lda 	#$2C
			sta 	LCD_CMD_DTA
			; C2 Command
			lda 	#$C2
            sta 	LCD_CMD_CMD
			lda 	#$01
			sta 	LCD_CMD_DTA
			; C3 Command
			lda 	#$C3
            sta 	LCD_CMD_CMD
			lda 	#$13
			sta 	LCD_CMD_DTA
			; C4 Command
			lda 	#$C4
            sta 	LCD_CMD_CMD
			lda 	#$20
			sta 	LCD_CMD_DTA
			; C6 Command
			lda 	#$C6
            sta 	LCD_CMD_CMD
			lda 	#$0F
			sta 	LCD_CMD_DTA
			; D0 Command
			lda 	#$D0
            sta 	LCD_CMD_CMD
			lda 	#$A4
			sta 	LCD_CMD_DTA
			lda 	#$A1
			sta 	LCD_CMD_DTA
			; D6 Command
			lda 	#$D0
            sta 	LCD_CMD_CMD
			lda 	#$A4
			sta 	LCD_CMD_DTA
			; E0 Command
			ldx 	#$00
			lda 	#$E0
            sta 	LCD_CMD_CMD
Init_CMDE0_Loop:
			lda 	LCD_Init_CMD_E0_SEQ, x
			sta 	LCD_CMD_DTA
		    inx
			cpx 	#size(LCD_Init_CMD_E0_SEQ)
			bne 	Init_CMDE0_Loop

			; E1 Command
			ldx 	#$00
			lda 	#$E1
            sta 	LCD_CMD_CMD
Init_CMDE1_Loop:
			lda 	LCD_Init_CMD_E1_SEQ, x
			sta 	LCD_CMD_DTA
		    inx
			cpx 	#size(LCD_Init_CMD_E1_SEQ)
			bne 	Init_CMDE1_Loop

			; 21 Command
			lda 	#$21
            sta 	LCD_CMD_CMD
			; 11	 Command
			lda 	#$11
            sta 	LCD_CMD_CMD
			jsr 	WAIT_100ms
			jsr 	WAIT_100ms
			lda 	#$29
            sta 	LCD_CMD_CMD
			rts

; Init Sequence with different command
;LCD_Init_SEQ_CMD		.text $36, $3A, $B2, $B2, $B2, $B2, $B2, $B7, $BB, $C0, $C2, $C3, $C4, $C6, $D0, $D0
;LCD_Init_SEQ_DAT		.text $00, $05, $0C, $0C, $00, $33, $33, $35, $35, $2C, $01, $13, $20, $0F, $A4, $A1
; Specific Command String of Data for setup $E0, $E1
LCD_Init_CMD_E0_SEQ   	.text $F0, $00, $04, $04, $04, $05, $29, $33, $3E, $38, $12, $12, $28, $30
LCD_Init_CMD_E1_SEQ   	.text $F0, $07, $0A, $0D, $0B, $07, $28, $33, $3E, $36, $14, $14, $29, $32


Splash_LCD_Download:
; The Data on the FLASH for the LCD is made of a BMP File (2 Bytes 565 Encoded) but the file doesn't have a header, so the file needs to be read inverted
            ; Setup the LCD Windows to go Write into - In this case it is the whole Memory (240x320)
            ; Full Screen
            ; FIRST HALF
			; 2A Command ( Window X)
            ; XS = 0
            ; XE = 239
			lda 	#$2A
            sta 	LCD_CMD_CMD
			lda 	#$00	; XStart_High
			sta 	LCD_CMD_DTA
			lda 	#$00	; XStart_Low
			sta 	LCD_CMD_DTA
			lda 	#$00	; XEnd_High
			sta 	LCD_CMD_DTA
			lda 	#$EF	; Xend_Low
			sta 	LCD_CMD_DTA
			; 2B Command (Window Y)
            ; YS = 0
            ; YS = 319
			lda 	#$2B
            sta 	LCD_CMD_CMD
			lda 	#$00	; YStart_High
			sta 	LCD_CMD_DTA
			lda 	#$00	; YStart_Low
			sta 	LCD_CMD_DTA
			lda 	#$01	; YEnd_High	; 280
			sta 	LCD_CMD_DTA
			lda 	#$3F		; Yend_Low
			sta 	LCD_CMD_DTA

			lda 	#$2C        ; Tell the LCD to expect Data
            sta 	LCD_CMD_CMD

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

;; ********************************
;; *********** LCD ****************
;; ********************************
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
            sta     LCD_PIX_LO
            .platform.spi_flash.get_queued
            sta     LCD_PIX_HI
            dex
            bne     -

          ; Return the controller to idle
            jsr     platform.spi_flash.end_transfer
            clc
_out:
            rts

;
; Wait for 100ms
;
; Not Super Sexy but so early in the initialisation of the system that'd prolly the best way to go (to be changed with something more sexy?)
WAIT_100ms: phx
            ldx 	#100
WAIT100L:   jsr 	WAIT_1MS
            dex
            bne 	WAIT100L
            plx
            rts

; Wait for about 1ms
;
WAIT_1MS:   phx
            phy

            ; Inner loop is 6 clocks per iteration or 1us
            ; Run the inner loop ~1000 times for 1ms

            ldx #3
wait_outr:  ldy #$ff
wait_inner: nop
            dey
            bne wait_inner
            dex
            bne wait_outr

            ply
            plx
            rts

            .send
            .endn
            .endn
