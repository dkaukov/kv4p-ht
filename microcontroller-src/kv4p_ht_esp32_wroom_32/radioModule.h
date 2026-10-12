#pragma once

#include <Arduino.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "globals.h"

// Desired settings are queued here; loop() serializes AT commands and reports
// results. Only begin() waits for a bounded number of handshake attempts.
class RadioModule {
public:
  enum Command : uint8_t { NONE, HANDSHAKE, VOLUME, FILTER, GROUP, OVERRIDE, RSSI };
  struct Result { Command command; bool ok; int value; };
  using Callback = void (*)(const Result &);
  explicit RadioModule(Stream &port, Callback callback) : port_(port), callback_(callback) {}

  // Try the handshake a bounded number of times before returning. Settings
  // supplied afterward are applied by loop() when the radio is available.
  bool begin(RfModuleType type, uint8_t retries = 3) {
    type_ = type;
    maxHandshakeAttempts_ = retries ? retries : 1;
    initComplete_ = false;
    found_ = false;
    handshakeAttempts_ = 0;
    filterDirty_ = false;
    groupDirty_ = false;
    rssiPending_ = false;
    retryAt_ = millis();
    command_ = NONE;
    resultReady_ = false;
    lineLength_ = 0;
    started_ = true;
    do {
      loop();
      if (initComplete_) break;
      delay(1);
    } while (true);
    return initComplete_ && found_;
  }

  bool busy() const { return command_ != NONE; }

  // Setters accept desired state immediately; the callback reports the
  // acknowledgment or timeout after loop() sends the command.
  void volume(uint8_t level) {
    desiredVolume_ = level < 1 ? 1 : level > 8 ? 8 : level;
    volumeDirty_ = true;
  }
  void filter(bool pre) {
    desiredFilterPre_ = pre;
    filterDirty_ = true;
  }
  static bool validFrequency(RfModuleType type, float mhz) {
    if (!isfinite(mhz)) return false;
    bool vhf = mhz >= 134.0f && mhz <= 174.0f;
    switch (type) {
      case RF_SA818_VHF: return vhf;
      case RF_SA818_UHF: return mhz >= 400.0f && mhz <= 480.0f;
      case RF_SA518_DUAL: return vhf || (mhz >= 400.0f && mhz <= 470.0f);
      default: return false;
    }
  }
  bool group(uint8_t bw, float tx, float rx, uint8_t txTone,
             Command kind = GROUP) {
    if ((kind != GROUP && kind != OVERRIDE) || bw > 1 || txTone > 38 ||
        !validFrequency(type_, tx) || !validFrequency(type_, rx)) return false;
    desiredGroup_ = {bw, tx, rx, txTone};
    desiredKind_ = kind;
    groupDirty_ = true;
    return true;
  }
  // Coalesce repeated requests until this one has been sent or completed.
  void rssi() {
    if (command_ != RSSI) rssiPending_ = true;
  }

  void loop() {
    now_ = millis();
    while (port_.available()) {
      int byte = port_.read();
      if (byte < 0) break;
      if (byte == '\r' || byte == '\n') {
        if (lineLength_) {
          line_[lineLength_] = 0;
          acceptLine();
          lineLength_ = 0;
        }
      } else if (lineLength_ < sizeof(line_) - 1) {
        line_[lineLength_++] = (char)byte;
      } else {
        lineLength_ = 0;
      }
    }
    if (busy() && (int32_t)(now_ - deadline_) >= 0) complete(false, -1);
    if (resultReady_) {
      Result result = result_;
      resultReady_ = false;
      if (callback_) callback_(result);
    }
    if (!started_ || busy() || (int32_t)(now_ - retryAt_) < 0) return;
    if (!initComplete_) {
      if (handshakeAttempts_ < maxHandshakeAttempts_) {
        if (start(HANDSHAKE, "AT+DMOCONNECT\r\n")) handshakeAttempts_++;
      } else {
        initComplete_ = true;
      }
      return;
    }
    if (!found_) return;
    if (volumeDirty_) {
      sentVolume_ = desiredVolume_;
      char command[32];
      snprintf(command, sizeof(command), "AT+DMOSETVOLUME=%u\r\n", sentVolume_);
      start(VOLUME, command);
    } else if (filterDirty_) {
      sentFilterPre_ = desiredFilterPre_;
      char command[32];
      snprintf(command, sizeof(command), "AT+SETFILTER=%u,1,1\r\n", sentFilterPre_ ? 0 : 1);
      start(FILTER, command);
    } else if (groupDirty_) {
      sentGroup_ = desiredGroup_;
      sentKind_ = desiredKind_;
      char command[64];
      snprintf(command, sizeof(command), "AT+DMOSETGROUP=%u,%.4f,%.4f,%04u,0,0000\r\n",
               sentGroup_.bw, sentGroup_.tx, sentGroup_.rx, sentGroup_.txTone);
      start(sentKind_, command);
    } else if (rssiPending_) {
      rssiPending_ = false;
      start(RSSI, type_ == RF_SA518_DUAL ? "AT+RSSI?\r\n" : "RSSI?\r\n");
    }
  }

private:
  struct GroupSettings {
    uint8_t bw;
    float tx;
    float rx;
    uint8_t txTone;
  };
  static bool sameGroup(const GroupSettings &a, const GroupSettings &b) {
    return a.bw == b.bw && a.tx == b.tx && a.rx == b.rx && a.txTone == b.txTone;
  }
  bool start(Command kind, const char *text) {
    if (busy()) return false;
    // Discard a late reply to the previous command before starting another.
    while (port_.available()) port_.read();
    lineLength_ = 0;
    command_ = kind;
    deadline_ = now_ + (kind == HANDSHAKE ? 1000 : 500);
    port_.write((const uint8_t *)text, strlen(text));
    return true;
  }
  void complete(bool ok, int value) {
    if (command_ == HANDSHAKE) {
      if (ok) {
        found_ = true;
        initComplete_ = true;
      } else if (handshakeAttempts_ >= maxHandshakeAttempts_) {
        initComplete_ = true;
      } else {
        retryAt_ = now_ + 250;
      }
    } else if (command_ == VOLUME) {
      volumeDirty_ = desiredVolume_ != sentVolume_;
    } else if (command_ == FILTER) {
      filterDirty_ = desiredFilterPre_ != sentFilterPre_;
    } else if (command_ == GROUP || command_ == OVERRIDE) {
      groupDirty_ = desiredKind_ != sentKind_ ||
        !sameGroup(desiredGroup_, sentGroup_);
      if (!ok) {
        retryAt_ = now_ + 500;
      }
    }
    result_ = {command_, ok, value};
    resultReady_ = true;
    command_ = NONE;
  }
  void acceptLine() {
    if (!busy()) return;
    if (command_ == RSSI) {
      if (strncmp(line_, "RSSI:", 5) && strncmp(line_, "RSSI=", 5)) return;
      int value = -1;
      if (sscanf(line_ + 5, "%d", &value) == 1 && value >= 0 && value <= 255)
        complete(true, value);
      else complete(false, -1);
      return;
    }
    const char *prefix = command_ == HANDSHAKE ? "+DMOCONNECT:" :
      command_ == VOLUME ? "+DMOSETVOLUME:" :
      command_ == FILTER ? "+DMOSETFILTER:" : "+DMOSETGROUP:";
    size_t n = strlen(prefix);
    if (!strncmp(line_, prefix, n)) complete(line_[n] == '0', -1);
  }

  Stream &port_;
  Callback callback_;
  RfModuleType type_ = RF_SA818_VHF;
  Command command_ = NONE;
  Command desiredKind_ = GROUP;
  Command sentKind_ = GROUP;
  Result result_ = {NONE, false, -1};
  bool resultReady_ = false;
  uint32_t deadline_ = 0;
  uint32_t now_ = 0;
  uint32_t retryAt_ = 0;
  uint8_t desiredVolume_ = 1;
  uint8_t sentVolume_ = 1;
  uint8_t handshakeAttempts_ = 0;
  uint8_t maxHandshakeAttempts_ = 3;
  bool started_ = false;
  bool initComplete_ = false;
  bool found_ = false;
  bool volumeDirty_ = false;
  bool desiredFilterPre_ = false;
  bool sentFilterPre_ = false;
  bool filterDirty_ = false;
  bool groupDirty_ = false;
  bool rssiPending_ = false;
  GroupSettings desiredGroup_ = {};
  GroupSettings sentGroup_ = {};
  char line_[48] = {};
  size_t lineLength_ = 0;
};
