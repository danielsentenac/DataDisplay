package org.virgo.datadisplay.dto;

public final class DdChannelItemDto {
    private final String name;
    private final String displayName;
    private final String unit;
    private final String category;
    private final double sampleRateHz;

    public DdChannelItemDto(String name, String displayName, String unit, String category, double sampleRateHz) {
        this.name = name;
        this.displayName = displayName;
        this.unit = unit;
        this.category = category;
        this.sampleRateHz = sampleRateHz;
    }

    public String getName() { return name; }
    public String getDisplayName() { return displayName; }
    public String getUnit() { return unit; }
    public String getCategory() { return category; }
    public double getSampleRateHz() { return sampleRateHz; }
}
