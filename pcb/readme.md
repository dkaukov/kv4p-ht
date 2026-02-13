# Harmonic filtering test results

## PCB v1.8x
v1.8a, v1.8b, and v1.8c of the PCB are -53.0dBc for the 2nd harmonic, and 5uW of harmonic power, fully FCC part 97 compliant (tested with 62dB of attenuation):

![A photo of a TinySA measuring the spurious emissions of the kv4p HT v1.8x, the graph shows a single large spike at the transmitting frequency.](https://kv4p.com/img/spectral-purity-PCB-v1.8x.jpg "v1.8x TinySA results")

## PCB v1.7b
v1.7b of the PCB is -52.9dBc for the 2nd harmonic, and 5uW of harmonic power, fully FCC part 97 compliant (tested with 56dB of attenuation):

![A photo of a TinySA measuring the spurious emissions of the kv4p HT v1.7b, the graph shows a single large spike at the transmitting frequency.](https://kv4p.com/img/v1.7b-harmonics.jpg "v1.7b TinySA results")

## PCB v1.7
v1.7 of the PCB is -52.7dBc for the 2nd harmonic, and below 4uW of harmonic power, fully FCC part 97 compliant (tested with 56dB of attenuation):

![A photo of a TinySA measuring the spurious emissions of the kv4p HT v1.7, the graph shows a single large spike at the transmitting frequency.](https://kv4p.com/img/tinysa-spurious-v1.7.jpg "v1.7 TinySA results")

# To generate a new NVS binary (for contributors)

Build:
```
../scripts/nvs_partition_gen.py generate board-config.csv  board-config.bin 0x6000
```


Flash:
```
esptool.py  write_flash 0x9000 board-config.bin
```
