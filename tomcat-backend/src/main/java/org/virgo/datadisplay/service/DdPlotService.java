package org.virgo.datadisplay.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.virgo.datadisplay.archive.FflArchiveAdapter;
import org.virgo.datadisplay.archive.FflRawSeries;
import org.virgo.datadisplay.dto.DdBucketedSeriesDto;
import org.virgo.datadisplay.dto.DdQueryMetaDto;
import org.virgo.datadisplay.dto.DdQueryRequestDto;
import org.virgo.datadisplay.dto.DdQueryResponseDto;
import org.virgo.datadisplay.dto.DdRawSeriesDto;
import org.virgo.dataviewer.adapter.service.AdapterException;
import org.virgo.dataviewer.backend.time.GpsTimeConverter;

/**
 * Core business logic: translate a DdQueryRequestDto into a DdQueryResponseDto by reading
 * the appropriate FFL archive and either returning raw samples or bucketed min/max.
 */
public final class DdPlotService {
    private static final int MAX_RAW_SAMPLES_PER_SERIES = 50_000;

    private final GpsTimeConverter gpsTimeConverter;

    public DdPlotService(GpsTimeConverter gpsTimeConverter) {
        this.gpsTimeConverter = gpsTimeConverter;
    }

    public DdQueryResponseDto query(DdQueryRequestDto request, FflArchiveAdapter adapter) throws AdapterException {
        validateRequest(request);

        long startGps = gpsTimeConverter.utcMsToGpsSeconds(request.getStartUtcMs());
        long endGps = gpsTimeConverter.utcMsToGpsSeconds(request.getEndUtcMs());
        long durationSeconds = Math.max(1L, endGps - startGps);

        List<FflRawSeries> rawSeries = adapter.readSeries(request.getChannels(), startGps, durationSeconds);

        boolean wantBucketed = request.getTargetBuckets() != null && request.getTargetBuckets() > 0;
        List<Object> series = new ArrayList<Object>(rawSeries.size());
        for (FflRawSeries raw : rawSeries) {
            if (wantBucketed) {
                series.add(toBucketed(raw, request.getTargetBuckets(), request.getStartUtcMs(), adapter.getSource().getId()));
            } else {
                series.add(toRaw(raw, request.getStartUtcMs(), adapter.getSource().getId()));
            }
        }

        long actualEndUtcMs = rawSeries.isEmpty()
                ? request.getEndUtcMs()
                : gpsTimeConverter.gpsSecondsToUtcMs(endGps);
        DdQueryMetaDto meta = new DdQueryMetaDto(
                rawSeries.size(),
                adapter.getSource().getId(),
                gpsTimeConverter.gpsSecondsToUtcMs(startGps),
                startGps,
                request.getEndUtcMs(),
                actualEndUtcMs,
                null,
                true);
        return new DdQueryResponseDto(meta, series);
    }

    // ─── Raw ──────────────────────────────────────────────────────────────

    private DdRawSeriesDto toRaw(FflRawSeries raw, long startUtcMs, String fflSource) {
        List<Double> values = raw.getValues();
        if (values.size() > MAX_RAW_SAMPLES_PER_SERIES) {
            values = values.subList(0, MAX_RAW_SAMPLES_PER_SERIES);
        }
        long startUtcMsActual = gpsTimeConverter.gpsSecondsToUtcMs(raw.getStartGps());
        return new DdRawSeriesDto(
                raw.getChannel(),
                raw.getChannel(),
                raw.getUnit() != null ? raw.getUnit() : "",
                fflSource,
                startUtcMsActual,
                raw.getStepNs(),
                values);
    }

    // ─── Bucketed ─────────────────────────────────────────────────────────

    private DdBucketedSeriesDto toBucketed(FflRawSeries raw, int targetBuckets, long queryStartUtcMs, String fflSource) {
        List<Double> allValues = raw.getValues();
        int n = allValues.size();
        if (n == 0) {
            return new DdBucketedSeriesDto(
                    raw.getChannel(), raw.getChannel(),
                    raw.getUnit() != null ? raw.getUnit() : "",
                    fflSource,
                    gpsTimeConverter.gpsSecondsToUtcMs(raw.getStartGps()),
                    raw.getStepNs(),
                    Collections.<Double>emptyList(),
                    Collections.<Double>emptyList());
        }

        // Total nanoseconds of this series
        long totalNs = (long) n * raw.getStepNs();
        int numBuckets = Math.min(targetBuckets, n);
        long bucketNs = Math.max(raw.getStepNs(), totalNs / numBuckets);
        // Re-compute actual bucket count after clamping
        numBuckets = (int) Math.ceil((double) totalNs / bucketNs);

        List<Double> minValues = new ArrayList<Double>(numBuckets);
        List<Double> maxValues = new ArrayList<Double>(numBuckets);

        // Samples per bucket (may be fractional — track accumulation)
        double samplesPerBucket = (double) n / numBuckets;
        for (int b = 0; b < numBuckets; b++) {
            int fromIndex = (int) Math.round(b * samplesPerBucket);
            int toIndex = Math.min(n, (int) Math.round((b + 1) * samplesPerBucket));
            if (fromIndex >= toIndex) {
                minValues.add(null);
                maxValues.add(null);
                continue;
            }
            double min = Double.POSITIVE_INFINITY;
            double max = Double.NEGATIVE_INFINITY;
            boolean anyFinite = false;
            for (int i = fromIndex; i < toIndex; i++) {
                Double v = allValues.get(i);
                if (v == null || Double.isNaN(v)) continue;
                if (v < min) min = v;
                if (v > max) max = v;
                anyFinite = true;
            }
            minValues.add(anyFinite ? min : null);
            maxValues.add(anyFinite ? max : null);
        }

        long startUtcMsActual = gpsTimeConverter.gpsSecondsToUtcMs(raw.getStartGps());
        return new DdBucketedSeriesDto(
                raw.getChannel(), raw.getChannel(),
                raw.getUnit() != null ? raw.getUnit() : "",
                fflSource,
                startUtcMsActual,
                bucketNs,
                minValues,
                maxValues);
    }

    // ─── Validation ───────────────────────────────────────────────────────

    private void validateRequest(DdQueryRequestDto request) throws AdapterException {
        if (request.getStartUtcMs() >= request.getEndUtcMs()) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE", "startUtcMs must be before endUtcMs.");
        }
        if (request.getChannels() == null || request.getChannels().isEmpty()) {
            throw AdapterException.badRequest("MISSING_CHANNELS", "At least one channel must be requested.");
        }
    }
}
