import 'package:flutter/material.dart';

import '../../app/empty_state_panel.dart';
import '../../core/monitoring/network_monitor_controller.dart';
import '../charts/charts_screen.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({required this.monitor, super.key});

  final NetworkMonitorController monitor;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  @override
  void initState() {
    super.initState();
    widget.monitor.refreshSessions();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.monitor,
      builder: (context, _) {
        final sessions = widget.monitor.sessions;
        return RefreshIndicator(
          onRefresh: widget.monitor.refreshSessions,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (sessions.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: widget.monitor.isRecording
                        ? null
                        : _deleteAll,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Удалить всю историю'),
                  ),
                ),
              if (sessions.isEmpty)
                const EmptyStatePanel(
                  icon: Icons.history,
                  title: 'Сессий пока нет',
                  message:
                      'Записи появятся после запуска мониторинга или ручного скоростного теста.',
                )
              else
                for (final session in sessions) _sessionCard(context, session),
            ],
          ),
        );
      },
    );
  }

  Widget _sessionCard(BuildContext context, Map<String, dynamic> session) {
    final started = _time(session['startedAtUtc']);
    final ended = session['endedAtUtc'] == null
        ? null
        : _time(session['endedAtUtc']);
    final active = session['endedAtUtc'] == null &&
        session['id'] == widget.monitor.recordingSessionId;
    return Card(
      child: ListTile(
        onTap: () => _openSession(context, session),
        leading: Icon(
          active ? Icons.fiber_manual_record : Icons.history,
          color: active ? Theme.of(context).colorScheme.error : null,
        ),
        title: Text(active ? 'Запись активна · $started' : started),
        subtitle: Text(
          '${ended == null ? 'Открыта' : 'Завершена $ended'} · '
          '${session['sampleCount'] ?? 0} записей · '
          '${session['failedProbes'] ?? 0} неудачных проб',
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Действия с сессией',
          onSelected: (action) => _handleAction(context, session, action),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'csv', child: Text('Экспорт CSV')),
            const PopupMenuItem(value: 'json', child: Text('Экспорт JSON')),
            PopupMenuItem(
              value: 'delete',
              enabled: !active && !widget.monitor.isRecording,
              child: const Text('Удалить'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    Map<String, dynamic> session,
    String action,
  ) async {
    if (action == 'csv' || action == 'json') {
      final saved = await widget.monitor.exportSession(session, action);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? 'Файл сохранён.'
                : 'Экспорт отменён или не удалось записать файл.',
          ),
        ),
      );
      return;
    }
    if (action == 'delete') await _deleteOne(context, session);
  }

  Future<void> _deleteOne(
    BuildContext context,
    Map<String, dynamic> session,
  ) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить сессию?'),
        content: const Text('Её измерения и события будут удалены с устройства.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final deleted = await widget.monitor.deleteSession(session['id'] as String);
    if (context.mounted && !deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.monitor.platformError ?? 'Не удалось удалить сессию.')),
      );
    }
  }

  Future<void> _deleteAll() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить всю историю?'),
        content: const Text('Все сохранённые сессии и измерения будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить всё'),
          ),
        ],
      ),
    );
    if (accepted == true) await widget.monitor.deleteAllSessions();
  }

  void _openSession(BuildContext context, Map<String, dynamic> session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SessionDetailPage(monitor: widget.monitor, session: session),
      ),
    );
  }

  static String _time(Object? epoch) {
    if (epoch is! num) return '—';
    final value = DateTime.fromMillisecondsSinceEpoch(epoch.toInt()).toLocal();
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }
}

class _SessionDetailPage extends StatelessWidget {
  const _SessionDetailPage({required this.monitor, required this.session});

  final NetworkMonitorController monitor;
  final Map<String, dynamic> session;

  @override
  Widget build(BuildContext context) {
    final id = session['id'] as String;
    return Scaffold(
      appBar: AppBar(title: const Text('Сессия')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: const Text('Начало'),
                  subtitle: Text(_time(session['startedAtUtc']) ?? '—'),
                ),
                ListTile(
                  leading: const Icon(Icons.stop),
                  title: const Text('Окончание'),
                  subtitle: Text(_time(session['endedAtUtc']) ?? 'Запись активна'),
                ),
                ListTile(
                  leading: const Icon(Icons.analytics_outlined),
                  title: const Text('Записей / неудачных проб'),
                  subtitle: Text('${session['sampleCount'] ?? 0} / ${session['failedProbes'] ?? 0}'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Графики сессии')),
                  body: ChartsScreen(monitor: monitor, initialSessionId: id),
                ),
              ),
            ),
            icon: const Icon(Icons.show_chart),
            label: const Text('Открыть графики'),
          ),
        ],
      ),
    );
  }

  static String? _time(Object? epoch) {
    if (epoch is! num) return null;
    final value = DateTime.fromMillisecondsSinceEpoch(epoch.toInt()).toLocal();
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.'
        '${value.year} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }
}
