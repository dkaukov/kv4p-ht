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

#include <Arduino.h>
#if CONFIG_IDF_TARGET_ESP32
#include <BluetoothSerial.h>
#endif
#include <esp_system.h>
#include <esp_task_wdt.h>
#include "globals.h"
#include "radioModule.h"
#include "debug.h"
#include "BluedroidBleKissGattStream.h"
#include "led.h"
#include "protocol.h"
#include "state.h"
#include "rxAudio.h"
#include "txAudio.h"
#include "ax25TxScheduler.h"
#include "buttons.h"
#include "utils.h"
#include "board.h"

const uint16_t FIRMWARE_VER = 17;

const uint32_t RSSI_REPORT_INTERVAL_MS = 100;
const uint32_t DEVICE_STATE_REPORT_INTERVAL_MS = 500;
const uint32_t RADIO_STATE_SAVE_DELAY_MS = 1500;
const uint16_t USB_BUFFER_SIZE = 1024*2;
const uint16_t BLE_KISS_WINDOW_SIZE = 4096;

using Kv4pBleKissStream = BluedroidBleKissGattStream<4096, 512, 32>;

char bleKissDeviceName[12] = "kv4p";

Kv4pBleKissStream::Config bleKissConfig() {
  Kv4pBleKissStream::Config cfg;
  cfg.deviceName = bleKissDeviceName;
  cfg.preferredMtu = 247;
  cfg.requireNotifySubscription = true;
  cfg.maxNotifyChunksPerLoop = 4;
  cfg.minNotifyIntervalMs = 0;
  cfg.notifyFailureBackoffMs = 25;
  cfg.writeQueueWaitMs = 15;
#if CONFIG_IDF_TARGET_ESP32S3
  cfg.txPower = ESP_PWR_LVL_P9;
#else
  cfg.txPower = ESP_PWR_LVL_P7;
#endif
  return cfg;
}

void handleRadioResult(const RadioModule::Result &result);
RadioModule radio(Serial1, handleRadioResult);
bool radioFound = false;
bool normalRadioConfigured = false;
bool radioFilterPending = false;
bool radioGroupPending = false;
uint8_t pendingModuleSquelch = 0;
uint8_t appliedModuleSquelch = 0;
HostDesiredState pendingRadioState = {};
uint16_t pendingFilterFlags = 0;
Kv4pBleKissStream bleKissStream(bleKissConfig());
#if CONFIG_IDF_TARGET_ESP32
BluetoothSerial SerialBT;
#endif
bool bluetoothStarted = false;
bool bluetoothProtocolConnected = false;
bool bleKissProtocolConnected = false;
KissParser bluetoothParser(protocolBtSession, &handleCommands, &handleAx25Data,
  &handleKissParameter);
KissParser bleKissParser(protocolBleSession, &handleCommands, &handleAx25Data,
  &handleKissParameter);
Ax25TxScheduler ax25TxScheduler;
// SoftSQ needs its 250 ms close/open interval after a retune before its raw
// HF-noise carrier decision is reliable. Keep a small loop-timing margin.
static constexpr uint16_t AX25_OVERRIDE_RX_SETTLE_MS = 260;
bool ax25OverrideChannelPrepared = false;
bool ax25OverrideInProgress = false;
uint32_t ax25OverrideChannelReadyAt = 0;
uint32_t desiredRadioStateChangedAtMs = 0;

char radioStatus() {
  return radioFound ? RADIO_MODULE_FOUND : RADIO_MODULE_NOT_FOUND;
}

float moduleMinRadioFreq() {
  return hw.rfModuleType == RF_SA818_UHF ? 400.0f : 134.0f;
}

float moduleMaxRadioFreq() {
  return hw.rfModuleType == RF_SA818_UHF ? 480.0f :
    hw.rfModuleType == RF_SA518_DUAL ? 470.0f : 174.0f;
}

float moduleDefaultRadioFreq() {
  return hw.rfModuleType == RF_SA818_UHF ? 435.0f : 144.0f;
}

float clampModuleRadioFreq(float freq) {
  if (isModuleRadioFreq(freq)) return freq;
  if (hw.rfModuleType == RF_SA518_DUAL && freq > 174.0f && freq < 400.0f)
    return freq < 287.0f ? 174.0f : 400.0f;
  return min(max(freq, moduleMinRadioFreq()), moduleMaxRadioFreq());
}

bool isModuleRadioFreq(float freq) {
  return RadioModule::validFrequency(hw.rfModuleType, freq);
}

void loadPersistedRadioState() {
  prefs.begin("radio", true);
  uint16_t flags = desiredState.flags;
  flags &= ~(HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED | HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW | HOST_STATE_TX_ALLOWED);
  flags |= HOST_STATE_RADIO_CONFIG_VALID;
  desiredState.bw = prefs.getUChar("bw", 1);
  desiredState.freq_tx = prefs.getFloat("freq_tx", moduleDefaultRadioFreq());
  desiredState.freq_rx = prefs.getFloat("freq_rx", moduleDefaultRadioFreq());
  desiredState.ctcss_tx = prefs.getUChar("ctcss_tx", 0);
  desiredState.squelch = prefs.getUChar("squelch", 0);
  desiredState.ctcss_rx = prefs.getUChar("ctcss_rx", 0);
  desiredState.memoryId = prefs.getInt("memory_id", -1);
  if (!isModuleRadioFreq(desiredState.freq_tx) || !isModuleRadioFreq(desiredState.freq_rx)) {
    desiredState.freq_tx = clampModuleRadioFreq(desiredState.freq_tx);
    desiredState.freq_rx = clampModuleRadioFreq(desiredState.freq_rx);
    desiredState.memoryId = -1;
  }
  if (prefs.getBool("high", true)) {
    flags |= HOST_STATE_HIGH_POWER;
  }
  if (prefs.getBool("rssi", true)) {
    flags |= HOST_STATE_RSSI_ENABLED;
  }
  if (prefs.getBool("flt_pre", false)) {
    flags |= HOST_STATE_FILTER_PRE;
  }
  if (prefs.getBool("flt_high", false)) {
    flags |= HOST_STATE_FILTER_HIGH;
  }
  if (prefs.getBool("flt_low", false)) {
    flags |= HOST_STATE_FILTER_LOW;
  }
  if (prefs.getBool("tx_allowed", false)) {
    flags |= HOST_STATE_TX_ALLOWED;
  }
  desiredState.flags = flags;
  softSquelchEffect.setDeadbandLevel(desiredState.squelch);
  desiredState.sequence = 0;
  desiredState.flags &= ~(HOST_STATE_PTT_REQUESTED | HOST_STATE_SESSION_FLAG_MASK);
  appliedState.memoryId = desiredState.memoryId;
  persistedState = desiredState;
  prefs.end();
}

uint16_t persistedStateFlags(uint16_t flags) {
  return flags & (HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED | HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW | HOST_STATE_TX_ALLOWED);
}

bool samePersistedRadioState(const HostDesiredState &a, const HostDesiredState &b) {
  return a.bw == b.bw
    && a.freq_tx == b.freq_tx
    && a.freq_rx == b.freq_rx
    && a.ctcss_tx == b.ctcss_tx
    && a.squelch == b.squelch
    && a.ctcss_rx == b.ctcss_rx
    && a.memoryId == b.memoryId
    && persistedStateFlags(a.flags) == persistedStateFlags(b.flags);
}

bool persistedRadioStateMatchesDesired() {
  return samePersistedRadioState(persistedState, desiredState);
}

void savePersistedRadioStateIfChanged() {
  // Coalesce rapid frequency changes before writing flash, including scan steps.
  if (mode == MODE_TX || persistedRadioStateMatchesDesired() ||
      (uint32_t)(millis() - desiredRadioStateChangedAtMs) < RADIO_STATE_SAVE_DELAY_MS) {
    return;
  }
  if (!prefs.begin("radio", false)) return;
  if (persistedState.bw != desiredState.bw) prefs.putUChar("bw", desiredState.bw);
  if (persistedState.freq_tx != desiredState.freq_tx) prefs.putFloat("freq_tx", desiredState.freq_tx);
  if (persistedState.freq_rx != desiredState.freq_rx) prefs.putFloat("freq_rx", desiredState.freq_rx);
  if (persistedState.ctcss_tx != desiredState.ctcss_tx) prefs.putUChar("ctcss_tx", desiredState.ctcss_tx);
  if (persistedState.squelch != desiredState.squelch) prefs.putUChar("squelch", desiredState.squelch);
  if (persistedState.ctcss_rx != desiredState.ctcss_rx) prefs.putUChar("ctcss_rx", desiredState.ctcss_rx);
  if (persistedState.memoryId != desiredState.memoryId) prefs.putInt("memory_id", desiredState.memoryId);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_HIGH_POWER)
    prefs.putBool("high", (desiredState.flags & HOST_STATE_HIGH_POWER) != 0);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_RSSI_ENABLED)
    prefs.putBool("rssi", (desiredState.flags & HOST_STATE_RSSI_ENABLED) != 0);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_FILTER_PRE)
    prefs.putBool("flt_pre", (desiredState.flags & HOST_STATE_FILTER_PRE) != 0);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_FILTER_HIGH)
    prefs.putBool("flt_high", (desiredState.flags & HOST_STATE_FILTER_HIGH) != 0);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_FILTER_LOW)
    prefs.putBool("flt_low", (desiredState.flags & HOST_STATE_FILTER_LOW) != 0);
  if ((persistedState.flags ^ desiredState.flags) & HOST_STATE_TX_ALLOWED)
    prefs.putBool("tx_allowed", (desiredState.flags & HOST_STATE_TX_ALLOWED) != 0);
  prefs.end();
  persistedState = desiredState;
}

uint8_t getFirmwareFeatures() {
  return (hw.features.hasHL ? FEATURE_HAS_HL : 0)
    | (hw.features.hasPhysPTT ? FEATURE_HAS_PHY_PTT : 0)
    | FEATURE_HAS_ESP32_AFSK
    | FEATURE_HAS_FREEDV_2400B;
}

Mode rxIdleMode() {
  return protocolAnySessionFlag(HOST_STATE_RX_AUDIO_OPEN) ? MODE_RX : MODE_STOPPED;
}

uint16_t desiredFilterFlags() {
  return desiredState.flags & (HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW);
}

bool txAllowedByHost() {
  return desiredState.flags & HOST_STATE_TX_ALLOWED;
}

bool freeDv2400bEnabled() {
  return desiredState.flags & HOST_STATE_FREEDV_2400B;
}

uint8_t moduleSquelchLevel() {
  return hw.rfModuleType == RF_SA518_DUAL && !freeDv2400bEnabled()
    ? min(desiredState.squelch, (uint8_t)8) : 0;
}

uint16_t deviceStateFlags(uint16_t sessionFlags) {
  uint16_t flags = desiredState.flags;
  flags |= sessionFlags & HOST_STATE_SESSION_FLAG_MASK;
  if (isPhysPttDown) {
    flags |= DEVICE_STATE_PHYS_PTT_DOWN;
  }
  if (mode == MODE_TX) {
    flags |= DEVICE_STATE_TX_ACTIVE;
  }
  if (squelched) {
    flags |= DEVICE_STATE_SQUELCHED;
  }
  return flags;
}

uint8_t deviceMode() {
  switch (mode) {
    case MODE_TX:
      return DEVICE_MODE_TX;
    case MODE_RX:
      return DEVICE_MODE_RX;
    case MODE_STOPPED:
    default:
      return DEVICE_MODE_STOPPED;
  }
}

DeviceState currentDeviceState(uint16_t sessionFlags = 0) {
  return {
    .appliedSequence = desiredState.sequence,
    .memoryId = appliedState.memoryId,
    .flags = deviceStateFlags(sessionFlags),
    .bw = appliedState.bw,
    .freq_tx = appliedState.freq_tx,
    .freq_rx = appliedState.freq_rx,
    .ctcss_tx = appliedState.ctcss_tx,
    .squelch = appliedState.squelch,
    .ctcss_rx = appliedState.ctcss_rx,
    .radioModuleStatus = radioStatus(),
    .mode = deviceMode(),
    .lastError = lastDeviceStateError,
    .latestRssi = latestRssi,
  };
}

void sendCurrentDeviceState() {
  bool sent = false;
  if (protocolSessionConnected(protocolUsbSession) && (protocolUsbSession.flags & HOST_STATE_ENABLE_STATUS_REPORTS)) {
    sendDeviceState(*protocolUsbSession.stream, currentDeviceState(protocolUsbSession.flags));
    sent = true;
  }
  if (protocolHasBtSession() && (protocolBtSession.flags & HOST_STATE_ENABLE_STATUS_REPORTS)) {
    sendDeviceState(*protocolBtSession.stream, currentDeviceState(protocolBtSession.flags));
    sent = true;
  }
  if (protocolHasBleSession() && (protocolBleSession.flags & HOST_STATE_ENABLE_STATUS_REPORTS)) {
    sendDeviceState(*protocolBleSession.stream, currentDeviceState(protocolBleSession.flags));
    sent = true;
  }
  if (sent) {
    deviceStateDirty = false;
  }
}

void markDeviceStateDirty() {
  deviceStateDirty = true;
}

bool radioConfigChanged() {
  return !normalRadioConfigured
    || appliedState.bw != desiredState.bw
    || appliedState.freq_tx != desiredState.freq_tx
    || appliedState.freq_rx != desiredState.freq_rx
    || appliedState.ctcss_tx != desiredState.ctcss_tx
    || appliedState.squelch != desiredState.squelch
    || appliedModuleSquelch != moduleSquelchLevel()
    || appliedState.ctcss_rx != desiredState.ctcss_rx
    || appliedState.memoryId != desiredState.memoryId;
}

void reconcileDesiredState(bool sendReport = true) {
  bool wantHigh = desiredState.flags & HOST_STATE_HIGH_POWER;
  if (hw.features.hasHL) {
    digitalWrite(hw.pins.pinHl, wantHigh ? LOW : HIGH);
  }
  rssiOn = desiredState.flags & HOST_STATE_RSSI_ENABLED;

  // A pending retune must never leave host-requested PTT keyed on the old channel.
  if (radioConfigChanged() && mode == MODE_TX) setMode(rxIdleMode());
  if ((desiredState.flags & HOST_STATE_PTT_REQUESTED) && txAllowedByHost()
      && (desiredState.flags & HOST_STATE_RADIO_CONFIG_VALID)
      && !radioConfigChanged()) {
    setMode(MODE_TX);
  } else {
    setMode(rxIdleMode());
  }
  if (sendReport) {
    markDeviceStateDirty();
  }
}

void setMode(Mode newMode) {
  if (mode == newMode) {
    return;
  }
  freeDvRx.reset();
  freeDvTx.reset();
  mode = newMode;
  markDeviceStateDirty();
  switch (mode) {
    case MODE_STOPPED:
      _LOGI("MODE_STOPPED");
      digitalWrite(hw.pins.pinPtt, HIGH);
      endI2STx();
      initI2SRx();
    break;
    case MODE_RX:
      _LOGI("MODE_RX");
      digitalWrite(hw.pins.pinPtt, HIGH);
      endI2STx();
      initI2SRx();
    break;
    case MODE_TX:
      _LOGI("MODE_TX");
      txStartTime = millis();
      txWatchDog.reset(txStartTime);
      digitalWrite(hw.pins.pinPtt, LOW);
      endI2SRx();
      initI2STx();
    break;
  }
}

void setup() {
  boardSetup();
  loadPersistedRadioState();
  // Communication with Android via USB cable
  Serial.setRxBufferSize(USB_BUFFER_SIZE);
  Serial.setTxBufferSize(USB_BUFFER_SIZE);
  protocolUsbSession.windowSize = USB_BUFFER_SIZE;
#if CONFIG_IDF_TARGET_ESP32S3
  protocolUsbSession.connected = false;
#endif
  Serial.begin(115200);
  Serial.println();
  Serial.println("===== kv4p serial output =====");
  Serial.println("This port will emit binary data using the kv4p protocol.");
  Serial.println("You will see watchdog resets — this is expected behavior.");
  Serial.println("Use `logcat` or a kv4p decoder to view readable logs.");
  Serial.println("More info: https://github.com/VanceVagell/kv4p-ht/blob/main/microcontroller-src/kv4p_ht_esp32_wroom_32/readme.md");
  Serial.println("==============================");
#if CONFIG_IDF_TARGET_ESP32
  char bluetoothDeviceName[12];
  formatBluetoothDeviceName(bluetoothDeviceName, sizeof(bluetoothDeviceName));
  bluetoothStarted = SerialBT.begin(bluetoothDeviceName);
  if (bluetoothStarted) {
    protocolBtSession.stream = &SerialBT;
    protocolBtSession.windowSize = USB_BUFFER_SIZE;
  } else {
    _LOGE("Classic Bluetooth init failed");
  }
#endif
  formatBluetoothDeviceName(bleKissDeviceName, sizeof(bleKissDeviceName));
  protocolBleSession.stream = &bleKissStream;
  protocolBleSession.windowSize = BLE_KISS_WINDOW_SIZE;
  if (!bleKissStream.begin()) {
    Serial.println("BLE KISS init failed");
  } else {
    Serial.print("BLE KISS advertising as ");
    Serial.println(bleKissDeviceName);
  }
  // Configure watch dog timer (WDT), which will reset the system if it gets stuck somehow.
  esp_task_wdt_init(10, true);
  esp_task_wdt_add(NULL);
  buttonsSetup();
  // Set up radio module defaults
  pinMode(hw.pins.pinPd, OUTPUT);
  digitalWrite(hw.pins.pinPd, HIGH);  // Power on
  pinMode(hw.pins.pinPtt, OUTPUT);
  digitalWrite(hw.pins.pinPtt, HIGH);  // Rx
  pinMode(hw.pins.pinSq, INPUT);
  if (hw.features.hasHL) {
    pinMode(hw.pins.pinHl, OUTPUT);
    digitalWrite(hw.pins.pinHl, LOW);  // High power
  }
  // Communication with the selected radio module via GPIO pins
  Serial1.begin(9600, SERIAL_8N1, hw.pins.pinRfModuleRxd, hw.pins.pinRfModuleTxd);
  Serial1.setTimeout(10);  // Very short so we don't tie up rx audio while reading from radio module (responses are tiny so this is ok)
  //
  debugSetup();
  // Begin in STOPPED mode
  squelched = true;
  setMode(MODE_STOPPED);
  initI2SRx();
  ledSetup();
  initRadio((desiredState.flags & HOST_STATE_HIGH_POWER) != 0);
  _LOGI("Setup is finished");
}

void initRadio(bool isHigh) {
  if (hw.features.hasHL) {
    digitalWrite(hw.pins.pinHl, isHigh ? LOW : HIGH);
  }
  radioFound = radio.begin(hw.rfModuleType, 3);
  radio.volume(hw.volume);
}

bool radioHelloReady() {
  return !radioFound || normalRadioConfigured ||
    lastDeviceStateError == DEVICE_STATE_ERROR_RADIO_CONFIG_FAILED;
}

void handleRadioResult(const RadioModule::Result &result) {
  uint32_t now = millis();
  switch (result.command) {
      case RadioModule::FILTER:
        radioFilterPending = false;
        if (result.ok) {
          lastDeviceStateError = DEVICE_STATE_ERROR_NONE;
        } else {
          lastDeviceStateError = DEVICE_STATE_ERROR_FILTERS_FAILED;
        }
        // A failed filter command must not prevent channel setup or USB HELLO.
        appliedState.flags = (appliedState.flags & ~(HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW)) | pendingFilterFlags;
        filtersApplied = true;
        break;
      case RadioModule::GROUP:
        radioGroupPending = false;
        if (result.ok) {
          normalRadioConfigured = true;
          appliedModuleSquelch = pendingModuleSquelch;
          appliedState.bw = pendingRadioState.bw;
          appliedState.freq_tx = pendingRadioState.freq_tx;
          appliedState.freq_rx = pendingRadioState.freq_rx;
          appliedState.ctcss_tx = pendingRadioState.ctcss_tx;
          appliedState.squelch = pendingRadioState.squelch;
          appliedState.ctcss_rx = pendingRadioState.ctcss_rx;
          appliedState.memoryId = pendingRadioState.memoryId;
          appliedState.flags |= HOST_STATE_RADIO_CONFIG_VALID;
          softSquelchEffect.setDeadbandLevel(appliedState.squelch);
          freeDvSquelch.setLevel(appliedState.squelch);
          if (freeDv2400bEnabled()) squelched = !freeDvSquelch.open();
          softSquelchEffect.setCtcssTone(appliedState.ctcss_rx);
          if (lastDeviceStateError != DEVICE_STATE_ERROR_FILTERS_FAILED)
            lastDeviceStateError = DEVICE_STATE_ERROR_NONE;
        } else {
          normalRadioConfigured = false;
          lastDeviceStateError = DEVICE_STATE_ERROR_RADIO_CONFIG_FAILED;
        }
        break;
      case RadioModule::OVERRIDE:
        ax25OverrideInProgress = false;
        if (result.ok) {
          ax25OverrideChannelPrepared = true;
          ax25OverrideChannelReadyAt = now + AX25_OVERRIDE_RX_SETTLE_MS;
          lastDeviceStateError = DEVICE_STATE_ERROR_NONE;
        } else {
          lastDeviceStateError = DEVICE_STATE_ERROR_RADIO_CONFIG_FAILED;
        }
        break;
      case RadioModule::RSSI:
        if (result.ok) {
          uint8_t rssi = result.value;
          if (hw.rfModuleType == RF_SA518_DUAL) {
            rssi = rssi / 2 - 30;
          }
          //_LOGD("Radio RSSI response: %d", rssi);
          if (latestRssi != rssi) latestRssi = rssi;
        }
        break;
    default: break;
  }
  markDeviceStateDirty();
}

void radioLoop() {
  radio.loop();

  static bool usbHelloSent = false;
#if !CONFIG_IDF_TARGET_ESP32S3
  if (radioHelloReady() && !usbHelloSent) {
    sendHello(protocolUsbSession, FIRMWARE_VER, radioStatus(), hw.rfModuleType,
      moduleMinRadioFreq(), moduleMaxRadioFreq(), getFirmwareFeatures(),
      currentDeviceState(protocolUsbSession.flags));
    usbHelloSent = true;
  }
#endif
  if (!radioFound || ax25OverrideChannelPrepared || ax25OverrideInProgress) return;

  uint16_t filterFlags = desiredFilterFlags();
  uint16_t appliedFilterFlags = appliedState.flags &
    (HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW);
  if (!radioFilterPending && (!filtersApplied || filterFlags != appliedFilterFlags)) {
    rxDownsample.setFilters((filterFlags & HOST_STATE_FILTER_HIGH) != 0,
                            (filterFlags & HOST_STATE_FILTER_LOW) != 0);
    pendingFilterFlags = filterFlags;
    radioFilterPending = true;
    radio.filter((filterFlags & HOST_STATE_FILTER_PRE) != 0);
    return;
  }
  if (radioFilterPending) return;

  if (!radioGroupPending && (desiredState.flags & HOST_STATE_RADIO_CONFIG_VALID) && radioConfigChanged()) {
    if (!isModuleRadioFreq(desiredState.freq_tx) || !isModuleRadioFreq(desiredState.freq_rx)
        || desiredState.bw > 1 || desiredState.ctcss_tx > 38) {
      lastDeviceStateError = DEVICE_STATE_ERROR_RADIO_CONFIG_FAILED;
      return;
    }
    pendingRadioState = desiredState;
    pendingModuleSquelch = moduleSquelchLevel();
    setMode(rxIdleMode());
    if (!radio.group(desiredState.bw, desiredState.freq_tx,
      desiredState.freq_rx, desiredState.ctcss_tx, RadioModule::GROUP,
      pendingModuleSquelch)) {
      lastDeviceStateError = DEVICE_STATE_ERROR_RADIO_CONFIG_FAILED;
    } else {
      radioGroupPending = true;
    }
    return;
  }
  if (!radioGroupPending) reconcileDesiredState(false);
}

void handleCommands(ProtocolSession &session, RcvCommand command, uint8_t *params, size_t param_len) {
  switch (command) {
    case COMMAND_HOST_TX_AUDIO:
      if (mode == MODE_TX && !freeDv2400bEnabled()) {
        processTxAudio(params, param_len);
        esp_task_wdt_reset();
      }
      break;
    case COMMAND_HOST_TX_DIGITAL:
      // The command ID unambiguously selects the digital path. Do not also
      // gate it on the session flag: PTT and session-state snapshots travel
      // independently and the first voice frame can win that race.
      if (mode == MODE_TX && freeDv2400bEnabled()) {
        processTxDigital(params, param_len);
        esp_task_wdt_reset();
      }
      break;
    case COMMAND_HOST_DESIRED_STATE:
      if (param_len == sizeof(HostDesiredState)) {
        HostDesiredState incomingState;
        memcpy(&incomingState, params, sizeof(HostDesiredState));
        uint16_t oldSessionFlags = session.flags;
        session.flags = incomingState.flags & HOST_STATE_SESSION_FLAG_MASK;
        bool sessionFlagsChanged = oldSessionFlags != session.flags;
        // Desired-state sequence is global across transports; hosts must sync from
        // DeviceState.appliedSequence before sending their next update.
        bool globalStateChanged = incomingState.sequence > desiredState.sequence;
        if (globalStateChanged) {
          HostDesiredState previousState = desiredState;
          const bool freeDvModeChanged =
              ((incomingState.flags ^ desiredState.flags) &
               HOST_STATE_FREEDV_2400B) != 0;
          desiredState = incomingState;
          desiredState.flags &= HOST_STATE_GLOBAL_FLAG_MASK;
          if (!samePersistedRadioState(previousState, desiredState))
            desiredRadioStateChangedAtMs = millis();
          if (freeDvModeChanged) {
            latestRssi = 0;
            freeDvSquelch.reset();
            squelched = freeDv2400bEnabled()
                ? !freeDvSquelch.open()
                : !softSquelchEffect.isSoftOpen();
          }
        }
        if (sessionFlagsChanged || globalStateChanged) {
          reconcileDesiredState();
        }
        esp_task_wdt_reset();
      }
      break;
    case COMMAND_HOST_TX_AX25:
      if (param_len > sizeof(Ax25TxOverride)) {
        Ax25TxOverride txOverride;
        memcpy(&txOverride, params, sizeof(txOverride));
        size_t ax25Len = param_len - sizeof(txOverride);
        if (isModuleRadioFreq(txOverride.freqTx) && ax25Len <= AX25_MAX_KISS_DATA_LEN
            && !ax25TxScheduler.enqueue(params + sizeof(txOverride), ax25Len, &txOverride)) {
          _LOGW("AX.25 TX queue full; dropped frequency-override job");
        }
      }
      break;
  }
}

void handleAx25Data(uint8_t *ax25, size_t ax25_len) {
  if (ax25_len > 0 && ax25_len <= AX25_MAX_KISS_DATA_LEN && txAllowedByHost()) {
    if (!ax25TxScheduler.enqueue(ax25, ax25_len)) {
      _LOGW("AX.25 TX queue full; dropped KISS DATA frame");
    }
  }
}

void handleKissParameter(uint8_t command, uint8_t value) {
  if (command == KISS_CMD_TXDELAY) ax25TxScheduler.setTxDelay(value);
  else if (command == KISS_CMD_PERSIST) ax25TxScheduler.setPersist(value);
  else if (command == KISS_CMD_SLOTTIME) ax25TxScheduler.setSlotTime(value);
}

void prepareAx25TxOverrideChannel(const Ax25TxOverride &txOverride) {
  if (radio.group(txOverride.bw, txOverride.freqTx,
      txOverride.freqTx, txOverride.ctcssTx, RadioModule::OVERRIDE)) {
    normalRadioConfigured = false;
    ax25OverrideInProgress = true;
    markDeviceStateDirty();
  }
}

// Android sends COMMAND_HOST_TX_AX25 for every APRS packet, including a
// beacon on the channel that is already configured. Avoid an unnecessary
// radio group command in that case: it would otherwise also force a second
// group command immediately after PTT is released.
bool ax25OverrideMatchesActiveChannel(const Ax25TxOverride &txOverride) {
  static constexpr float FREQ_MATCH_EPSILON_MHZ = 0.0001f;
  return normalRadioConfigured
    && (desiredState.flags & HOST_STATE_RADIO_CONFIG_VALID)
    && txOverride.bw == desiredState.bw
    && txOverride.ctcssTx == desiredState.ctcss_tx
    && fabsf(txOverride.freqTx - desiredState.freq_tx) < FREQ_MATCH_EPSILON_MHZ
    && fabsf(txOverride.freqTx - desiredState.freq_rx) < FREQ_MATCH_EPSILON_MHZ;
}

void ax25TxLoop() {
  bool receiveIdle = mode == MODE_RX || mode == MODE_STOPPED;
  if (!receiveIdle) return;
  if (ax25TxScheduler.dropDisallowedStandardJobs(txAllowedByHost()) > 0) {
    _LOGW("Dropped queued KISS DATA frame after TX became disallowed");
  }
  const Ax25TxJob *pendingJob = ax25TxScheduler.head();
  if (pendingJob == nullptr || !radioFound) return;
  uint32_t now = millis();
  if (pendingJob->hasTxOverride && !ax25OverrideMatchesActiveChannel(pendingJob->txOverride)) {
    // A host configuration update may have restored the normal radio while
    // this job was waiting, so prepare the target channel again in that case.
    if (!ax25OverrideChannelPrepared || normalRadioConfigured) {
      if (!ax25OverrideInProgress && !radio.busy() &&
          !radioFilterPending && !radioGroupPending)
        prepareAx25TxOverrideChannel(pendingJob->txOverride);
      return;
    }
    if ((int32_t)(now - ax25OverrideChannelReadyAt) < 0) return;
  }
  if (radio.busy() || radioFilterPending || radioGroupPending ||
      (!pendingJob->hasTxOverride && radioConfigChanged())) return;

  bool ourTx = mode == MODE_TX;
  bool afskDcd = afskDemod.carrierDetected();
  bool rfCarrierDetected;
  if (hw.rfModuleType == RF_SA518_DUAL) {
    // SQ=0 bypasses hardware squelch, so use AFSK DCD alone.
    rfCarrierDetected = appliedModuleSquelch > 0 && digitalRead(hw.pins.pinSq) == LOW;
  } else {
    rfCarrierDetected = softSquelchEffect.isCarrierDetected();
  }
  bool channelBusy = ourTx || afskDcd || rfCarrierDetected;
  bool channelClear = !channelBusy;
  if (!ax25TxScheduler.ready(now, channelClear, (uint8_t)esp_random())) {
    return;
  }
  const Ax25TxJob *job = ax25TxScheduler.head();
  if (job == nullptr) return;

  setMode(MODE_TX);
  latestRssi = (uint8_t)TX_AUDIO_LEVEL_FULL_SCALE_RSSI;
  txAudioLevel = TX_AUDIO_LEVEL_FULL_SCALE_RSSI;
  sendCurrentDeviceState();
  // BLE state frames are queued until bleKissLoop() runs. AFSK modulation is
  // synchronous, so flush TX state now rather than delivering it together
  // with the RX state after the packet finishes.
  if (protocolHasBleSession()
      && (protocolBleSession.flags & HOST_STATE_ENABLE_STATUS_REPORTS)) {
    bleKissStream.flush();
  }
  pulseAprsTxLED();
  bool firstFrame = true;
  bool sentOverride = job->hasTxOverride;
  do {
    const Ax25TxJob *nextJob = ax25TxScheduler.next();
    bool batchNextStandardFrame = !job->hasTxOverride && nextJob != nullptr && !nextJob->hasTxOverride;
    processTxAx25(job->data, job->len, firstFrame ? ax25TxScheduler.txDelayMs() : 0,
                  batchNextStandardFrame ? 0 : TX_AFSK_TAIL_SILENCE_MS);
    ax25TxScheduler.complete();
    if (!batchNextStandardFrame) break;
    job = ax25TxScheduler.head();
    firstFrame = false;
  } while (job != nullptr);
  setMode(rxIdleMode());
  if (sentOverride) ax25OverrideChannelPrepared = false;
  // Apply the latest desired normal configuration only after PTT is released.
  reconcileDesiredState(false);
  sendCurrentDeviceState();
  esp_task_wdt_reset();
}

void rssiLoop() {
  if (rssiOn) {
    EVERY_N_MILLISECONDS(RSSI_REPORT_INTERVAL_MS) {
      if (mode == MODE_TX) {
        uint8_t rssi = (uint8_t)roundf(constrain(txAudioLevel, 0.0f, 255.0f));
        if (latestRssi != rssi) {
          latestRssi = rssi;
          markDeviceStateDirty();
        }
      } else if (mode == MODE_RX && !freeDv2400bEnabled() &&
                 radioFound && !radio.busy() && !radioConfigChanged() &&
                 filtersApplied && desiredFilterFlags() ==
                   (appliedState.flags & (HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW))) {
        radio.rssi();
      }
    }
    END_EVERY_N_MILLISECONDS();
  }
}

void deviceStateLoop() {
  if (!protocolAnySessionFlag(HOST_STATE_ENABLE_STATUS_REPORTS)) {
    return;
  }

  bool sent = false;
  if (deviceStateDirty) {
    sendCurrentDeviceState();
    sent = true;
  }
  EVERY_N_MILLISECONDS(DEVICE_STATE_REPORT_INTERVAL_MS) {
    if (!sent) {
      sendCurrentDeviceState();
    }
  }
  END_EVERY_N_MILLISECONDS();
}

void bluetoothLoop() {
#if CONFIG_IDF_TARGET_ESP32
  if (!bluetoothStarted) return;
  bool connected = SerialBT.hasClient();
  if (connected && radioHelloReady() && !bluetoothProtocolConnected) {
    bluetoothProtocolConnected = true;
    protocolBtSession.connected = true;
    bluetoothParser.reset();
    sendHello(protocolBtSession, FIRMWARE_VER, radioStatus(), hw.rfModuleType,
      moduleMinRadioFreq(), moduleMaxRadioFreq(), getFirmwareFeatures(),
      currentDeviceState(protocolBtSession.flags));
  } else if (!connected && bluetoothProtocolConnected) {
    bluetoothProtocolConnected = false;
    protocolBtSession.connected = false;
    uint16_t oldSessionFlags = protocolBtSession.flags;
    protocolBtSession.flags = 0;
    bluetoothParser.reset();
    if (oldSessionFlags != 0) reconcileDesiredState();
  }
  if (bluetoothProtocolConnected) bluetoothParser.loop();
#endif
}

void bleKissLoop() {
  bleKissStream.loop();
  bool connected = bleKissStream.isConnected();
  bool protocolReady = bleKissStream.canSend();
  if (protocolReady && radioHelloReady() && !bleKissProtocolConnected) {
    bleKissParser.reset();
    sendHello(protocolBleSession, FIRMWARE_VER, radioStatus(), hw.rfModuleType, moduleMinRadioFreq(), moduleMaxRadioFreq(), getFirmwareFeatures(), currentDeviceState(protocolBleSession.flags));
    bleKissProtocolConnected = true;
    protocolBleSession.connected = true;
    _LOGI("BLE KISS sent HELLO after notify subscription: firmware=%u window=%u", FIRMWARE_VER, BLE_KISS_WINDOW_SIZE);
  } else if ((!connected || !protocolReady) && bleKissProtocolConnected) {
    bleKissProtocolConnected = false;
    protocolBleSession.connected = false;
    uint16_t oldSessionFlags = protocolBleSession.flags;
    protocolBleSession.flags = 0;
    bleKissParser.reset();
    if (oldSessionFlags != 0) {
      reconcileDesiredState();
    }
  }

  if (bleKissProtocolConnected) {
    bleKissParser.loop();
  }
}

void usbConnectionLoop() {
#if CONFIG_IDF_TARGET_ESP32S3
  // Native CDC disappears and reappears on reset. Send HELLO each time the
  // Android host opens the new port, after it has asserted DTR.
  bool connected = static_cast<bool>(Serial);
  if (connected && radioHelloReady() && !protocolUsbSession.connected) {
    parser.reset();
    protocolUsbSession.connected = true;
    sendHello(protocolUsbSession, FIRMWARE_VER, radioStatus(),
      hw.rfModuleType, moduleMinRadioFreq(), moduleMaxRadioFreq(),
      getFirmwareFeatures(), currentDeviceState(protocolUsbSession.flags));
  } else if (!connected && protocolUsbSession.connected) {
    protocolUsbSession.connected = false;
    uint16_t oldSessionFlags = protocolUsbSession.flags;
    protocolUsbSession.flags = 0;
    parser.reset();
    if (oldSessionFlags != 0) reconcileDesiredState();
  }
#endif
}

void squelchLoop() {
  freeDvSquelchLoop();
  if (freeDv2400bEnabled()) return;
  bool nextSquelched = hw.rfModuleType == RF_SA518_DUAL
    ? !softSquelchEffect.isCtcssDetected() ||
      (desiredState.squelch > 0 &&
       (appliedModuleSquelch == 0 || digitalRead(hw.pins.pinSq) == HIGH))
    : !softSquelchEffect.isSoftOpen();
  if (nextSquelched != squelched) {
    squelched = nextSquelched;
    markDeviceStateDirty();
  }
}

void loop() {
  radioLoop();
  usbConnectionLoop();
  squelchLoop();
  debugLoop();
  ledLoop();
  buttonsLoop();
  if (radioHelloReady()) protocolLoop();
  bluetoothLoop();
  bleKissLoop();
  rxAudioLoop();
  ax25TxLoop();
  txAudioLoop();
  rssiLoop();
  deviceStateLoop();
  savePersistedRadioStateIfChanged();
}
