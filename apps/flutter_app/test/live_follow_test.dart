import 'package:datadisplay_app/src/datadisplay_backend.dart';
import 'package:datadisplay_app/src/live_follow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gpsNowSeconds applies the GPS epoch and leap-second offset', () {
    // At the GPS epoch (1980-01-06 UTC) the constant-offset formula yields
    // exactly the leap-second count.
    expect(gpsNowSeconds(DateTime.utc(1980, 1, 6)), gpsLeapSeconds);

    // The conversion is a pure offset: deltas are preserved.
    final t0 = DateTime.utc(2026, 7, 7, 12, 0, 0);
    final t1 = t0.add(const Duration(seconds: 100));
    expect(gpsNowSeconds(t1) - gpsNowSeconds(t0), 100.0);
  });

  test('slideLiveWindow keeps the duration and trails now by the margin', () {
    const current = TimeRange(
      startNs: 1000000000000,
      endNs: 1000000000000 + 60000000000, // 60 s window
    );
    final slid = slideLiveWindow(
      current: current,
      gpsNowSeconds: 1_400_000_000.0,
    );

    // Duration preserved.
    expect(slid.endNs - slid.startNs, 60000000000);
    // Window ends 30 s (default latency margin) behind GPS now.
    expect(slid.endNs, ((1_400_000_000.0 - 30.0) * 1e9).round());
    expect(slid.startNs, ((1_400_000_000.0 - 30.0 - 60.0) * 1e9).round());
  });

  test('slideLiveWindow honors a custom latency margin', () {
    const current = TimeRange(startNs: 0, endNs: 10000000000); // 10 s
    final slid = slideLiveWindow(
      current: current,
      gpsNowSeconds: 1000.0,
      latencyMarginSeconds: 5.0,
    );
    expect(slid.endNs, 995000000000);
    expect(slid.startNs, 985000000000);
  });
}
