    AREA VARS, DATA, READWRITE
    ALIGN 4
myVar DCD 0     ; Stores the decoded 32-bit RFID card UID

; Clock and GPIO register definitions
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU 0x40023830

GPIOA_BASE      EQU 0x40020000
GPIOB_BASE      EQU 0x40020400

; NXP MFRC522 Register Map
CommandReg      EQU 0x01
ComIrqReg       EQU 0x04
DivIrqReg       EQU 0x05
ErrorReg        EQU 0x06
FIFODataReg     EQU 0x09
FIFOLevelReg    EQU 0x0A
ControlReg      EQU 0x0C
BitFramingReg   EQU 0x0D
ModeReg         EQU 0x11
TxControlReg    EQU 0x14
TxASKReg        EQU 0x15
TModeReg        EQU 0x2A
TPrescalerReg   EQU 0x2B
TReloadRegH     EQU 0x2C
TReloadRegL     EQU 0x2D

    AREA    |.text|, CODE, READONLY, ALIGN=2
    
    EXPORT  RFID_Init
    EXPORT  RFID_Process
    EXPORT  myVar

    IMPORT  TFT_Fill
    IMPORT  TFT_DrawChar
    IMPORT  TFT_DrawString
    IMPORT  TFT_DrawNumber
    IMPORT  temp_data
    IMPORT  final_spo2
    IMPORT  final_bpm
    IMPORT  read_velostat
    IMPORT  temp_int
    IMPORT  Last_Rate
    IMPORT  DS18B20_UpdateTemp
    IMPORT  MAX30102_Update

; ==============================================================================
; RFID_Init: Configures SPI GPIO pins and executes MFRC522 initialization sequence
; PA8  = Hard Reset (RST)
; PA9  = Bit-Banged SPI SCK
; PA10 = Bit-Banged SPI MOSI
; PB14 = Bit-Banged SPI MISO
; ==============================================================================
RFID_Init FUNCTION
    PUSH {LR}
    
    ; Enable GPIOA and GPIOB peripheral clocks
    LDR R0, =RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #0x03         
    STR R1, [R0]

    ; Configure PA8 as Output (RST)
    LDR R0, =GPIOA_BASE
    LDR R1, [R0, #0x00]   
    LDR R2, =0x00030000       
    BIC R1, R1, R2
    LDR R2, =0x00010000       
    ORR R1, R1, R2
    STR R1, [R0, #0x00]       
    
    ; Deassert Hard Reset (take RC522 out of power-down)
    LDR R1, =(1<<8)
    STR R1, [R0, #0x18]       

    ; Clear GPIOB upper pins configuration
    LDR R0, =GPIOB_BASE
    LDR R1, [R0, #0x00]       
    LDR R2, =0x30000000       
    BIC R1, R1, R2            
    STR R1, [R0, #0x00]      

    ; 1. Issue SoftReset command (0x0F)
    MOV R0, #CommandReg
    MOV R1, #0x0F            
    BL RC522_WriteReg
    LDR R2, =0x000FFFFF      ; Wait for internal analog circuitry to reset
Reset_Wait
    SUBS R2, R2, #1
    BNE Reset_Wait

    ; 2. Configure internal timer: auto-restart with 30ms timeout
    MOV R0, #TModeReg
    MOV R1, #0x80            ; TAuto = 1
    BL RC522_WriteReg
    MOV R0, #TPrescalerReg
    MOV R1, #0xA9            ; Prescaler setting
    BL RC522_WriteReg
    MOV R0, #TReloadRegH
    MOV R1, #0x03            ; Timer reload high byte
    BL RC522_WriteReg
    MOV R0, #TReloadRegL
    MOV R1, #0xE8            ; Timer reload low byte (0x03E8 = 1000 ticks)
    BL RC522_WriteReg
    
    ; 3. Configure RF modulation: 100% ASK and 0x6363 CRC preset
    MOV R0, #TxASKReg
    MOV R1, #0x40            ; Force 100% ASK
    BL RC522_WriteReg
    MOV R0, #ModeReg
    MOV R1, #0x3D            ; Set CRC preset to 0x6363
    BL RC522_WriteReg
    
    ; 4. Turn on antenna driver pins (Tx1RFEn | Tx2RFEn)
    MOV R0, #TxControlReg
    BL RC522_ReadReg
    ORR R1, R0, #0x03        
    MOV R0, #TxControlReg
    BL RC522_WriteReg

    POP {PC}
    ENDFUNC

; ==============================================================================
; RFID_Process: Periodic polling routine to detect proximity cards and parse UID
; ==============================================================================
RFID_Process FUNCTION
    PUSH {LR}
    BL Poll_Card              ; Query for card presence
    CMP R4, #0                ; R4 returns 0 if no card detected
    BEQ Process_End           
    BL Check_UID              ; Card found: match against clinical registry
Process_End
    POP {PC}
    ENDFUNC

; ==============================================================================
; Poll_Card: Sends ISO14443A REQA and executes Anti-Collision cascade to get UID
; Returns: R4 = 32-bit UID (or 0 if failed / timed out)
; ==============================================================================
Poll_Card
    PUSH {LR, R5, R6, R7}
    MOV R4, #0                ; Default return value (No card)

    ; --- Step 1: Transmit REQA (Request Command, 7 bits) ---
    MOV R0, #CommandReg
    MOV R1, #0x00             ; Idle command
    BL RC522_WriteReg
    MOV R0, #ComIrqReg
    MOV R1, #0x7F             ; Clear IRQ flags
    BL RC522_WriteReg
    MOV R0, #FIFOLevelReg
    MOV R1, #0x80             ; Flush FIFO buffer
    BL RC522_WriteReg
    
    MOV R0, #FIFODataReg
    MOV R1, #0x26             ; 0x26 = ISO14443A REQA
    BL RC522_WriteReg
    
    MOV R0, #CommandReg
    MOV R1, #0x0C             ; Transceive command
    BL RC522_WriteReg
    MOV R0, #BitFramingReg
    MOV R1, #0x87             ; StartSend = 1, RxAlign = 0, TxLastBits = 7
    BL RC522_WriteReg
    
    ; Poll for response
    LDR R6, =0x1000
Wait_REQA
    SUBS R6, R6, #1
    BEQ Poll_Fail             ; Timeout: no response from card
    MOV R0, #ComIrqReg
    BL RC522_ReadReg
    ANDS R7, R0, #0x20        ; Check RxIRq bit
    BEQ Wait_REQA

    ; --- Step 2: Anti-Collision Cascade Level 1 (0x93, 0x20) ---
    MOV R0, #CommandReg
    MOV R1, #0x00             
    BL RC522_WriteReg
    MOV R0, #ComIrqReg
    MOV R1, #0x7F             
    BL RC522_WriteReg
    MOV R0, #FIFOLevelReg
    MOV R1, #0x80             ; Flush FIFO
    BL RC522_WriteReg
    
    MOV R0, #FIFODataReg
    MOV R1, #0x93             ; PICC_ANTICOLL Cascade Level 1
    BL RC522_WriteReg
    MOV R0, #FIFODataReg
    MOV R1, #0x20             ; NVB (Number of Valid Bits: 2 bytes)
    BL RC522_WriteReg
    
    MOV R0, #CommandReg
    MOV R1, #0x0C             ; Transceive
    BL RC522_WriteReg
    MOV R0, #BitFramingReg
    MOV R1, #0x80             ; StartSend = 1, full 8-bit framing
    BL RC522_WriteReg
    
    ; Poll for UID reply
    LDR R6, =0x1000
Wait_Anti
    SUBS R6, R6, #1
    BEQ Poll_Fail
    MOV R0, #ComIrqReg
    BL RC522_ReadReg
    ANDS R7, R0, #0x20        
    BEQ Wait_Anti

    MOV R0, #BitFramingReg
    MOV R1, #0x00             ; Clear StartSend
    BL RC522_WriteReg

    ; Verify FIFO contains exactly 5 bytes (4-byte UID + 1-byte BCC checksum)
    MOV R0, #FIFOLevelReg
    BL RC522_ReadReg
    CMP R0, #5
    BNE Poll_Fail

    ; Extract 4-byte UID from FIFO into R4 (little-endian byte order)
    MOV R4, #0
    
    MOV R0, #FIFODataReg
    BL RC522_ReadReg          ; UID Byte 0
    ORR R4, R4, R0
    
    MOV R0, #FIFODataReg
    BL RC522_ReadReg          ; UID Byte 1
    LSL R0, R0, #8
    ORR R4, R4, R0
    
    MOV R0, #FIFODataReg
    BL RC522_ReadReg          ; UID Byte 2
    LSL R0, R0, #16
    ORR R4, R4, R0
    
    MOV R0, #FIFODataReg
    BL RC522_ReadReg          ; UID Byte 3
    LSL R0, R0, #24
    ORR R4, R4, R0
    
Poll_Fail
    POP {LR, R5, R6, R7}
    BX LR

; ==============================================================================
; SPI_TxRx: Bit-banged SPI byte transfer (Mode 0, MSB first)
; Transmits byte in R0, returns received byte in R0
; SCK = PA9, MOSI = PA10, MISO = PB14
; ==============================================================================
SPI_TxRx FUNCTION
    PUSH {R1-R6, LR}
    MOV R4, #8               ; 8 bits
    MOV R5, #0               ; Received byte accumulator
    LDR R1, =GPIOA_BASE      
    LDR R6, =GPIOB_BASE      
    LDR R2, =(1<<9)          ; SCK Set Bit
    LDR R3, =(1<<10)         ; MOSI Set Bit

spi_loop
    ; Set MOSI pin level to match MSB
    TST R0, #0x80            
    BNE set_mosi
    LDR R12, =(1<<26)        ; MOSI Reset bit (10 + 16)
    STR R12, [R1, #0x18]     
    B clk_pulse
set_mosi
    STR R3, [R1, #0x18]      

clk_pulse
    ; Clock rising edge: assert SCK HIGH
    STR R2, [R1, #0x18]      

    ; Sample MISO on PB14 (GPIOB_IDR bit 14)
    LSL R5, R5, #1           
    LDR R12, [R6, #0x10]     
    TST R12, #(1 << 14)      
    BEQ clk_low
    ORR R5, R5, #1           

clk_low
    ; Clock falling edge: assert SCK LOW
    LDR R12, =(1<<25)        ; SCK Reset bit (9 + 16)
    STR R12, [R1, #0x18]     

    ; Shift byte left for next bit
    LSL R0, R0, #1           
    SUBS R4, R4, #1          
    BNE spi_loop             

    MOV R0, R5               
    POP {R1-R6, PC}
    ENDFUNC

; ==============================================================================
; RC522_WriteReg: Writes a byte (R1) to an RC522 register address (R0)
; SPI write format: Address byte = (Address << 1) & 0x7E
; ==============================================================================
RC522_WriteReg
    PUSH {LR, R4, R5}
    MOV R4, R0                
    MOV R5, R1                
    LDR R1, =GPIOA_BASE + 0x18
    LDR R2, =(1<<24)       ; Assert CS LOW (PA8 reset bit: 8 + 16)
    STR R2, [R1]           
    
    ; Format register address for Write (MSB = 0)
    LSL R0, R4, #1
    AND R0, R0, #0x7E         
    BL SPI_TxRx               ; Send address
    MOV R0, R5
    BL SPI_TxRx               ; Send data
    
    LDR R1, =GPIOA_BASE + 0x18
    LDR R2, =(1<<8)        ; Deassert CS HIGH
    STR R2, [R1]           
    
    POP {LR, R4, R5}
    BX LR

; ==============================================================================
; RC522_ReadReg: Reads a byte from an RC522 register address (R0)
; SPI read format: Address byte = ((Address << 1) & 0x7E) | 0x80
; ==============================================================================
RC522_ReadReg
    PUSH {LR, R4}
    MOV R4, R0                
    LDR R1, =GPIOA_BASE + 0x18
    LDR R2, =(1<<24)       ; Assert CS LOW
    STR R2, [R1]           
    
    ; Format register address for Read (MSB = 1)
    LSL R0, R4, #1
    AND R0, R0, #0x7E
    ORR R0, R0, #0x80         
    BL SPI_TxRx               ; Send address
    MOV R0, #0x00             
    BL SPI_TxRx               ; Clock in slave data byte
    
    LDR R1, =GPIOA_BASE + 0x18
    LDR R2, =(1<<8)        ; Deassert CS HIGH
    STR R2, [R1]           
    
    POP {LR, R4}
    BX LR

    LTORG

; ==============================================================================
; Check_UID: Matches captured UID with on-chip clinical database records and
; draws the patient profile card on the ST7735 TFT display
; ==============================================================================
Check_UID FUNCTION
    PUSH {LR}                 
    
    ; Patient 1: Safwat
    LDR R5, =0x031F39CA       ; Card 1 UID
    LDR R0, =myVar
    STR R4, [R0]              
    CMP R4, R5
    BEQ.W Show_1              

    ; Patient 2: Omar
    LDR R5, =0x023338e6       ; Card 2 UID
    CMP R4, R5
    BEQ.W Show_2              

    B Check_UID_End           ; Unregistered tag, ignore

Show_1
    LDR R0, =0x0000           ; Black background
    BL TFT_Fill               
    
    ; Refresh sensor readouts
    BL DS18B20_UpdateTemp
    
    ; Draw Patient Demographic Information
    MOV R0, #5                
    MOV R1, #5               
    LDR R2, =str_NAME        
    LDR R3, =0xFFFF           ; White text
    BL TFT_DrawString
    
    MOV R0, #5                
    MOV R1, #20               
    LDR R2, =str_AGE       
    LDR R3, =0xFFFF           
    BL TFT_DrawString
    
    MOV R0, #5                
    MOV R1, #35               
    LDR R2, =str_COND        
    LDR R3, =0xFFFF           
    BL TFT_DrawString

    ; Draw Room Temperature
    MOV R0, #5                
    MOV R1, #55               
    LDR R2, =str_ROOM_LBL     
    LDR R3, =0x07E0           ; Green
    BL TFT_DrawString

    LDR R0, =temp_data        
    LDRSH R2, [R0]
    ASRS R2, R2, #4           ; Convert 12-bit fixed point to integer
    MOV R0, #95               
    MOV R1, #55               
    LDR R3, =0xFFFF           
    BL TFT_DrawNumber

    ; Refresh and Draw SpO2
    BL MAX30102_Update
    MOV R0, #5                
    MOV R1, #70               
    LDR R2, =str_SPO2_LBL     
    LDR R3, =0x07FF           ; Cyan
    BL TFT_DrawString

    LDR R0, =final_spo2
    LDR R2, [R0]              
    MOV R0, #95
    MOV R1, #70
    LDR R3, =0xFFFF
    BL TFT_DrawNumber

    ; Draw Heart Rate
    MOV R0, #5                
    MOV R1, #85               
    LDR R2, =str_HR_LBL     
    LDR R3, =0xF800           ; Red
    BL TFT_DrawString

    LDR R0, =final_bpm
    LDR R2, [R0]              
    MOV R0, #95
    MOV R1, #85
    LDR R3, =0xFFFF
    BL TFT_DrawNumber

    ; Read and Draw Bed Pressure (Velostat ADC)
    MOV R0, #5                
    MOV R1, #100               
    LDR R2, =str_PRESS_LBL     
    LDR R3, =0xFFE0           ; Yellow
    BL TFT_DrawString

    BL read_velostat          
    MOV R2, R0                
    MOV R0, #95
    MOV R1, #100
    LDR R3, =0xFFFF
    BL TFT_DrawNumber

    ; Draw Body Temperature
    MOV R0, #5                
    MOV R1, #115               
    LDR R2, =str_USE_TEMP_LBL     
    LDR R3, =0xF81F           ; Magenta
    BL TFT_DrawString

    LDR R0, =temp_int
    LDRB R2, [R0]             
    MOV R0, #95
    MOV R1, #115
    LDR R3, =0xFFFF
    BL TFT_DrawNumber

    ; Draw IV Drop Rate
    MOV R0, #5                
    MOV R1, #130               
    LDR R2, =str_RATE_LBL     
    LDR R3, =0xFFFF           
    BL TFT_DrawString

    LDR R0, =Last_Rate
    LDR R2, [R0]              
    MOV R0, #95
    MOV R1, #130
    LDR R3, =0xFFFF
    BL TFT_DrawNumber

    B Check_UID_End
    LTORG

Show_2
    ; Patient 2 card overview
    LDR R0, =0x0000           
    BL TFT_Fill
    MOV R0, #5              
    MOV R1, #5             
    LDR R2, =str_NAME2        
    LDR R3, =0xFFFF           
    BL TFT_DrawString
    MOV R0, #5              
    MOV R1, #20             
    LDR R2, =str_AGE2      
    LDR R3, =0xFFFF           
    BL TFT_DrawString
    MOV R0, #5              
    MOV R1, #35             
    LDR R2, =str_COND2        
    LDR R3, =0xFFFF           
    BL TFT_DrawString
    B Check_UID_End

Check_UID_End
    POP {PC}
    ENDFUNC


    AREA RFID_STRINGS, DATA, READONLY
    ALIGN 4
        
str_ROOM_LBL     DCB "Room Temp: ", 0
str_SPO2_LBL     DCB "SpO2: ", 0
str_HR_LBL       DCB "HR: ", 0
str_PRESS_LBL    DCB "Pressure: ", 0
str_USE_TEMP_LBL DCB "Max Temp: ", 0
str_RATE_LBL     DCB "Last Rate: ", 0
        
str_NAME   DCB "Name: SAFWAT", 0
str_AGE    DCB "Age: 19", 0
str_COND   DCB "Condition: Post-Op", 0

str_NAME2  DCB "Name: OMAR", 0
str_AGE2   DCB "Age: 21", 0
str_COND2  DCB "Condition: Stable", 0

    ALIGN 4
    END