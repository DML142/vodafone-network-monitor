import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/empty_state_panel.dart';
import '../../core/monitoring/network_monitor_controller.dart';

enum _Metric {
  latency('Задержка', 'latency_ms', 'мс'),
  signal('Сигнал', 'signal_dbm', 'dBm'),
  rsrp('RSRP', 'rsrp_dbm', 'dBm'),
  download('Загрузка', 'download_mbps', 'Мбит/с'),
  upload('Отдача', 'upload_mbps', 'Мбит/с');

  const _Metric(this.label, this.key, this.unit);
  final String label;
  final String key;
  final String unit;
}

class ChartsScreen extends StatefulWidget {
  const ChartsScreen({
    required this.monitor,
    this.initialSessionId,
    this.isActive = true,
    super.key,
  });

  final NetworkMonitorController monitor;
  final String? initialSessionId;
  final bool isActive;

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  String? _sessionId;
  List<Map<String, dynamic>> _measurements = [];
  Duration? _range = const Duration(hours: 1);
  _Metric _metric = _Metric.latency;
  bool _loading = false;
  bool _refreshInProgress = false;
  Timer? _refreshTimer;
  Duration? _refreshInterval;
  int _loadRequest = 0;
  String? _lastRecordingSessionId;
  bool _lastWasRecording = false;
  Object? _lastSpeedTest;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.initialSessionId;
    _lastRecordingSessionId = widget.monitor.recordingSessionId;
    _lastWasRecording = widget.monitor.isRecording;
    _lastSpeedTest = widget.monitor.lastSpeedTest;
    widget.monitor.addListener(_onMonitorChanged);
    _syncRefreshTimer();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChartsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monitor != widget.monitor) {
      oldWidget.monitor.removeListener(_onMonitorChanged);
      _lastRecordingSessionId = widget.monitor.recordingSessionId;
      _lastWasRecording = widget.monitor.isRecording;
      _lastSpeedTest = widget.monitor.lastSpeedTest;
      widget.monitor.addListener(_onMonitorChanged);
      _load();
    }
    if (oldWidget.isActive != widget.isActive ||
        oldWidget.monitor != widget.monitor) {
      _syncRefreshTimer();
    }
    if (oldWidget.initialSessionId != widget.initialSessionId &&
        widget.initialSessionId != null) {
      _sessionId = widget.initialSessionId;
      _load();
    }
  }

  void _onMonitorChanged() {
    final previousRecordingId = _lastRecordingSessionId;
    final currentRecordingId = widget.monitor.recordingSessionId;
    final recordingChanged =
        previousRecordingId != currentRecordingId ||
        _lastWasRecording != widget.monitor.isRecording;
    _lastRecordingSessionId = currentRecordingId;
    _lastWasRecording = widget.monitor.isRecording;

    final speedTestChanged =
        !identical(_lastSpeedTest, widget.monitor.lastSpeedTest) &&
        widget.monitor.lastSpeedTest != null;
    _lastSpeedTest = widget.monitor.lastSpeedTest;
    _syncRefreshTimer();

    if (!recordingChanged && !speedTestChanged) return;

    final activeId = widget.monitor.isRecording ? currentRecordingId : null;
    if (activeId != null) {
      _load(preferredSessionId: activeId);
    } else if (speedTestChanged) {
      _load(selectLatest: true);
    } else if (_sessionId == previousRecordingId) {
      _load(preferredSessionId: previousRecordingId);
    } else {
      _load();
    }
  }

  void _syncRefreshTimer() {
    final intervalSeconds = widget.monitor.autoSpeedTestEnabled
        ? math.min(
            widget.monitor.probeIntervalSeconds,
            widget.monitor.autoSpeedTestIntervalSeconds,
          )
        : widget.monitor.probeIntervalSeconds;
    final interval = Duration(seconds: intervalSeconds);
    if (!widget.isActive || !widget.monitor.isRecording) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _refreshInterval = null;
      return;
    }
    if (_refreshTimer != null && _refreshInterval == interval) return;
    _refreshTimer?.cancel();
    _refreshInterval = interval;
    _refreshTimer = Timer.periodic(interval, (_) {
      unawaited(_refreshActiveSession());
    });
  }

  Future<void> _refreshActiveSession() async {
    if (_refreshInProgress || _loading) return;
    _refreshInProgress = true;
    try {
      await widget.monitor.refreshSessions();
      final activeId = widget.monitor.recordingSessionId;
      if (!widget.monitor.isRecording || activeId == null) return;
      if (_sessionId != activeId) return;
      final measurements = await widget.monitor.loadMeasurements(activeId);
      if (!mounted || _sessionId != activeId) return;
      setState(() => _measurements = measurements);
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _load({
    String? preferredSessionId,
    bool selectLatest = false,
  }) async {
    final request = ++_loadRequest;
    if (mounted) setState(() => _loading = true);
    await widget.monitor.refreshSessions();
    final sessions = widget.monitor.sessions;
    if (!mounted || request != _loadRequest) return;
    final requested = selectLatest ? null : preferredSessionId ?? _sessionId;
    final selected = sessions.any((row) => row['id'] == requested)
        ? requested
        : sessions.isEmpty
        ? null
        : sessions.first['id'] as String?;
    _sessionId = selected;
    final measurements = selected == null
        ? <Map<String, dynamic>>[]
        : await widget.monitor.loadMeasurements(selected);
    if (!mounted || request != _loadRequest) return;
    setState(() {
      _measurements = measurements;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.monitor.removeListener(_onMonitorChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.monitor,
      builder: (context, _) {
        final sessions = widget.monitor.sessions;
        final selectedRows = _filteredRows;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (sessions.isEmpty)
              const EmptyStatePanel(
                icon: Icons.show_chart,
                title: 'Нет измерений',
                message: 'Начните запись или запустите ручной скоростной тест.',
              )
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey(_sessionId),
                initialValue: sessions.any((row) => row['id'] == _sessionId)
                    ? _sessionId
                    : sessions.first['id'] as String?,
                decoration: const InputDecoration(labelText: 'Сессия'),
                items: sessions
                    .map(
                      (row) => DropdownMenuItem<String>(
                        value: row['id'] as String,
                        child: Text(
                          _sessionLabel(row),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _sessionId = value);
                  _load();
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _rangeChoice('1 ч', const Duration(hours: 1)),
                  _rangeChoice('6 ч', const Duration(hours: 6)),
                  _rangeChoice('24 ч', const Duration(hours: 24)),
                  _rangeChoice('Всё', null),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _Metric.values
                    .map(
                      (metric) => ChoiceChip(
                        label: Text(metric.label),
                        selected: _metric == metric,
                        onSelected: (_) => setState(() => _metric = metric),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (selectedRows.isEmpty)
                EmptyStatePanel(
                  icon: Icons.show_chart,
                  title: 'Нет точек для графика',
                  message: _emptyMessage,
                )
              else
                _LineChart(rows: selectedRows, metric: _metric),
              const SizedBox(height: 8),
              Text(
                'Время показано по часовому поясу телефона; единицы измерения указаны рядом с графиком.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        );
      },
    );
  }

  List<Map<String, dynamic>> get _filteredRows {
    final rows = _measurements.where((row) {
      final value = row[_metric.key];
      final observed = row['observed_at_utc'];
      return value is num && observed is num;
    }).toList();
    final range = _range;
    if (range == null || rows.isEmpty) return rows;
    final latest = (rows.last['observed_at_utc'] as num).toInt();
    final cutoff = latest - range.inMilliseconds;
    return rows
        .where((row) => (row['observed_at_utc'] as num).toInt() >= cutoff)
        .toList();
  }

  String get _emptyMessage => switch (_metric) {
    _Metric.rsrp =>
      'RSRP доступен для LTE/5G. В этой сессии Android '
          'записал ${_sessionTechnology ?? 'другой тип сети'}; посмотрите график «Сигнал».',
    _Metric.signal =>
      'Android не вернул уровень сигнала в dBm для точек '
          'этой сессии.',
    _Metric.download => _speedEmptyMessage('download_error'),
    _Metric.upload => _speedEmptyMessage('upload_error'),
    _ => 'В этой сессии нет значений «${_metric.label}» за выбранный диапазон.',
  };

  String _speedEmptyMessage(String errorKey) {
    for (final row in _measurements.reversed) {
      if (row['event_type'] != 'speed_test') continue;
      final error = row[errorKey];
      if (error is String && error.isNotEmpty) {
        return 'Последний тест не получил значение скорости: '
            '${_speedErrorDescription(error)}';
      }
    }
    if (widget.monitor.autoSpeedTestEnabled) {
      return 'Автотест включён с интервалом '
          '${widget.monitor.autoSpeedTestIntervalSeconds} с. '
          'Значение появится после завершения следующего теста.';
    }
    return 'Обычная запись не запускает скоростной тест. Запустите ручной '
        'тест на экране «Обзор» или включите автотест в настройках. '
        'Без активной записи ручной тест создаёт отдельную сессию.';
  }

  String _speedErrorDescription(String error) {
    if (error == 'cellular_unavailable') {
      return 'сотовый интернет недоступен; проверьте, что мобильные данные включены';
    }
    if (error == 'cellular_permission_denied') {
      return 'Android не разрешил выбрать сотовую сеть';
    }
    if (error == 'timeout') {
      return 'истекло время ожидания; медленной сети могло не хватить времени';
    }
    if (error == 'tls_error') return 'ошибка защищённого соединения';
    if (error == 'incomplete_download') {
      return 'передача завершилась раньше времени';
    }
    if (error.startsWith('http_')) {
      return 'сервер вернул код ${error.substring(5)}';
    }
    return 'ошибка соединения ($error)';
  }

  String? get _sessionTechnology {
    for (final row in _measurements.reversed) {
      final value = row['radio_technology'];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  Widget _rangeChoice(String label, Duration? range) => ChoiceChip(
    label: Text(label),
    selected: _range == range,
    onSelected: (_) => setState(() => _range = range),
  );

  String _sessionLabel(Map<String, dynamic> row) {
    final timestamp = (row['startedAtUtc'] as num?)?.toInt();
    if (timestamp == null) return 'Сессия';
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final count = row['sampleCount'] ?? 0;
    return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} · $count записей';
  }
}

class _LineChart extends StatelessWidget {
  const _LineChart({required this.rows, required this.metric});

  final List<Map<String, dynamic>> rows;
  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    final values = rows
        .map((row) => (row[metric.key] as num).toDouble())
        .toList();
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${metric.label} · ${metric.unit}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              width: double.infinity,
              child: CustomPaint(
                painter: _LineChartPainter(
                  rows: rows,
                  metric: metric,
                  color: Theme.of(context).colorScheme.primary,
                  gridColor: Theme.of(context).colorScheme.outlineVariant,
                  labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              '${minValue.toStringAsFixed(1)}–${maxValue.toStringAsFixed(1)} ${metric.unit} · ${rows.length} точек',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.rows,
    required this.metric,
    required this.color,
    required this.gridColor,
    required this.labelColor,
  });

  final List<Map<String, dynamic>> rows;
  final _Metric metric;
  final Color color;
  final Color gridColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 42.0;
    const top = 8.0;
    const right = 8.0;
    const bottom = 28.0;
    final chart = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final values = rows
        .map((row) => (row[metric.key] as num).toDouble())
        .toList();
    final times = rows
        .map((row) => (row['observed_at_utc'] as num).toInt())
        .toList();
    var minimum = values.reduce(math.min);
    var maximum = values.reduce(math.max);
    if (minimum == maximum) {
      final padding = minimum.abs() * 0.1 + 1;
      minimum -= padding;
      maximum += padding;
    }
    final firstTime = times.first;
    final lastTime = times.last;
    final timeSpan = math.max(1, lastTime - firstTime);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var index = 0; index <= 4; index++) {
      final fraction = index / 4;
      final y = chart.top + chart.height * fraction;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final value = maximum - (maximum - minimum) * fraction;
      _drawLabel(
        canvas,
        value.toStringAsFixed(0),
        Offset(0, y - 7),
        labelColor,
      );
    }
    for (var index = 0; index <= 2; index++) {
      final x = chart.left + chart.width * index / 2;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), gridPaint);
      final time = DateTime.fromMillisecondsSinceEpoch(
        firstTime + timeSpan * index ~/ 2,
      ).toLocal();
      final text =
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
      _drawLabel(canvas, text, Offset(x - 18, chart.bottom + 8), labelColor);
    }

    final path = Path();
    final points = <Offset>[];
    for (var index = 0; index < rows.length; index++) {
      final x = rows.length == 1
          ? chart.center.dx
          : chart.left + chart.width * (times[index] - firstTime) / timeSpan;
      final y =
          chart.bottom -
          chart.height * (values[index] - minimum) / (maximum - minimum);
      final point = Offset(x, y);
      points.add(point);
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    if (points.length > 1) canvas.drawPath(path, linePaint);
    final pointPaint = Paint()..color = color;
    for (final point in points) {
      canvas.drawCircle(point, 3.5, pointPaint);
    }
  }

  void _drawLabel(Canvas canvas, String value, Offset offset, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.metric != metric ||
      oldDelegate.color != color ||
      oldDelegate.gridColor != gridColor;
}
