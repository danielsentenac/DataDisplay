package org.virgo.dataviewer.backend.live;

final class LiveSnapshot {
    private final long gpsSeconds;
    private final long utcMs;
    private final double[] valuesByChannelIndex;

    LiveSnapshot(long gpsSeconds, long utcMs, double[] valuesByChannelIndex) {
        this.gpsSeconds = gpsSeconds;
        this.utcMs = utcMs;
        this.valuesByChannelIndex = valuesByChannelIndex == null ? new double[0] : valuesByChannelIndex;
    }

    long getGpsSeconds() {
        return gpsSeconds;
    }

    long getUtcMs() {
        return utcMs;
    }

    Double findNumericValue(int channelIndex) {
        if (channelIndex < 0 || channelIndex >= valuesByChannelIndex.length) {
            return null;
        }
        double value = valuesByChannelIndex[channelIndex];
        return Double.isNaN(value) ? null : Double.valueOf(value);
    }
}
