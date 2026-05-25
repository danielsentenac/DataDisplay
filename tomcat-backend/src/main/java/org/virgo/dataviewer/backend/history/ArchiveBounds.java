package org.virgo.dataviewer.backend.history;

public final class ArchiveBounds {
    private final long startGps;
    private final long endGps;

    public ArchiveBounds(long startGps, long endGps) {
        this.startGps = startGps;
        this.endGps = endGps;
    }

    public long getStartGps() { return startGps; }
    public long getEndGps() { return endGps; }
}
