import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../features/access/application/user_access_provider.dart';
import '../../../../features/access/domain/entities/access_level.dart';
import '../../../../features/access/domain/entities/saved_central.dart';
import '../../../../features/access/presentation/screens/my_qr_screen.dart';
import '../../../../features/access/presentation/sheets/add_central_sheet.dart';
import '../../../../features/central/presentation/screens/central_status_screen.dart';
import '../../../../presentation/screens/main/main_screen.dart';
import '../../../../shared/widgets/app_search_bar.dart';
import '../../../../shared/widgets/presence_indicator.dart';

class CentralsListScreen extends ConsumerStatefulWidget {
  const CentralsListScreen({super.key});

  @override
  ConsumerState<CentralsListScreen> createState() => _CentralsListScreenState();
}

class _CentralsListScreenState extends ConsumerState<CentralsListScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final allCentrals = ref.watch(savedCentralsProvider);
    final q = _query.toLowerCase().trim();
    final filtered = q.isEmpty
        ? allCentrals
        : allCentrals
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'Centrais',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_rounded),
            tooltip: 'Meu QR Code',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyQrScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: Column(
        children: [
          // ── Search bar ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: AppSearchBar(
              hintText: 'Buscar por nome...',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),

          // ── Count badge ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  filtered.isEmpty
                      ? 'Nenhuma central'
                      : '${filtered.length} central${filtered.length == 1 ? '' : 'is'}',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_query.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    'para "$_query"',
                    style: TextStyle(
                      color: AppColors.secondary.withValues(alpha: 0.75),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── List ──────────────────────────────────────────────────────
          Expanded(
            child: filtered.isEmpty
                ? _EmptyState(hasQuery: _query.isNotEmpty)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _CentralCard(
                      item: filtered[i],
                      onTap: () {
                        final central = filtered[i];
                        // Accepted → the real central dashboard (no drawer/
                        // bottom nav, just its data). Anything else (pending/
                        // rejected/blocked) → the lightweight status screen.
                        if (central.status == 'ACCEPTED') {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => MainScreen(
                                centralId: central.identityId,
                              ),
                            ),
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CentralStatusScreen(
                              identityId: central.identityId,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showAddCentralSheet(context),
        backgroundColor: AppColors.secondary,
        elevation: 4,
        child: const Icon(Icons.add_rounded, color: Colors.white),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: context.borderColor.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              child: Icon(
                hasQuery ? Icons.search_off_rounded : Icons.sensors_off_rounded,
                size: 28,
                color: context.textSecondary.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasQuery ? 'Nenhum resultado' : 'Nenhuma central adicionada',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? 'Não encontramos nada para "$hasQuery".'
                  : 'Toque em + para solicitar acesso a uma central.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Central card (original design, adapted for SavedCentral) ──────────────────

class _CentralCard extends StatelessWidget {
  const _CentralCard({required this.item, required this.onTap});

  final SavedCentral item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isPending = item.status == 'PENDING';
    final isRejected = item.status == 'REJECTED';
    final isBlocked = item.status == 'BLOCKED';

    final statusColor = isPending
        ? AppColors.warning
        : (isRejected || isBlocked)
            ? AppColors.error
            : AppColors.success;

    final statusLabel = isPending
        ? 'Aguardando aprovação'
        : isRejected
            ? 'Acesso negado'
            : isBlocked
                ? 'Bloqueado'
                : (item.level ?? AccessLevel.level1).label;

    return Material(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isPending
                  ? AppColors.warning.withValues(alpha: 0.35)
                  : context.borderColor.withValues(alpha: 0.6),
              width: isPending ? 1 : 0.5,
            ),
          ),
          child: Row(
            children: [
              // ── Icon ──────────────────────────────────────────────────
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.sensors_rounded,
                  color: statusColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),

              // ── Info ───────────────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name.isNotEmpty ? item.name : item.subId,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // The subId is the central's public identity (QR/lookup)
                    // — always visible so personal nicknames can't cause
                    // ambiguity about which central this is.
                    Text(
                      item.subId,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    // Accepted → the granted level, rendered with the same
                    // icon/color/label pattern the central's Acessos screen
                    // uses. Other statuses keep the plain status dot.
                    if (isPending || isRejected || isBlocked)
                      Row(
                        children: [
                          if (isPending)
                            _PulsingDot(color: statusColor)
                          else
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: statusColor,
                              ),
                            ),
                          const SizedBox(width: 5),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      )
                    else
                      _LevelBadge(level: item.level ?? AccessLevel.level1),
                    const SizedBox(height: 4),
                    PresenceIndicator(identityId: item.identityId, dotSize: 6, fontSize: 11),
                  ],
                ),
              ),

              // ── Trailing icon ──────────────────────────────────────────
              Icon(
                Icons.chevron_right_rounded,
                color: context.textSecondary.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Level rendering matching the central's Acessos screen: level icon +
/// colored label + the NÍVEL pill (same colors from [AccessLevel]).
class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.level});
  final AccessLevel level;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(level.icon, size: 12, color: level.color),
        const SizedBox(width: 5),
        Text(
          level.label,
          style: TextStyle(
            color: level.color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: level.color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: level.color.withValues(alpha: 0.3),
              width: 0.8,
            ),
          ),
          child: Text(
            level.shortLabel,
            style: TextStyle(
              color: level.color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
        ),
      ),
    );
  }
}
