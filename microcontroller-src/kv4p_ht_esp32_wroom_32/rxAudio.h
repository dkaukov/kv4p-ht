/*
KV4P-HT (see http://kv4p.com)
Copyright (C) 2026 Vance Vagell

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
#include <AudioTools/AudioCodecs/CodecADPCM.h>
#if CONFIG_IDF_TARGET_ESP32S3
#include "s3AdcStream.h"
#endif
#if CONFIG_IDF_TARGET_ESP32
#include <driver/dac.h>
#endif
#include <esp_task_wdt.h>
#if CONFIG_IDF_TARGET_ESP32S3
#include <dsps_fir.h>
// The IDF 4 S3 optimized FIR requires a tap count divisible by four;
// the AFSK and software squelch filters use odd tap counts.
#undef dsps_fir_f32
#define dsps_fir_f32 dsps_fir_f32_ansi
#undef dsps_fird_f32
#define dsps_fird_f32 dsps_fird_f32_ansi
#endif
#include <AfskDemodulator.h>
#include <FreeDv2400b.h>
#include <math.h>
#include "globals.h"
#include "protocol.h"
#include "debug.h"
#include "dsp/audioResampler.h"
#include "dsp/softSquelchEffect.h"
#include "freeDvSquelch.h"

class SerialOutput : public AudioOutput {
public:
  size_t write(const uint8_t *data, size_t len) override {
    if (len > 0) {
      if (len > PROTO_MTU) {
        len = PROTO_MTU;
      }
      if (mode == MODE_RX) {
        sendAudio((uint8_t*)data, len);
      }
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

static void onAfskPacketDecoded(const uint8_t *frame, size_t len) {
  if (frame && len > 0) {
    pulseAprsRxLED();
    sendAx25Packet(frame, len);
  }
}

AfskDemodulator afskDemod(AUDIO_SAMPLE_RATE, 2, onAfskPacketDecoded);

FreeDvSquelch freeDvSquelch;
uint32_t lastFreeDvFrameAtMs = 0;

static void onFreeDvFrameDecoded(const uint8_t *frame, size_t len,
                                 const FreeDv2400bDecodeResult &result) {
  lastFreeDvFrameAtMs = millis();
  const bool accepted = freeDvSquelch.accept(result);
  const bool nextSquelched = !freeDvSquelch.open();
  if (freeDv2400bEnabled() && nextSquelched != squelched) {
    squelched = nextSquelched;
    markDeviceStateDirty();
  }
  if (frame && len == freedv2400b::PAYLOAD_BYTES && accepted) {
    sendDigitalFrame(frame, len);
  }
}

void freeDvSquelchLoop() {
  const uint32_t now = millis();
  if ((uint32_t)(now - lastFreeDvFrameAtMs) <
      FreeDvSquelch::NO_FRAME_TIMEOUT_MS) return;

  if (freeDv2400bEnabled() && freeDvSquelch.level() != 0 &&
      freeDvSquelch.open()) {
    freeDvSquelch.reset();
    if (!squelched) {
      squelched = true;
      markDeviceStateDirty();
    }
  }
}

FreeDv2400bDemodulator freeDvRx(onFreeDvFrameDecoded);

class FreeDvTapEffect : public AudioEffect {
public:
  FreeDvTapEffect *clone() override { return new FreeDvTapEffect(*this); }
  effect_t process(effect_t input) {
    if (active()) {
      samples[sampleCount++] = (int16_t)input;
      if (sampleCount == BUFFER_SAMPLES) {
        freeDvRx.processSamples(samples, sampleCount);
        if (freeDv2400bEnabled() && freeDvRx.hasDecodeResult()) {
          latestRssi = FreeDvSquelch::snrToRssi(
              freeDvRx.discriminatorSnrDbNow());
        }
        sampleCount = 0;
      }
    }
    return input;
  }
  void flush() {
    sampleCount = 0;
    freeDvRx.reset();
    freeDvSquelch.reset();
    if (freeDv2400bEnabled()) squelched = !freeDvSquelch.open();
    lastFreeDvFrameAtMs = millis();
  }
private:
  static const size_t BUFFER_SAMPLES = 256;
  int16_t samples[BUFFER_SAMPLES];
  size_t sampleCount = 0;
};

class AfskTapEffect : public AudioEffect {
public:
  AfskTapEffect *clone() override {
    return new AfskTapEffect(*this);
  }

  effect_t process(effect_t input) {
    if (active()) {
      samples[sampleCount++] = (int16_t)input;
      if (sampleCount >= AFSK_TAP_BUFFER_SAMPLES) {
        afskDemod.processSamples(samples, sampleCount);
        sampleCount = 0;
      }
    }
    return input;
  }

  void flush() {
    if (sampleCount > 0) {
      afskDemod.processSamples(samples, sampleCount);
      sampleCount = 0;
    }
    afskDemod.flush();
  }

private:
  static const size_t AFSK_TAP_BUFFER_SAMPLES = 256;
  int16_t samples[AFSK_TAP_BUFFER_SAMPLES];
  size_t sampleCount = 0;
};

bool rxStreamConfigured = false;
#if CONFIG_IDF_TARGET_ESP32S3
S3AdcStream in;
#else
AnalogAudioStream in;
#endif
AudioInfo rxInfo(AUDIO_SAMPLE_RATE, 1, 16);
// The classic ESP32 ADC/I2S clock was measured about 400 samples/s slow.
// The S3 uses a different ADC DMA clock, so do not apply that measurement.
#if CONFIG_IDF_TARGET_ESP32
static const uint32_t RX_ADC_SAMPLE_RATE_CORRECTION = 400;
#else
static const uint32_t RX_ADC_SAMPLE_RATE_CORRECTION = 0;
#endif
static const uint32_t RX_ADC_SAMPLE_RATE =
    AUDIO_SAMPLE_RATE + RX_ADC_SAMPLE_RATE_CORRECTION;
AudioInfo rxAudioInfo(AUDIO_WIRE_SAMPLE_RATE, 1, 16);
SerialOutput rxAudioOutput;
ADPCMEncoder rxAdpcmEncoder(AV_CODEC_ID_ADPCM_IMA_WAV, AUDIO_FRAME_BYTES);
EncodedAudioStream rxOut(&rxAudioOutput, &rxAdpcmEncoder);
AudioDownsampleConverter rxDownsample;
AudioEffectStream effects(in);  
ConverterStream<int16_t> rxDownsampledEffects(effects, rxDownsample);
StreamCopy rxCopier(rxOut, rxDownsampledEffects, AUDIO_FRAME_SAMPLES_48K * sizeof(int16_t));
Boost mute(0.0);
Boost gain(16.0);
DCOffsetRemover dcOffsetRemover(DECAY_TIME, AUDIO_SAMPLE_RATE);
AfskTapEffect afskTapEffect;
FreeDvTapEffect freeDvTapEffect;
SoftSquelchEffect softSquelchEffect(AUDIO_SAMPLE_RATE, ZCR_DECAY_TIME, SQ_CLOSE_DELAY);

inline void injectADCBias() {
#if CONFIG_IDF_TARGET_ESP32
  dac_output_enable(DAC_CHANNEL_2);  // GPIO26 (DAC1)
  dac_output_voltage(DAC_CHANNEL_2, (255.0 / 3.3) * hw.adcBias);
#endif
} 

inline void setUpADCAttenuator() {
#if CONFIG_IDF_TARGET_ESP32
  adc1_config_channel_atten(I2S_ADC_CHANNEL, hw.adcAttenuation);
#endif
}

void initI2SRx() {
  if (rxStreamConfigured) {
    return;
  }
  injectADCBias();
  setUpADCAttenuator();
  //AudioToolsLogger.begin(debugPrinter, AudioToolsLogLevel::Debug);
#if CONFIG_IDF_TARGET_ESP32S3
  if (!in.begin(RX_ADC_SAMPLE_RATE, hw.pins.pinAudioIn, hw.adcAttenuation)) {
    _LOGE("S3 ADC initialization failed");
    return;
  }
#else
  auto config = in.defaultConfig(RX_MODE);
  config.copyFrom(rxInfo);
  config.is_auto_center_read = false; // We use dcOffsetRemover instead
  config.use_apll = true;
  config.auto_clear = false;
  config.adc_pin = hw.pins.pinAudioIn;
  config.sample_rate = RX_ADC_SAMPLE_RATE;
  in.begin(config);
#endif
  // effects
  effects.clear();
  if (!effects.begin(rxInfo)) {
    _LOGE("RX effects initialization failed");
    in.end();
    return;
  }
  afskTapEffect.setActive(true);
  effects.addEffect(dcOffsetRemover);
  effects.addEffect(gain);
  effects.addEffect(afskTapEffect);
  freeDvTapEffect.setActive(true);
  effects.addEffect(freeDvTapEffect);
  effects.addEffect(softSquelchEffect);
  effects.addEffect(mute);
  // open output
  rxDownsample.begin();
  rxOut.begin(rxAudioInfo);
  rxCopier.setMinCopySize(sizeof(int16_t));
  rxCopier.setCheckAvailable(false);
  rxStreamConfigured = true;
}

void endI2SRx() {
  if (rxStreamConfigured) {
    afskTapEffect.flush();
    freeDvTapEffect.flush();
    rxOut.end();
    effects.end();
    in.end();
  }
  rxStreamConfigured = false;
}
  
void rxAudioLoop() {
  softSquelchEffect.setHardwareSquelched(digitalRead(hw.pins.pinSq) == HIGH);
  if (mode == MODE_RX || mode == MODE_STOPPED) {
    mute.setActive(squelched);
    rxCopier.copy();
    esp_task_wdt_reset();
  }
}
