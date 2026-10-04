# ESP32-S3 firmware variant

Build with `pio run -e esp32s3` from `microcontroller-src/`. The variant uses
the ESP32-S3's native USB Serial/JTAG CDC port. Its USB ID is Espressif
`303A:1001`, which Android recognizes and reopens after the device restarts.
No project-specific VID/PID is assigned.

The build targets the Waveshare ESP32-S3-Zero. Its onboard RGB LED is driven
through GPIO21 by the existing NeoPixel status code. The pin defaults are:

| Signal | GPIO |
| --- | ---: |
| SA518 TXD → ESP UART RX / SA518 RXD ← ESP UART TX | 44 / 43 |
| RX audio (ADC1) / TX audio (PDM) | 1 / 2 |
| Radio PTT / power down / H/L through Q3 | 4 / 5 / 6 |
| Audio_ON / RX status, active-low | 7 |
| Left / right buttons | 8 / 9 |
| Red LED / onboard RGB LED | 11 / 21 |

GPIO3, GPIO10, GPIO12, and GPIO13 are unused; GPIO19 and GPIO20 are reserved
for USB. The S3 has no DAC, so the board provides ADC bias through SJ1. RSSI
is queried over UART (the module's `RSSI?` command) and has no dedicated GPIO.
The extension headers were removed. Classic Bluetooth SPP is available only on the original
ESP32; the S3 variant offers USB CDC and BLE.
