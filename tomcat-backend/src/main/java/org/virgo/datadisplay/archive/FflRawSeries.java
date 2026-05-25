package org.virgo.datadisplay.archive;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Raw time series read from a Frame File List archive.
 * Uses nanosecond step resolution so 50 Hz and raw data are represented correctly.
 */
public final class FflRawSeries {
    private final String channel;
    private final String unit;
    private final long startGps;
    private final long stepNs;   // nanoseconds between samples
    private final List<Double> values;

    public FflRawSeries(String channel, String unit, long startGps, long stepNs, List<Double> values) {
        this.channel = channel;
        this.unit = unit;
        this.startGps = startGps;
        this.stepNs = stepNs;
        this.values = Collections.unmodifiableList(new ArrayList<Double>(values));
    }

    public String getChannel() { return channel; }
    public String getUnit() { return unit; }
    public long getStartGps() { return startGps; }
    public long getStepNs() { return stepNs; }
    public List<Double> getValues() { return values; }
}
