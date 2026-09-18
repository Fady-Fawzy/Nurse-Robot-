; Peripheral register addresses for Clock, GPIO, and ADC1
RCC_AHB1ENR  EQU 0x40023830  ; AHB1 clock enable (GPIOA)
RCC_APB2ENR  EQU 0x40023844  ; APB2 clock enable (ADC1)
GPIOA_MODER  EQU 0x40020000  ; GPIOA mode register
ADC1_SR      EQU 0x40012000  ; ADC1 status register (EOC flag)
ADC1_CR1     EQU 0x40012004  ; ADC1 control register 1
ADC1_CR2     EQU 0x40012008  ; ADC1 control register 2 (ADON, SWSTART)
ADC1_SQR3    EQU 0x40012034  ; ADC1 regular sequence register 3
ADC1_DR      EQU 0x4001204C  ; ADC1 regular data register (12-bit result)

            AREA    |.text|, CODE, READONLY
            
            EXPORT  init_velostat
            EXPORT  read_velostat

; ==============================================================================
; init_velostat: Configures ADC1 Channel 0 (PA0) for single-conversion readings
; from the Velostat piezoresistive pressure divider circuit
; ==============================================================================
init_velostat
            PUSH {R0-R2, LR}         

            ; Enable GPIOA clock
            LDR R0, =RCC_AHB1ENR
            LDR R1, [R0]
            ORR R1, R1, #0x01        
            STR R1, [R0]

            ; Enable ADC1 peripheral clock (bit 8 on APB2)
            LDR R0, =RCC_APB2ENR
            LDR R1, [R0]
            ORR R1, R1, #0x0100      
            STR R1, [R0]

            ; Set PA0 to Analog mode (bits 1:0 = 11) to disable digital Schmitt triggers
            LDR R0, =GPIOA_MODER
            LDR R1, [R0]
            ORR R1, R1, #0x03        
            STR R1, [R0]

            ; Set Channel 0 (PA0) as the first conversion in regular sequence (SQ1)
            LDR R0, =ADC1_SQR3
            LDR R1, [R0]
            BIC R1, R1, #0x1F        ; Clear SQ1 bits to select CH0
            STR R1, [R0]

            ; Power on the ADC (set ADON bit)
            LDR R0, =ADC1_CR2
            LDR R1, [R0]
            ORR R1, R1, #0x01        
            STR R1, [R0]

            ; Wait for ADC internal reference and analog circuitry to stabilize (tSTAB)
            LDR R2, =10000
Delay_Init
            SUBS R2, R2, #1
            BNE Delay_Init

            POP {R0-R2, PC}         


; ==============================================================================
; read_velostat: Triggers a single conversion on PA0 and returns 12-bit value in R0
; ==============================================================================
read_velostat
            PUSH {R1, LR}           
            
            ; Start conversion by setting SWSTART bit in CR2
            LDR R0, =ADC1_CR2
            LDR R1, [R0]
            ORR R1, R1, #0x40000000  
            STR R1, [R0]

Wait_EOC
            ; Poll for End Of Conversion flag (SR bit 1)
            LDR R0, =ADC1_SR
            LDR R1, [R0]
            ANDS R1, R1, #0x02       
            BEQ Wait_EOC             ; Keep polling until conversion finishes

            ; Read 12-bit result (reading DR also clears the EOC flag)
            LDR R0, =ADC1_DR
            LDR R0, [R0]             

            POP {R1, PC}             
            
            ALIGN
            END