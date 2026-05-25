package org.virgo.datadisplay.archive;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.virgo.dataviewer.adapter.service.AdapterException;
import org.virgo.dataviewer.backend.history.ArchiveBounds;
import org.virgo.dataviewer.backend.history.JniTrendArchiveReader;
import org.virgo.dataviewer.backend.history.TrendRawSeries;

/**
 * Wraps JniTrendArchiveReader for a specific FflSource, correcting the step for sub-second data
 * and exposing FflRawSeries (stepNs) rather than TrendRawSeries (stepSeconds).
 */
public final class FflArchiveAdapter {
    private final FflSource source;
    private final JniTrendArchiveReader reader;

    public FflArchiveAdapter(FflSource source, String jniLibraryName, String jniLibraryPath) {
        this.source = source;
        this.reader = new JniTrendArchiveReader(source.getPath(), jniLibraryName, jniLibraryPath);
    }

    public FflSource getSource() { return source; }

    public ArchiveBounds resolveBounds() throws AdapterException {
        return reader.resolveBounds();
    }

    public java.util.List<String> listChannels() throws AdapterException {
        return reader.listChannels();
    }

    public List<FflRawSeries> readSeries(List<String> channels, long startGps, long durationSeconds) throws AdapterException {
        List<TrendRawSeries> raw = reader.readRawSeries(channels, startGps, durationSeconds);
        List<FflRawSeries> result = new ArrayList<FflRawSeries>(raw.size());
        for (TrendRawSeries trend : raw) {
            long stepNs = resolveStepNs(trend.getStepSeconds());
            result.add(new FflRawSeries(trend.getChannel(), trend.getUnit(), trend.getStartGps(), stepNs, trend.getValues()));
        }
        return result;
    }

    /**
     * Convert JNI stepSeconds to nanoseconds.
     * stepSeconds is 0 for sub-second sample rates; fall back to the nominal rate from FFL config.
     */
    private long resolveStepNs(int stepSeconds) {
        if (stepSeconds > 0) {
            return stepSeconds * 1_000_000_000L;
        }
        return source.nominalStepNs();
    }
}
