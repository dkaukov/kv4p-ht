/*
KV4P-HT (see http://kv4p.com)
Copyright (C) 2025 Vance Vagell

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/
#pragma once

#include <Arduino.h>
#include <AudioTools.h>
#include <AudioTools/AudioCodecs/CodecOpus.h>
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0)
#include <driver/dac_oneshot.h>
#else
#include <driver/dac.h>
#endif
#include <esp_task_wdt.h>
#include "globals.h"
#include "protocol.h"
#include "debug.h"
#include "utils.h"


// Custom Output to Forward Encoded Data to Serial
class SerialOutput : public AudioOutput {
public:
  size_t write(const uint8_t *data, size_t len) override {
    if (len > 0) {
      if (len > PROTO_MTU) {
        len = PROTO_MTU;
      }
      sendAudio((uint8_t*)data, len);
      return len;
    }
    return len;
  } 
};

#define DECAY_TIME 0.25  // seconds

class DCOffsetRemover : public AudioEffect {
public:
  DCOffsetRemover(float decay_time = 0.25f, float sample_rate = AUDIO_SAMPLE_RATE): prev_y(0.0f) {
    alpha = 1.0f - expf(-1.0f / (sample_rate * (decay_time / logf(2.0f))));
  }
  DCOffsetRemover(const DCOffsetRemover &) = default;
  effect_t process(effect_t input) {
    return active() ? remove_dc(input) : input;
  }
  DCOffsetRemover *clone() override {
    return new DCOffsetRemover(*this);
  }
private:
  float prev_y;
  float alpha;
  int16_t remove_dc(int16_t x) {
    prev_y = alpha * x + (1.0f - alpha) * prev_y;
    return x - (int16_t)prev_y;
  }
};

constexpr int LUT_SIZE = 256;          
constexpr int16_t FULL_SCALE = 32767;

static const int16_t SINE_LUT[LUT_SIZE] PROGMEM = {
     0,   804,  1608,  2411,  3212,  4011,  4808,  5602,
  6393,  7179,  7961,  8737,  9508, 10272, 11029, 11778,
 12519, 13251, 13973, 14685, 15386, 16075, 16753, 17418,
 18070, 18708, 19333, 19943, 20538, 21118, 21682, 22230,
 22761, 23275, 23771, 24250, 24711, 25154, 25578, 25983,
 26369, 26736, 27083, 27411, 27718, 28006, 28273, 28520,
 28746, 28952, 29136, 29299, 29442, 29563, 29663, 29741,
 29798, 29834, 29848, 29841, 29812, 29761, 29689, 29595,
 29480, 29343, 29185, 29006, 28805, 28583, 28340, 28076,
 27792, 27487, 27162, 26817, 26451, 26066, 25661, 25237,
 24794, 24332, 23851, 23352, 22836, 22301, 21749, 21181,
 20595, 19992, 19373, 18738, 18088, 17422, 16742, 16047,
 15338, 14615, 13879, 13130, 12369, 11596, 10811, 10015,
  9209,  8392,  7576,  6751,  5926,  5104,  4284,  3467,
  2653,  1843,  1037,   236,  -560, -1351, -2136, -2914,
 -3686, -4450, -5207, -5954, -6693, -7422, -8140, -8848,
 -9544,-10228,-10900,-11559,-12206,-12839,-13458,-14064,
-14654,-15230,-15791,-16336,-16864,-17377,-17872,-18350,
-18811,-19254,-19679,-20085,-20473,-20842,-21192,-21523,
-21834,-22126,-22398,-22650,-22882,-23093,-23285,-23456,
-23606,-23736,-23845,-23934,-24002,-24049,-24075,-24081,
-24065,-24029,-23972,-23894,-23796,-23677,-23538,-23379,
-23199,-22999,-22779,-22539,-22279,-21999,-21699,-21381,
-21042,-20685,-20309,-19914,-19500,-19069,-18619,-18151,
-17666,-17164,-16645,-16109,-15557,-14989,-14405,-13806,
-13192,-12564,-11921,-11264,-10594, -9911, -9225, -8537,
 -7847, -7156, -6463, -5770, -5076, -4383, -3690, -2998,
 -2308, -1620,  -935,  -252
};

// ---- Effect ----
class SineEffect : public AudioEffect {
public:
  // amp: 0..32767
  SineEffect(float freqHz = 1000.0f, float sampleRateHz = 48000.0f, int16_t amp = FULL_SCALE): freq(freqHz), fs(sampleRateHz), amplitude(amp) {
    updatePhaseInc();
  }
  // Ignore input; generate sine
  effect_t process(effect_t /*in*/) override {
    if (!active_flag) return (effect_t)0;
    // Integer part & fractional part of LUT index
    uint32_t i0 = (uint32_t)phase;           // floor
    uint32_t i1 = (i0 + 1) & (LUT_SIZE - 1); // wrap (LUT_SIZE is power of two)
    float frac = phase - (float)i0;
    // Fetch from table (ESP32 reads PROGMEM like normal memory)
    int16_t y0 = SINE_LUT[i0];
    int16_t y1 = SINE_LUT[i1];
    // Linear interpolation
    float yf = (float)y0 + (float)(y1 - y0) * frac;
    // Apply amplitude scaling
    int32_t s = (int32_t)llroundf(yf * (float)amplitude / (float)FULL_SCALE);
    // Advance phase
    phase += phaseInc;
    if (phase >= (float)LUT_SIZE) phase -= (float)LUT_SIZE;
    // Optional safety: clip to 16-bit range using base helper
    return (effect_t)clip(s);
  }
  SineEffect(const SineEffect &) = default;
  SineEffect *clone() override {
    return new SineEffect(*this);
  }
  // ---- Controls ----
  void setFrequency(float freqHz) { freq = freqHz; updatePhaseInc(); }
  void setAmplitude(int16_t amp) { amplitude = (amp < 0 ? 0 : amp); }
private:
  float freq;
  float fs;
  int16_t amplitude;
  // phase is in [0, LUT_SIZE)
  float phase = 0.0f;
  float phaseInc = 0.0f; // LUT steps per output sample
  void updatePhaseInc() {
    if (fs <= 0.0f) fs = 48000.0f;
    // steps per sample = (freq / fs) * LUT_SIZE
    phaseInc = (freq / fs) * (float)LUT_SIZE;
    // keep in reasonable bounds if params are odd
    if (phaseInc < 0) phaseInc = 0;
    if (phaseInc > LUT_SIZE) phaseInc = fmodf(phaseInc, (float)LUT_SIZE);
  }
};

bool rxStreamConfigured = false;
bool rxEncConfigured = false;
AnalogAudioStream in;
AudioInfo rxInfo(AUDIO_SAMPLE_RATE, 1, 16);
OpusAudioEncoder rxEnc;
SerialOutput rxAudioOutput;
EncodedAudioStream rxOut(&rxAudioOutput, &rxEnc);
AudioEffectStream effects(in);  
StreamCopy rxCopier(rxOut, effects);
Boost mute(0.0);
Boost gain(16.0);
DCOffsetRemover dcOffsetRemover(DECAY_TIME, AUDIO_SAMPLE_RATE);
SineEffect sineEffect(1000.0f, AUDIO_SAMPLE_RATE);

inline void injectADCBias() {
#if SOC_DAC_SUPPORTED
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0)
  dac_oneshot_handle_t dac_handle;
  dac_oneshot_config_t dac_config = {
      .chan_id = DAC_CHAN_1  // GPIO26 (DAC1)
  };
  ESP_ERROR_CHECK(dac_oneshot_new_channel(&dac_config, &dac_handle));
  ESP_ERROR_CHECK(dac_oneshot_output_voltage(dac_handle, (255.0 / 3.3) * hw.adcBias));
  ESP_ERROR_CHECK(dac_oneshot_del_channel(dac_handle));
#else
  dac_output_enable(DAC_CHANNEL_1); // GPIO26 (DAC1)
  dac_output_voltage(DAC_CHANNEL_1, (255.0 / 3.3) * hw.adcBias);
#endif
#endif 
} 

inline void setUpADCAttenuator() {
}

void initI2SRx() {
  injectADCBias();
  setUpADCAttenuator();
  //AudioToolsLogger.begin(debugPrinter, AudioToolsLogLevel::Debug);
  auto config = in.defaultConfig(RX_MODE);
  config.copyFrom(rxInfo);
  config.is_auto_center_read = false; // We use dcOffsetRemover instead
#if defined(HAS_ESP32_DAC) || ESP_IDF_VERSION < ESP_IDF_VERSION_VAL(5, 0 , 0)
  config.use_apll = true;
#endif  
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0)
  config.adc_calibration_active = false;
  config.adc_attenuation = hw.adcAttenuation;
  gpioToAdc(hw.pins.pinAudioIn, config.adc_unit, config.adc_channels[0]);
#else
  config.auto_clear = false;
  config.adc_pin = hw.pins.pinAudioIn;
#endif  
  in.begin(config);
  if (!rxEncConfigured) {
    rxEnc.setAudioInfo(rxInfo);
    // configure OPUS additinal parameters
    auto &encoderConfig = rxEnc.config();
    encoderConfig.application = OPUS_APPLICATION_AUDIO;
    encoderConfig.frame_sizes_ms_x2 = OPUS_FRAMESIZE_20_MS;
    encoderConfig.vbr = 1;
    encoderConfig.max_bandwidth = OPUS_BANDWIDTH_NARROWBAND;
    encoderConfig.signal = OPUS_SIGNAL_MUSIC;
    rxEnc.begin(encoderConfig);
    // effects
    effects.clear();
    effects.addEffect(dcOffsetRemover);
    effects.addEffect(gain);
    effects.addEffect(mute);
    //effects.addEffect(sineEffect);
    effects.begin(rxInfo);
    // open output
    rxOut.begin(rxInfo);
  }
  rxEncConfigured = true;
  rxStreamConfigured = true;
}

void endI2SRx() {
  if (rxStreamConfigured) {
    //rxOut.end();
    //effects.end();
    in.end();
  }
  rxStreamConfigured = false;
}
  
void rxAudioLoop() {
  if (mode == MODE_RX) {
    mute.setActive(squelched);
    rxCopier.copy();
    esp_task_wdt_reset();
  }
}