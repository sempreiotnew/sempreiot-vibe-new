source ~/.espressif/tools/activate_idf_v5.5.2.sh
cd tools
python -m esptool -p /dev/cu.usbmodemXXXX read_mac        # per unit
python3 make_sticker.py --id dev-b --mac AA:BB:CC:DD:EE:FF  # then dev-c, dev-board

## Bench LED language (board + node, since 2026-09-18)

| LED | Meaning |
|---|---|
| white blink | setup mode — waiting to be provisioned (board or node) |
| white solid | node looking for the network (not joined yet) |
| green flash every 5 s | ROOT node (level 1 — the one connected to the board's AP and bridging TCP) |
| off | NODE (child, level 2+) joined under a root — the console prints a big `THIS DEVICE IS A NODE` banner |
| magenta solid | board ("router" of the mesh) up and serving |
| blue, one short pulse (150 ms, role colour off) | one frame sent or received on the mesh side |
| blue blink | IDENTIFY command from the app |
| red solid | node with an active ALARM (double press) until RESET |

Bench mode (`NODE_BENCH_BUTTON_ONLY 1` in `node_safr.c`): no HEARTBEAT / TOPOLOGY / NAME_ANNOUNCE (so the app will not list nodes as online; set it to 0 to restore). Instead each joined node sends the same MANUAL_TEST frame as a button tap every 10 s (`NODE_BENCH_AUTO_TEST_MS`, 0 = taps only).

Test button (node, short tap): sends `EVENT ALERT MANUAL_TEST` to the board — the blue pulse on the node is the send itself (no pulse = not joined, nothing left the device); the board pulses blue when the frame arrives. Double tap = ALARM; hold ≥ 5 s = factory reset.

Implementation: `components/siot_led` (`siot_led_comm_blink()`), `node/main/node_safr.c` (`update_role_led`), `node/main/node_mesh.c` (send/receive hooks), `board/main/board_main.c` + `tcp_link.c`.
