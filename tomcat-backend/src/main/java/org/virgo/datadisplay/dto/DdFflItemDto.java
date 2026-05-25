package org.virgo.datadisplay.dto;

public final class DdFflItemDto {
    private final String id;
    private final String label;
    private final double sampleRateHz;

    public DdFflItemDto(String id, String label, double sampleRateHz) {
        this.id = id;
        this.label = label;
        this.sampleRateHz = sampleRateHz;
    }

    public String getId() { return id; }
    public String getLabel() { return label; }
    public double getSampleRateHz() { return sampleRateHz; }
}
