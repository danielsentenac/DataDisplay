package org.virgo.dataviewer.backend.history;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class TrendRawSeries {
    private final String channel;
    private final String unit;
    private final long startGps;
    private final int stepSeconds;
    private final List<Double> values;

    public TrendRawSeries(String channel, String unit, long startGps, int stepSeconds, List<Double> values) {
        this.channel = channel;
        this.unit = unit;
        this.startGps = startGps;
        this.stepSeconds = stepSeconds;
        this.values = Collections.unmodifiableList(new ArrayList<Double>(values));
    }

    public String getChannel() { return channel; }
    public String getUnit() { return unit; }
    public long getStartGps() { return startGps; }
    public int getStepSeconds() { return stepSeconds; }
    public List<Double> getValues() { return values; }
}
