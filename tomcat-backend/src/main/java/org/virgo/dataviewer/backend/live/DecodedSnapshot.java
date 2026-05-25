package org.virgo.dataviewer.backend.live;

import java.util.Map;

final class DecodedSnapshot {
    private final long gpsSeconds;
    private final long utcMs;
    private final Map<String, Double> numericValues;
    private final Map<String, String> catalogUnits;

    DecodedSnapshot(long gpsSeconds, long utcMs, Map<String, Double> numericValues, Map<String, String> catalogUnits) {
        this.gpsSeconds = gpsSeconds;
        this.utcMs = utcMs;
        this.numericValues = numericValues;
        this.catalogUnits = catalogUnits;
    }

    long getGpsSeconds() {
        return gpsSeconds;
    }

    long getUtcMs() {
        return utcMs;
    }

    Map<String, Double> getNumericValues() {
        return numericValues;
    }

    Map<String, String> getCatalogUnits() {
        return catalogUnits;
    }
}
