import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import 'device_avatar.dart';

/// How long "Novo root" stays up after an election ended.
const rootElectedBannerFor = Duration(seconds: 6);

/// The line under the Rede status strip while the mesh chooses its root
/// (root_election_provider): which root was lost, who is contending, how
/// long it has been against the limit a failover may take — and, for a
/// few seconds after, who won and in how long. Red once the election runs
/// past [rootElectionOverdue]. Nothing at all while a root holds.
///
/// A phone viewing a central computes the same election from the map the
/// central publishes, so it shows the same banner.
class RootElectionBanner extends StatefulWidget {
  const RootElectionBanner({
    super.key,
    required this.election,
    required this.nodes,
  });

  final RootElectionState election;
  final List<TopologyNode> nodes;

  @override
  State<RootElectionBanner> createState() => _RootElectionBannerState();
}

class _RootElectionBannerState extends State<RootElectionBanner> {
  Timer? _hide;

  /// The election whose "Novo root" has been shown long enough.
  DateTime? _shownEnough;

  @override
  void didUpdateWidget(RootElectionBanner old) {
    super.didUpdateWidget(old);
    _scheduleHide();
  }

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  /// The "Novo root" view goes away by itself: nothing else rebuilds the
  /// screen once the mesh is quiet.
  void _scheduleHide() {
    _hide?.cancel();
    final at = widget.election.electedAt;
    if (widget.election.electing || at == null) return;
    final left = rootElectedBannerFor - DateTime.now().toUtc().difference(at);
    if (left <= Duration.zero) return;
    _hide = Timer(left, () {
      if (mounted) setState(() => _shownEnough = at);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  String _name(String mac) {
    for (final n in widget.nodes) {
      if (n.mac == mac) return deviceDisplayName(n);
    }
    return mac;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.election;
    final now = DateTime.now().toUtc();
    final elected = !e.electing &&
        e.electedAt != null &&
        e.electedMac != null &&
        e.electedAt != _shownEnough &&
        now.difference(e.electedAt!) < rootElectedBannerFor;

    final Widget child;
    if (e.electing) {
      child = _Electing(
        key: const ValueKey('electing'),
        election: e,
        now: now,
        name: _name,
      );
    } else if (elected) {
      child = _Elected(
        key: ValueKey('elected-${e.electedAt}'),
        name: _name(e.electedMac!),
        after: e.electedAfter ?? Duration.zero,
      );
    } else {
      child = const SizedBox(width: double.infinity, key: ValueKey('none'));
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, -0.15), end: Offset.zero)
                .animate(a),
            child: c,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.20),
            color.withValues(alpha: 0.06),
          ],
        ),
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.16), blurRadius: 14),
        ],
      ),
      child: child,
    );
  }
}

class _Electing extends StatelessWidget {
  const _Electing({
    super.key,
    required this.election,
    required this.now,
    required this.name,
  });
  final RootElectionState election;
  final DateTime now;
  final String Function(String mac) name;

  @override
  Widget build(BuildContext context) {
    final overdue = election.overdue(now);
    final color = overdue ? AppColors.error : AppColors.warning;
    final secs = election.elapsed(now).inSeconds;
    final limit = rootElectionOverdue.inSeconds;
    final lost = election.lostRootMac;
    final candidates = election.candidates.toList();

    final title = overdue
        ? 'Sem root há $secs s'
        : lost != null
            ? 'Root perdido — elegendo um novo'
            : 'Escolhendo o root da malha';
    final subtitle = overdue
        ? 'Passou do tempo de uma troca de root. Verifique se os dispositivos '
            'alimentados estão ligados e ao alcance da placa.'
        : 'A malha se reorganiza sozinha. Um dispositivo alimentado se liga '
            'à placa e vira o novo root.';

    return _Frame(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Radar(color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$secs s',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    'LIMITE $limit s',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (secs / limit).clamp(0.0, 1.0),
              minHeight: 4,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (lost != null)
                _UnitChip(
                  label: 'Root anterior',
                  name: name(lost),
                  color: AppColors.error,
                  icon: Icons.link_off_rounded,
                ),
              if (candidates.isEmpty)
                Text(
                  'Aguardando um dispositivo se ligar à placa…',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                for (final mac in candidates)
                  _UnitChip(
                    label: 'Candidato',
                    name: name(mac),
                    color: AppColors.warning,
                    icon: Icons.how_to_vote_outlined,
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Elected extends StatelessWidget {
  const _Elected({super.key, required this.name, required this.after});
  final String name;
  final Duration after;

  @override
  Widget build(BuildContext context) {
    // ROOT is green on the map (the root's green flash): the same here.
    const color = AppColors.success;
    return _Frame(
      color: color,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.7)),
            ),
            child: const Icon(Icons.hub_rounded, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Novo root: '),
                TextSpan(
                  text: name,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: ' · rede reorganizada em ${after.inSeconds} s',
                  style: TextStyle(color: context.textSecondary),
                ),
              ]),
              style: const TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitChip extends StatelessWidget {
  const _UnitChip({
    required this.label,
    required this.name,
    required this.color,
    required this.icon,
  });
  final String label;
  final String name;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '$label  ',
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small radar sweep: the mesh is looking for its root.
class _Radar extends StatefulWidget {
  const _Radar({required this.color});
  final Color color;

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 34,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _RadarPainter(t: _c.value, color: widget.color),
          child: Center(
            child: Icon(Icons.hub_outlined, size: 16, color: widget.color),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.t, required this.color});
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.35),
    );
    for (final lag in const [0.0, 0.5]) {
      final k = (t + lag) % 1.0;
      canvas.drawCircle(
        c,
        8 + (r - 8) * k,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * (1 - k) + 0.4
          ..color = color.withValues(alpha: 0.8 * (1 - k)),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t || old.color != color;
}
