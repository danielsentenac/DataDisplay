package org.virgo.datadisplay.dto;

import java.util.List;

/**
 * Series response in min/max bucketed mode.
 * bucketNs covers the bucket width in nanoseconds so sub-second rates work correctly.
 */
public final class DdBucketedSeriesDto {
    private final String channel;
    private final String displayName;
    private final String unit;
    private final String fflSource;
    private final String samplingMode = "minmax_bucket";
    private final long startUtcMs;
    private final long bucketNs;
    private final List<Double> minValues;
    private final List<Double> maxValues;

    public DdBucketedSeriesDto(String channel, String displayName, String unit, String fflSource,
                               long startUtcMs, long bucketNs, List<Double> minValues, List<Double> maxValues) {
        this.channel = channel;
        this.displayName = displayName;
        this.unit = unit;
        this.fflSource = fflSource;
        this.startUtcMs = startUtcMs;
        this.bucketNs = bucketNs;
        this.minValues = minValues;
        this.maxValues = maxValues;
    }

    public String getChannel() { return channel; }
    public String getDisplayName() { return displayName; }
    public String getUnit() { return unit; }
    public String getFflSource() { return fflSource; }
    public String getSamplingMode() { return samplingMode; }
    public long getStartUtcMs() { return startUtcMs; }
    public long getBucketNs() { return bucketNs; }
    public List<Double> getMinValues() { return minValues; }
    public List<Double> getMaxValues() { return maxValues; }
}
