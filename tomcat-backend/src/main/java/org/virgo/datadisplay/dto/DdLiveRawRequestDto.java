package org.virgo.datadisplay.dto;

import java.util.List;

/** Poll request for online raw/50Hz data (future — not yet served by zFdVac). */
public final class DdLiveRawRequestDto {
    private final String fflSource;
    private final List<String> channels;
    private final long afterUtcMs;

    public DdLiveRawRequestDto(String fflSource, List<String> channels, long afterUtcMs) {
        this.fflSource = fflSource;
        this.channels = channels;
        this.afterUtcMs = afterUtcMs;
    }

    public String getFflSource() { return fflSource; }
    public List<String> getChannels() { return channels; }
    public long getAfterUtcMs() { return afterUtcMs; }
}
