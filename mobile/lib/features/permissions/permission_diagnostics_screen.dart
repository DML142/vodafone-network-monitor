import 'package:flutter/material.dart';

class PermissionDiagnosticsScreen extends StatelessWidget {
  const PermissionDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.check_circle_outline),
            title: Text('Разрешения пока не запрашивались'),
            subtitle: Text(
              'Каркас приложения не собирает данные сети или телефона.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Android требует разрешение на точное местоположение для '
              'получения сведений CellInfo. Приложение объяснит это перед '
              'включением радиоданных; без разрешения базовая проверка '
              'интернета должна работать.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      ],
    );
  }
}
