/*
    Based on chegewara example for IDF: https://github.com/chegewara/esp32-OTA-over-BLE
    Ported to Arduino ESP32 by Claes Hallberg
    Licence: MIT
    OTA Bluetooth example between ESP32 (using NimBLE Bluetooth stack) and iOS swift (CoreBluetooth framework)
    Tested withh NimBLE v 1.3.1, iOS 14, ESP32 core 1.06
    N.B standard "nimconfig.h" needs to be customised (see below). In this example we only use the ESP32
    as perhipheral, hence no need to activate scan or central mode. Stack usage performs better for file transfer
    if stack is increased to 8192 Bytes
*/
#include "NimBLEDevice.h"     // via Arduino library manager // https://github.com/h2zero/NimBLE-Arduino
// The following file needs to be changed: "nimconfig.h"
// Line 14: uncomment and increase MTU size to: #define CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU 512
// Line 45: uncomment : #define CONFIG_BT_NIMBLE_ROLE_CENTRAL_DISABLED
// Line 50: uncomment : #define CONFIG_BT_NIMBLE_ROLE_OBSERVER_DISABLED
// Line 86: uncomments and increase stack size to : #define CONFIG_BT_NIMBLE_TASK_STACK_SIZE 8192

#include "esp_ota_ops.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <esp_task_wdt.h>

/*------------------------------------------------------------------------------
  BLE instances & variables
  ----------------------------------------------------------------------------*/
BLEServer* pServer = NULL;
BLECharacteristic * pTxCharacteristic;
BLECharacteristic * pOtaCharacteristic;

bool deviceConnected = false;
bool oldDeviceConnected = false;

String fileExtension = "";

#define SERVICE_UUID                  "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
#define CHARACTERISTIC_TX_UUID        "62ec0272-3ec5-11eb-b378-0242ac130003"
#define CHARACTERISTIC_OTA_UUID       "62ec0272-3ec5-11eb-b378-0242ac130005"

/*------------------------------------------------------------------------------
  OTA instances & variables
  ----------------------------------------------------------------------------*/
static esp_ota_handle_t otaHandler = 0;
static const esp_partition_t *update_partition = NULL;

uint8_t     txValue = 0;
int         bufferCount = 0;
bool        downloadFlag = false;

/*------------------------------------------------------------------------------
  BLE Server callback
  ----------------------------------------------------------------------------*/
class MyServerCallbacks: public BLEServerCallbacks {
    
    void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
      Serial.println("*** App connected");
      /*----------------------------------------
       * BLE Power settings. P9 = max power +9db
       ---------------------------------------*/
      esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_CONN_HDL0, ESP_PWR_LVL_P9);
      esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_CONN_HDL1, ESP_PWR_LVL_P9);
      esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_DEFAULT, ESP_PWR_LVL_P9);
      esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_ADV, ESP_PWR_LVL_P9);

      Serial.println(NimBLEAddress(desc->peer_ota_addr).toString().c_str());
      /*    We can use the connection handle here to ask for different connection parameters.
            Args: connection handle, min connection interval, max connection interval
            latency, supervision timeout.
            Units; Min/Max Intervals: 1.25 millisecond increments.
            Latency: number of intervals allowed to skip.
            Timeout: 10 millisecond increments, try for 5x interval time for best results.
      */
      pServer->updateConnParams(desc->conn_handle, 12, 12, 2, 100);
      deviceConnected = true;
    }

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      downloadFlag    = false;
      Serial.println("*** App disconnected");
    }
};

/*------------------------------------------------------------------------------
  BLE Peripheral callback(s)
  ----------------------------------------------------------------------------*/
  
class otaCallback: public BLECharacteristicCallbacks {
    
    void onWrite(BLECharacteristic *pCharacteristic) 
    {
      std::string rxData = pCharacteristic->getValue();
      bufferCount++;
     
      if (!downloadFlag) 
      {
        //-----------------------------------------------
        // First BLE bytes have arrived
        //-----------------------------------------------
        
        Serial.println("1. BeginOTA");
        const esp_partition_t *configured = esp_ota_get_boot_partition();
        const esp_partition_t *running = esp_ota_get_running_partition();

        if (configured != running) 
        {
          Serial.printf("ERROR: Configured OTA boot partition at offset 0x%08x, but running from offset 0x%08x", configured->address, running->address);
          Serial.println("(This can happen if either the OTA boot data or preferred boot image become corrupted somehow.)");
          downloadFlag = false;
          esp_ota_end(otaHandler);
        } else {
          Serial.printf("2. Running partition type %d subtype %d (offset 0x%08x) \n", running->type, running->subtype, running->address);
        }

        update_partition = esp_ota_get_next_update_partition(NULL);
        assert(update_partition != NULL);

        Serial.printf("3. Writing to partition subtype %d at offset 0x%x \n", update_partition->subtype, update_partition->address);
        
        //------------------------------------------------------------------------------------------
        // esp_ota_begin can take a while to complete as it erase the flash partition (3-5 seconds) 
        // so make sure there's no timeout on the client side (iOS) that triggers before that. 
        //------------------------------------------------------------------------------------------
        esp_task_wdt_init(10, false);
        vTaskDelay(5);
        
        if (esp_ota_begin(update_partition, OTA_SIZE_UNKNOWN, &otaHandler) != ESP_OK) {
          downloadFlag = false;
          return;
        }
        downloadFlag = true;
      }
      
      if (bufferCount >= 1 || rxData.length() > 0) 
      { 
        if(esp_ota_write(otaHandler, (uint8_t *) rxData.c_str(), rxData.length()) != ESP_OK) {
          Serial.println("Error: write to flash failed");
          downloadFlag = false;
          return;
        } else {
          bufferCount = 1;
          Serial.println("--Data received---");
          //Notify the iOS app so next batch can be sent
          pTxCharacteristic->setValue(&txValue, 1);
          pTxCharacteristic->notify();
        }
        
        //-------------------------------------------------------------------
        // check if this was the last data chunk? (normaly the last chunk is 
        // smaller than the maximum MTU size). For improvement: let iOS app send byte 
        // length instead of hardcoding "510"
        //-------------------------------------------------------------------
        if (rxData.length() < 510) // TODO Asumes at least 511 data bytes (@BLE 4.2). 
        {
          Serial.println("4. Final byte arrived");
          //-----------------------------------------------------------------
          // Final chunk arrived. Now check that
          // the length of total file is correct
          //-----------------------------------------------------------------
          if (esp_ota_end(otaHandler) != ESP_OK) 
          {
            Serial.println("OTA end failed ");
            downloadFlag = false;
            return;
          }
          
          //-----------------------------------------------------------------
          // Clear download flag and restart the ESP32 if the firmware
          // update was successful
          //-----------------------------------------------------------------
          Serial.println("Set Boot partion");
          if (ESP_OK == esp_ota_set_boot_partition(update_partition)) 
          {
            esp_ota_end(otaHandler);
            downloadFlag = false;
            Serial.println("Restarting...");
            esp_restart();
            return;
          } else {
            //------------------------------------------------------------
            // Something whent wrong, the upload was not successful
            //------------------------------------------------------------
            Serial.println("Upload Error");
            downloadFlag = false;
            esp_ota_end(otaHandler);
            return;
          }
        }
      } else {
        downloadFlag = false;
      }
    }
};



void setup() {
  Serial.begin(115200);
  Serial.println("Starting BLE OTA work!");
  Serial.printf("ESP32 Chip model = %d\n", ESP.getChipRevision());
  Serial.printf("This chip has %d MHz\n", ESP.getCpuFreqMHz());

  // 1. Create the BLE Device
  NimBLEDevice::init("ESP32 iOS OTA NimBLE");
  NimBLEDevice::setMTU(517);
  
  // 2. Create the BLE server
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // 3. Create BLE Service
  NimBLEService *pService = pServer->createService(SERVICE_UUID);
  
  // 4. Create BLE Characteristics inside the service(s)
  pTxCharacteristic = pService->createCharacteristic(CHARACTERISTIC_TX_UUID,
                      NIMBLE_PROPERTY:: NOTIFY);

  pOtaCharacteristic = pService->createCharacteristic(CHARACTERISTIC_OTA_UUID,
                       NIMBLE_PROPERTY:: WRITE_NR);
  pOtaCharacteristic->setCallbacks(new otaCallback());

  // 5. Start the service(s)
  pService->start();

  // 6. Start advertising
  pServer->getAdvertising()->addServiceUUID(pService->getUUID());
  pServer->getAdvertising()->start();
  
  NimBLEDevice::startAdvertising();
  Serial.println("Waiting a client connection to notify...");
  downloadFlag = false;
}


void loop() {
  if (!deviceConnected && oldDeviceConnected) {
    delay(100);
    pServer->startAdvertising();
    Serial.println("start advertising");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    Serial.println("main loop started");
    oldDeviceConnected = deviceConnected;
  }
}
