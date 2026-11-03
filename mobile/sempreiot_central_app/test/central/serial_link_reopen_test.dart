import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/serial_link_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';

/// The board silent behind an open port (2026-11-03): after a while the link
/// closes and opens the port again, stays `stalled` while it does — one
/// trouble, not one per attempt — and is `connected` again only with a frame.
/// Real timers, scaled down: the notifier reads the wall clock.
void main() {
  // Each wait lands well inside the window it checks: a re-open is due
  // every reopenEvery, and the checks sit ~200 ms away from either edge.
  const tick = Duration(milliseconds: 20);
  const silence = Duration(milliseconds: 200);
  const reopenAfter = Duration(milliseconds: 300);
  const reopenEvery = Duration(milliseconds: 500);
  const margin = Duration(milliseconds: 100);

  late SerialNotifier port;
  late ProviderContainer container;
  late int reopens;
  late List<SerialLinkStatus> seen;

  SerialLinkStatus status() => container.read(serialLinkProvider);
  SerialLinkNotifier link() => container.read(serialLinkProvider.notifier);
  Future<void> wait(Duration d) => Future<void>.delayed(d);

  setUp(() {
    port = SerialNotifier.detached();
    reopens = 0;
    seen = [];
    container = ProviderContainer(overrides: [
      serialProvider.overrideWith((ref) => port),
      serialLinkProvider.overrideWith(
        (ref) => SerialLinkNotifier(
          ref,
          tick: tick,
          silence: silence,
          reopenAfter: reopenAfter,
          reopenEvery: reopenEvery,
          reopen: () async {
            reopens++;
            port.debugReopen();
          },
        ),
      ),
    ]);
    container.listen<SerialLinkStatus>(
      serialLinkProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
  });

  tearDown(() => container.dispose());

  Future<void> boardTalksThenGoesSilent() async {
    port.debugSetConnected(true);
    link().reportValidFrame();
    expect(status(), SerialLinkStatus.connected);
    await wait(silence + margin); // ~300 ms: stalled since ~210
    expect(status(), SerialLinkStatus.stalled);
    expect(reopens, 0, reason: 'a stall is first given its own time');
  }

  test('a lasting stall re-opens the port, stays stalled, and again later',
      () async {
    await boardTalksThenGoesSilent();

    await wait(reopenAfter); // ~600 ms: first re-open at ~510
    expect(reopens, 1);
    expect(status(), SerialLinkStatus.stalled);

    await wait(reopenEvery + margin); // ~1200 ms: second at ~1010, third ~1510
    expect(reopens, 2);
    expect(status(), SerialLinkStatus.stalled);

    final sinceStall = seen.sublist(seen.indexOf(SerialLinkStatus.stalled));
    expect(sinceStall, [SerialLinkStatus.stalled],
        reason: 'the re-opens never show as connecting: one trouble only');
  });

  test('a frame after the re-open ends the stall', () async {
    await boardTalksThenGoesSilent();
    await wait(reopenAfter);
    expect(reopens, 1);

    link().reportValidFrame();
    expect(status(), SerialLinkStatus.connected);

    await wait(silence ~/ 2);
    expect(status(), SerialLinkStatus.connected);
    expect(reopens, 1, reason: 'a live link is left alone');
  });

  test('a cable pulled during a stall is a new port, not the same stall',
      () async {
    await boardTalksThenGoesSilent();
    await wait(reopenAfter);
    expect(reopens, 1);

    port.debugSetConnected(false);
    expect(status(), SerialLinkStatus.disconnected);

    port.debugSetConnected(true);
    expect(status(), SerialLinkStatus.connecting,
        reason: 'a fresh port starts from nothing');
    await wait(reopenEvery + margin);
    expect(reopens, 1, reason: 'no re-open while the port is only silent');
  });
}
