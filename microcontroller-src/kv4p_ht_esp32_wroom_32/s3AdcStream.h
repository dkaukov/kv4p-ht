#pragma once

#if CONFIG_IDF_TARGET_ESP32S3

#include <AudioTools.h>
#include <driver/adc.h>

// Audio Tools 1.2.3 omits AnalogAudioStream on S3 with IDF 4.4.
// Feed its existing effects pipeline from the IDF 4 ADC DMA driver instead.
class S3AdcStream : public audio_tools::AudioStream {
 public:
  bool begin(uint32_t sampleRate, int pin, adc_atten_t attenuation) {
    if (pin < 1 || pin > 10) return false;
    channel_ = static_cast<uint8_t>(pin - 1);
    adc_digi_init_config_t init = {};
    init.max_store_buf_size = 4096;
    init.conv_num_each_intr = 256;
    init.adc1_chan_mask = 1u << channel_;
    if (adc_digi_initialize(&init) != ESP_OK) return false;

    adc_digi_pattern_config_t pattern = {};
    pattern.atten = static_cast<uint8_t>(attenuation);
    pattern.channel = channel_;
    pattern.unit = ADC_UNIT_1;
    pattern.bit_width = 12;
    adc_digi_configuration_t config = {};
    config.pattern_num = 1;
    config.adc_pattern = &pattern;
    config.sample_freq_hz = sampleRate;
    config.conv_mode = ADC_CONV_SINGLE_UNIT_1;
    config.format = ADC_DIGI_OUTPUT_FORMAT_TYPE2;
    if (adc_digi_controller_configure(&config) != ESP_OK ||
        adc_digi_start() != ESP_OK) {
      adc_digi_deinitialize();
      return false;
    }
    running_ = true;
    setAudioInfo(audio_tools::AudioInfo(sampleRate, 1, 16));
    return true;
  }

  void end() {
    if (!running_) return;
    adc_digi_stop();
    adc_digi_deinitialize();
    running_ = false;
  }

  size_t readBytes(uint8_t *output, size_t length) override {
    if (!running_) return 0;
    size_t written = 0;
    size_t readsRemaining = (length / sizeof(int16_t) + 63) / 64 + 2;
    while (written + sizeof(int16_t) <= length && readsRemaining-- > 0) {
      adc_digi_output_data_t samples[64];
      uint32_t received = 0;
      size_t requested = min((length - written) / sizeof(int16_t), size_t(64));
      esp_err_t result = adc_digi_read_bytes(
          reinterpret_cast<uint8_t *>(samples),
          requested * sizeof(samples[0]), &received, 20);
      if (result != ESP_OK || received == 0) break;
      for (size_t i = 0; i < received / sizeof(samples[0]); ++i) {
        if (samples[i].type2.channel != channel_ || samples[i].type2.unit != 0) continue;
        int16_t sample = static_cast<int16_t>(samples[i].type2.data);
        memcpy(output + written, &sample, sizeof(sample));
        written += sizeof(sample);
      }
    }
    return written;
  }

  int available() override { return running_ ? 1920 : 0; }
  int read() override { return -1; }
  int peek() override { return -1; }
  size_t write(uint8_t) override { return 0; }

 private:
  uint8_t channel_ = 0;
  bool running_ = false;
};

#endif
