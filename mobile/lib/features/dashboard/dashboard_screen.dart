import 'package:flutter/material.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.pause_circle_outline,
                  size: 32,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Сбор не запущен'),
                      SizedBox(height: 6),
                      Text(
                        'На этом этапе приложение ещё не измеряет сеть. '
                        'Радиорегистрация сама по себе не подтверждает доступ '
                        'к интернету.',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Состояние', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        const _MetricCard(
          icon: Icons.cell_tower,
          label: 'Мобильная сеть',
          value: 'Неизвестно',
        ),
        const _MetricCard(
          icon: Icons.public,
          label: 'Доступ в интернет',
          value: 'Не проверен',
        ),
        const SizedBox(height: 20),
        Text(
          'Последние показатели',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricCard(
              icon: Icons.speed,
              label: 'Задержка',
              value: '—',
              unit: 'мс',
            ),
            _MetricCard(
              icon: Icons.warning_amber_outlined,
              label: 'Потери',
              value: '—',
              unit: '%',
            ),
            _MetricCard(
              icon: Icons.download_outlined,
              label: 'Скорость',
              value: '—',
              unit: 'Мбит/с',
            ),
            _MetricCard(
              icon: Icons.signal_cellular_alt,
              label: 'Радиосигнал',
              value: 'Нет данных',
            ),
          ],
        ),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Последняя успешная проверка'),
            subtitle: const Text('Нет данных'),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: SizedBox(
        width: 164,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(height: 14),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text(
                unit == null ? value : '$value $unit',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
