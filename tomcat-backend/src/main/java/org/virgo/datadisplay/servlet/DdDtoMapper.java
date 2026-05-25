package org.virgo.datadisplay.servlet;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.virgo.datadisplay.dto.DdBucketedSeriesDto;
import org.virgo.datadisplay.dto.DdChannelItemDto;
import org.virgo.datadisplay.dto.DdFflItemDto;
import org.virgo.datadisplay.dto.DdLiveResponseDto;
import org.virgo.datadisplay.dto.DdLiveSeriesDto;
import org.virgo.datadisplay.dto.DdQueryMetaDto;
import org.virgo.datadisplay.dto.DdQueryResponseDto;
import org.virgo.datadisplay.dto.DdRawSeriesDto;

/**
 * Converts DTOs to plain Map/List structures that Nashorn / NashornJsonCodec can serialise.
 * All keys are snake_case to match the Rust dto.rs Deserialize field names.
 */
public final class DdDtoMapper {

    private DdDtoMapper() {}

    // ─── FFL list ─────────────────────────────────────────────────────────

    public static List<Map<String, Object>> fflList(List<DdFflItemDto> items) {
        List<Map<String, Object>> result = new ArrayList<Map<String, Object>>(items.size());
        for (DdFflItemDto item : items) result.add(fflItem(item));
        return result;
    }

    private static Map<String, Object> fflItem(DdFflItemDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("id", dto.getId());
        m.put("label", dto.getLabel());
        m.put("sample_rate_hz", dto.getSampleRateHz());
        return m;
    }

    // ─── Channel search ───────────────────────────────────────────────────

    public static Map<String, Object> channelPage(List<DdChannelItemDto> items, int total, int offset, int limit) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("total", total);
        m.put("offset", offset);
        m.put("limit", limit);
        List<Map<String, Object>> rows = new ArrayList<Map<String, Object>>(items.size());
        for (DdChannelItemDto item : items) rows.add(channelItem(item));
        m.put("channels", rows);
        return m;
    }

    private static Map<String, Object> channelItem(DdChannelItemDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("name", dto.getName());
        m.put("display_name", dto.getDisplayName());
        m.put("unit", dto.getUnit());
        m.put("category", dto.getCategory());
        m.put("sample_rate_hz", dto.getSampleRateHz());
        return m;
    }

    // ─── Query response ───────────────────────────────────────────────────

    public static Map<String, Object> queryResponse(DdQueryResponseDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("meta", queryMeta(dto.getMeta()));
        List<Map<String, Object>> seriesList = new ArrayList<Map<String, Object>>(dto.getSeries().size());
        for (Object series : dto.getSeries()) {
            if (series instanceof DdRawSeriesDto) seriesList.add(rawSeries((DdRawSeriesDto) series));
            else if (series instanceof DdBucketedSeriesDto) seriesList.add(bucketedSeries((DdBucketedSeriesDto) series));
        }
        m.put("series", seriesList);
        return m;
    }

    private static Map<String, Object> queryMeta(DdQueryMetaDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("channel_count", dto.getChannelCount());
        m.put("ffl_source", dto.getFflSource());
        m.put("resolved_start_utc_ms", dto.getResolvedStartUtcMs());
        m.put("resolved_start_gps", dto.getResolvedStartGps());
        m.put("requested_end_utc_ms", dto.getRequestedEndUtcMs());
        m.put("loaded_end_utc_ms", dto.getLoadedEndUtcMs());
        m.put("next_chunk_start_utc_ms", dto.getNextChunkStartUtcMs());
        m.put("history_complete", dto.isHistoryComplete());
        return m;
    }

    private static Map<String, Object> rawSeries(DdRawSeriesDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("sampling_mode", dto.getSamplingMode());
        m.put("channel", dto.getChannel());
        m.put("display_name", dto.getDisplayName());
        m.put("unit", dto.getUnit());
        m.put("ffl_source", dto.getFflSource());
        m.put("start_utc_ms", dto.getStartUtcMs());
        m.put("step_ns", dto.getStepNs());
        m.put("values", dto.getValues());
        return m;
    }

    private static Map<String, Object> bucketedSeries(DdBucketedSeriesDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("sampling_mode", dto.getSamplingMode());
        m.put("channel", dto.getChannel());
        m.put("display_name", dto.getDisplayName());
        m.put("unit", dto.getUnit());
        m.put("ffl_source", dto.getFflSource());
        m.put("start_utc_ms", dto.getStartUtcMs());
        m.put("bucket_ns", dto.getBucketNs());
        m.put("min_values", dto.getMinValues());
        m.put("max_values", dto.getMaxValues());
        return m;
    }

    // ─── Live response ────────────────────────────────────────────────────

    public static Map<String, Object> liveResponse(DdLiveResponseDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("server_now_utc_ms", dto.getServerNowUtcMs());
        List<Map<String, Object>> seriesList = new ArrayList<Map<String, Object>>(dto.getSeries().size());
        for (DdLiveSeriesDto s : dto.getSeries()) seriesList.add(liveSeries(s));
        m.put("series", seriesList);
        return m;
    }

    private static Map<String, Object> liveSeries(DdLiveSeriesDto dto) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("channel", dto.getChannel());
        m.put("start_utc_ms", dto.getStartUtcMs());
        m.put("step_ms", dto.getStepMs());
        m.put("values", dto.getValues());
        return m;
    }

    // ─── Error ────────────────────────────────────────────────────────────

    public static Map<String, Object> errorBody(String code, String message) {
        Map<String, Object> m = new LinkedHashMap<String, Object>();
        m.put("error_code", code);
        m.put("message", message);
        return m;
    }
}
