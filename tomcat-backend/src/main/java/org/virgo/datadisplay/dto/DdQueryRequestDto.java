package org.virgo.datadisplay.dto;

import java.util.List;

/**
 * Request for offline FFL historical data.
 *
 * <pre>
 * {
 *   "channels": ["V1:DER_DATA_H"],
 *   "fflSource": "trend",           // "trend" | "50Hz" | "raw" (or any configured id)
 *   "startUtcMs": 1745000000000,
 *   "endUtcMs":   1745003600000,
 *   "sampling": {
 *     "targetBuckets": 720,
 *     "preserveExtrema": true
 *   },
 *   // Optional paging (for large raw/50 Hz requests):
 *   "chunkDurationSeconds": 60,
 *   "cursorStartUtcMs": null
 * }
 * </pre>
 */
public final class DdQueryRequestDto {
    private final List<String> channels;
    private final String fflSource;
    private final long startUtcMs;
    private final long endUtcMs;
    private final Integer targetBuckets;
    private final boolean preserveExtrema;
    private final Integer chunkDurationSeconds;
    private final Long cursorStartUtcMs;

    public DdQueryRequestDto(
            List<String> channels,
            String fflSource,
            long startUtcMs,
            long endUtcMs,
            Integer targetBuckets,
            boolean preserveExtrema,
            Integer chunkDurationSeconds,
            Long cursorStartUtcMs) {
        this.channels = channels;
        this.fflSource = fflSource;
        this.startUtcMs = startUtcMs;
        this.endUtcMs = endUtcMs;
        this.targetBuckets = targetBuckets;
        this.preserveExtrema = preserveExtrema;
        this.chunkDurationSeconds = chunkDurationSeconds;
        this.cursorStartUtcMs = cursorStartUtcMs;
    }

    public List<String> getChannels() { return channels; }
    public String getFflSource() { return fflSource; }
    public long getStartUtcMs() { return startUtcMs; }
    public long getEndUtcMs() { return endUtcMs; }
    public Integer getTargetBuckets() { return targetBuckets; }
    public boolean isPreserveExtrema() { return preserveExtrema; }
    public Integer getChunkDurationSeconds() { return chunkDurationSeconds; }
    public Long getCursorStartUtcMs() { return cursorStartUtcMs; }
}
