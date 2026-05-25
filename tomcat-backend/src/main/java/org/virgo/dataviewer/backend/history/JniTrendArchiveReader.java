package org.virgo.dataviewer.backend.history;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.virgo.dataviewer.adapter.service.AdapterException;

/**
 * JNI-backed frame archive reader.  Symbol names are fixed by the class and package name
 * (Java_org_virgo_dataviewer_backend_history_JniTrendArchiveReader_*) and must match the
 * deployed libvirgo_frame_jni.so.
 */
public final class JniTrendArchiveReader implements TrendArchiveReader {
    private final String fflPath;
    private final String libraryName;
    private final String libraryPath;
    private volatile boolean initialized;

    public JniTrendArchiveReader(String fflPath, String libraryName, String libraryPath) {
        this.fflPath = fflPath;
        this.libraryName = libraryName;
        this.libraryPath = libraryPath;
    }

    @Override
    public ArchiveBounds resolveBounds() throws AdapterException {
        ensureInitialized();
        try {
            long[] bounds = resolveBoundsNative(fflPath);
            if (bounds == null || bounds.length < 2) {
                throw AdapterException.serviceUnavailable("Frame archive JNI returned invalid archive bounds.");
            }
            return new ArchiveBounds(bounds[0], bounds[1]);
        } catch (AdapterException exception) {
            throw exception;
        } catch (Throwable throwable) {
            throw AdapterException.serviceUnavailable("Unable to inspect archive through JNI: " + throwable.getMessage());
        }
    }

    @Override
    public List<String> listChannels() throws AdapterException {
        ensureInitialized();
        try {
            String[] names = listChannelsNative(fflPath);
            if (names == null) return Collections.emptyList();
            List<String> result = new ArrayList<String>(names.length);
            for (String name : names) {
                if (name != null && !name.trim().isEmpty()) result.add(name.trim());
            }
            return Collections.unmodifiableList(result);
        } catch (UnsatisfiedLinkError unsatisfiedLinkError) {
            // listChannelsNative is not implemented in the currently deployed native library.
            // Return empty list — channel browsing will be limited to manual name entry.
            return Collections.emptyList();
        } catch (Throwable throwable) {
            throw AdapterException.serviceUnavailable("Unable to list channels through JNI: " + throwable.getMessage());
        }
    }

    @Override
    public List<TrendRawSeries> readRawSeries(List<String> channels, long startGps, long durationSeconds) throws AdapterException {
        ensureInitialized();
        List<TrendRawSeries> out = new ArrayList<TrendRawSeries>();
        for (String channel : channels == null ? Collections.<String>emptyList() : channels) {
            if (channel == null || channel.trim().isEmpty()) {
                continue;
            }
            out.add(readOneChannel(channel.trim(), startGps, durationSeconds));
        }
        return out;
    }

    private TrendRawSeries readOneChannel(String channel, long startGps, long durationSeconds) throws AdapterException {
        try {
            JniArchiveSlice slice = readRawSeriesNative(fflPath, channel, startGps, durationSeconds);
            if (slice == null) {
                return new TrendRawSeries(channel, null, startGps, 0, nullFilledValues(durationSeconds));
            }
            return new TrendRawSeries(
                    channel,
                    slice.getUnit(),
                    slice.getStartGps(),
                    slice.getStepSeconds(),   // NOTE: 0 for sub-second data; caller applies nominal rate
                    toNullableValues(slice.getValues()));
        } catch (Throwable throwable) {
            throw AdapterException.serviceUnavailable(
                    "Unable to read archive through JNI for channel " + channel + ": " + throwable.getMessage());
        }
    }

    private void ensureInitialized() throws AdapterException {
        if (initialized) {
            return;
        }
        synchronized (this) {
            if (initialized) {
                return;
            }
            try {
                if (libraryPath != null && !libraryPath.trim().isEmpty()) {
                    System.load(libraryPath);
                } else {
                    System.loadLibrary(libraryName);
                }
                initialized = true;
            } catch (UnsatisfiedLinkError unsatisfiedLinkError) {
                String msg = unsatisfiedLinkError.getMessage();
                if (msg != null && msg.contains("already loaded in another classloader")) {
                    // Hot-redeploy: a previous webapp classloader already loaded this library.
                    // The native symbols remain registered in the JVM; safe to proceed.
                    initialized = true;
                } else {
                    throw AdapterException.serviceUnavailable(
                            "Frame archive JNI runtime is unavailable. Ensure " + libraryName + " is deployed: " + msg);
                }
            } catch (Throwable throwable) {
                throw AdapterException.serviceUnavailable(
                        "Frame archive JNI runtime is unavailable. Ensure " + libraryName + " is deployed: " + throwable.getMessage());
            }
        }
    }

    private static List<Double> toNullableValues(double[] rawValues) {
        List<Double> values = new ArrayList<Double>(rawValues == null ? 0 : rawValues.length);
        if (rawValues == null) {
            return values;
        }
        for (double rawValue : rawValues) {
            values.add(Double.isFinite(rawValue) ? Double.valueOf(rawValue) : null);
        }
        return values;
    }

    private static List<Double> nullFilledValues(long sampleCount) throws AdapterException {
        if (sampleCount < 0L || sampleCount > Integer.MAX_VALUE) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE", "Requested archive span is too large.");
        }
        return new ArrayList<Double>(Collections.nCopies((int) sampleCount, (Double) null));
    }

    private static native long[] resolveBoundsNative(String fflPath);
    private static native String[] listChannelsNative(String fflPath);
    private static native JniArchiveSlice readRawSeriesNative(String fflPath, String channel, long startGps, long durationSeconds);
}
