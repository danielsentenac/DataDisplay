package org.virgo.datadisplay.dto;

import java.util.List;

/**
 * One channel's data in a live raw/50Hz poll response.
 * stepNs encodes the nominal sample period in nanoseconds (e.g. 20_000_000 for 50 Hz).
 */
public final class DdLiveRawSeriesDto {
    private final String channel;
    private final long startUtcMs;
    private final long stepNs;
    private final List<Double> values;

    public DdLiveRawSeriesDto(String channel, long startUtcMs, long stepNs, List<Double> values) {
        this.channel = channel;
        this.startUtcMs = startUtcMs;
        this.stepNs = stepNs;
        this.values = values;
    }

    public String getChannel() { return channel; }
    public long getStartUtcMs() { return startUtcMs; }
    public long getStepNs() { return stepNs; }
    public List<Double> getValues() { return values; }
}
