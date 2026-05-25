package org.virgo.datadisplay.dto;

import java.util.List;

public final class DdQueryResponseDto {
    private final DdQueryMetaDto meta;
    /** Each element is either a DdRawSeriesDto or DdBucketedSeriesDto. */
    private final List<Object> series;

    public DdQueryResponseDto(DdQueryMetaDto meta, List<Object> series) {
        this.meta = meta;
        this.series = series;
    }

    public DdQueryMetaDto getMeta() { return meta; }
    public List<Object> getSeries() { return series; }
}
