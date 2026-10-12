#include <Arduino.h>
#include <unity.h>
#include <string>
#include <vector>

#include "radioModule.h"

static std::vector<RadioModule::Result> radioEvents;

static void onRadioResult(const RadioModule::Result &result) {
  radioEvents.push_back(result);
}

class FakeRadioPort : public Stream {
public:
  std::string sent;
  std::string received;
  bool replyToStartup = false;

  int available() override { return received.size(); }
  int read() override {
    if (received.empty()) return -1;
    int byte = received.front();
    received.erase(0, 1);
    return byte;
  }
  int peek() override { return received.empty() ? -1 : received.front(); }
  size_t write(uint8_t byte) override {
    sent += (char)byte;
    if (replyToStartup && byte == '\n') {
      if (sent.find("AT+DMOCONNECT\r\n") != std::string::npos &&
          sent.rfind("AT+DMOCONNECT\r\n") == sent.size() - 15)
        received += "+DMOCONNECT:0\r\n";
      else if (sent.rfind("AT+DMOSETVOLUME=") != std::string::npos)
        received += "+DMOSETVOLUME:0\r\n";
    }
    return 1;
  }
};

void test_frequency_limits_use_module_enum() {
  TEST_ASSERT_TRUE(RadioModule::validFrequency(RF_SA518_DUAL, 144.0f));
  TEST_ASSERT_TRUE(RadioModule::validFrequency(RF_SA518_DUAL, 435.0f));
  TEST_ASSERT_FALSE(RadioModule::validFrequency(RF_SA518_DUAL, 200.0f));
  TEST_ASSERT_FALSE(RadioModule::validFrequency(RF_SA518_DUAL, 480.0f));
  TEST_ASSERT_FALSE(RadioModule::validFrequency(RF_SA818_VHF, 435.0f));
  TEST_ASSERT_FALSE(RadioModule::validFrequency(RF_SA818_UHF, 144.0f));
  TEST_ASSERT_FALSE(RadioModule::validFrequency(static_cast<RfModuleType>(99), 144.0f));
}

void test_begin_uses_bounded_handshake_retries() {
  nativeTestMillis = 0;
  radioEvents.clear();
  FakeRadioPort port;
  RadioModule radio(port, onRadioResult);
  TEST_ASSERT_FALSE(radio.begin(RF_SA818_VHF, 2));
  TEST_ASSERT_EQUAL_UINT32(2250, nativeTestMillis);
  TEST_ASSERT_EQUAL_STRING("AT+DMOCONNECT\r\nAT+DMOCONNECT\r\n", port.sent.c_str());
  delay(2000);
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+DMOCONNECT\r\nAT+DMOCONNECT\r\n", port.sent.c_str());
}

void test_volume_is_queued_after_begin_and_tracks_latest_value() {
  nativeTestMillis = 0;
  radioEvents.clear();
  FakeRadioPort port;
  port.replyToStartup = true;
  RadioModule radio(port, onRadioResult);
  TEST_ASSERT_TRUE(radio.begin(RF_SA818_VHF, 2));
  TEST_ASSERT_EQUAL_STRING("AT+DMOCONNECT\r\n", port.sent.c_str());
  radioEvents.clear();
  port.sent.clear();
  radio.volume(9);
  TEST_ASSERT_TRUE(port.sent.empty());
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+DMOSETVOLUME=8\r\n", port.sent.c_str());
  radio.volume(4);
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+DMOSETVOLUME=8\r\nAT+DMOSETVOLUME=4\r\n", port.sent.c_str());
  radio.loop();
  TEST_ASSERT_FALSE(radio.busy());
  TEST_ASSERT_EQUAL(2, radioEvents.size());
  TEST_ASSERT_EQUAL(RadioModule::VOLUME, radioEvents[0].command);
  TEST_ASSERT_EQUAL(RadioModule::VOLUME, radioEvents[1].command);
}

void test_filter_and_group_are_queued_and_acknowledged_in_order() {
  nativeTestMillis = 0;
  radioEvents.clear();
  FakeRadioPort port;
  port.replyToStartup = true;
  RadioModule radio(port, onRadioResult);
  TEST_ASSERT_TRUE(radio.begin(RF_SA518_DUAL, 3));
  radio.volume(9);
  radio.loop();
  radio.loop();
  TEST_ASSERT_FALSE(radio.busy());
  radioEvents.clear();
  port.sent.clear();

  radio.filter(true);
  TEST_ASSERT_TRUE(radio.group(1, 144.5f, 435.5f, 0));
  TEST_ASSERT_TRUE(port.sent.empty());
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+SETFILTER=0,1,1\r\n", port.sent.c_str());
  port.received = "+DMOSETFILTER:0\r\n";
  radio.loop();
  TEST_ASSERT_EQUAL_STRING(
    "AT+SETFILTER=0,1,1\r\nAT+DMOSETGROUP=1,144.5000,435.5000,0000,0,0000\r\n",
    port.sent.c_str());
  port.received = "+DMOSETGROUP:0\r\n";
  radio.loop();
  TEST_ASSERT_EQUAL(2, radioEvents.size());
  TEST_ASSERT_EQUAL(RadioModule::FILTER, radioEvents[0].command);
  TEST_ASSERT_EQUAL(RadioModule::GROUP, radioEvents[1].command);
}

void test_rssi_requests_coalesce_and_report_through_callback() {
  nativeTestMillis = 0;
  radioEvents.clear();
  FakeRadioPort port;
  port.replyToStartup = true;
  RadioModule radio(port, onRadioResult);
  TEST_ASSERT_TRUE(radio.begin(RF_SA518_DUAL, 3));
  radioEvents.clear();
  port.sent.clear();

  radio.rssi();
  radio.rssi();
  TEST_ASSERT_TRUE(port.sent.empty());
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+RSSI?\r\n", port.sent.c_str());
  radio.rssi();
  port.received = "RSSI:125\r\n";
  radio.loop();
  radio.loop();
  TEST_ASSERT_EQUAL_STRING("AT+RSSI?\r\n", port.sent.c_str());
  TEST_ASSERT_EQUAL(1, radioEvents.size());
  TEST_ASSERT_EQUAL(RadioModule::RSSI, radioEvents[0].command);
  TEST_ASSERT_TRUE(radioEvents[0].ok);
  TEST_ASSERT_EQUAL(125, radioEvents[0].value);
}

void test_failed_group_delays_next_queued_command() {
  nativeTestMillis = 0;
  radioEvents.clear();
  FakeRadioPort port;
  port.replyToStartup = true;
  RadioModule radio(port, onRadioResult);
  TEST_ASSERT_TRUE(radio.begin(RF_SA818_UHF, 3));
  radioEvents.clear();
  TEST_ASSERT_TRUE(radio.group(1, 435.0f, 435.0f, 0));
  radio.loop();
  size_t firstCommandLength = port.sent.size();
  port.received = "+DMOSETGROUP:1\r\n";
  radio.loop();
  TEST_ASSERT_FALSE(radio.busy());
  TEST_ASSERT_TRUE(radio.group(1, 436.0f, 436.0f, 0));
  delay(499);
  radio.loop();
  TEST_ASSERT_EQUAL(firstCommandLength, port.sent.size());
  delay(1);
  radio.loop();
  TEST_ASSERT_TRUE(port.sent.size() > firstCommandLength);
  TEST_ASSERT_EQUAL(RadioModule::GROUP, radioEvents[0].command);
  TEST_ASSERT_FALSE(radioEvents[0].ok);
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_frequency_limits_use_module_enum);
  RUN_TEST(test_begin_uses_bounded_handshake_retries);
  RUN_TEST(test_volume_is_queued_after_begin_and_tracks_latest_value);
  RUN_TEST(test_filter_and_group_are_queued_and_acknowledged_in_order);
  RUN_TEST(test_rssi_requests_coalesce_and_report_through_callback);
  RUN_TEST(test_failed_group_delays_next_queued_command);
  return UNITY_END();
}
