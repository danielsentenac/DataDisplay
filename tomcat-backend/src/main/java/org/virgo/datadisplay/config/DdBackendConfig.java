package org.virgo.datadisplay.config;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import javax.servlet.ServletContext;

import org.virgo.datadisplay.archive.FflSource;

public final class DdBackendConfig {
    private final List<FflSource> fflSources;
    private final String historyBackend;
    private final String frameJniLibraryName;
    private final String frameJniLibraryPath;
    private final String zcmEndpoint;
    private final String gpsChannel;
    private final int liveBufferSeconds;
    private final int livePollMs;

    private DdBackendConfig(
            List<FflSource> fflSources,
            String historyBackend,
            String frameJniLibraryName,
            String frameJniLibraryPath,
            String zcmEndpoint,
            String gpsChannel,
            int liveBufferSeconds,
            int livePollMs) {
        this.fflSources = Collections.unmodifiableList(new ArrayList<FflSource>(fflSources));
        this.historyBackend = historyBackend;
        this.frameJniLibraryName = frameJniLibraryName;
        this.frameJniLibraryPath = frameJniLibraryPath;
        this.zcmEndpoint = zcmEndpoint;
        this.gpsChannel = gpsChannel;
        this.liveBufferSeconds = liveBufferSeconds;
        this.livePollMs = livePollMs;
    }

    public static DdBackendConfig from(ServletContext context) {
        String sourcesParam = trimToDefault(context.getInitParameter("datadisplay.ffl.sources"), "trend,50Hz,raw");
        String[] sourceIds = sourcesParam.split(",");
        List<FflSource> fflSources = new ArrayList<FflSource>();
        for (String rawId : sourceIds) {
            String id = rawId.trim();
            if (id.isEmpty()) continue;
            String path = trimToDefault(context.getInitParameter("datadisplay.ffl." + id + ".path"), "/virgoData/ffl/" + id + ".ffl");
            String label = trimToDefault(context.getInitParameter("datadisplay.ffl." + id + ".label"), id);
            double rate = parsePositiveDouble(context.getInitParameter("datadisplay.ffl." + id + ".rate"), 1.0);
            fflSources.add(new FflSource(id, label, path, rate));
        }

        String historyBackend = trimToDefault(context.getInitParameter("datadisplay.history.backend"), "jni");
        String jniLibName = trimToDefault(context.getInitParameter("datadisplay.frame.jni.library"), "virgo_frame_jni");
        String jniLibPath = trimToNull(context.getInitParameter("datadisplay.frame.jni.path"));
        String zcmEndpoint = trimToDefault(context.getInitParameter("datadisplay.zcm.endpoint"), "");
        String gpsChannel = trimToDefault(context.getInitParameter("datadisplay.zcm.gps.channel"), "GPS");
        int liveBufferMinutes = parsePositiveInt(context.getInitParameter("datadisplay.live.buffer.minutes"), 5);
        int liveBufferSeconds = parsePositiveInt(context.getInitParameter("datadisplay.live.buffer.seconds"), liveBufferMinutes * 60);
        int livePollMs = parsePositiveInt(context.getInitParameter("datadisplay.live.poll.ms"), 1000);

        return new DdBackendConfig(fflSources, historyBackend, jniLibName, jniLibPath, zcmEndpoint, gpsChannel, liveBufferSeconds, livePollMs);
    }

    public List<FflSource> getFflSources() { return fflSources; }
    public FflSource getFflSource(String id) {
        for (FflSource source : fflSources) {
            if (source.getId().equals(id)) return source;
        }
        return null;
    }
    public String getHistoryBackend() { return historyBackend; }
    public String getFrameJniLibraryName() { return frameJniLibraryName; }
    public String getFrameJniLibraryPath() { return frameJniLibraryPath; }
    public String getZcmEndpoint() { return zcmEndpoint; }
    public String getGpsChannel() { return gpsChannel; }
    public int getLiveBufferSeconds() { return liveBufferSeconds; }
    public int getLivePollMs() { return livePollMs; }

    private static String trimToDefault(String value, String fallback) {
        if (value == null) return fallback;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? fallback : trimmed;
    }
    private static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
    private static int parsePositiveInt(String value, int fallback) {
        if (value == null) return fallback;
        try {
            int parsed = Integer.parseInt(value.trim());
            return parsed > 0 ? parsed : fallback;
        } catch (NumberFormatException e) { return fallback; }
    }
    private static double parsePositiveDouble(String value, double fallback) {
        if (value == null) return fallback;
        try {
            double parsed = Double.parseDouble(value.trim());
            return parsed > 0 ? parsed : fallback;
        } catch (NumberFormatException e) { return fallback; }
    }
}
