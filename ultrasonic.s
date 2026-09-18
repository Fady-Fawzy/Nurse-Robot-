; Register definitions for GPIO and Clock management
GPIOB_BASE      EQU 0x40020400
GPIOA_BASE      EQU 0x40020000
GPIOB_MODER     EQU GPIOB_BASE + 0x00
GPIOA_MODER     EQU GPIOA_BASE + 0x00
GPIOB_IDR       EQU GPIOB_BASE + 0x10
GPIOB_BSRR      EQU GPIOB_BASE + 0x18
GPIOA_BSRR      EQU 0x40020018
GPIOA_ODR       EQU GPIOA_BASE + 0x14
GPIOB_ODR       EQU GPIOB_BASE + 0x14	

; Clock enable registers
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU 0x30 
RCC_APB1ENR     EQU 0x40 
RCC_APB2ENR     EQU 0x44 
    
GPIO_MODER      EQU 0x00
GPIO_AFRL       EQU 0x20

; Shared variable holding the measured distance
    AREA    HC_DATA, DATA, READWRITE
    ALIGN 4
    EXPORT  distance_cm
distance_cm SPACE   4   ; Calculated distance in centimeters

    AREA    |.text|, CODE, READONLY
    ALIGN 4
    
    EXPORT HCSR04_Init
    EXPORT HCSR04_Measure
    EXPORT hc_delay_us

; ==============================================================================
; HCSR04_Init: Sets up PB10 as Trigger (Output) and PB2 as Echo (Input)
; ==============================================================================
HCSR04_Init FUNCTION
    PUSH {R0, R1, LR}
    
    ; Enable clocks for GPIOA and GPIOB on AHB1
    LDR R0, =0x40023830      ; RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #0x03        
    STR R1, [R0]

    ; Configure GPIOA pin modes (chassis drive outputs)
    LDR R0, =0x40020000      ; GPIOA_MODER
    LDR R1, [R0]
    LDR R2, =0xFFFFFC03       
    AND R1, R1, R2
    LDR R2, =0x00000154       
    ORR R1, R1, R2
    STR R1, [R0]

    ; Clear GPIOA output data lines
    LDR R0, =0x40020014      ; GPIOA_ODR
    LDR R1, [R0]
    BIC R1, R1, #0x1E        
    STR R1, [R0]

    ; Configure GPIOB pin modes
    LDR R0, =0x40020400      ; GPIOB_MODER
    LDR R1, [R0]
    LDR R2, =0xFFCFFFCF       
    AND R1, R1, R2
    LDR R2, =0x00100000       
    ORR R1, R1, R2
    STR R1, [R0]

    ; Explicitly set PB10 to Output (Trigger) and PB2 to Input (Echo)
    LDR R0, =GPIOB_MODER
    LDR R1, [R0]
    BIC R1, R1, #(3 :SHL: 20)   ; Clear PB10 mode
    BIC R1, R1, #(3 :SHL: 4)    ; Clear PB2 mode (00 = Input)
    ORR R1, R1, #(1 :SHL: 20)   ; Set PB10 mode to Output (01)
    STR R1, [R0]

    ; Ensure Trigger pin starts LOW
    LDR R0, =GPIOB_BSRR
    MOV R1, #(1 :SHL: 26)       ; Reset PB10 (bit 10 + 16)
    STR R1, [R0]

    POP {R0, R1, PC}
    ENDFUNC


; ==============================================================================
; HCSR04_Measure: Triggers sensor ping, times the echo pulse width, and
; converts the duration to distance in centimeters
; ==============================================================================
HCSR04_Measure FUNCTION
    PUSH {R0-R5, LR}
    
    ; 1. Generate 10us HIGH trigger pulse on PB10
    LDR R3, =GPIOB_BSRR
    MOV R1, #(1 :SHL: 10)       ; Set PB10 HIGH
    STR R1, [R3]
    
    MOVS R0, #10                
    BL hc_delay_us              ; Hold for 10 microseconds
    
    MOV R1, #(1 :SHL: 26)       ; Pull PB10 back LOW
    STR R1, [R3]
    
    ; 2. Wait for Echo pin (PB2) to transition HIGH
    LDR R3, =GPIOB_IDR
    LDR R5, =60000              ; Guard against hang if sensor disconnected
wait_rise
    SUBS R5, R5, #1
    BEQ measure_error           ; Timed out waiting for pulse start
    LDR R0, [R3]
    TST R0, #(1 :SHL: 2)        ; Sample PB2
    BEQ wait_rise               

    ; 3. Pulse active: count iterations until PB2 returns LOW
    MOVS R4, #0                 ; Reset pulse width accumulator
    LDR R5, =30000              ; Max timeout limit (~5m range ceiling)
wait_fall
    LDR R0, [R3]                
    TST R0, #(1 :SHL: 2)        ; Check if echo line is still HIGH
    BEQ calc_dist               ; Line went LOW: capture finished
    ADD R4, R4, #1              
    CMP R4, R5                  
    BGE calc_dist               ; Exceeded timeout, compute with clamped count
    
    ; Calibration NOPs: tuned so one loop takes ~1us at 16MHz clock
    NOP                         
    NOP                         
    NOP                         
    NOP                         
    NOP                         
    NOP                         
    B wait_fall                 

calc_dist
    ; 4. Distance math:
    ; Speed of sound is ~340 m/s (29 us/cm). With two-way flight time,
    ; distance (cm) = pulse_width_us / 58.
    MOVS R1, #58
    UDIV R4, R4, R1            
    
save_dist
    LDR R1, =distance_cm
    STR R4, [R1]
    B measure_end

measure_error
    ; Store 0 cm on timeout / failure
    MOVS R4, #0
    LDR R1, =distance_cm
    STR R4, [R1]

measure_end
    POP {R0-R5, PC}
    ENDFUNC


; ==============================================================================
; hc_delay_us: Calibrated software delay loop for 16MHz SYSCLK
; ==============================================================================
hc_delay_us
    PUSH {R1, LR}
    MOVS R1, #4                 ; ~4 clock cycles per loop iteration
    MUL R0, R1, R0              
    CMP R0, #0
    BEQ delay_us_end
delay_us_loop
    NOP                         
    SUBS R0, R0, #1             
    BNE delay_us_loop           
delay_us_end
    POP {R1, PC}

EXIT
    B EXIT

    END
