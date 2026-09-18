; DS18B20 1-Wire Digital Thermometer Driver (16 MHz Core Clock)
; PA11 is configured as Open-Drain and requires an external 4.7kΩ pull-up resistor to 3.3V

; Register definitions
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU RCC_BASE + 0x30
GPIOA_BASE      EQU 0x40020000
GPIOA_MODER     EQU GPIOA_BASE + 0x00
GPIOA_OTYPER    EQU GPIOA_BASE + 0x04
GPIOA_IDR       EQU GPIOA_BASE + 0x10
GPIOA_BSRR      EQU GPIOA_BASE + 0x18

; Shared storage for raw 16-bit temperature reading
    AREA    DS_DATA, DATA, READWRITE
    ALIGN 4
    EXPORT  temp_data
temp_data   SPACE   2  ; Raw 12-bit temperature word (sign-extended to 16 bits)

    AREA    DS_CODE, CODE, READONLY
    ALIGN 4
    
    EXPORT DS18B20_Init
    EXPORT DS18B20_UpdateTemp

; ==============================================================================
; DS18B20_Init: Configures PA11 as an Open-Drain output for 1-Wire bus transactions
; ==============================================================================
DS18B20_Init FUNCTION
    PUSH {R0, R1, LR}
    
    ; Enable GPIOA peripheral clock
    LDR R0, =RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #1
    STR R1, [R0]

    ; Configure PA11 as General Purpose Output ('01')
    LDR R0, =GPIOA_MODER
    LDR R1, [R0]
    BIC R1, R1, #(3 :SHL: 22)   ; Clear mode bits 23:22
    ORR R1, R1, #(1 :SHL: 22)   
    STR R1, [R0]

    ; Set Open-Drain output type on PA11
    ; Allows both MCU and sensor to pull the bus LOW without bus contention
    LDR R0, =GPIOA_OTYPER
    LDR R1, [R0]
    ORR R1, R1, #(1 :SHL: 11)   
    STR R1, [R0]

    ; Float the bus HIGH (idle state)
    BL pin_high
    POP {R0, R1, PC}
    ENDFUNC

; ==============================================================================
; DS18B20_UpdateTemp: Triggers a temperature conversion, waits for ADC completion,
; then reads the 2-byte temperature scratchpad
; ==============================================================================
DS18B20_UpdateTemp FUNCTION
    PUSH {R0, R1, R4, LR}
    
    ; --- Phase 1: Issue Convert T command ---
    BL ds18b20_reset            ; Issue bus reset pulse
    MOVS R0, #0xCC              ; Skip ROM command (single slave on bus)
    BL ds18b20_write_byte
    MOVS R0, #0x44              ; Convert T command (initiates 12-bit ADC conversion)
    BL ds18b20_write_byte
    
    ; Wait for conversion (12-bit resolution takes up to 750ms)
    LDR R0, =750
    BL ds_delay_ms

    ; --- Phase 2: Read Scratchpad ---
    BL ds18b20_reset            
    MOVS R0, #0xCC              ; Skip ROM command
    BL ds18b20_write_byte
    MOVS R0, #0xBE              ; Read Scratchpad command
    BL ds18b20_write_byte
    
    ; Read Temperature LSB (Byte 0)
    BL ds18b20_read_byte
    MOV R4, R0                  
    
    ; Read Temperature MSB (Byte 1)
    BL ds18b20_read_byte
    LSL R0, R0, #8              
    ORR R4, R4, R0              ; Pack into 16-bit word
    
    ; Save raw reading in RAM
    LDR R1, =temp_data
    STRH R4, [R1]               
    
    POP {R0, R1, R4, PC}
    ENDFUNC

; ==============================================================================
; Bus line control helpers using atomic BSRR register writes
; ==============================================================================
pin_low
    PUSH {R0, R1, LR}
    LDR R0, =GPIOA_BSRR
    MOV R1, #(1 :SHL: 27)    ; Reset PA11 (bit 11 + 16)
    STR R1, [R0]
    POP {R0, R1, PC}

pin_high
    PUSH {R0, R1, LR}
    LDR R0, =GPIOA_BSRR
    MOV R1, #(1 :SHL: 11)    ; Set PA11 (bit 11) -> floats line to 3.3V via pull-up
    STR R1, [R0]
    POP {R0, R1, PC}

; ==============================================================================
; ds18b20_reset: Generates the 1-Wire reset pulse sequence (480us LOW, 60us wait)
; ==============================================================================
ds18b20_reset
    PUSH {R0, LR}
    BL pin_low                  
    LDR R0, =480                ; Master pull-down interval: 480us
    BL ds_delay_us                 
    BL pin_high                 ; Release bus to pull-up
    LDR R0, =60                 ; Wait 60us for slave presence pulse window
    BL ds_delay_us                 
    LDR R0, =420                ; Wait remainder of presence detection period
    BL ds_delay_us                 
    POP {R0, PC}

; ==============================================================================
; ds18b20_write_byte: Writes 8 bits onto 1-Wire bus (LSB first)
; Interrupts are briefly masked during critical edge timing
; ==============================================================================
ds18b20_write_byte
    PUSH {R1, R2, LR}
    MOVS R1, #8                 
    MOV R2, R0                  
w_loop
    LSRS R2, R2, #1             ; Shift bit to carry
    BCC write_0_bit             

    ; Transmit logic '1' slot: pull LOW for 2us, then release for >=60us
    CPSID i                     ; Guard critical timing
    BL pin_low                  
    MOVS R0, #2
    BL ds_delay_us              
    BL pin_high                 
    CPSIE i                     
    
    MOVS R0, #60
    BL ds_delay_us              
    B w_next
    
write_0_bit
    ; Transmit logic '0' slot: hold LOW for entire 60us slot
    CPSID i                     
    BL pin_low                  
    MOVS R0, #60
    BL ds_delay_us              
    BL pin_high                 
    CPSIE i                     
    
    MOVS R0, #2                 ; Recovery time between slots (tREC >= 1us)
    BL ds_delay_us              
    
w_next
    SUBS R1, R1, #1
    BNE w_loop
    POP {R1, R2, PC}

; ==============================================================================
; ds18b20_read_byte: Reads 8 bits from 1-Wire bus (LSB first)
; Master initiates slot by pulling LOW for 2us, releases, and samples at 12us
; ==============================================================================
ds18b20_read_byte
    PUSH {R1, R2, R3, LR}
    MOVS R1, #8                 
    MOVS R2, #0                 ; Received byte accumulator
    LDR R3, =GPIOA_IDR          
r_loop
    LSRS R2, R2, #1             ; Make space at MSB
    
    CPSID i                     ; Disable interrupts for jitter-free sampling
    BL pin_low                  ; Master initiate pulse
    MOVS R0, #2
    BL ds_delay_us              
    BL pin_high                 ; Release line so slave can hold LOW if transmitting '0'
    MOVS R0, #10
    BL ds_delay_us              ; Wait until 12us mark to sample
    
    LDR R0, [R3]                
    TST R0, #(1 :SHL: 11)       
    BEQ r_zero                  ; Line is LOW -> bit is '0'
    ORR R2, R2, #0x80           ; Line is HIGH -> bit is '1'
r_zero
    CPSIE i                     
    
    MOVS R0, #50                ; Wait for slot completion (total >= 60us)
    BL ds_delay_us              
    SUBS R1, R1, #1
    BNE r_loop                  
    
    MOV R0, R2                  
    POP {R1, R2, R3, PC}

; ==============================================================================
; ds_delay_us: Calibrated microsecond software delay for 16MHz clock
; ==============================================================================
ds_delay_us
    PUSH {R1, LR}
    MOVS R1, #4                 ; 4 cycles per loop = ~0.25us at 16MHz
    MUL R0, R1, R0              
    CMP R0, #0
    BEQ delay_us_end
delay_us_loop
    NOP                         
    SUBS R0, R0, #1             
    BNE delay_us_loop           
delay_us_end
    POP {R1, PC}

; ==============================================================================
; ds_delay_ms: Millisecond software delay (loops 1000us per millisecond)
; ==============================================================================
ds_delay_ms
    PUSH {R0, R1, LR}
ms_loop
    CMP R0, #0
    BEQ ms_end
    PUSH {R0}                   
    LDR R0, =1000               
    BL ds_delay_us                 
    POP {R0}                    
    SUBS R0, R0, #1             
    B ms_loop
ms_end
    POP {R0, R1, PC}
    
    END