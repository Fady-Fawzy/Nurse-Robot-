    AREA TFT_CODE, CODE, READONLY
    EXPORT TFT_Init
    EXPORT TFT_Fill
    EXPORT TFT_DrawChar
    
    EXPORT TFT_WriteCommand
    EXPORT TFT_WriteData
    EXPORT TFT_WriteData16
        
    IMPORT font8x8              ; 8x8 monochrome bitmap font glyph table

; Memory mapped peripheral base addresses
RCC_BASE     EQU 0x40023800
GPIOA_BASE   EQU 0x40020000
GPIOB_BASE   EQU 0x40020400

RCC_AHB1ENR  EQU 0x30
GPIO_MODER   EQU 0x00
GPIO_ODR     EQU 0x14
GPIO_BSRR    EQU 0x18
GPIO_OSPEEDR EQU 0x08

; ST7735 display interface pin mappings
TFT_SCK_BIT  EQU 9      ; PA9  - Software SPI Clock
TFT_MOSI_BIT EQU 10     ; PA10 - Software SPI MOSI (Data Output)

TFT_CS_BIT   EQU 12     ; PB12 - Chip Select (Active Low)
TFT_RST_BIT  EQU 13     ; PB13 - Hardware Reset (Active Low)
TFT_DC_BIT   EQU 15     ; PB15 - Data/Command select (Low = Command, High = Data)

; ==============================================================================
; TFT_Init: Configures GPIO pins, performs hardware reset, and initializes
; the ST7735 controller for 16-bit RGB565 graphics
; ==============================================================================
TFT_Init FUNCTION
    PUSH {R0-R2, LR}
    
    ; Enable GPIOA and GPIOB peripheral clocks
    LDR R0, =RCC_BASE + RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #0x03
    STR R1, [R0]

    ; Configure PA9 and PA10 as Outputs for SPI
    LDR R0, =GPIOA_BASE
    LDR R1, [R0, #GPIO_MODER]
    LDR R2, =0x003C0000       ; Clear mode bits for PA9, PA10
    BIC R1, R1, R2
    LDR R2, =0x00140000       ; Set to General Purpose Output (01)
    ORR R1, R1, R2
    STR R1, [R0, #GPIO_MODER]

    ; Set GPIOA pins to High Speed to sharpen SPI edge transitions
    LDR R1, [R0, #GPIO_OSPEEDR]
    LDR R2, =0x003C0000       
    ORR R1, R1, R2
    STR R1, [R0, #GPIO_OSPEEDR]

    ; Configure PB12, PB13, PB15 as Outputs (CS, RST, D/C)
    LDR R0, =GPIOB_BASE
    LDR R1, [R0, #GPIO_MODER]
    LDR R2, =0xCF000000      ; Clear mode bits for 12, 13, 15
    BIC R1, R1, R2
    LDR R2, =0x45000000      ; Set to Output (01)
    ORR R1, R1, R2
    STR R1, [R0, #GPIO_MODER]

    ; Set GPIOB control pins to High Speed
    LDR R1, [R0, #GPIO_OSPEEDR]
    LDR R2, =0xCF000000       
    ORR R1, R1, R2
    STR R1, [R0, #GPIO_OSPEEDR]

    ; Deassert CS (idle HIGH)
    LDR R0, =GPIOB_BASE
    LDR R1, =(1 << TFT_CS_BIT)
    STR R1, [R0, #GPIO_BSRR]
    
    ; Idle SCK LOW (SPI Mode 0)
    LDR R0, =GPIOA_BASE
    LDR R1, =(1 << (TFT_SCK_BIT + 16)) 
    STR R1, [R0, #GPIO_BSRR]

    ; Hardware reset cycle: pulse RST LOW then release HIGH
    LDR R0, =GPIOB_BASE
    LDR R1, =(1 << (TFT_RST_BIT + 16)) 
    STR R1, [R0, #GPIO_BSRR]
    BL delay
    
    LDR R1, =(1 << TFT_RST_BIT)        
    STR R1, [R0, #GPIO_BSRR]
    BL delay

    ; Sleep out command (0x11)
    MOV R0, #0x11        
    BL TFT_WriteCommand
    BL delay

    ; Interface pixel format (0x3A): set to 16 bits/pixel (RGB565 = 0x55)
    MOV R0, #0x3A        
    BL TFT_WriteCommand
    MOV R0, #0x55
    BL TFT_WriteData

    ; Memory data access control (0x36): configure display orientation and RGB order
    MOV R0, #0x36        
    BL TFT_WriteCommand
    MOV R0, #0xE8        
    BL TFT_WriteData

    ; Display ON command (0x29)
    MOV R0, #0x29        
    BL TFT_WriteCommand

    POP {R0-R2, PC}
    ENDFUNC

; ==============================================================================
; TFT_Fill: Fills the entire display buffer with a specified 16-bit color (R0)
; ==============================================================================
TFT_Fill FUNCTION
    PUSH {R1-R4, LR}
    MOV R4, R0           ; Preserve target color in R4

    ; Set column address range (0 to 127)
    MOV R0, #0x2A        ; CASET command
    BL TFT_WriteCommand
    MOV R0, #0x00        ; Column start MSB
    BL TFT_WriteData
    MOV R0, #0x00        ; Column start LSB
    BL TFT_WriteData
    MOV R0, #0x01        ; Column end MSB
    BL TFT_WriteData
    MOV R0, #0xDF        ; Column end LSB
    BL TFT_WriteData

    ; Set row address range (0 to 159)
    MOV R0, #0x2B        ; RASET command
    BL TFT_WriteCommand
    MOV R0, #0x00        ; Row start MSB
    BL TFT_WriteData
    MOV R0, #0x00        ; Row start LSB
    BL TFT_WriteData
    MOV R0, #0x01        ; Row end MSB
    BL TFT_WriteData
    MOV R0, #0x3F        ; Row end LSB
    BL TFT_WriteData

    ; Initiate memory write (RAMWR command)
    MOV R0, #0x2C        
    BL TFT_WriteCommand

    ; Stream pixel colors across the frame
    LDR R3, =153600      ; Pixel clear iterations to flush full controller display buffer
fill_pixels
    MOV R0, R4           
    BL TFT_WriteData16
    SUBS R3, R3, #1
    BNE fill_pixels

    POP {R1-R4, PC}
    ENDFUNC

; ==============================================================================
; TFT_DrawChar: Renders an 8x8 ASCII glyph at pixel coordinates (X, Y)
; Arguments: R0 = X, R1 = Y, R2 = ASCII Char, R3 = Foreground Color
; ==============================================================================
TFT_DrawChar FUNCTION
    PUSH {R4-R9, LR}
    
    MOV R4, R0          ; X coordinate
    MOV R5, R1          ; Y coordinate
    MOV R6, R2          ; ASCII character
    MOV R7, R3          ; Foreground color
    LDR R8, =0x0000     ; Background color (Black)

    ; Validate printable ASCII bounds
    CMP R6, #32
    BLT end_draw
    CMP R6, #126
    BGT end_draw

    ; Define 8x8 pixel bounding box: columns X to X+7
    ADD R9, R4, #7
    MOV R0, #0x2A       ; CASET
    BL TFT_WriteCommand
    LSR R0, R4, #8
    BL TFT_WriteData
    AND R0, R4, #0xFF
    BL TFT_WriteData
    LSR R0, R9, #8
    BL TFT_WriteData
    AND R0, R9, #0xFF
    BL TFT_WriteData

    ; Rows: Y to Y+7
    ADD R9, R5, #7
    MOV R0, #0x2B       ; RASET
    BL TFT_WriteCommand
    LSR R0, R5, #8
    BL TFT_WriteData
    AND R0, R5, #0xFF
    BL TFT_WriteData
    LSR R0, R9, #8
    BL TFT_WriteData
    AND R0, R9, #0xFF
    BL TFT_WriteData

    ; Initiate pixel stream
    MOV R0, #0x2C       ; RAMWR
    BL TFT_WriteCommand

    ; Calculate glyph offset in font table: (char - 32) * 8 bytes
    SUB R6, R6, #32     
    LSL R6, R6, #3      
    LDR R9, =font8x8
    ADD R9, R9, R6      ; R9 points to 8-byte character bitmap

    MOV R5, #8          ; 8 rows per character
row_loop
    LDRB R6, [R9]       ; Load row pattern byte
    ADD R9, R9, #1      
    
    MOV R4, #8          ; 8 pixels per row
bit_loop
    TST R6, #0x80       ; Test leftmost bit (MSB)
    BNE draw_fg         

draw_bg
    ; Bit is 0: plot background color
    MOV R0, R8          
    BL TFT_WriteData16
    B next_bit

draw_fg
    ; Bit is 1: plot text color
    MOV R0, R7          
    BL TFT_WriteData16

next_bit
    LSL R6, R6, #1      ; Advance to next column bit
    SUBS R4, R4, #1
    BNE bit_loop        
    
    SUBS R5, R5, #1
    BNE row_loop        

end_draw
    POP {R4-R9, PC}
    ENDFUNC

; ==============================================================================
; TFT_SPI_SendByte: Software bit-bang SPI transmission (MSB first, Mode 0)
; ==============================================================================
TFT_SPI_SendByte FUNCTION
    PUSH {R1-R3}
    LDR R1, =GPIOA_BASE + GPIO_BSRR
    MOV R3, #8             
spi_loop
    ; Set MOSI to match MSB
    TST R0, #0x80
    BNE set_mosi
    LDR R2, =(1 << (TFT_MOSI_BIT + 16)) ; Pull MOSI LOW
    STR R2, [R1]
    B clk_pulse
set_mosi
    LDR R2, =(1 << TFT_MOSI_BIT)        ; Pull MOSI HIGH
    STR R2, [R1]

clk_pulse
    ; Pulse SCK HIGH then LOW
    LDR R2, =(1 << TFT_SCK_BIT)         
    STR R2, [R1]
    LSL R0, R0, #1                      
    LDR R2, =(1 << (TFT_SCK_BIT + 16))  
    STR R2, [R1]

    SUBS R3, R3, #1
    BNE spi_loop
    
    POP {R1-R3}
    BX LR
    ENDFUNC

; ==============================================================================
; TFT_WriteCommand: Asserts CS LOW, D/C LOW, transmits byte, and deasserts CS
; ==============================================================================
TFT_WriteCommand FUNCTION
    PUSH {R1-R2, LR}
    LDR R1, =GPIOB_BASE + GPIO_BSRR
    
    ; Pull CS LOW and D/C LOW
    LDR R2, =(1 << (TFT_CS_BIT + 16)) | (1 << (TFT_DC_BIT + 16))
    STR R2, [R1]
    
    BL TFT_SPI_SendByte
    
    ; Deassert CS HIGH
    LDR R2, =(1 << TFT_CS_BIT)
    STR R2, [R1]
    
    POP {R1-R2, PC}
    ENDFUNC

; ==============================================================================
; TFT_WriteData: Asserts CS LOW, D/C HIGH, transmits byte, and deasserts CS
; ==============================================================================
TFT_WriteData FUNCTION
    PUSH {R1-R2, LR}
    LDR R1, =GPIOB_BASE + GPIO_BSRR

    ; Pull CS LOW and D/C HIGH
    LDR R2, =(1 << (TFT_CS_BIT + 16)) | (1 << TFT_DC_BIT)
    STR R2, [R1]
    
    BL TFT_SPI_SendByte
    
    ; Deassert CS HIGH
    LDR R2, =(1 << TFT_CS_BIT)
    STR R2, [R1]
    
    POP {R1-R2, PC}
    ENDFUNC

; ==============================================================================
; TFT_WriteData16: Sends a 16-bit word as two successive bytes (MSB first)
; ==============================================================================
TFT_WriteData16 FUNCTION
    PUSH {R0-R3, LR}
    MOV R3, R0              
    LSR R0, R3, #8          ; High byte
    BL TFT_WriteData
    MOV R0, R3
    AND R0, R0, #0xFF       ; Low byte
    BL TFT_WriteData
    POP {R0-R3, PC}
    ENDFUNC

; ==============================================================================
; delay: General software spin delay
; ==============================================================================
delay FUNCTION
    PUSH {R0, LR}
    LDR R0, =0x20000        
delay_loop
    SUBS R0, R0, #1
    BNE delay_loop
    POP {R0, PC}
    ENDFUNC

    ALIGN
    END