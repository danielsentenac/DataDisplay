import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single data point from a live poll response.
class LiveSeriesPoint {
  final String channel;
  final int startUtcMs;
  final int stepMs;
  final List<double?> values;

  const LiveSeriesPoint({
    required this.channel,
    required this.startUtcMs,
    required this.stepMs,
    required this.values,
  });

  factory LiveSeriesPoint.fromJson(Map<String, dynamic> json) {
    return LiveSeriesPoint(
      channel: json['channel'] as String,
      startUtcMs: (json['start_utc_ms'] as num).toInt(),
      stepMs: (json['step_ms'] as num).toInt(),
      values: (json['values'] as List<dynamic>)
          .map((v) => v == null ? null : (v as num).toDouble())
          .toList(),
    );
  }
}

/// Result of a single live poll request.
class LivePollResult {
  final int serverNowUtcMs;
  final List<LiveSeriesPoint> series;

  const LivePollResult({required this.serverNowUtcMs, required this.series});
}

/// Polls the Tomcat backend `/api/v1/datadisplay/plots/live` endpoint at a
/// configurable interval and broadcasts results via a [Stream].
///
/// Usage:
/// ```dart
/// final poller = TomcatLivePoller(
///   baseUrl: 'http://olserver134:8080/datadisplay-tomcat-backend',
///   channels: ['V1:DER_DATA_H'],
///   pollIntervalMs: 1000,
/// );
/// poller.stream.listen((result) { ... });
/// poller.start();
/// // later:
/// poller.stop();
/// ```
class TomcatLivePoller {
  final String baseUrl;
  final List<String> channels;
  final int pollIntervalMs;

  final _controller = StreamController<LivePollResult>.broadcast();
  Stream<LivePollResult> get stream => _controller.stream;

  Timer? _timer;
  int _afterUtcMs = 0;
  bool _running = false;

  TomcatLivePoller({
    required this.baseUrl,
    required this.channels,
    this.pollIntervalMs = 1000,
  });

  void start() {
    if (_running) return;
    _running = true;
    _afterUtcMs = DateTime.now().millisecondsSinceEpoch - 30000; // start 30s back
    _timer = Timer.periodic(Duration(milliseconds: pollIntervalMs), (_) => _poll());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  Future<void> _poll() async {
    if (!_running) return;
    try {
      final uri = Uri.parse('$baseUrl/api/v1/datadisplay/plots/live');
      final body = jsonEncode({
        'channels': channels,
        'after_utc_ms': _afterUtcMs,
      });
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (response.statusCode != 200) return;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final serverNow = (json['server_now_utc_ms'] as num).toInt();
      final seriesJson = (json['series'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final series = seriesJson.map(LiveSeriesPoint.fromJson).toList();

      if (series.isNotEmpty) {
        // Advance cursor to avoid re-receiving the same samples
        int latestSampleUtcMs = _afterUtcMs;
        for (final s in series) {
          final last = s.startUtcMs + s.stepMs * s.values.length;
          if (last > latestSampleUtcMs) latestSampleUtcMs = last;
        }
        _afterUtcMs = latestSampleUtcMs;
      }

      if (!_controller.isClosed) {
        _controller.add(LivePollResult(serverNowUtcMs: serverNow, series: series));
      }
    } catch (_) {
      // swallow transient network errors; they are displayed via stream absence
    }
  }
}
