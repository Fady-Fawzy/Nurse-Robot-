	AREA |.text|, CODE, READONLY, ALIGN=2
    THUMB

; Clock and GPIO configuration registers
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU 0x30 
RCC_APB1ENR     EQU 0x40 
RCC_APB2ENR     EQU 0x44 
    
GPIOA_BASE      EQU 0x40020000
GPIOB_BASE      EQU 0x40020400  
GPIO_MODER      EQU 0x00
GPIO_ODR        EQU 0x14
    
; TIM4 registers used for microsecond pulse-width measurement
TIM4_BASE       EQU 0x40000800  
TIM_CR1         EQU 0x00
TIM_EGR         EQU 0x14
TIM_CNT         EQU 0x24
TIM_PSC         EQU 0x28
TIM_ARR         EQU 0x2C

; SYSCFG registers for external interrupt pin mapping
SYSCFG_BASE     EQU 0x40013800
SYSCFG_EXTICR2  EQU 0x0C        
    
; EXTI registers to detect falling edges from the VS1838B IR receiver
EXTI_BASE       EQU 0x40013C00
EXTI_IMR        EQU 0x00
EXTI_FTSR       EQU 0x0C
EXTI_PR         EQU 0x14
    
; NVIC interrupt set-enable register
NVIC_ISER0      EQU 0xE000E100

    EXPORT IR_Init
    EXPORT EXTI9_5_IRQHandler    
    
    IMPORT ir_command
    IMPORT ir_flag


    AREA IR_VARS, DATA, READWRITE, ALIGN=2
ir_data      DCD 0  ; 32-bit shift register holding the raw NEC frame
ir_bitcount  DCD 0  ; Bit index accumulator (0 to 32)


    AREA |.text|, CODE, READONLY, ALIGN=2

; ==============================================================================
; IR_Init: Sets up PB5 as an input with EXTI5 falling-edge interrupt and
; configures TIM4 to run at 1MHz (1 microsecond per tick)
; ==============================================================================
IR_Init FUNCTION
    PUSH {R4, LR}                  

    ; Enable peripheral clocks: GPIOA/B on AHB1, SYSCFG on APB2, TIM4 on APB1
    LDR R0, =RCC_BASE
    LDR R1, [R0, #RCC_AHB1ENR]
    ORR R1, R1, #0x03          
    STR R1, [R0, #RCC_AHB1ENR]
    
    LDR R1, [R0, #RCC_APB2ENR]
    ORR R1, R1, #(1 << 14)     ; SYSCFG clock
    STR R1, [R0, #RCC_APB2ENR]
    
    LDR R1, [R0, #RCC_APB1ENR]
    ORR R1, R1, #(1 << 2)      ; TIM4 clock
    STR R1, [R0, #RCC_APB1ENR]

    ; Configure GPIOA pin modes
    LDR R0, =GPIOA_BASE
    LDR R1, [R0, #GPIO_MODER]
    LDR R2, =0x000002A8             
    BIC R1, R1, R2             
    LDR R2, =0x00000154             
    ORR R1, R1, R2             
    STR R1, [R0, #GPIO_MODER]

    ; Configure PB5 as Input for the VS1838B demodulator output
    LDR R0, =GPIOB_BASE
    LDR R1, [R0, #GPIO_MODER]
    BIC R1, R1, #(3 << 10)     ; 00 = Input mode
    STR R1, [R0, #GPIO_MODER]

    ; Configure TIM4 timebase: 16MHz clock / (15 + 1) = 1MHz -> 1 tick = 1us
    LDR R0, =TIM4_BASE         
    LDR R1, =15                
    STR R1, [R0, #TIM_PSC]
    LDR R1, =0xFFFFFFFF        ; Max counter range
    STR R1, [R0, #TIM_ARR]
    MOV R1, #1
    STR R1, [R0, #TIM_EGR]     ; Force update generation to load prescaler
    STR R1, [R0, #TIM_CR1]     ; Start timer

    ; Route EXTI Line 5 to Port B (PB5) via SYSCFG_EXTICR2
    LDR R0, =SYSCFG_BASE
    LDR R1, [R0, #SYSCFG_EXTICR2]
    BIC R1, R1, #(0xF << 4)    ; Clear EXTI5 configuration bits
    ORR R1, R1, #(0x1 << 4)    ; Port B = 0x1
    STR R1, [R0, #SYSCFG_EXTICR2]

    ; Configure EXTI Line 5 for falling-edge detection (IR receiver pulls line LOW on carrier)
    LDR R0, =EXTI_BASE
    LDR R1, [R0, #EXTI_FTSR]
    ORR R1, R1, #(1 << 5)      
    STR R1, [R0, #EXTI_FTSR]
    LDR R1, [R0, #EXTI_IMR]    
    ORR R1, R1, #(1 << 5)      ; Unmask EXTI5 interrupt line
    STR R1, [R0, #EXTI_IMR]

    ; Enable EXTI9_5 vector in NVIC (IRQ 23)
    LDR R0, =NVIC_ISER0
    LDR R1, [R0]
    ORR R1, R1, #(1 << 23)     
    STR R1, [R0]
    
    ; Clear state variables
    LDR R0, =ir_data
    MOV R1, #0
    STR R1, [R0]
    LDR R0, =ir_bitcount
    STR R1, [R0]

    POP {R4, PC}                  
    ENDFUNC

; ==============================================================================
; EXTI9_5_IRQHandler: Interrupt handler decoding incoming NEC infrared frames
; Measures the delta time between falling edges using TIM4 counter
; ==============================================================================
EXTI9_5_IRQHandler FUNCTION
    PUSH {R4-R7, R12, LR}            

    ; Clear pending interrupt flag for Line 5 (write 1 to clear)
    LDR R0, =EXTI_BASE
    MOV R1, #(1 << 5)          
    STR R1, [R0, #EXTI_PR]

    ; Read elapsed microseconds since previous falling edge, then reset counter
    LDR R0, =TIM4_BASE        
    LDR R1, [R0, #TIM_CNT]     
    MOV R2, #0
    STR R2, [R0, #TIM_CNT]     

    ; Load current decoded frame data and bit counter
    LDR R4, =ir_data
    LDR R5, [R4]               
    LDR R6, =ir_bitcount
    LDR R7, [R6]               

    ; Check for NEC leader code: 9ms burst + 4.5ms space = ~13.5ms total interval
    LDR R2, =13000
    CMP R1, R2
    BLT Check_Bit              
    LDR R2, =14000
    CMP R1, R2
    BGT Reset_State            ; Interval exceeds valid leader burst, drop frame
    ; Valid leader code detected: re-arm bit counter and clear buffer
    MOV R5, #0                 
    MOV R7, #0                 
    B Save_State

Check_Bit
    ; Logic '0': 562.5us mark + 562.5us space = 1.125ms interval (accept 900us - 1400us)
    LDR R2, =900
    CMP R1, R2
    BLT Reset_State            ; Glitch / runt pulse
    LDR R2, =1400
    CMP R1, R2
    BLT Is_Logic_0

    ; Logic '1': 562.5us mark + 1.6875ms space = 2.25ms interval (accept 2000us - 2500us)
    LDR R2, =2000
    CMP R1, R2
    BLT Reset_State            ; Pulse duration in invalid gap between '0' and '1'
    LDR R2, =2500
    CMP R1, R2
    BGT Reset_State            ; Pulse duration too long

Is_Logic_1
    ; Shift existing bits right, insert 1 into MSB
    LSR R5, R5, #1             
    LDR R2, =0x80000000
    ORR R5, R5, R2             
    ADD R7, R7, #1             
    B Check_Done

Is_Logic_0
    ; Shift existing bits right, MSB remains 0
    LSR R5, R5, #1             
    ADD R7, R7, #1             
    B Check_Done

Check_Done
    ; Check if all 32 bits have been accumulated
    CMP R7, #32
    BNE Save_State             
    
    ; Verify NEC frame checksum:
    ; Frame format: [8-bit Address] [8-bit ~Address] [8-bit Command] [8-bit ~Command]
    ; Extract Command byte
    LSR R2, R5, #16
    AND R2, R2, #0xFF          
    
    ; Extract inverted Command byte
    LSR R3, R5, #24
    AND R3, R3, #0xFF          
    
    ; Validate: Command + ~Command must equal 0xFF
    ADD R3, R3, R2
    CMP R3, #0xFF
    BNE Reset_State            ; Parity mismatch, drop corrupt packet

    ; Frame valid: publish command byte and assert flag for main application
    LDR R0, =ir_command
    STRB R2, [R0]              
    
    LDR R0, =ir_flag
    MOV R1, #1
    STRB R1, [R0]              
    
    B Reset_State

Reset_State
    MOV R7, #0                 
    MOV R5, #0

Save_State
    STR R5, [R4]               
    STR R7, [R6]               

    POP {R4-R7, R12, PC}            
    ENDFUNC

    ALIGN
    END