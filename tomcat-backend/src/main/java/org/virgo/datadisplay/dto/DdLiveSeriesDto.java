package org.virgo.datadisplay.dto;

import java.util.List;

/** One channel's data in a live Ser (trend-rate) poll response. */
public final class DdLiveSeriesDto {
    private final String channel;
    private final long startUtcMs;
    private final int stepMs;       // 1000 ms for 1 Hz Ser data
    private final List<Double> values;

    public DdLiveSeriesDto(String channel, long startUtcMs, int stepMs, List<Double> values) {
        this.channel = channel;
        this.startUtcMs = startUtcMs;
        this.stepMs = stepMs;
        this.values = values;
    }

    public String getChannel() { return channel; }
    public long getStartUtcMs() { return startUtcMs; }
    public int getStepMs() { return stepMs; }
    public List<Double> getValues() { return values; }
}
