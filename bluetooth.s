	AREA    |.text|, CODE, READONLY
    ALIGN
    
    EXPORT  BT_Init
    EXPORT  BT_Get_Data

; External vital sign readings streamed via telemetry
    IMPORT bpm_current
    IMPORT spo2_current
    IMPORT press_current
    IMPORT temp_int
    IMPORT Last_Rate
    IMPORT temp_data

    EXPORT BT_Send_Char
    EXPORT BT_Send_String
    EXPORT BT_Send_Number
    EXPORT BT_Send_Sensor_Data

; Telemetry packet label strings
    AREA BT_STRINGS, DATA, READONLY
    ALIGN 4
str_hr      DCB "HR:", 0
str_spo2    DCB " SpO2:", 0
str_press   DCB " Press:", 0
str_rtemp   DCB " RTemp:", 0
str_drop    DCB " Drop:", 0
str_nl      DCB "\r\n", 0
    ALIGN 4

    AREA |.text|, CODE, READONLY
    ALIGN 4

; Peripheral base addresses for Clock and GPIO
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU RCC_BASE + 0x30
RCC_APB2ENR     EQU RCC_BASE + 0x44  

GPIOB_BASE      EQU 0x40020400
GPIOB_MODER     EQU GPIOB_BASE + 0x00
GPIOB_AFRL      EQU GPIOB_BASE + 0x20 

; USART1 registers for HC-05 serial link
USART1_BASE     EQU 0x40011000
USART1_SR       EQU USART1_BASE + 0x00
USART1_DR       EQU USART1_BASE + 0x04
USART1_BRR      EQU USART1_BASE + 0x08
USART1_CR1      EQU USART1_BASE + 0x0C

; ==============================================================================
; BT_Init: Sets up USART1 on PB6 (TX) and PB7 (RX) at 9600-8-N-1
; ==============================================================================
BT_Init
    PUSH {R0-R2, LR}

    ; Enable GPIOB peripheral clock on AHB1
    LDR R0, =RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #0x02
    STR R1, [R0]

    ; Enable USART1 clock on APB2 (bit 4)
    LDR R0, =RCC_APB2ENR
    LDR R1, [R0]
    LDR R2, =0x00000010     
    ORR R1, R1, R2
    STR R1, [R0]

    ; Configure PB6 and PB7 for Alternate Function mode ('10')
    LDR R0, =GPIOB_MODER
    LDR R1, [R0]
    LDR R2, =0xFFFF0FFF     ; Mask MODER6 and MODER7
    AND R1, R1, R2
    LDR R2, =0x0000A000     
    ORR R1, R1, R2
    STR R1, [R0]

    ; Route PB6 and PB7 to AF7 (USART1)
    LDR R0, =GPIOB_AFRL
    LDR R1, [R0]
    LDR R2, =0x00FFFFFF     ; Clear AFRL6 and AFRL7
    AND R1, R1, R2
    LDR R2, =0x77000000     ; AF7 = 0x7 for both pins
    ORR R1, R1, R2
    STR R1, [R0]

    ; Baud rate generator setup for 9600 bps:
    ; With f_CK = 16 MHz: USARTDIV = 16,000,000 / (16 * 9600) = 104.1667
    ; Mantissa = 104 = 0x68, Fraction = round(0.1667 * 16) = 3 = 0x03 -> BRR = 0x0683
    LDR R0, =USART1_BRR
    LDR R1, =0x0683
    STR R1, [R0]

    ; Enable USART1 with transmitter and receiver active (UE | TE | RE)
    LDR R0, =USART1_CR1
    LDR R1, =0x200C         ; Bit 13 (UE), Bit 3 (TE), Bit 2 (RE)
    STR R1, [R0]

    POP {R0-R2, PC}        

; ==============================================================================
; BT_Get_Data: Non-blocking poll of RX data register. Returns character in R0,
; or returns 0 if no new byte has arrived.
; ==============================================================================
BT_Get_Data
    LDR R1, =USART1_SR
    LDR R2, [R1]
    TST R2, #0x20           ; Check RXNE (Read Data Register Not Empty)
    BEQ no_bt_data          
    
    LDR R1, =USART1_DR
    LDR R0, [R1]            ; Read received byte (clears RXNE)
    BX LR                  

no_bt_data
    MOV R0, #0              
    BX LR                   
	
; ==============================================================================
; BT_Send_Char: Transmits a single byte (R0) over USART1, blocking until TX buffer is ready
; ==============================================================================
BT_Send_Char
    PUSH {R1, R2, LR}
    LDR R1, =USART1_BASE    
wait_tx
    LDR R2, [R1, #0x00]      ; Read USART1_SR
    TST R2, #0x80            ; Check TXE (Transmit Data Register Empty)
    BEQ wait_tx              
    STR R0, [R1, #0x04]      ; Write to USART1_DR
    POP {R1, R2, PC}

; ==============================================================================
; BT_Send_String: Transmits a null-terminated ASCII string (pointer in R0)
; ==============================================================================
BT_Send_String
    PUSH {R0, R1, R2, LR}
    MOV R1, R0
send_str_loop
    LDRB R0, [R1], #1        
    CMP R0, #0               
    BEQ send_str_done
    BL BT_Send_Char          
    B send_str_loop
send_str_done
    POP {R0, R1, R2, PC}

; ==============================================================================
; BT_Send_Number: Converts an unsigned integer (R0) to ASCII and sends it
; ==============================================================================
BT_Send_Number
    PUSH {R0-R5, LR}
    CMP R0, #0               ; Fast-path zero value
    BNE btsn_start
    MOV R0, #'0'            
    BL BT_Send_Char
    B btsn_end

btsn_start
    MOV R1, #10              
    MOV R2, #0               ; Digit count index
    SUB SP, SP, #16          ; Temporary stack frame for digit storage
btsn_loop
    CMP R0, #0               
    BEQ btsn_send
    UDIV R3, R0, R1          ; R3 = R0 / 10
    MLS R4, R3, R1, R0       ; R4 = R0 - (R3 * 10) = R0 % 10
    ADD R4, R4, #'0'         ; Convert to ASCII char
    STRB R4, [SP, R2]        
    ADD R2, R2, #1           
    MOV R0, R3               
    B btsn_loop
btsn_send
    ; Pop and transmit digits in forward order (MSB to LSB)
    SUB R2, R2, #1           
    LDRB R0, [SP, R2]
    BL BT_Send_Char          
    CMP R2, #0
    BNE btsn_send
    ADD SP, SP, #16          ; Restore stack pointer
btsn_end
    POP {R0-R5, PC}

; ==============================================================================
; BT_Send_Sensor_Data: Transmits a complete clinical telemetry frame:
; "HR:<bpm> SpO2:<spo2> Press:<press> RTemp:<temp> Drop:<drop>\r\n"
; ==============================================================================
BT_Send_Sensor_Data
    PUSH {R0-R3, LR}

    ; 1. Heart Rate (BPM)
    LDR R0, =str_hr
    BL BT_Send_String
    LDR R0, =bpm_current
    LDR R0, [R0]
    BL BT_Send_Number

    ; 2. Blood Oxygen Saturation (SpO2 %)
    LDR R0, =str_spo2
    BL BT_Send_String
    LDR R0, =spo2_current
    LDR R0, [R0]
    BL BT_Send_Number

    ; 3. Patient Bed Pressure (Velostat ADC reading)
    LDR R0, =str_press
    BL BT_Send_String
    LDR R0, =press_current
    LDR R0, [R0]
    BL BT_Send_Number

    ; 4. Room Temperature (DS18B20 integer Celsius)
    LDR R0, =str_rtemp
    BL BT_Send_String
    LDR R0, =temp_data
    LDRSH R0, [R0]           ; Load 16-bit raw signed reading
    ASRS R0, R0, #4          ; Shift out 4 fractional bits to obtain integer part
    BL BT_Send_Number

    ; 5. IV Drop Rate (Drops per minute)
    LDR R0, =str_drop
    BL BT_Send_String
    LDR R0, =Last_Rate
    LDR R0, [R0]
    BL BT_Send_Number

    ; Line terminator
    LDR R0, =str_nl
    BL BT_Send_String
    
    POP {R0-R3, PC}
    
    END