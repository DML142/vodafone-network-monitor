import 'package:flutter/material.dart';

import '../../app/empty_state_panel.dart';

class ChartsScreen extends StatelessWidget {
  const ChartsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text('Здесь будут графики задержки, скорости и радиосигнала.'),
        SizedBox(height: 12),
        EmptyStatePanel(
          icon: Icons.show_chart,
          title: 'Нет измерений',
          message: 'Начните запись сессии, чтобы появились данные для графика.',
        ),
      ],
    );
  }
}
