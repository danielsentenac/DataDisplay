package org.virgo.dataviewer.backend.history;

import java.util.List;

import org.virgo.dataviewer.adapter.service.AdapterException;

public interface TrendArchiveReader {
    ArchiveBounds resolveBounds() throws AdapterException;
    List<String> listChannels() throws AdapterException;
    List<TrendRawSeries> readRawSeries(List<String> channels, long startGps, long durationSeconds) throws AdapterException;
}
