# ESP32-S3 / IDF 4 experiment

This branch starts from `main` and keeps PlatformIO `espressif32@6.10.0`,
Arduino-ESP32 2.0.17 (ESP-IDF 4.4.7), and Arduino Audio Tools 1.2.3.
Both targets use the Arduino core's bundled Bluedroid BLE library. Classic
Bluetooth SPP is enabled only on the original ESP32 because S3 has no Classic
Bluetooth radio.

Build with `pio run -e esp32dev` and `pio run -e esp32s3`. The S3 environment
uses the `esp32-s3-devkitc-1` board definition with 4 MB flash and native USB
CDC to represent the S3-Zero. It maps the S3-Zero's onboard RGB LED to GPIO21
and uses the S3 pin mapping from the hardware design.

`pio run -e esp32s3-release` produces the S3 image bundled by Android. The
Android flasher detects the chip before choosing the ESP32 or S3 bootloader
and application image. The partition table and `boot_app0` are identical for
these two builds. S3 native USB can re-enumerate during bootloader entry, so
the flashing transport reopens the new USB device before writing flash.

Audio Tools 1.2.3 disables its analog stream on S3 with IDF 4. The S3 build
therefore uses a small `adc_digi` input stream, leaving Audio Tools itself at
v1.2.3. This only proves that the firmware compiles. ADC sample rate, PDM TX
clock, BLE throughput, and USB reconnection still need tests on hardware.

Radio control uses the same queued AT-command controller for SA818 and SA518.
The S3 defaults to SA518 dual-band mode; the module type can also be selected
through hardware-config NVS. Android recognizes the dual-band module, keeps
2 m and 70 cm channel limits separate, and rejects frequencies in the gap.
SA518 RSSI uses `AT+RSSI?`. Module responses, ADC/PDM timing, BLE throughput,
and USB reconnection still need tests on the connected hardware.
