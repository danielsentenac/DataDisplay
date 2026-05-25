package org.virgo.datadisplay.dto;

import java.util.List;

/** Poll request for online Ser (trend-rate) data from zFdVac. */
public final class DdLiveRequestDto {
    private final List<String> channels;
    private final long afterUtcMs;

    public DdLiveRequestDto(List<String> channels, long afterUtcMs) {
        this.channels = channels;
        this.afterUtcMs = afterUtcMs;
    }

    public List<String> getChannels() { return channels; }
    public long getAfterUtcMs() { return afterUtcMs; }
}
