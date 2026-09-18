; Peripheral base addresses for GPIOA and Timers
GPIOA_BASE_RM   EQU 0x40020000
GPIOA_ODR_RM    EQU GPIOA_BASE_RM + 0x14

TIM3_BASE_RM    EQU 0x40000400
TIM5_BASE_RM    EQU 0x40000C00

TIM_CR1_RM      EQU 0x00
TIM_CNT_RM      EQU 0x24
TIM_PSC_RM      EQU 0x28
TIM_ARR_RM      EQU 0x2C
TIM_CCR1_RM     EQU 0x34
TIM_CCR2_RM     EQU 0x38
TIM_CCR3_RM     EQU 0x3C
TIM_CCR4_RM     EQU 0x40

; Navigation distance thresholds (in centimeters)
DIST_ARM_LOW1    EQU 85      ; Patient Room 1 detection window lower bound
DIST_ARM_HIGH1   EQU 100     ; Patient Room 1 detection window upper bound
DIST_ARM_LOW2    EQU 155     ; Patient Room 2 detection window lower bound
DIST_ARM_HIGH2   EQU 170     ; Patient Room 2 detection window upper bound
DIST_STOP        EQU 30      ; Safety emergency braking distance ceiling

; External sensor routines and shared variables
    IMPORT  HCSR04_Measure     
    IMPORT  hc_delay_us        
    IMPORT  distance_cm        
    IMPORT  ir_flag            
    IMPORT  ir_command         

    AREA    ROBOT_CODE, CODE, READONLY
    ALIGN   4

    EXPORT  Enter_Robot_Mode    

; ==============================================================================
; Enter_Robot_Mode: Supervisor control loop for autonomous hospital corridor
; navigation, obstacle detection, and bedside medicine delivery
; ==============================================================================
Enter_Robot_Mode FUNCTION
    PUSH    {R4-R11, LR}

    ; Ensure drive motors are idle before entering autonomous loop
    BL      RM_StopMotors

robot_main_loop

    ; 1. Check for user interrupt from IR remote
    LDR     R0, =ir_flag
    LDRB    R1, [R0]
    CMP     R1, #0
    BNE     robot_exit          ; Remote key pressed: abort and return to stationary mode

    ; 2. Drive forward along corridor
    BL      RM_Forward

    ; 3. Sample distance ahead via ultrasonic sensor
    BL      HCSR04_Measure

    LDR     R0, =distance_cm
    LDR     R4, [R0]          

    ; 4. Collision avoidance check
    CMP     R4, #0
    BEQ     rm_too_close        ; Reading of 0 indicates sensor error / timeout; treat as blocked
    CMP     R4, #DIST_STOP
    BLE     rm_too_close        ; Obstacle detected within 30cm: brake immediately

CHECK1
    ; 5. Patient Room 1 detection zone: 85 cm to 100 cm
    CMP     R4, #DIST_ARM_LOW1
    BLT     rm_continue         ; Closer than 85cm (and >30cm): keep moving forward
    CMP     R4, #DIST_ARM_HIGH1
    BGT     CHECK2   	        ; Past Room 1: check Room 2 distance
	B 		TRIGGER_ARM         ; Within Room 1 window: stop and deliver

CHECK2	
    ; 6. Patient Room 2 detection zone: 155 cm to 170 cm
    CMP     R4, #DIST_ARM_LOW2
    BLT     rm_continue         
    CMP     R4, #DIST_ARM_HIGH2
    BGT     rm_continue         ; Past Room 2: keep patrolling

TRIGGER_ARM
    ; 7. Room reached: brake vehicle, execute delivery arm routine
    BL      RM_Brake
    BL      RM_ArmSequence      
    B       rm_ping_delay

rm_too_close
    ; Obstacle too close: brake motors and exit robot mode
    BL      RM_Brake
    B       robot_exit

rm_continue
    ; Corridor clear: continue moving forward
    B       rm_ping_delay

rm_ping_delay
    ; 60ms delay between ultrasonic pings to let acoustic reflections dissipate
    LDR     R0, =60000         
    BL      hc_delay_us
    B       robot_main_loop

robot_exit
    ; Acknowledge and clear the interrupt flag
    LDR     R0, =ir_flag
    MOV     R1, #0
    STRB    R1, [R0]

    ; Ensure motors are completely stopped upon exit
    BL      RM_StopMotors

    POP     {R4-R11, PC}
    ENDFUNC

; ==============================================================================
; RM_Forward: Sets H-Bridge directional pins to drive wheels forward
; ==============================================================================
RM_Forward
    PUSH    {R0, R1, LR}
    LDR     R0, =GPIOA_ODR_RM
    LDR     R1, [R0]
    BIC     R1, R1, #0x1E       ; Clear motor driver lines (PA1-PA4)
    ORR     R1, R1, #0x0C       ; Forward drive bitmask
    STR     R1, [R0]
    POP     {R0, R1, PC}

; ==============================================================================
; RM_StopMotors: Floats motor inputs allowing vehicle to coast to a stop
; ==============================================================================
RM_StopMotors
    PUSH    {R0, R1, LR}
    LDR     R0, =GPIOA_ODR_RM
    LDR     R1, [R0]
    BIC     R1, R1, #0x1E       ; Disable all motor bridge outputs
    STR     R1, [R0]
    POP     {R0, R1, PC}

; ==============================================================================
; RM_Brake: Actively brakes DC motors by pulling both terminals HIGH
; ==============================================================================
RM_Brake
    PUSH    {R0, R1, LR}
    LDR     R0, =GPIOA_ODR_RM
    LDR     R1, [R0]
    BIC     R1, R1, #0x1E
    ORR     R1, R1, #0x1E       ; Short motor terminals to dynamic brake
    STR     R1, [R0]
    POP     {R0, R1, PC}

; ==============================================================================
; RM_ArmSequence: Pre-programmed joint trajectory to deliver medication tray.
; TIM3 channels 1-4 drive servos with pulse widths in microseconds.
; ==============================================================================
RM_ArmSequence FUNCTION
    PUSH    {R0-R2, LR}
    LDR     R0, =TIM3_BASE_RM

    ; Step 1: Adjust base height (Servo 2 to 1000us)
    LDR     R1, =1000
    STR     R1, [R0, #TIM_CCR2_RM]
    BL      RM_Delay_1s

    ; Step 2: Open gripper partially (Servo 4 to 750us)
    LDR     R1, =750
    STR     R1, [R0, #TIM_CCR4_RM]
    BL      RM_Delay_1s

    ; Step 3: Reach forward with elbow joint (Servo 3 to 1500us)
    LDR     R1, =1500
    STR     R1, [R0, #TIM_CCR3_RM]
    BL      RM_Delay_1s

    ; Step 4: Swivel base toward bedside tray (Servo 1 to 600us)
    LDR     R1, =600
    STR     R1, [R0, #TIM_CCR1_RM]
    BL      RM_Delay_1s
	
    ; Step 5: Release medication cup (Servo 4 to 500us)
    LDR     R1, =500
    STR     R1, [R0, #TIM_CCR4_RM]
    BL      RM_Delay_1s
	
    ; Step 6: Swing base back toward centerline (Servo 1 to 1600us)
    LDR     R1, =1600
    STR     R1, [R0, #TIM_CCR1_RM]
    BL      RM_Delay_1s

    ; Step 7: Retract elbow joint (Servo 3 to 500us)
    LDR     R1, =500
    STR     R1, [R0, #TIM_CCR3_RM]
    BL      RM_Delay_1s
	
    ; Step 8: Lower arm to travel profile (Servo 2 to 700us)
    LDR     R1, =700
    STR     R1, [R0, #TIM_CCR2_RM]
    BL      RM_Delay_1s

    ; Home sequence: return all joints to safe stowed configuration
    LDR     R1, =500
    STR     R1, [R0, #TIM_CCR4_RM]
    BL      RM_Delay_1s
	
    LDR     R1, =1500
    STR     R1, [R0, #TIM_CCR3_RM]
    BL      RM_Delay_1s
	
    LDR     R1, =750
    STR     R1, [R0, #TIM_CCR4_RM]
    BL      RM_Delay_1s

    LDR     R1, =1400
    STR     R1, [R0, #TIM_CCR1_RM]
    BL      RM_Delay_1s
 
    LDR     R1, =1500
    STR     R1, [R0, #TIM_CCR2_RM]
    BL      RM_Delay_1s
 
    LDR     R1, =750
    STR     R1, [R0, #TIM_CCR4_RM]
    BL      RM_Delay_1s
  
    ; Final park positions:
    LDR     R1, =1600
    STR     R1, [R0, #TIM_CCR1_RM]    ; Shoulder park
    LDR     R1, =1500
    STR     R1, [R0, #TIM_CCR2_RM]    ; Base park
    LDR     R1, =500
    STR     R1, [R0, #TIM_CCR3_RM]    ; Elbow park
    LDR     R1, =500
    STR     R1, [R0, #TIM_CCR4_RM]    ; Gripper closed park
    BL      RM_Delay_1s

    POP     {R0-R2, PC}
    ENDFUNC

; ==============================================================================
; RM_Delay_1s: ~1 second calibrated delay loop (4 cycles per loop at 16MHz)
; ==============================================================================
RM_Delay_1s
    PUSH    {R2, LR}
    LDR     R2, =4000000      ; 16MHz / 4 cycles = 4,000,000 iterations
rm_delay_loop
    SUBS    R2, R2, #1
    BNE     rm_delay_loop
    POP     {R2, PC}

    END