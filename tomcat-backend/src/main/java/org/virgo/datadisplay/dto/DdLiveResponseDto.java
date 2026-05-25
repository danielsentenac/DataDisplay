package org.virgo.datadisplay.dto;

import java.util.List;

/** Poll response for online Ser (trend-rate) data. */
public final class DdLiveResponseDto {
    private final long serverNowUtcMs;
    private final List<DdLiveSeriesDto> series;

    public DdLiveResponseDto(long serverNowUtcMs, List<DdLiveSeriesDto> series) {
        this.serverNowUtcMs = serverNowUtcMs;
        this.series = series;
    }

    public long getServerNowUtcMs() { return serverNowUtcMs; }
    public List<DdLiveSeriesDto> getSeries() { return series; }
}
