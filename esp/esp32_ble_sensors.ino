/*
 * MCT332s Smart Bike Sensor Station — 4-Sensor ESP32 BLE + Wi-Fi Firmware
 * 1. S1 (ON/OFF): Water-Drop / Rain Sensor (FC-37) on GPIO 27
 * 2. S2 (0-5V Analog): 10k Steering Angle Potentiometer on GPIO 34
 * 3. S3 (Conditioned): Wheel Speed Encoder + LPF + Schmitt Trigger on GPIO 18
 * 4. S4 (Extra): MPU6050 6-Axis IMU on GPIO 21 (SDA) / 22 (SCL)
 */
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Wire.h>

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

const int PIN_RAIN_DO   = 27; // S1: LOW when water detected
const int PIN_STEER_POT = 34; // S2: 0-5V Steering Potentiometer
const int PIN_ENC_COND  = 18; // S3: Conditioned Encoder Schmitt Trigger Output
const int MPU_ADDR      = 0x68; // S4: MPU6050 I2C
