; Clock and peripheral register addresses for I2C1 and GPIOB
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU RCC_BASE + 0x30
RCC_APB1ENR     EQU RCC_BASE + 0x40
RCC_APB1RSTR    EQU RCC_BASE + 0x20      

GPIOB_BASE      EQU 0x40020400
GPIOB_MODER     EQU GPIOB_BASE + 0x00
GPIOB_OTYPER    EQU GPIOB_BASE + 0x04
GPIOB_PUPDR     EQU GPIOB_BASE + 0x0C
GPIOB_AFRH      EQU GPIOB_BASE + 0x24    

; I2C1 register offsets
I2C1_BASE       EQU 0x40005400
I2C1_CR1        EQU I2C1_BASE + 0x00
I2C1_CR2        EQU I2C1_BASE + 0x04
I2C1_DR         EQU I2C1_BASE + 0x10
I2C1_SR1        EQU I2C1_BASE + 0x14
I2C1_SR2        EQU I2C1_BASE + 0x18
I2C1_CCR        EQU I2C1_BASE + 0x1C
I2C1_TRISE      EQU I2C1_BASE + 0x20

; Optical finger detection thresholds (raw 18-bit IR counts)
WAKE_THRESHOLD  EQU 20000       ; Minimum IR reflection indicating finger placed on sensor
SLEEP_THRESHOLD EQU 25000       ; Hysteresis threshold to prevent flapping

; MAX30102 7-bit I2C device address
MAX30102_ADDR   EQU 0x57

    AREA    MAX30102_DATA, DATA, READWRITE
    ALIGN
ir_value        SPACE   4       ; Latest unpacked 18-bit IR PPG sample
red_value       SPACE   4       ; Latest unpacked 18-bit Red PPG sample
temp_int        SPACE   1       ; Die temperature integer part (Celsius)
temp_frac       SPACE   1       ; Die temperature fractional part (0.0625 deg C steps)
    ALIGN
final_temp_c    SPACE   4
final_bpm       SPACE   4       ; Calculated heart rate (beats per minute)
final_spo2      SPACE   4       ; Calculated blood oxygen saturation (%)

; DSP algorithm pipeline variables
dsp_sample_cnt  SPACE   4       ; Running sample sequence counter
dsp_last_beat   SPACE   4       ; Sample index timestamp of the previous detected peak
dsp_ir_max      SPACE   4       ; Peak IR value in current analysis window
dsp_ir_min      SPACE   4       ; Trough IR value in current analysis window
dsp_red_max     SPACE   4       ; Peak Red value in current analysis window
dsp_red_min     SPACE   4       ; Trough Red value in current analysis window
dsp_window_cnt  SPACE   4       ; Samples accumulated in current 100-sample window
dsp_last_ir     SPACE   4       ; Previous sample value for zero-crossing detection

    ALIGN 4
bpm_hist_count  DCB 0           
    ALIGN 4
bpm_history     SPACE 24       
    ALIGN 4
spo2_hist_count DCB 0           
    ALIGN 4
spo2_history    SPACE 24       
    ALIGN 4
mtemp_hist_count DCB 0          
    ALIGN 4
mtemp_history    SPACE 24       
	ALIGN 4
led_state       SPACE 1         ; 1 = active measurement mode, 0 = low-power idle
    ALIGN 4


    AREA    MAX30102_CODE, CODE, READONLY
    EXPORT  MAX30102_Setup
    EXPORT  MAX30102_Update
    EXPORT  temp_int
    EXPORT  final_bpm
    EXPORT  final_spo2
	EXPORT  ir_value
		
	EXPORT  bpm_hist_count
    EXPORT  bpm_history
    EXPORT  spo2_hist_count
    EXPORT  spo2_history
    EXPORT  mtemp_hist_count
    EXPORT  mtemp_history
		
	EXPORT  delay
    ALIGN

; ==============================================================================
; MAX30102_Setup: High-level initialization for I2C hardware and sensor registers
; ==============================================================================
MAX30102_Setup
    PUSH {LR}
    BL DSP_Init                 ; Reset algorithm variables
    BL I2C1_Hardware_Init       ; Configure PB8/PB9 and I2C1 peripheral
    LDR R0, =500000
    BL delay                    ; Power-on stabilization delay
    BL MAX30102_Init            ; Program sensor operating modes and FIFO
    POP {PC}

; ==============================================================================
; MAX30102_Update: Periodic acquisition and signal processing step
; ==============================================================================
MAX30102_Update
    PUSH {LR}
    BL I2C_Read_FIFO            ; Read latest 6-byte sample burst from FIFO
    BL MAX30102_Read_Temp       ; Sample die temperature
    BL Process_Data             ; Run pulse peak detection and SpO2 math
    POP {PC}


; ==============================================================================
; I2C1_Hardware_Init: Configures PB8 (SCL) and PB9 (SDA) for 100kHz standard mode
; ==============================================================================
I2C1_Hardware_Init
    PUSH {R0, R1, LR}
    
    ; Enable clocks for GPIOB (AHB1) and I2C1 (APB1 bit 21)
    LDR R0, =RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #(1 :SHL: 1)     
    STR R1, [R0]
    LDR R0, =RCC_APB1ENR
    LDR R1, [R0]
    ORR R1, R1, #(1 :SHL: 21)     
    STR R1, [R0]

    ; Force soft reset on I2C1 to clear any bus hang
    LDR R0, =I2C1_CR1
    LDR R1, =(1 :SHL: 15)         
    STR R1, [R0]                   
    MOVS R1, #0
    STR R1, [R0]                  

    ; Configure PB8 and PB9 for Alternate Function mode ('10')
    LDR R0, =GPIOB_MODER
    LDR R1, [R0]
    BIC R1, R1, #(0xF :SHL: 16)
    ORR R1, R1, #(0xA :SHL: 16)
    STR R1, [R0]
    
    ; Configure PB8 and PB9 as Open-Drain
    LDR R0, =GPIOB_OTYPER
    LDR R1, [R0]
    ORR R1, R1, #(3 :SHL: 8)
    STR R1, [R0]
    
    ; Enable internal pull-up resistors on PB8 and PB9
    LDR R0, =GPIOB_PUPDR
    LDR R1, [R0]
    BIC R1, R1, #(0xF :SHL: 16)
    ORR R1, R1, #(0x5 :SHL: 16)
    STR R1, [R0]
    
    ; Assign AF4 (I2C1) to PB8 and PB9 in AFRH
    LDR R0, =GPIOB_AFRH
    LDR R1, [R0]
    BIC R1, R1, #0xFF             
    ORR R1, R1, #0x44            
    STR R1, [R0]
    
    ; Timing configuration: Standard Mode (100kHz) with 16MHz APB1 clock
    LDR R0, =I2C1_CR1
    MOVS R1, #0
    STR R1, [R0]
    LDR R0, =I2C1_CR2
    MOVS R1, #16                 ; FREQ = 16 MHz
    STR R1, [R0]
    LDR R0, =I2C1_CCR
    MOVS R1, #80                 ; Thigh = Tlow = 80 * (1/16MHz) = 5us -> 100kHz
    STR R1, [R0]
    LDR R0, =I2C1_TRISE
    MOVS R1, #17                 ; (1000ns / 62.5ns) + 1 = 17
    STR R1, [R0]

    ; Enable peripheral
    LDR R0, =I2C1_CR1
    MOVS R1, #1                  ; Set PE bit
    STR R1, [R0]
    POP {R0, R1, PC}


; ==============================================================================
; Process_Data: Real-time PPG signal processing:
; - Dynamic power management based on finger presence
; - Midpoint crossing threshold for peak detection (Heart Rate)
; - AC/DC ratio calculation over a 100-sample window (SpO2)
; ==============================================================================
Process_Data
    PUSH {R4-R11, LR}

    LDR R0, =ir_value
    LDR R4, [R0]                

    ; Check whether sensor is currently in active or low-power state
    LDR R0, =led_state
    LDRB R1, [R0]
    CMP R1, #1                 
    BEQ check_sleep

check_wake                   
    ; Idle state: check if finger is placed (IR reading exceeds wake threshold)
    LDR R2, =WAKE_THRESHOLD
    CMP R4, R2
    BLO skip_calculations       
    B wake_up                  

check_sleep                   
    ; Active state: check if finger was lifted
    LDR R2, =SLEEP_THRESHOLD
    CMP R4, R2
    BHS continue_processing     

go_to_sleep
    ; Finger removed: throttle LED drive current to reduce thermal dissipation and power
    BL Set_LED_Low              
    LDR R0, =led_state
    MOV R1, #0
    STRB R1, [R0]
    BL DSP_Init                 
    B skip_calculations

wake_up
    ; Finger detected: boost LED currents to nominal clinical levels
    BL Set_LED_High             
    LDR R0, =led_state
    MOV R1, #1
    STRB R1, [R0]
    BL DSP_Init                 
    B skip_calculations         

skip_calculations
    ; Invalidate readings when no finger is placed
    MOVS R1, #0
    LDR R0, =final_bpm
    STR R1, [R0]
    LDR R0, =final_spo2
    STR R1, [R0]
    POP {R4-R11, PC}            
	LTORG

continue_processing
    LDR R0, =temp_int
    LDRB R4, [R0]
    STR R4, [R0]                

    ; Fetch raw PPG channel values
    LDR R0, =ir_value
    LDR R4, [R0]               
    LDR R0, =red_value
    LDR R5, [R0]                
    
    ; Advance sequence counter
    LDR R0, =dsp_sample_cnt
    LDR R6, [R0]
    ADD R6, R6, #1              
    STR R6, [R0]

    ; Track dynamic min/max peaks for IR channel
    LDR R0, =dsp_ir_max
    LDR R7, [R0]
    CMP R4, R7
    IT HI
    STRHI R4, [R0]              
    LDR R0, =dsp_ir_min
    LDR R8, [R0]
    CMP R4, R8
    IT CC
    STRCC R4, [R0]              

    ; Track dynamic min/max peaks for Red channel
    LDR R0, =dsp_red_max
    LDR R9, [R0]
    CMP R5, R9
    IT HI
    STRHI R5, [R0]
    LDR R0, =dsp_red_min
    LDR R10, [R0]
    CMP R5, R10
    IT CC
    STRCC R5, [R0]

    ; Midpoint threshold: (Max + Min) / 2
    ADD R11, R7, R8
    LSR R11, R11, #1            
    
    ; Zero-crossing peak detection
    LDR R0, =dsp_last_ir
    LDR R1, [R0]
    STR R4, [R0]                
    
    CMP R1, R11
    BHS skip_beat               ; Signal did not cross from below
    CMP R4, R11
    BLO skip_beat               
    
    ; Valid heartbeat edge detected: calculate elapsed samples since previous beat
    LDR R0, =dsp_last_beat
    LDR R1, [R0]
    STR R6, [R0]                
    SUBS R2, R6, R1             ; Delta samples
    CMP R2, #5                  ; Debounce limit against spurious noise
    BLS skip_beat
    
    ; Heart rate math: BPM = (Sampling_Rate * 60) / Delta_Samples
    LDR R0, =1200
    UDIV R0, R0, R2             
    CMP R0, #200                ; Upper clinical boundary
    BHI skip_beat
    CMP R0, #30                 ; Lower clinical boundary
    BLO skip_beat
    LDR R1, =final_bpm
    STR R0, [R1]                

skip_beat
    ; Accumulate window for SpO2 calculation (evaluated every 100 samples)
    LDR R0, =dsp_window_cnt
    LDR R1, [R0]
    ADD R1, R1, #1
    STR R1, [R0]
    CMP R1, #100                
    BLO dsp_done
    
    ; Reset window counter
    MOVS R1, #0
    STR R1, [R0]
    
    ; Compute AC components: AC = Max - Min
    SUBS R9, R9, R10            ; RED AC
    SUBS R7, R7, R8             ; IR AC
    
    ; Guard against divide-by-zero
    CMP R7, #0
    BEQ reset_minmax
    CMP R10, #0
    BEQ reset_minmax
    
    ; Ratio of Ratios: R = (RED_AC / RED_DC) / (IR_AC / IR_DC)
    ; Scaled integer formulation: R = (RED_AC * IR_DC * 100) / (IR_AC * RED_DC)
    MUL R0, R9, R8
    MOV R1, #100                
    MUL R0, R0, R1
    MUL R1, R7, R10
    UDIV R2, R0, R1
    
    ; Empirical SpO2 linear approximation: SpO2 = 104 - 0.17 * R
    MOV R0, #17
    MUL R2, R2, R0
    MOV R0, #100
    UDIV R2, R2, R0
    MOV R0, #104
    SUBS R0, R0, R2
    
    ; Clamp saturation ceiling at 100%
    CMP R0, #100
    IT HI
    MOVHI R0, #100
    LDR R1, =final_spo2
    STR R0, [R1]                

reset_minmax
    BL DSP_Init

dsp_done
    POP {R4-R11, PC}


; ==============================================================================
; DSP_Init: Clears min/max accumulators for a new window
; ==============================================================================
DSP_Init
    PUSH {R0, R1, LR}
    LDR R0, =dsp_ir_max
    MOVS R1, #0
    STR R1, [R0]
    LDR R0, =dsp_red_max
    STR R1, [R0]
    LDR R0, =dsp_ir_min
    LDR R1, =0x0003FFFF         ; Initialize minimums to maximum 18-bit range
    STR R1, [R0]
    LDR R0, =dsp_red_min
    STR R1, [R0]
    POP {R0, R1, PC}


; ==============================================================================
; MAX30102_Init: Configures sensor FIFO, sample rate, and default LED currents
; ==============================================================================
MAX30102_Init
    PUSH {R0, R1, R2, LR}
    
    ; Soft reset command (MODE_CONFIG = 0x40)
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x09
    MOVS R2, #0x40
    BL I2C_Write
    LDR R0, =100000
    BL delay
    
    ; Clear FIFO read/write/overflow pointers
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x04
    MOVS R2, #0
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x05
    MOVS R2, #0
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x06
    MOVS R2, #0
    BL I2C_Write
    
    ; Mode configuration: SpO2 Mode (RED and IR channels enabled)
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x09
    MOVS R2, #0x03
    BL I2C_Write
    
    ; SpO2 configuration: ADC range 4096nA, 100 samples/s, 18-bit resolution (411us pulse)
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0A
    MOVS R2, #0x67              
    BL I2C_Write
    
    ; Default LED pulse amplitudes (~7.2mA current)
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0C              ; LED1 (Red)
    MOVS R2, #0x24              
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0D              ; LED2 (IR)
    MOVS R2, #0x24              
    BL I2C_Write
    POP {R0, R1, R2, PC}

; ==============================================================================
; Low-level I2C transaction helpers
; ==============================================================================

I2C_Start
    PUSH {R0, R1, LR}
    LDR R0, =I2C1_CR1
    LDR R1, [R0]
    ORR R1, R1, #(1 :SHL: 8)    ; Assert START condition
    STR R1, [R0]
    LDR R0, =I2C1_SR1
wait_start
    LDR R1, [R0]
    TST R1, #(1 :SHL: 0)        ; Poll SB flag
    BEQ wait_start
    POP {R0, R1, PC}

I2C_Stop
    PUSH {R0, R1, LR}
    LDR R0, =I2C1_CR1
    LDR R1, [R0]
    ORR R1, R1, #(1 :SHL: 9)    ; Assert STOP condition
    STR R1, [R0]
    POP {R0, R1, PC}

I2C_WriteByte
    PUSH {R1, R2, LR}
    LDR R1, =I2C1_SR1
wait_txe
    LDR R2, [R1]
    TST R2, #(1 :SHL: 7)        ; Poll TXE (Transmit Data Register Empty)
    BEQ wait_txe
    LDR R1, =I2C1_DR
    STR R0, [R1]                ; Write data byte
    LDR R1, =I2C1_SR1
wait_btf
    LDR R2, [R1]
    TST R2, #(1 :SHL: 2)        ; Poll BTF (Byte Transfer Finished)
    BEQ wait_btf
    POP {R1, R2, PC}

I2C_Read_ACK
    PUSH {R1, R2, LR}
    LDR R1, =I2C1_CR1
    LDR R2, [R1]
    ORR R2, R2, #(1 :SHL: 10)   ; Enable ACK generation
    STR R2, [R1]
    LDR R1, =I2C1_SR1
wait_rxne_ack
    LDR R2, [R1]
    TST R2, #(1 :SHL: 6)        ; Poll RXNE (Receive Data Register Not Empty)
    BEQ wait_rxne_ack
    LDR R1, =I2C1_DR
    LDR R0, [R1]                
    AND R0, R0, #0xFF           
    POP {R1, R2, PC}

I2C_Read_NACK
    PUSH {R1, R2, LR}
    LDR R1, =I2C1_CR1
    LDR R2, [R1]
    BIC R2, R2, #(1 :SHL: 10)   ; Clear ACK (send NACK to terminate slave transmission)
    ORR R2, R2, #(1 :SHL: 9)    ; Schedule STOP condition
    STR R2, [R1]
    LDR R1, =I2C1_SR1
wait_rxne_nack
    LDR R2, [R1]
    TST R2, #(1 :SHL: 6)        
    BEQ wait_rxne_nack
    LDR R1, =I2C1_DR
    LDR R0, [R1]                
    AND R0, R0, #0xFF           
    POP {R1, R2, PC}

I2C_Write
    PUSH {R3, LR}
    BL I2C_Start
    LDR R3, =I2C1_DR
    LSL R0, R0, #1              ; Address << 1 for Write (R/W bit = 0)
    STR R0, [R3]
    LDR R3, =I2C1_SR1
wait_addr_w
    LDR R0, [R3]
    TST R0, #(1 :SHL: 1)        ; Poll ADDR flag
    BEQ wait_addr_w
    LDR R3, =I2C1_SR2
    LDR R0, [R3]                ; Read SR2 to clear ADDR flag
    MOV R0, R1                  
    BL I2C_WriteByte            ; Write sub-address register
    MOV R0, R2                  
    BL I2C_WriteByte            ; Write register payload
    BL I2C_Stop
    POP {R3, PC}

; ==============================================================================
; I2C_Read_FIFO: Burst-reads 6 bytes from FIFO_DATA register (0x07)
; Bytes 0-2: Red channel (18-bit)
; Bytes 3-5: IR channel (18-bit)
; ==============================================================================
I2C_Read_FIFO
    PUSH {R4-R9, LR}
    
    ; Address pointer setup: write register index 0x07
    BL I2C_Start
    LDR R0, =I2C1_DR
    MOVS R1, #0xAE              ; Slave address + Write
    STR R1, [R0]
    LDR R0, =I2C1_SR1
wait_fifo_w
    LDR R1, [R0]
    TST R1, #(1 :SHL: 1)
    BEQ wait_fifo_w
    LDR R1, =I2C1_SR2
    LDR R1, [R1]
    MOVS R0, #0x07              ; FIFO_DATA address
    BL I2C_WriteByte
    
    ; Repeated Start for multi-byte read
    BL I2C_Start
    LDR R0, =I2C1_DR
    MOVS R1, #0xAF              ; Slave address + Read
    STR R1, [R0]
    LDR R0, =I2C1_SR1
wait_fifo_r
    LDR R1, [R0]
    TST R1, #(1 :SHL: 1)
    BEQ wait_fifo_r
    LDR R1, =I2C1_SR2
    LDR R1, [R1]
    
    ; Read 6 bytes sequentially (ACK for bytes 1-5, NACK for final byte)
    BL I2C_Read_ACK
    MOV R4, R0                 ; RED Byte 1 (MSB)
    BL I2C_Read_ACK
    MOV R5, R0                 ; RED Byte 2
    BL I2C_Read_ACK
    MOV R6, R0                 ; RED Byte 3 (LSB)
    BL I2C_Read_ACK
    MOV R7, R0                 ; IR Byte 1 (MSB)
    BL I2C_Read_ACK
    MOV R8, R0                 ; IR Byte 2
    BL I2C_Read_NACK
    MOV R9, R0                 ; IR Byte 3 (LSB)
    BL I2C_Stop
    
    ; Assemble 18-bit RED value
    AND R4, R4, #0x03           ; Upper 6 bits are unused
    LSL R4, R4, #16
    LSL R5, R5, #8
    ORR R4, R4, R5
    ORR R4, R4, R6
    LDR R0, =red_value
    STR R4, [R0]
    
    ; Assemble 18-bit IR value
    AND R7, R7, #0x03
    LSL R7, R7, #16
    LSL R8, R8, #8
    ORR R7, R7, R8
    ORR R7, R7, R9
    LDR R0, =ir_value
    STR R7, [R0]
    
    POP {R4-R9, PC}

; ==============================================================================
; MAX30102_Read_Temp: Initiates die temperature conversion and reads scratchpad
; ==============================================================================
MAX30102_Read_Temp
    PUSH {R4, R5, LR}
    
    ; Assert TEMP_EN in DIE_TEMP_CONFIG (0x21)
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x21
    MOVS R2, #0x01
    BL I2C_Write
    LDR R0, =500000 
    BL delay                    ; Allow thermal ADC conversion time (~29ms)
    
    ; Read Temperature Integer (0x1F) and Fraction (0x20)
    BL I2C_Start
    LDR R0, =I2C1_DR
    MOVS R1, #0xAE              
    STR R1, [R0]
    LDR R0, =I2C1_SR1
wait_temp_w
    LDR R1, [R0]
    TST R1, #(1 :SHL: 1)
    BEQ wait_temp_w
    LDR R1, =I2C1_SR2
    LDR R1, [R1]                
    MOVS R0, #0x1F              ; Pointer to integer register
    BL I2C_WriteByte
    
    BL I2C_Start
    LDR R0, =I2C1_DR
    MOVS R1, #0xAF              ; Read mode
    STR R1, [R0]
    LDR R0, =I2C1_SR1
wait_temp_r
    LDR R1, [R0]
    TST R1, #(1 :SHL: 1)
    BEQ wait_temp_r
    LDR R1, =I2C1_SR2
    LDR R1, [R1]                
    
    BL I2C_Read_ACK             
    MOV R4, R0                  ; Integer part (deg C)
    BL I2C_Read_NACK            
    MOV R5, R0                  ; Fractional part
    BL I2C_Stop
    
    LDR R0, =temp_int
    STRB R4, [R0]
    LDR R0, =temp_frac
    STRB R5, [R0]
    POP {R4, R5, PC}

; ==============================================================================
; Dynamic LED drive current configurations
; ==============================================================================
Set_LED_High
    PUSH {R0-R3, LR}
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0A
    MOVS R2, #0x67              ; Nominal sample rate
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0C
    MOVS R2, #0x24              ; ~7.2mA nominal drive
    BL I2C_Write
    BL Flush_MAX_FIFO           
    POP {R0-R3, PC}

Set_LED_Low
    PUSH {R0-R3, LR}
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0A
    MOVS R2, #0x02              ; Minimal power mode
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x0C
    MOVS R2, #0x02              ; Minimum drive current (~0.4mA)
    BL I2C_Write
    BL Flush_MAX_FIFO
    POP {R0-R3, PC}

; ==============================================================================
; Flush_MAX_FIFO: Clears FIFO pointers to purge stale samples
; ==============================================================================
Flush_MAX_FIFO
    PUSH {R0-R3, LR}
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x04             ; FIFO_WR_PTR
    MOVS R2, #0x00
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x05             ; OVF_COUNTER
    MOVS R2, #0x00
    BL I2C_Write
    MOVS R0, #MAX30102_ADDR
    MOVS R1, #0x06             ; FIFO_RD_PTR
    MOVS R2, #0x00
    BL I2C_Write
    POP {R0-R3, PC}

; ==============================================================================
; delay: Software spin loop
; ==============================================================================
delay
    PUSH {R0, LR}
    CMP R0, #0
    BEQ delay_end
delay_loop
    NOP
    SUBS R0, R0, #1
    BNE delay_loop
delay_end
    POP {R0, PC}

    END