import 'package:flutter/material.dart';

import '../../core/monitoring/network_monitor_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.monitor,
    required this.themeMode,
    required this.onThemeModeChanged,
    super.key,
  });

  final NetworkMonitorController monitor;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _urlController;
  late int _intervalSeconds;
  late int _retentionDays;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.monitor.probeHost);
    _urlController = TextEditingController(text: widget.monitor.probeUrl);
    _intervalSeconds = widget.monitor.probeIntervalSeconds;
    _retentionDays = widget.monitor.retentionDays;
    widget.monitor.addListener(_syncSavedValues);
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monitor != widget.monitor) {
      oldWidget.monitor.removeListener(_syncSavedValues);
      widget.monitor.addListener(_syncSavedValues);
      _syncSavedValues();
    }
  }

  void _syncSavedValues() {
    final monitor = widget.monitor;
    if (_hostController.text == monitor.probeHost &&
        _urlController.text == monitor.probeUrl &&
        _intervalSeconds == monitor.probeIntervalSeconds &&
        _retentionDays == monitor.retentionDays) {
      return;
    }
    setState(() {
      _hostController.text = monitor.probeHost;
      _urlController.text = monitor.probeUrl;
      _intervalSeconds = monitor.probeIntervalSeconds;
      _retentionDays = monitor.retentionDays;
    });
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_syncSavedValues);
    _hostController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Оформление', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('Системная'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Светлая'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Тёмная'),
            ),
          ],
          selected: {widget.themeMode},
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) {
              widget.onThemeModeChanged(selection.first);
            }
          },
        ),
        const SizedBox(height: 24),
        Text('Мониторинг', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: _intervalSeconds,
                  decoration: const InputDecoration(
                    labelText: 'Интервал проб, секунды',
                  ),
                  items: const [15, 30, 60, 120, 300]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value секунд'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _intervalSeconds = value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _retentionDays,
                  decoration: const InputDecoration(
                    labelText: 'Хранить историю',
                  ),
                  items: const [7, 14, 30, 60, 90]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value дней'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _retentionDays = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _hostController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'DNS-имя контрольного узла',
                    hintText: 'connectivitycheck.gstatic.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS URL контрольного узла',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'URL должен использовать HTTPS и тот же узел, что и DNS-имя. '
                  'Настройки применяются к экранной и фоновой записи.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Сохранить настройки'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Данные хранятся локально'),
            subtitle: const Text(
              'Идентификаторы сот, телефона и SIM не записываются. '
              'Скоростной тест запускается отдельно и вручную.',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = await widget.monitor.saveSettings(
      newProbeIntervalSeconds: _intervalSeconds,
      newRetentionDays: _retentionDays,
      newProbeHost: _hostController.text.trim(),
      newProbeUrl: _urlController.text.trim(),
      newThemeMode: switch (widget.themeMode) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      },
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? 'Настройки сохранены на устройстве.'
              : widget.monitor.platformError ?? 'Не удалось сохранить настройки.',
        ),
      ),
    );
  }
}
