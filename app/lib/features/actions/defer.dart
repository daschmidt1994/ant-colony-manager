import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../domain/due.dart';
import '../../shared/widgets.dart';

/// „Aufschieben mit Grund“: instead of just moving the due date, document why
/// – „Noch ausreichend Wasser“, „Futter nicht angenommen“ … – and for how long.
Future<void> showDeferSheet(BuildContext context, WidgetRef ref, DueTask task) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => _DeferSheet(task: task),
);

/// Days to offer; the interval of the plan is a good upper bound.
List<int> deferDays(num intervalDays) => {1, 2, 3, 7}.where((d) => d == 1 || d <= intervalDays * 2).toList();

class _DeferSheet extends ConsumerStatefulWidget {
  const _DeferSheet({required this.task});
  final DueTask task;
  @override
  ConsumerState<_DeferSheet> createState() => _DeferSheetState();
}

class _DeferSheetState extends ConsumerState<_DeferSheet> {
  late final _reasons = S.deferReasonsFor(widget.task.schedule.taskType);
  late String _reason = _reasons.first;
  int _days = 1;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final repo = ref.read(repositoryProvider)!;
    final messenger = ScaffoldMessenger.of(context);
    final r = repo.deferSchedule(widget.task.schedule.id, reason: _reason, days: _days, note: _note.text);
    Navigator.pop(context);
    if (r == null) return;
    final (event, previous) = r;
    showUndoSnackOn(
      messenger,
      S.eventSummary(event),
      onUndo: () {
        repo.deleteEvent(event.id);
        repo.setScheduleSnooze(widget.task.schedule.id, previous);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final name = t.schedule.taskType == 'custom'
        ? (t.schedule.title ?? tr('Aufgabe'))
        : S.taskNames[t.schedule.taskType]!;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('{0} aufschieben', [name]), style: Theme.of(context).textTheme.titleLarge),
          SectionHeader(tr('Grund')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in _reasons)
                ChoiceChip(
                  label: Text(S.deferReasons[r]!),
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ],
          ),
          SectionHeader(tr('Wieder fällig in')),
          Wrap(
            spacing: 8,
            children: [
              for (final d in deferDays(t.schedule.intervalDays))
                ChoiceChip(
                  label: Text(d == 1 ? tr('1 Tag') : tr('{0} Tage', [d])),
                  selected: _days == d,
                  onSelected: (_) => setState(() => _days = d),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: InputDecoration(
              labelText: tr('Notiz (optional)'),
              hintText: tr('z. B. Reagenzglas noch halb voll'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: Text(tr('Aufschieben'))),
        ],
      ),
    );
  }
}
