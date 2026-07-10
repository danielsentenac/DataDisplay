import 'dart:math' as math;

import 'datadisplay_backend.dart';

/// Helpers for the live deck-refresh mode ("follow now").

/// GPS epoch (1980-01-06T00:00:00 UTC) expressed as Unix seconds.
const gpsUnixEpochSeconds = 315964800;

/// GPS-UTC offset in leap seconds. A constant is fine here: it has been 18
/// since 2017-01-01 and only sub-minute display alignment depends on it.
const gpsLeapSeconds = 18;

/// Current GPS time in seconds for a UTC wall-clock instant.
double gpsNowSeconds(DateTime nowUtc) {
  return nowUtc.millisecondsSinceEpoch / 1000.0 -
      gpsUnixEpochSeconds +
      gpsLeapSeconds;
}

/// Slides a GPS window to follow "now": the duration is preserved and the
/// window ends `latencyMarginSeconds` behind the current GPS time (data
/// close to now is typically not on disk yet).
TimeRange slideLiveWindow({
  required TimeRange current,
  required double gpsNowSeconds,
  double latencyMarginSeconds = 30.0,
}) {
  final durationNs = math.max(1, current.endNs - current.startNs);
  final endNs = ((gpsNowSeconds - latencyMarginSeconds) * 1.0e9).round();
  return TimeRange(startNs: endNs - durationNs, endNs: endNs);
}
