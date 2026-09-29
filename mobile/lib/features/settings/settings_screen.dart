import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    super.key,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

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
          selected: {themeMode},
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) onThemeModeChanged(selection.first);
          },
        ),
        const SizedBox(height: 24),
        Text('Мониторинг', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.timer_outlined),
            title: Text('Интервалы, контрольные узлы и хранение'),
            subtitle: Text('Появятся после реализации сетевого мониторинга.'),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Выбранная тема действует до закрытия приложения. '
          'Сохранение настроек появится в следующем этапе.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
