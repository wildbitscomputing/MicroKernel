.global krn_ptr1, bank_save
.global fat32_bufptr, fat32_lfn_bufptr, fat32_ptr, fat32_ptr2
.global spi_ctrl_ptr, spi_data_ptr

.segment "ZEROPAGE" : zeropage

; DOS
krn_ptr1:
	.res 2
bank_save:
	.res 1

; FAT 32
fat32_bufptr:
	.res 2 ; word - Internally used by FAT32 code
fat32_lfn_bufptr:
	.res 2 ; word - Internally used by FAT32 code
fat32_ptr:
	.res 2 ; word - Buffer pointer to various functions
fat32_ptr2:
	.res 2 ; word - Buffer pointer to various functions

; Active slow-SPI controller.  K2 exposes the front card at $DD00/$DD01
; and the internal microSD card at $DD20/$DD21.
spi_ctrl_ptr:
	.res 2
spi_data_ptr:
	.res 2
