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

#include <FreeDv2400b.h>
#include <stdint.h>

class FreeDvSquelch {
public:
  static constexpr uint8_t GOOD_FRAMES_TO_OPEN = 10;
  static constexpr uint8_t BAD_FRAMES_TO_CLOSE = 20;

  explicit FreeDvSquelch(uint8_t level = 4) { setLevel(level); reset(); }

  void setLevel(uint8_t level) {
    level_ = level > 8 ? 8 : level;
    if (level_ == 0) open_ = true;
  }

  uint8_t level() const { return level_; }
  bool open() const { return open_; }

  bool accept(const FreeDv2400bDecodeResult &result) {
    if (result.frameType != FreeDv2400bFrameType::VOICE) return false;
    if (level_ == 0) {
      open_ = true;
      return true;
    }

    static const uint8_t maxUwErrors[9] = {16, 7, 6, 5, 4, 3, 2, 1, 0};
    static const float minimumSnrDb[9] =  {-100.0f, 0.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f};
    const bool good = result.synchronized && result.uniqueWordErrors <= maxUwErrors[level_] && result.discriminatorSnrDb >= minimumSnrDb[level_];
    if (good) {
      badFrames_ = 0;
      if (goodFrames_ < 255) ++goodFrames_;
      if (goodFrames_ >= GOOD_FRAMES_TO_OPEN) open_ = true;
    } else {
      goodFrames_ = 0;
      if (badFrames_ < 255) ++badFrames_;
      if (badFrames_ >= BAD_FRAMES_TO_CLOSE) open_ = false;
    }
    return open_ && good;
  }

  void reset() {
    goodFrames_ = 0;
    badFrames_ = 0;
    open_ = level_ == 0;
  }

private:
  uint8_t level_;
  uint8_t goodFrames_;
  uint8_t badFrames_;
  bool open_;
};
