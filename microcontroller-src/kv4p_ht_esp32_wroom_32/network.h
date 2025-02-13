#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <esp_task_wdt.h>
#include "secrets.h"
#include "debug.h"
#include <ArduinoOTA.h>

#define CLIENT_ID_TEMPLATE "kv4p-%06X"
#define CLIENT_ID_SIZE (sizeof(CLIENT_ID_TEMPLATE) + 5)

String deviceId;

void initDeviceId() {
#if defined(DEVICE_ID)
    deviceId = DEVICE_ID;
#else
    char clientId[CLIENT_ID_SIZE];
    uint64_t mac = ESP.getEfuseMac();
    uint32_t chipid = (mac >> 24) & 0xFFFFFF; 
    snprintf(clientId, CLIENT_ID_SIZE, CLIENT_ID_TEMPLATE, chipid);
    deviceId = String(clientId);
#endif
}

const char *getDeviceId() {
    return deviceId.c_str();
}

void WiFiSTAConnect() {
  //WiFi.disconnect();
  WiFi.mode(WIFI_STA);
  WiFi.persistent(true);
  WiFi.setSleep(false);
#if (!defined(IP_CONFIGURATION_TYPE) || (IP_CONFIGURATION_TYPE == IP_CONFIGURATION_TYPE_DHCP))
  //WiFi.config(INADDR_NONE, INADDR_NONE, INADDR_NONE);
  WiFi.config(INADDR_NONE, INADDR_NONE, INADDR_NONE, INADDR_NONE);
#elif (defined(IP_CONFIGURATION_TYPE) && (IP_CONFIGURATION_TYPE == IP_CONFIGURATION_TYPE_STATIC))
#define IP(name, value) IPAddress name(value);
  IP(local_ip, IP_CONFIGURATION_ADDRESS);
  IP(local_mask, IP_CONFIGURATION_MASK);
  IP(gw, IP_CONFIGURATION_GW);
  WiFi.config(local_ip, gw, local_mask);
#else
#error "Incorrect IP_CONFIGURATION_TYPE."
#endif
  WiFi.setHostname(getDeviceId());
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  WiFi.setHostname(getDeviceId());
  WiFi.setAutoReconnect(true);
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
}

void WiFiStationConnected(WiFiEvent_t event, WiFiEventInfo_t info) {
  _LOGI("Connected to AP successfully!");
}

void wiFiStationDisconnected(WiFiEvent_t event, WiFiEventInfo_t info) {
  WiFiSTAConnect();
}

void wiFiGotIP(WiFiEvent_t event, WiFiEventInfo_t info) {
  _LOGI("WiFi connected!");
  _LOGI("IP address: %s", WiFi.localIP().toString().c_str());
  _LOGI("IP hostname: %s", WiFi.getHostname());
}

void setupWiFi() {
  btStop();
  WiFiSTAConnect();
  WiFi.onEvent(WiFiStationConnected, WiFiEvent_t::ARDUINO_EVENT_WIFI_STA_CONNECTED);
  WiFi.onEvent(wiFiStationDisconnected, WiFiEvent_t::ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  WiFi.onEvent(wiFiGotIP, WiFiEvent_t::ARDUINO_EVENT_WIFI_STA_GOT_IP);
#if defined(NTP_SERVER)
  sntp_setoperatingmode(SNTP_OPMODE_POLL);
  sntp_setservername(0, (char *)NTP_SERVER);
  sntp_init();
#endif
  while (WiFi.waitForConnectResult() != WL_CONNECTED) {
    _LOGE("Wifi connection failed!");
  }
}

void otaProgress(unsigned int pg, unsigned int total) {
  esp_task_wdt_reset();
}
  
void inline networkSetup() {
  initDeviceId();
  WiFi.setHostname(getDeviceId());
  WiFi.begin("", "");
  setupWiFi();
  ArduinoOTA.setMdnsEnabled(true);
  ArduinoOTA.setHostname(getDeviceId());
  ArduinoOTA.onProgress(&otaProgress);
  ArduinoOTA.begin();
}
  
void inline networkLoop() { 
  ArduinoOTA.handle(); 
}