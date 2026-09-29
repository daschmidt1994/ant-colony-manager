import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/strings.dart';
import '../app/theme.dart';
import '../core/session.dart';
import '../data/sync/sync_engine.dart';
import '../domain/due.dart';
import '../domain/models.dart';
import '../app/i18n.dart';

/// Icon per event type (docs/11 §3).
IconData eventIcon(String type) => switch (type) {
  'feeding' => Icons.pest_control_outlined,
  'water' => Icons.water_drop_outlined,
  'cleaning' => Icons.cleaning_services_outlined,
  'check' => Icons.visibility_outlined,
  'note' => Icons.sticky_note_2_outlined,
  'problem' => Icons.warning_amber_rounded,
  'photo' => Icons.photo_camera_outlined,
  'measurement' => Icons.thermostat_outlined,
  'census' => Icons.groups_outlined,
  'brood' => Icons.egg_outlined,
  'habitat_move' => Icons.home_work_outlined,
  'queen' => Icons.workspace_premium_outlined,
  'winter_start' || 'winter_end' => Icons.ac_unit,
  _ => Icons.event_note_outlined,
};

IconData taskIcon(String taskType) => switch (taskType) {
  'protein' || 'feeding' => Icons.pest_control_outlined,
  'carbohydrate' => Icons.water_drop,
  'water' => Icons.water_drop_outlined,
  'cleaning' => Icons.cleaning_services_outlined,
  'check' => Icons.visibility_outlined,
  _ => Icons.task_alt,
};

IconData _statusSymbol(DueStatus s) => switch (s) {
  DueStatus.overdue => Icons.error,
  DueStatus.soon => Icons.schedule,
  DueStatus.ok => Icons.check_circle,
  DueStatus.paused => Icons.ac_unit,
};

/// Traffic light chip – always symbol + text, never colour alone.
class DueChip extends StatelessWidget {
  const DueChip(this.task, {super.key, this.compact = false});
  final DueTask task;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.due(task.status);
    final label = task.schedule.taskType == 'custom'
        ? (task.schedule.title ?? tr('Aufgabe'))
        : S.taskNames[task.schedule.taskType]!;
    return Semantics(
      label: '$label ${S.dueText(task)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_statusSymbol(task.status), size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                compact ? label : '$label · ${S.dueText(task)}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line per task on the colony page.
class DueRow extends StatelessWidget {
  const DueRow(this.task, {super.key, this.onSnooze});
  final DueTask task;

  /// „Heute keine Zeit“ – offered on long press for care due by today.
  final VoidCallback? onSnooze;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.due(task.status);
    final name = task.schedule.taskType == 'custom'
        ? (task.schedule.title ?? tr('Aufgabe'))
        : S.taskNames[task.schedule.taskType]!;
    final canSnooze = onSnooze != null && task.status != DueStatus.paused && task.days <= 0;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(_statusSymbol(task.status), color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          ),
          Text(
            S.dueText(task),
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    if (!canSnooze) return row;
    return InkWell(
      onLongPress: () => showModalBottomSheet<void>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(name, style: Theme.of(c).textTheme.titleMedium),
                subtitle: Text(S.dueText(task)),
              ),
              ListTile(
                leading: const Icon(Icons.update),
                title: Text(tr('Auf morgen verschieben')),
                subtitle: Text(tr('Heute keine Zeit – ab morgen wieder fällig')),
                onTap: () {
                  Navigator.pop(c);
                  onSnooze!();
                },
              ),
            ],
          ),
        ),
      ),
      child: row,
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: .6, color: context.colors.muted),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Large touch target for quick actions (72 dp).
class QuickActionTile extends StatelessWidget {
  const QuickActionTile({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.done = false,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: context.colors.surface2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(done ? Icons.check_circle : icon, color: done ? context.colors.ok : scheme.primary, size: 26),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(fontSize: 12, color: context.colors.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.text, this.action});
  final IconData icon;
  final String title;
  final String? text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: context.colors.muted),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (text != null) ...[
            const SizedBox(height: 8),
            Text(
              text!,
              style: TextStyle(color: context.colors.muted),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

/// Unobtrusive sync indicator; tap opens the sync details.
class SyncBadge extends ConsumerWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final (icon, tip, color) = switch (s.phase) {
      SyncPhase.syncing => (Icons.sync, tr('Synchronisiere …'), null),
      SyncPhase.offline => (Icons.cloud_off, tr('Offline · {0} ausstehend', [s.pending]), context.colors.muted),
      SyncPhase.error ||
      SyncPhase.loginRequired => (Icons.sync_problem, s.message ?? tr('Sync-Fehler'), context.colors.overdue),
      SyncPhase.idle when s.failed > 0 => (
        Icons.sync_problem,
        tr('{0} Änderung(en) abgelehnt', [s.failed]),
        context.colors.soon,
      ),
      SyncPhase.idle when s.pending > 0 => (
        Icons.cloud_upload_outlined,
        '${s.pending} ausstehend',
        context.colors.muted,
      ),
      _ => (Icons.cloud_done_outlined, tr('Synchron'), context.colors.muted),
    };
    return IconButton(
      tooltip: tip,
      icon: Badge(
        isLabelVisible: s.pending > 0 && s.phase != SyncPhase.syncing,
        label: Text('${s.pending}'),
        child: Icon(icon, color: color),
      ),
      onPressed: () => context.push('/settings/sync'),
    );
  }
}

/// Snackbar with „Rückgängig“ instead of confirmation dialogs (docs/11 rule 3).
void showUndoSnack(BuildContext context, String text, {VoidCallback? onUndo, VoidCallback? onDetails}) =>
    showUndoSnackOn(ScaffoldMessenger.of(context), text, onUndo: onUndo, onDetails: onDetails);

/// Variant for callers whose own context is gone (e.g. a closed bottom sheet).
void showUndoSnackOn(ScaffoldMessengerState m, String text, {VoidCallback? onUndo, VoidCallback? onDetails}) {
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (onDetails != null)
            TextButton(
              onPressed: () {
                m.hideCurrentSnackBar();
                onDetails();
              },
              child: Text(tr('Details')),
            ),
        ],
      ),
      action: onUndo == null ? null : SnackBarAction(label: tr('Rückgängig'), onPressed: onUndo),
    ),
  );
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(error))));
}

String errorText(Object e) {
  final s = e.toString();
  if (s.startsWith('NetworkException')) return tr('Server nicht erreichbar – gleiches Netzwerk? Adresse richtig?');
  if (s.startsWith('ApiException')) return s.substring(s.indexOf(':') + 1, s.length - 1).trim();
  return tr('Fehler: {0}', [s]);
}

/// Scientific name in italics (convention) + colony name.
class ColonyTitle extends StatelessWidget {
  const ColonyTitle(this.colony, {super.key, this.large = false});
  final Colony colony;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          colony.name,
          style: (large ? t.headlineSmall : t.titleMedium)?.copyWith(fontWeight: FontWeight.w700),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (colony.species.isNotEmpty && colony.species != colony.name)
          Text(
            colony.species,
            style: TextStyle(fontStyle: FontStyle.italic, color: context.colors.muted, fontSize: large ? 16 : 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// Date, then time – for entries logged afterwards (up to a year back, not in the future).
Future<DateTime?> pickPastDateTime(BuildContext context, {DateTime? initial}) async {
  final now = DateTime.now();
  final start = initial ?? now;
  final d = await showDatePicker(
    context: context,
    firstDate: now.subtract(const Duration(days: 365)),
    lastDate: now,
    initialDate: start.isAfter(now) ? now : start,
    helpText: tr('Wann war das?'),
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start), helpText: tr('Uhrzeit'));
  if (t == null) return null;
  final at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
  return at.isAfter(now) ? now : at;
}

/// Time chip for back-dating (docs/11 rule 9): „Jetzt“ by default, highlighted once changed.
class WhenChip extends StatelessWidget {
  const WhenChip({super.key, required this.value, required this.onChanged});
  final DateTime? value; // null = now
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null ? tr('Jetzt') : '${S.relativeDay(value!, DateTime.now())} ${S.time(value!)}';
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: tr('Zeitpunkt'),
      onSelected: (v) async {
        final now = DateTime.now();
        switch (v) {
          case 'now':
            onChanged(null);
          case '1h':
            onChanged(now.subtract(const Duration(hours: 1)));
          case 'morning':
            onChanged(DateTime(now.year, now.month, now.day, 8));
          case 'yesterday':
            onChanged(DateTime(now.year, now.month, now.day - 1, 18));
          case 'pick':
            final at = await pickPastDateTime(context, initial: value);
            if (at != null) onChanged(at);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'now', child: Text(tr('Jetzt'))),
        PopupMenuItem(value: '1h', child: Text(tr('Vor 1 Stunde'))),
        PopupMenuItem(value: 'morning', child: Text(tr('Heute Morgen'))),
        PopupMenuItem(value: 'yesterday', child: Text(tr('Gestern Abend'))),
        PopupMenuItem(value: 'pick', child: Text(tr('Datum/Uhrzeit wählen …'))),
      ],
      child: Chip(
        avatar: Icon(Icons.schedule, size: 18, color: value == null ? null : scheme.onPrimaryContainer),
        backgroundColor: value == null ? null : scheme.primaryContainer,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: value == null ? null : scheme.onPrimaryContainer)),
            Icon(Icons.arrow_drop_down, size: 18, color: value == null ? null : scheme.onPrimaryContainer),
          ],
        ),
      ),
    );
  }
}

/// Constrains content width on large screens (web).
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// The app's ant logo (same artwork as the launcher icon, tool/icon/ant.svg).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/icon/ant.png', width: size, height: size, semanticLabel: tr('Ant Colony Manager'));
}
