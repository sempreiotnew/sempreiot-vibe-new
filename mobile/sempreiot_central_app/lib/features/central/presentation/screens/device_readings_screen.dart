import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../application/topology_provider.dart';
import '../widgets/device_avatar.dart' show deviceDisplayName;
import '../widgets/device_temp_widgets.dart';

/// "Temperatura e umidade" of one unit: the last reading with its age and the
/// last hour of temperature — the same block the Dispositivo screen carries
/// ([DeviceTempSection]), on a screen of its own. Opened from the unit's
/// popover on Rede (the TEMPERATURA E UMIDADE tile).
class DeviceReadingsScreen extends ConsumerWidget {
  const DeviceReadingsScreen({super.key, required this.mac});

  final String mac;

  static const _maxWidth = 720.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    TopologyNode? node;
    for (final n in ref.watch(topologyProvider)) {
      if (n.mac == mac) {
        node = n;
        break;
      }
    }
    final hasReading = node?.tempTenths != null && node?.readingAt != null;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          node == null ? 'Temperatura e umidade' : deviceDisplayName(node),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            // Scrolls: the chart is taller than a phone on its side.
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              children: [
                if (hasReading)
                  DeviceTempSection(node: node!, zoomable: true)
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: Text(
                      node == null
                          ? 'Este dispositivo não está mais na rede.'
                          : 'Este dispositivo ainda não enviou uma leitura.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
