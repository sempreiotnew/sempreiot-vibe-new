/*
 * SAFR v3 — protocol constants.
 * Single source of truth: sempreiot-vibe-new/docs/safr/protocol-safr-v3.md
 * Do NOT document the layout here; change the spec first, then the code.
 */
#pragma once

#include <stdint.h>

#define SAFR_SOF        0xA5
#define SAFR_VER        0x03

#define SAFR_HDR_LEN    30   /* header == CCM AAD, bytes 0..29 */
#define SAFR_TAG_LEN    16
#define SAFR_CRC_LEN    2
#define SAFR_NONCE_LEN  12   /* SRC_MAC(6) ‖ BOOT_CTR(2) ‖ MSG_CTR(4) */
#define SAFR_MIN_FRAME  34
#define SAFR_MAX_FRAME  256
#define SAFR_MAX_PAYLOAD (SAFR_MAX_FRAME - SAFR_HDR_LEN - SAFR_TAG_LEN - SAFR_CRC_LEN)

/* Site identity (spec §3.1 — EN 54-25 site separation).
 * DEV value; production installations get a unique id via provisioning. */
#define SAFR_SYSTEM_ID  0x5346

/* MSG_TYPE */
#define SAFR_MSG_EVENT          0x01
#define SAFR_MSG_HEARTBEAT      0x02
#define SAFR_MSG_TOPOLOGY       0x03
#define SAFR_MSG_ACK            0x04
#define SAFR_MSG_COMMAND        0x05
#define SAFR_MSG_TIME_SYNC      0x06
#define SAFR_MSG_EVENT_LOG_REQ  0x07
#define SAFR_MSG_EVENT_LOG_DATA 0x08

/* FLAGS */
#define SAFR_F_ENC      0x01
#define SAFR_F_ACK_REQ  0x02
#define SAFR_F_RETX     0x04 /* ≤60 s re-announcement of same event (NFPA 72) */

/* EVENT_TYPE */
#define SAFR_EVT_OK       0x01
#define SAFR_EVT_ALERT    0x02
#define SAFR_EVT_ALARM    0x03
#define SAFR_EVT_TROUBLE  0x04

/* EVENT_CODE */
#define SAFR_EC_NONE          0x00
#define SAFR_EC_SMOKE_ALARM   0x01
#define SAFR_EC_HEAT_ALARM    0x02
#define SAFR_EC_SMOKE_RISING  0x03
#define SAFR_EC_MANUAL_TEST   0x04
#define SAFR_EC_TAMPER        0x05
#define SAFR_EC_BATT_LOW      0x06
#define SAFR_EC_BATT_CRIT     0x07
#define SAFR_EC_SENSOR_FAULT  0x08
#define SAFR_EC_COMM_FAULT    0x09
#define SAFR_EC_AC_LOST       0x0A
#define SAFR_EC_RESTORE       0x0B
#define SAFR_EC_RF_INTERF     0x0C

/* EVENT payload length (spec §7.1: v3 = 15 + DEV_SEQ) */
#define SAFR_EVENT_LEN  17

/* EVENT_LOG_DATA (spec §7.9) */
#define SAFR_LOG_DATA_LEN   28
#define SAFR_LOG_F_LAST     0x01
#define SAFR_LOG_F_EMPTY    0x02
#define SAFR_LOG_BATCH_DEF  32

/* PWR_FLAGS */
#define SAFR_PWR_AC_OK        0x01
#define SAFR_PWR_CHARGING     0x02
#define SAFR_PWR_ON_BATTERY   0x04
#define SAFR_PWR_TAMPER       0x08
#define SAFR_PWR_TEST_PRESSED 0x10

/* FAULT_FLAGS / FAULT_CODE */
#define SAFR_FLT_SMOKE_SENSOR 0x01
#define SAFR_FLT_TEMP_SENSOR  0x02
#define SAFR_FLT_BATT_CRIT    0x04
#define SAFR_FLT_MESH_LOST    0x08
#define SAFR_FLT_RELAY_FAIL   0x10

/* NODE_ROLE */
#define SAFR_ROLE_ROOT  0
#define SAFR_ROLE_NODE  1
#define SAFR_ROLE_LEAF  2

/* COMMAND CMD */
#define SAFR_CMD_LINK_CHECK 0x00 /* downlink supervision no-op (§9.3) */
#define SAFR_CMD_SILENCE    0x01
#define SAFR_CMD_TEST       0x02
#define SAFR_CMD_RELAY_SET  0x03
#define SAFR_CMD_IDENTIFY   0x04
#define SAFR_CMD_RESET      0x05 /* operator reset — only alarm-latch clear */

/* ACK STATUS */
#define SAFR_ACK_OK          0x00
#define SAFR_ACK_ERROR       0x01
#define SAFR_ACK_UNKNOWN_DST 0x02

/* Sentinels */
#define SAFR_NA_U8   0xFF
#define SAFR_NA_U16  0xFFFF
#define SAFR_NA_I16  0x7FFF
#define SAFR_NA_RSSI 0x7F

/* Development pre-shared key — must match safrDevPsk in the Flutter app.
 * DEV ONLY: per-installation keys via provisioning are a production launch
 * prerequisite (spec §4). */
static const uint8_t SAFR_PSK[16] = {
    0x25, 0x11, 0x8B, 0xA1, 0xDD, 0x19, 0xB8, 0x45,
    0x09, 0xDF, 0x36, 0xE9, 0x41, 0x6B, 0x8D, 0xBE,
};

/* Reserved MAC of the central on the serial link */
static const uint8_t SAFR_CENTRAL_MAC[6] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
static const uint8_t SAFR_BCAST_MAC[6]   = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
