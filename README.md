# Smart Nurse Robot

A team STM32 embedded prototype with ARM assembly modules for sensor acquisition, display, wireless telemetry, robot navigation, and arm actuation. This repository contains firmware sources and photographs of the hardware.

## Verified repository contents

| Module | Role represented in source |
| --- | --- |
| `main.s` | Integration loop and imported subsystem symbols |
| `TFT.s`, `RFID.s` | Display and RFID interface |
| `max.s`, `temperature.s`, `velostat.s` | Pulse-oximeter, temperature, pressure sensor routines |
| `DROP rate.s` | Optical drop-rate measurement routines |
| `bluetooth.s`, `IR.s` | Telemetry and infrared commands |
| `ultrasonic.s`, `Robot_mode.s`, `arm.s` | Distance sensing, navigation, actuation |

## Engineering approach

The modules use register-level ARM assembly and subsystem imports/exports. The integration loop coordinates sensor readouts and control routines rather than introducing a high-level application framework. Timing, wiring, and peripheral configuration are hardware-dependent.

See the [original hardware reference and team credits](docs/hardware-reference.md) for the design's pin mappings, subsystem descriptions, and attributed contributions. That document records the team's design claims; timing accuracy and clinical performance were not independently measured during this software review.

## Hardware photographs

![Robot prototype](Images/Robot.jpeg)

[Electronics and wiring](Images/Back%20view.jpeg) · [Bluetooth app photograph](Images/Bluetooth%20App.jpeg)

## Build and reproduce

The assembly uses Keil/ARMASM-style `AREA`, `IMPORT`, and `EXPORT` directives. The repository does not contain a complete Keil project, startup/vector source, linker configuration, or automated build. To reproduce it, recover the original project and exact STM32 part/board configuration, then add these modules to that known working toolchain and verify the wiring against the source and hardware reference.

No firmware build or hardware test is claimed here. A generic GNU assembler workflow would not validate this project. No environment variables or API credentials are required by the checked-in assembly.

## Limitations and next steps

This is an educational prototype, without demonstrated clinical calibration or safety certification. Sensor estimates and alert thresholds require hardware validation. The mobile app source is not included, although a photograph is present.

Recover the reproducible toolchain, document clocks and electrical connections, add hardware test procedures, and record measured results before asserting sensor accuracy, timing guarantees, or autonomous reliability.

## Team work

This is a collaborative project. The existing reference attributes Fady Fawzy's involvement to mechanical work, display work, optical-drop integration, and the mobile telemetry application with other contributors. The repository alone does not independently establish every contribution or claim solo authorship.
