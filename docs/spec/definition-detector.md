# GPIO Mapping

## Digital Inputs

| GPIO | Terminology | Additional | Description                                               | Function              | Obs                                                            |
| ---- | ----------- | ---------- | --------------------------------------------------------- | --------------------- | -------------------------------------------------------------- |
| 5    | ACOK        | Pull-up    | Indicates AC power connection                             | AC Status             | 0 (AC) → 1 (NO AC)                                             |
| 6    | BOOST       | Pull-up    | Battery is main power source                              | Battery Status        | 0 (Battery consuming) → 1 (Not consuming)                      |
| 7    | CHG         | Pull-up    | Battery charging                                          | Charge Status         | 0 (Battery charging) → 1 (Not charging)                        |
| 11   | TAMPER      | Pull-up    | Device removed from base                                  | Device opened/removed | 0 (TAMPER OK) → 1 (TAMPER REMOVED)                             |
| 21   | RST/TESTE   | Pull-up    | Test: short press alarm / Reset: long press factory reset | Test device / reset   | 0 (TEST: short press / RESET: long press 5s ) → 1 (NO PRESSED) |
| 4    | DTR_SLEEP   | ?          | Wake-up signal from sensors (temperature/smoke)           | Wake circuit          | Trigger from sensor                                            |

---

## Digital Outputs

| GPIO | Terminology | Additional | Description                      | Function                                            |
| ---- | ----------- | ---------- | -------------------------------- | --------------------------------------------------- |
| 12   | RELE        | -          | Relay control output             | 0 - LOW / 1 - HIGH                                  |
| 38   | EN_PCA9306  | Float      | Enable/disable I2C level shifter | 0 - LOW Disable / 1 - HIGH Enable I2C communication |

---

## ADC Inputs

| GPIO | Terminology | Additional | Description                 |
| ---- | ----------- | ---------- | --------------------------- |
| 10   | BATT        | Db?        | Battery voltage measurement |
| 9    | NTC         | Db?        | Battery temperature         |

---

## PWM Outputs (RGB / Control)

| GPIO | Terminology | Description   |
| ---- | ----------- | ------------- |
| 14   | R           | Red channel   |
| 47   | G           | Green channel |
| 48   | B           | Blue channel  |

---

## I2C Bus (ESP32)

| GPIO | Signal | Description  | Devices           |
| ---- | ------ | ------------ | ----------------- |
| 1    | SDA    | Serial Data  | ADP188BI, HDC2080 |
| 2    | SCL    | Serial Clock | ADP188BI, HDC2080 |

---

## UART

| GPIO | Terminology | Description | Function      |
| ---- | ----------- | ----------- | ------------- |
| 43   | U0_TXD      | Transmit    | Flash / Debug |
| 44   | U0_RXD      | Receive     | Flash / Debug |

---

## ADP188BI (Smoke Sensor)

| GPIO | Signal    | Type           | Description                     | Obs                     |
| ---- | --------- | -------------- | ------------------------------- | ----------------------- |
| 13   | SDA       | I2C            | Serial Data                     | 1.8v                    |
| 12   | SCL       | I2C            | Serial Clock                    | 1.8v                    |
| 5    | VLEDB     | I2C            | Send HEX for measurement        | Blue                    |
| 6    | VLEDIR    | I2C            | Send HEX for measurement        | Infra-Red               |
| 14   | DTR_SLEEP | Digital Output | Wake ESP32 (connected to GPIO4) | Open drain              |
| 15   | HEATER    | PWM            | Heater control (0–255)          | Avoid max for long time |

---

## HDC2080 (Temperature / Humidity)

| GPIO | Signal    | Type           | Description        |
| ---- | --------- | -------------- | ------------------ |
| 1    | SDA       | I2C            | Serial Data        |
| 6    | SCL       | I2C            | Serial Clock       |
| 4    | DTR_SLEEP | Digital Output | Wake ESP32 (GPIO4) |

---

## Misc

| GPIO | Terminology | Description             |
| ---- | ----------- | ----------------------- |
| 8    | UNDEFINED   | Reserved for future use |

## Protocol

```
Offset  Bytes  Field
------  -----  -------
0       1      SOF     0xA5
1       1      VER     0x01
2       2      LEN     total frame length (was 1 byte)
4       2      MSG_ID
6       6      SRC_ID
12      6      DST_ID
18      1      TTL
19      1      HOPS
20      1      FLAGS   ← new
--- AAD ends here (21 bytes) ---
21      4      NONCE
25      N      PAYLOAD (encrypted )
25+N    16     TAG
```

```
bit0 = HAS_SENSORS   (payload contains sensor block)
bit1 = HAS_FAULT     (payload contains fault block)
bit2 = ENCRYPTED     (0 = plaintext debug mode, 1 = CCM)
bit3 = ACK_REQUIRED  (sender expects an ACK back)
bit4 = BROADCAST_ACK (root should re-broadcast ACK)
```

# Payload JSON

```{
  "frame": {
    "ver": 1,
    "msg_id": 1042,
    "src_id": "AA:BB:CC:DD:EE:FF",
    "dst_id": "FF:FF:FF:FF:FF:FF",
    "ttl": 5,
    "hops": 2
  },
  "event": {
    "type": "ALARM",
    "type_code": 3,
    "timestamp": 1750000000,
    "timestamp_iso": "2025-06-15T14:13:20Z"
  },
  "power": {
    "ac_ok": true,
    "on_battery": false,
    "charging": false,
    "tamper": false,
    "test_pressed": false,
    "battery_v": 4.0
  },
  "sensors": {
    "smoke_raw": 4120,
    "temp_c": 58.3,
    "humidity_pct": 42,
    "ntc_temp_c": 61
  },
  "mesh": {
    "is_root": false,
    "is_relay": true,
    "rssi_dbm": -67,
    "parent_mac": "11:22:33:44:55:66",
    "children": [
      "AA:11:22:33:44:55",
      "BB:11:22:33:44:55"
    ]
  }
}
```

For TROUBLE event, replace "sensors" with:

```
"fault": {
    "flags": 5,
    "smoke_sensor": true,
    "temp_sensor": false,
    "batt_critical": true,
    "mesh_lost": false,
    "relay_fail": false,
    "primary_code": "FAULT_BATT_CRIT",
    "primary_code_raw": 3
}
```

## Important RULES

- bytes must not be above 512k

## Story

- Setup
  - PRE-SET
    - Assim que ligar o dispositivo (primeiro boot) ele vai verificar se está na AC ou na bateria

    - Os dispositivos estarão pré-setados para conectarem a rede pre-definida X
    - Dispositivos ainda não sabem o canal, primeiro tentará nos mais utilizados como 1,3,13 (confirmar) e se não conseguir tentará no restante
    - Com o pre-set não será necessário iniciar ESP-NOW ou WebServer, ao menos que o dispositivo seja resetado de fábrica através
      do long press no pino RST/TESTE 21
    -

  - POS-SET
    - Inicia no protocol ESP-NOW enviando mensagem broadcast indicando o sinal MAC, RSSI no canal fixo 6.

    - Outros dispositivos trocarão mensagens em ESP-NOW BROADCAST afim de identificados dispositivos próximos e sinal de comunicação entre eles.

    - Gera um WEBSERVER ou BLE dentro do app que permite configurar o ID da central + nome do dispositivo + credenciais.

    - Caso não houver interação com o dispositivo por XXXXX MINUTOS será gerado um timeout e o dispositivo dormirá por XXXXXXX TEMPO/INIFINITO.

    - Assim que o usuário estiver em comunicação com o dispositivo através do WEBSERVER ou BLE, será aberto uma comunicação em que permite o usuário
      providenciar os dados de configuração ID da central + nome do dispositivo + credenciais.

    - Após inserido a central em que o dispositivo irá conectar-se, será gravado na NVS todo os dados: ID central, credenciais, ID do usuário.

    - Em seguida da gravação na NVS o dispositivo irá fazer restart na primeira checagem deve tomar a decisão, se tiver central configurada iniciará a ESP-MEH-LITE rede, se não houver configuração manterá o passo inicial, gera ESP-NOW (broadcast), WEBSERVER ou BLE para comunicação com o dispositivo móvel do usuário ou até mesmo na própria central.

    - Ao iniciar o firmware pós configuração,

  - RULES
    - Central ficar mais de 200 segundos sem receber confirmação (ACK) - FALHA DE COMUNICAÇÃO

    --## EM SITUAÇÃO DE ALARME tem 10 segundos para enviar o dado para central (do node para o root)
    - Caso não chegue em 10s passado esse tempo ele enviará por 20 segundos até receber o ACK

    - Caso não receba essa confirmação enviará TROUBLE (pq não confirmou) e ALARME porque está em alarme

    - Após isso envia de 60 em 60 segundos, ou seja, dorme por 60s e envia o sinal

    - Repetição de ALARME a cada 60s (UL) 30s (BR)

    - LEAF nodes (placas que dormem) NUNCA devem aceitar conexões, serão dispositivos passivos que enviam ao PARENT as mensages e espero o retorno (ACK)

    -
