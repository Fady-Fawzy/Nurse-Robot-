    AREA    |.text|, CODE, READONLY
    ALIGN 4
    
    EXPORT ARM_INIT

; Base addresses and register offsets for Clock and GPIO
GPIOB_BASE      EQU 0x40020400
GPIOA_BASE      EQU 0x40020000
GPIO_MODER      EQU 0x00
GPIO_AFRL       EQU 0x20
RCC_BASE        EQU 0x40023800
RCC_AHB1ENR     EQU 0x30 
RCC_APB1ENR     EQU 0x40 
RCC_APB2ENR     EQU 0x44 

; TIM3 register offsets for 4-channel servo PWM generation
TIM3_BASE       EQU 0x40000400  
TIM_CR1         EQU 0x00
TIM_EGR         EQU 0x14
TIM_CCMR1       EQU 0x18
TIM_CCMR2       EQU 0x1C
TIM_CCER        EQU 0x20
TIM_PSC         EQU 0x28
TIM_ARR         EQU 0x2C
TIM_CCR1        EQU 0x34        
TIM_CCR2        EQU 0x38       
TIM_CCR3        EQU 0x3C       
TIM_CCR4        EQU 0x40

; ==============================================================================
; ARM_INIT: Configures TIM3 and GPIO pins (PA6, PA7, PB0, PB1) to output 50Hz PWM
; for the 4-DOF robotic arm (Base, Shoulder, Elbow, Gripper)
; ==============================================================================
ARM_INIT
    LDR R0, =RCC_BASE  
    
    ; Enable GPIOA and GPIOB peripheral clocks on AHB1
    LDR R1, [R0, #RCC_AHB1ENR]
    ORR R1, R1, #0x03          
    STR R1, [R0, #RCC_AHB1ENR]
    
    ; Enable SYSCFG clock on APB2
    LDR R1, [R0, #RCC_APB2ENR]
    ORR R1, R1, #(1 << 14)     
    STR R1, [R0, #RCC_APB2ENR]
    
    ; Enable TIM3 clock on APB1 (bit 1)
    LDR R1, [R0, #RCC_APB1ENR]
    ORR R1, R1, #0x02          
    STR R1, [R0, #RCC_APB1ENR]

    ; Configure PA6 (CH1) and PA7 (CH2) for Alternate Function mode
    LDR R0, =GPIOA_BASE
    LDR R1, [R0, #GPIO_MODER]
    LDR R2, =0xF000            ; Mask MODER6 and MODER7
    BIC R1, R1, R2             
    LDR R2, =0xA000            ; Set mode '10' (AF) for both pins
    ORR R1, R1, R2          
    STR R1, [R0, #GPIO_MODER]

    ; Route PA6 and PA7 to AF2 (TIM3_CH1 and TIM3_CH2)
    LDR R1, [R0, #GPIO_AFRL]
    LDR R2, =0xFF000000        ; Clear AFRL6 and AFRL7
    BIC R1, R1, R2             
    LDR R2, =0x22000000        ; AF2 = 0x2
    ORR R1, R1, R2
    STR R1, [R0, #GPIO_AFRL]

    ; Configure PB0 (CH3) and PB1 (CH4) for Alternate Function mode
    LDR R0, =GPIOB_BASE
    LDR R1, [R0, #GPIO_MODER]
    BIC R1, R1, #0x0F          ; Clear MODER0 and MODER1
    ORR R1, R1, #0x0A          ; Set mode '10' (AF)
    STR R1, [R0, #GPIO_MODER]

    ; Route PB0 and PB1 to AF2 (TIM3_CH3 and TIM3_CH4)
    LDR R1, [R0, #GPIO_AFRL]
    BIC R1, R1, #0xFF          ; Clear AFRL0 and AFRL1
    ORR R1, R1, #0x22          ; AF2 = 0x2
    STR R1, [R0, #GPIO_AFRL]

    ; Set up TIM3 timebase for 50Hz (20ms servo frame)
    ; With a 16MHz clock, prescaler = 15 gives 1MHz counter clock (1 tick = 1 microsecond)
    LDR R0, =TIM3_BASE
    LDR R1, =15                
    STR R1, [R0, #TIM_PSC]
    LDR R1, =19999             ; ARR = 20,000 ticks -> 20ms period (50Hz)
    STR R1, [R0, #TIM_ARR]
    
    ; Set PWM Mode 1 with preload enabled on all four channels
    LDR R1, =0x6868           
    STR R1, [R0, #TIM_CCMR1]   ; CH1 and CH2
    LDR R1, =0x6868            
    STR R1, [R0, #TIM_CCMR2]   ; CH3 and CH4
    
    ; Enable outputs for channels 1 through 4 (active high)
    LDR R1, =0x1111            
    STR R1, [R0, #TIM_CCER]

    ; Default neutral/park positions for servos (pulse width in microseconds)
    ; Nominal SG90 range: ~500us (0 deg) to ~2500us (180 deg), center at 1500us
    LDR R1, =1600              
    STR R1, [R0, #TIM_CCR1]    ; Servo 1: Shoulder default
    LDR R1, =1500              
    STR R1, [R0, #TIM_CCR2]    ; Servo 2: Base default
    LDR R1, =500               
    STR R1, [R0, #TIM_CCR3]    ; Servo 3: Elbow default
    LDR R1, =500               
    STR R1, [R0, #TIM_CCR4]    ; Servo 4: Gripper default (closed/stowed)
    
    ; Trigger update event to latch prescaler/ARR, then start the counter
    MOV R1, #1
    STR R1, [R0, #TIM_EGR]     
    STR R1, [R0, #TIM_CR1]     
    
    BX LR

    END
