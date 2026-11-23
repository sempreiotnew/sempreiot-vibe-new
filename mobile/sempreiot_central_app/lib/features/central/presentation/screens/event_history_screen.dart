import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../../../presentation/screens/main/widgets/principal_panel.dart';
import '../../application/panel_provider.dart';

/// "Ver todos" of Principal's last events (2026-11-19).
///
/// On the tablet ([centralId] null): the last [panelHistoryLimit] rows of
/// its own event table, newest first, live. On a user's phone: the events
/// the central keeps on the cloud — its last 20 — and a line saying the
/// rest is at the central.
class EventHistoryScreen extends ConsumerWidget {
  const EventHistoryScreen({super.key, this.centralId});

  final String? centralId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = centralId == null
        ? ref.watch(localPanelEventsProvider(panelHistoryLimit))
        : ref.watch(panelViewProvider(centralId)).events;
    final remote = centralId != null;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Eventos'),
        backgroundColor: context.bgColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: events.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nenhum evento registrado ainda.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 14),
                  ),
                ),
              )
            : LayoutBuilder(builder: (context, c) {
                final wide = c.maxWidth >= 560;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: events.length + 1,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.8,
                        color: context.borderColor.withValues(alpha: 0.7),
                      ),
                      itemBuilder: (context, i) {
                        if (i == events.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              remote
                                  ? 'Estes são os ${events.length} eventos '
                                      'mais recentes. O histórico completo '
                                      'fica na central.'
                                  : events.length >= panelHistoryLimit
                                      ? 'Estes são os $panelHistoryLimit '
                                          'eventos mais recentes.'
                                      : 'Fim do histórico.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: context.textSecondary, fontSize: 12),
                            ),
                          );
                        }
                        return PanelEventRow(
                          event: events[i],
                          showKind: wide,
                          exactTime: true,
                        );
                      },
                    ),
                  ),
                );
              }),
      ),
    );
  }
}
