; Peripheral base addresses for Clock, GPIO, and SysTick
RCC_AHB1ENR     EQU 0x40023830

GPIOA_BASE      EQU 0x40020000
GPIOA_MODER     EQU GPIOA_BASE + 0x00
GPIOA_BSRR      EQU GPIOA_BASE + 0x18

GPIOB_BASE      EQU 0x40020400
GPIOB_MODER     EQU GPIOB_BASE + 0x00
GPIOB_IDR       EQU GPIOB_BASE + 0x10
GPIOB_BSRR      EQU GPIOB_BASE + 0x18

; SysTick core timer registers (used as a 1-second interval timebase)
SYSTICK_CTRL    EQU 0xE000E010
SYSTICK_LOAD    EQU 0xE000E014
SYSTICK_VAL     EQU 0xE000E018


    AREA    |.data|, DATA, READWRITE
    ALIGN 4
Last_Rate       DCD 0       ; Calculated drop rate (drops/minute)
Total_Drops     DCD 0       ; Cumulative drop counter
Current_Count   DCD 0       ; Drop counter in the active 10-second sampling window
Sec_Count       DCD 0       ; Second counter (0 to 10)
Prev_State      DCD 1       ; Previous optical line state (1 = clear, 0 = drop detected)
Prev_Time       DCD 0       ; Reserved timestamp placeholder


    AREA    |.text|, CODE, READONLY
    EXPORT  IR_Drop_Init
    EXPORT  IR_Drop_Update
    EXPORT  Last_Rate
    EXPORT  Current_Count
    EXPORT  Total_Drops
    EXPORT  Sec_Count
    ALIGN 4


; ==============================================================================
; IR_Drop_Init: Configures GPIO pins for the optical IV gate and starts SysTick
; PA12: IR LED anode driver (Output)
; PB3 : IR phototransistor collector (Input)
; PB4 : Alarm buzzer / warning LED (Output)
; ==============================================================================
IR_Drop_Init FUNCTION
    PUSH {R0-R2, LR}

    ; Enable GPIOA and GPIOB peripheral clocks
    LDR R0, =RCC_AHB1ENR
    LDR R1, [R0]
    ORR R1, R1, #3             
    STR R1, [R0]

    ; Set PA12 as Output to drive the optical emitter
    LDR R0, =GPIOA_MODER
    LDR R1, [R0]
    LDR R2, =0x03000000         
    BIC R1, R1, R2
    LDR R2, =0x01000000         
    ORR R1, R1, R2
    STR R1, [R0]

    ; Configure PB3 as Input (sensor) and PB4 as Output (indicator/buzzer)
    LDR R0, =GPIOB_MODER
    LDR R1, [R0]
    LDR R2, =0x000003C0         
    BIC R1, R1, R2
    LDR R2, =0x00000100        
    ORR R1, R1, R2
    STR R1, [R0]

    ; Energize the IR transmitter LED
    LDR R0, =GPIOA_BSRR
    MOV R1, #(1 :SHL: 12)
    STR R1, [R0]

    ; Set up SysTick to roll over every 1 second (16,000,000 clock cycles at 16 MHz)
    LDR R0, =SYSTICK_LOAD
    LDR R1, =15999999           ; 16M - 1
    STR R1, [R0]
    LDR R0, =SYSTICK_VAL
    MOV R1, #0                  ; Clear current value
    STR R1, [R0]
    LDR R0, =SYSTICK_CTRL
    MOV R1, #5                  ; Enable SysTick with processor core clock (CLKSOURCE | ENABLE)
    STR R1, [R0]

    POP {R0-R2, PC}
    ENDFUNC


; ==============================================================================
; IR_Drop_Update: Periodic routine that samples the optical beam state, detects
; falling drops, and recomputes the flow rate (DPM) every 10 seconds
; ==============================================================================
IR_Drop_Update FUNCTION
    PUSH {R4-R7, LR}           

    ; Check if SysTick has reached zero since last poll (COUNTFLAG is bit 16)
    LDR R0, =SYSTICK_CTRL
    LDR R1, [R0]
    TST R1, #(1 :SHL: 16)      
    BEQ check_ir               ; Less than 1 second elapsed, skip window logic

    ; 1 second elapsed: advance second counter
    LDR R0, =Sec_Count
    LDR R5, [R0]
    ADD R5, R5, #1              
    STR R5, [R0]
    
    ; Check if our 10-second sampling interval is complete
    CMP R5, #10                 
    BLT check_ir                

    ; Calculate flow rate: (drops in 10s) * 6 = drops per minute (DPM)
    LDR R0, =Current_Count
    LDR R4, [R0]              
    MOV R2, #6                  
    MUL R3, R4, R2              
    
    LDR R0, =Last_Rate          
    STR R3, [R0]               
    
    ; Reset the second counter and window accumulator for next interval
    MOV R5, #0                  
    LDR R0, =Sec_Count
    STR R5, [R0]
    MOV R4, #0                  
    LDR R0, =Current_Count
    STR R4, [R0]

check_ir
    ; Sample the IR phototransistor line on PB3
    LDR R0, =GPIOB_IDR
    LDR R1, [R0]
    TST R1, #(1 :SHL: 3)       
    BEQ ir_is_blocked          ; LOW level means optical beam is occluded by a falling drop
    B ir_is_clear              

ir_is_blocked
    ; Beam blocked: verify this is a fresh edge transition (Prev_State was 1)
    LDR R0, =Prev_State
    LDR R6, [R0]
    CMP R6, #1                 
    BNE end_update             ; Drop still passing through, avoid duplicate count

    ; New drop confirmed: increment window count and cumulative total
    LDR R0, =Current_Count
    LDR R4, [R0]
    ADD R4, R4, #1              
    STR R4, [R0]               

    LDR R0, =Total_Drops
    LDR R7, [R0]
    ADD R7, R7, #1              
    STR R7, [R0]                
    
    ; Mark beam state as blocked (0)
    LDR R0, =Prev_State
    MOV R6, #0                  
    STR R6, [R0]

    ; Turn off alarm pin (PB4 reset)
    LDR R0, =GPIOB_BSRR
    MOV R1, #(1 :SHL: 20)      ; PB4 reset bit (4 + 16)
    STR R1, [R0]
    B end_update

ir_is_clear
    ; Beam has cleared: re-arm transition detector
    LDR R0, =Prev_State
    MOV R6, #1                 
    STR R6, [R0]

    ; Turn on indicator pin (PB4 set)
    LDR R0, =GPIOB_BSRR
    MOV R1, #(1 :SHL: 4)        
    STR R1, [R0]

end_update
    POP {R4-R7, PC}            
    ENDFUNC

    END