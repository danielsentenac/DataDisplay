package org.virgo.datadisplay.archive;

/** Descriptor for one FFL data source (trend, 50Hz, raw, …). */
public final class FflSource {
    private final String id;
    private final String label;
    private final String path;
    private final double nominalSampleRateHz;

    public FflSource(String id, String label, String path, double nominalSampleRateHz) {
        this.id = id;
        this.label = label;
        this.path = path;
        this.nominalSampleRateHz = nominalSampleRateHz;
    }

    public String getId() { return id; }
    public String getLabel() { return label; }
    public String getPath() { return path; }
    public double getNominalSampleRateHz() { return nominalSampleRateHz; }

    /** Step in nanoseconds derived from the nominal sample rate. */
    public long nominalStepNs() {
        return Math.round(1e9 / nominalSampleRateHz);
    }
}
