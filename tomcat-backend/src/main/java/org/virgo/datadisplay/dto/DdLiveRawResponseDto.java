package org.virgo.datadisplay.dto;

import java.util.List;

/** Poll response for online raw/50Hz data (future — stub). */
public final class DdLiveRawResponseDto {
    private final long serverNowUtcMs;
    private final List<DdLiveRawSeriesDto> series;

    public DdLiveRawResponseDto(long serverNowUtcMs, List<DdLiveRawSeriesDto> series) {
        this.serverNowUtcMs = serverNowUtcMs;
        this.series = series;
    }

    public long getServerNowUtcMs() { return serverNowUtcMs; }
    public List<DdLiveRawSeriesDto> getSeries() { return series; }
}
