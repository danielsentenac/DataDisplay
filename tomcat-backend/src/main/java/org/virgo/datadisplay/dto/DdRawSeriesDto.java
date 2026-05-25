package org.virgo.datadisplay.dto;

import java.util.List;

/**
 * Series response in raw (un-bucketed) mode.
 * stepNs uses nanoseconds so sub-second sample rates (50 Hz, raw) are exact.
 */
public final class DdRawSeriesDto {
    private final String channel;
    private final String displayName;
    private final String unit;
    private final String fflSource;
    private final String samplingMode = "raw";
    private final long startUtcMs;
    private final long stepNs;
    private final List<Double> values;

    public DdRawSeriesDto(String channel, String displayName, String unit, String fflSource,
                          long startUtcMs, long stepNs, List<Double> values) {
        this.channel = channel;
        this.displayName = displayName;
        this.unit = unit;
        this.fflSource = fflSource;
        this.startUtcMs = startUtcMs;
        this.stepNs = stepNs;
        this.values = values;
    }

    public String getChannel() { return channel; }
    public String getDisplayName() { return displayName; }
    public String getUnit() { return unit; }
    public String getFflSource() { return fflSource; }
    public String getSamplingMode() { return samplingMode; }
    public long getStartUtcMs() { return startUtcMs; }
    public long getStepNs() { return stepNs; }
    public List<Double> getValues() { return values; }
}
