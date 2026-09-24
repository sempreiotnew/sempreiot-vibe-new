# SempreIoT — Installation guide, step by step

_2026-09-24. What an installer and an operator actually do, in order, to put a site in service and to
keep it in service. This is the practical companion to `installation-lifecycle-v1.md` (the rules) and
`system-blueprint-v1.md` (the system). UI labels are the Portuguese ones in the app. Steps marked
Phases 1, 2 and 3 are all in the code as of 2026-09-24: **[Phase 1]** app sharing and joining,
**[Phase 2]** device table, board code read over USB, Case B, management actions, survey mode, and
**[Phase 3]** the board admin window and "Entrar pela placa". None of the firmware has had its bench
pass yet (lifecycle §10); do that once, with one reflash and one APK rebuild, before calling any of it
done on site._

---

## 0. What you need on site

| Item | Who carries it | Notes |
|---|---|---|
| Installer phone with the SempreIoT app (APP mode), logged in once | each installer | Everything below works **offline**. Android 10+ joins device Wi-Fi automatically; iOS joins it by hand in Settings. |
| The units to install (detectors, sirens, modules, the board), each with its **sticker** | installer | The sticker QR holds `id`, `mac`, `pop`. `pop` is the unit's secret. Do not photograph stickers into group chats. |
| The tablet (CENTRAL mode) and the USB cable to the board | operator | The tablet may have no camera; nothing below requires one. |
| A passphrase you will remember for the installation backup **[Phase 1]** | lead installer | Used to share the installation between phones. |

Vocabulary (blueprint §0): **board** = the unit wired to the tablet; **AC device / node** = mains-powered
unit (siren, module, repeater, AC detector); **battery detector / leaf** = sleeps, talks by ESP-NOW;
**the code** = the installation's secret bundle that every unit must hold.

---

## 1. Create the installation (once per site)

Any order works: you can do this before any unit is mounted, before the board exists, or after the
tablet and board are already on the wall (see §7 for that variant).

1. Phone → drawer **Configurar Dispositivo** → **Nova instalação**.
2. Type the site name (e.g. "Escola Municipal — Bloco B"). Confirm.
3. The phone generates the code (SYSTEM_ID, Wi-Fi name `SIOT-XXXX`, Wi-Fi password, SAFR key, channel)
   and stores it in its secure storage. You never see or type these values.
4. Open the installation → **Zonas** → add the zones you will use ("Térreo", "1º andar", "Cozinha").
   Zones are just labels ≤ 16 characters; you can add more later.

> Do this on **one** phone. Other installers get the code from you in §2, never by creating another
> installation with the same name — that would be a different site with a different key.

---

## 2. Share the installation with the other installers **[Phase 1]**

1. Lead installer's phone → the installation → **Compartilhar**.
2. Type a passphrase (≥ 8 characters). The phone shows a QR. The QR contains the code **encrypted**
   with that passphrase — a photo of it is useless without the passphrase.
3. Other installer's phone → **Configurar Dispositivo** → **Entrar em instalação existente** → scan
   the QR → type the passphrase.
4. Both phones now hold the same code. Each phone keeps its own list of the units it configures; the
   lists never need to be merged.

Phones still running the pre-lifecycle app show a plain backup QR with the keys in clear. The tablet
still accepts it, with a warning; upgrade those phones and use **Compartilhar** instead.

---

## 3. Configure each unit (detectors, sirens, modules)

About 20 s per unit. Power the unit first: LED **white blink** = waiting for setup.

1. Phone → the installation → **Provisionar dispositivo**.
2. **Scan the sticker** on the unit (or type `id`, `mac`, `pop` by hand).
3. **Name** the unit (mandatory, ≤ 32 characters, e.g. "Detector corredor 2º") and pick its **zone**.
   Names are what the operator will see on the tablet — never MACs.
4. The phone joins the unit's setup Wi-Fi `SIOT-SETUP-<id>` (Android does it alone; on iOS the app
   tells you to pick that network in Settings, password = the `pop` on the sticker, then come back).
5. The wizard identifies the unit, pushes the code, and reports **Armazenado** (`stored`).
6. The unit reboots. Its setup Wi-Fi disappears — it cannot be configured again without a factory
   reset (§10). Mount it.

What the LED tells you after that (one language for every unit):

| LED | Meaning |
|---|---|
| white blink | **only** "no code": waiting to be configured (§3), or the board's admin window is open (§11) |
| white **breathe** (slow dim fade, never a blink) | configured but no path to the board yet. Also the case when several units formed a mesh among themselves with the board off |
| green flash every 5 s | online **and** the board is reachable — this unit is the mesh root |
| off | also: online and the board is reachable, this unit is a child of the mesh (press TEST: a walk test with the board, a survey without it) |
| magenta flash every 5 s | the board itself, serving |
| short blue ticks | this unit sent a frame that can reach the tablet (only once the board is reachable) |
| blue blink for 1 s | survey: this unit heard a neighbour's probe and answered (§5) |
| green / yellow / red solid for 3 s | survey verdict on the unit whose TEST you pressed (§5) |
| blue blink for N s | "Piscar" from the tablet (identify) |
| red solid | alarm latched |

If the scan says **"Este dispositivo já foi configurado"** **[Phase 1]**: another installer already did
it, or it holds an old installation. To redo it, hold its button 5 s (§10) and start again.

**Battery detectors:** same steps. Their setup Wi-Fi stays up 10 minutes after power-up; press the
button once to bring it back if it timed out.

---

## 4. Configure the board

The board is configured **exactly like any unit** (§3) from any phone that holds the code. The wizard
recognises it as a board and additionally sends it the list of units this phone has configured so
far, so the tablet can show them as "expected" before they come online. Units configured by other
phones, or later, are discovered by the board when they join — nothing else to do.

Mount the board, connect mains, plug the tablet's USB.

---

## 5. Check radio reach without the board (survey) **[Phase 2]**

Optional, useful on large sites or thick walls, and possible **before** the board exists.

1. Mount the units where you intend to leave them; they are configured (§3), the board is off, and
   every LED breathes white slowly. (Two or more AC units may pair among themselves without the board; that changes
   nothing you can see, and TEST is still the survey on every unit that has no path to the board.)
2. Press **TEST** on a unit. Its LED goes **dark: the button is locked** while the survey runs
   (about 5 s). The unit sends the probe four times over 3.6 s so a neighbour that happens to be
   scanning for the board still hears it.
3. Every configured unit in range shows **1 s solid in the colour of the signal it heard**:
   **green** ≥ −75 dBm · **yellow** ≥ −85 dBm · **red** below. Stand next to a unit to see how well it
   hears the one you pressed.
4. The pressed unit, still dark, blinks **once per unit that answered**, in the colour of that link
   (the weaker direction of the pair). Three units in reach = three blinks. Nobody in reach = one red
   blink at the end. The board answers too if it is powered.
5. When the white breathe comes back, the button is unlocked. **Dark = wait, breathing = press.**
   A press while dark does nothing. Repeat unit by unit; aim for green on every link, and green between
   each unit and either the board or a neighbour that is green to the board. The console prints every
   answer with both directions' dBm.

Once a unit is online, TEST goes back to being the site-wide walk test.

---

## 6. Put the tablet in service

1. Plug the tablet into the board by USB. Unlock the tablet (6-digit PIN).
2. Drawer → **Instalação** (Master or Level 4 PIN **[Phase 1]**).
3. **Ler código da placa** **[Phase 2]**: type the `pop` printed on the board's sticker (or scan the
   sticker if this tablet has a camera). The tablet asks the board for the code over the USB cable and
   stores it. No phone, no Wi-Fi, no internet.
   Alternatives: scan the installer's encrypted QR or paste its text (**Escanear QR** / **Colar**).
4. The tablet now authenticates every frame with the site key. On link-up it reads the installation
   and the device list from the board. Units appear **with their names** as they come online.
5. If a banner says **"A placa pertence a outra instalação"** **[Phase 1]**, the code on the tablet and
   the code on the board differ: the board was configured for another installation, or the wrong
   backup was imported. Fix the side that is wrong.
6. Walk test: **Rede** → each unit → **Piscar** to locate it, rename if the installer's name is wrong
   (§8), then press TEST on the tablet or on a unit and confirm every unit reports.

The site is in service when every unit shows online with its name and the walk test passes. There is
no "assumed" state: a unit that never shows online is not installed.

---

## 7. Variant: tablet and board first, units later **[Phase 2]**

1. Mount the board, plug the tablet, power both.
2. Tablet → **Instalação** → **Criar instalação nesta central** → name the site → type or scan the
   board sticker's `pop`. The tablet generates the code and writes it into the board over USB; the
   board reboots and raises the installation Wi-Fi.
3. Tablet → **Compartilhar** → passphrase → QR. Each installer scans it on their phone (§2).
4. Configure units as in §3. They come online within seconds and appear on the tablet immediately.

---

## 8. Later changes (from the tablet, Master or Level 4 PIN) **[Phase 2]**

| I want to… | Do this | What happens |
|---|---|---|
| **Add a unit** | §3 from any phone that holds the code | It shows up online on the tablet; nothing to import |
| **Rename / move to another zone** | Rede → unit → **Renomear** / **Zona** | The board records it and pushes it to the unit; if the unit is off, it is applied when it returns ("pendente") |
| **Retire a unit** (broken, removed) | Rede → unit → **Aposentar** | The board ignores it from now on; it leaves supervision. Reversible with **Reativar** |
| **Replace a unit** | configure the new one (§3), then Rede → old unit → **Substituir por…** → pick the new one | Name and zone move to the new unit; the old one is retired and wiped if still reachable |
| **Wipe a unit remotely** | Rede → unit → **Apagar da placa** → type its name | The unit erases its code and returns to setup (white blink). Battery detectors: applied on their next wake, or use §10 |
| **Delete a retired unit for good** | Rede → unit → **Esquecer** | Removed from the board's list |
| **Resync the list** | Rede → **Ressincronizar com a placa** | Tablet re-reads the board's table |
| **A wiped unit reappears** | tablet offers **Reativar** if it had been retired | otherwise it simply comes back online |

Renaming on the phone only edits the phone's own list; the tablet is where names are managed.

---

## 9. Recovering from losses

| Lost… | Do this |
|---|---|
| **An installer's phone** | Get the code again from another installer's phone or from the tablet (**Compartilhar** → QR + passphrase) **[Phase 1]**, or from the board's admin window (§11) **[Phase 3]**. If the phone may be in bad hands, plan a re-key (Phase 4). |
| **The board** | Configure the new board from any phone (§4) or from the tablet (§7 step 2). Plug USB. Units rejoin on their own; the board rebuilds its list from what it hears. Tablet → **Reenviar nomes à placa** to push the names you had. |
| **The tablet** | New tablet → §6 (type the board's `pop`, read the code from the board). Nothing else. |
| **The passphrase** | Nothing is lost: the code is on the board and on every phone that already has it. Share again with a new passphrase. |

---

## 10. Factory reset of a unit (physical)

Hold the unit's button **5 s** at any time: LED white solid while held, then the unit wipes its code
(identity and sticker stay valid) and returns to setup mode (white blink). It can be configured again
(§3). On the tablet it shows as missing until you retire or forget it.

---

## 11. Board admin window **[Phase 3]**

For an installer who is on site with no phone that holds the code and no tablet at hand:

1. Double-tap the board's button. The board pauses the installation Wi-Fi and raises its setup Wi-Fi
   for 5 minutes (LED white blink). Refused while an alarm is active.
2. Phone → **Entrar pela placa** → scan the **board's** sticker → the phone joins, proves the `pop`,
   and receives the code.
3. The window closes after the first success; the network comes back within a minute.

Use the encrypted QR (§2) whenever possible; this is the last resort because the site loses its
network for the duration.

---

## 12. Things that are not (yet) possible — say so on site

- Confirming "online" on the phone. The phone stops at `stored`; online is confirmed on the tablet.
- Excluding a compromised unit that is still online without wiping it: retire only makes the board
  ignore it. Re-key (Phase 4) will address lost units, not live ones.
- More than 120 units on one board until the OTA phase fixes the production partition table.
- Renaming or wiping a sleeping battery detector instantly (waits for its next wake / the parent
  mailbox).
