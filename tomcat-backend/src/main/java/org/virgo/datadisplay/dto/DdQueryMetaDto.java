package org.virgo.datadisplay.dto;

public final class DdQueryMetaDto {
    private final int channelCount;
    private final String fflSource;
    private final long resolvedStartUtcMs;
    private final long resolvedStartGps;
    private final long requestedEndUtcMs;
    private final long loadedEndUtcMs;
    private final Long nextChunkStartUtcMs;
    private final boolean historyComplete;

    public DdQueryMetaDto(
            int channelCount,
            String fflSource,
            long resolvedStartUtcMs,
            long resolvedStartGps,
            long requestedEndUtcMs,
            long loadedEndUtcMs,
            Long nextChunkStartUtcMs,
            boolean historyComplete) {
        this.channelCount = channelCount;
        this.fflSource = fflSource;
        this.resolvedStartUtcMs = resolvedStartUtcMs;
        this.resolvedStartGps = resolvedStartGps;
        this.requestedEndUtcMs = requestedEndUtcMs;
        this.loadedEndUtcMs = loadedEndUtcMs;
        this.nextChunkStartUtcMs = nextChunkStartUtcMs;
        this.historyComplete = historyComplete;
    }

    public int getChannelCount() { return channelCount; }
    public String getFflSource() { return fflSource; }
    public long getResolvedStartUtcMs() { return resolvedStartUtcMs; }
    public long getResolvedStartGps() { return resolvedStartGps; }
    public long getRequestedEndUtcMs() { return requestedEndUtcMs; }
    public long getLoadedEndUtcMs() { return loadedEndUtcMs; }
    public Long getNextChunkStartUtcMs() { return nextChunkStartUtcMs; }
    public boolean isHistoryComplete() { return historyComplete; }
}
