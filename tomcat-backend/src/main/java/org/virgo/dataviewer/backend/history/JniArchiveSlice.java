package org.virgo.dataviewer.backend.history;

public final class JniArchiveSlice {
    private final String unit;
    private final long startGps;
    private final int stepSeconds;
    private final double[] values;

    public JniArchiveSlice(String unit, long startGps, int stepSeconds, double[] values) {
        this.unit = unit;
        this.startGps = startGps;
        this.stepSeconds = stepSeconds;
        this.values = values == null ? new double[0] : values.clone();
    }

    public String getUnit() { return unit; }
    public long getStartGps() { return startGps; }
    public int getStepSeconds() { return stepSeconds; }
    public double[] getValues() { return values.clone(); }
}
