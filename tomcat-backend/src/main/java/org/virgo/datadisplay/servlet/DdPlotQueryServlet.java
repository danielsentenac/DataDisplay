package org.virgo.datadisplay.servlet;

import java.io.IOException;
import java.util.List;
import java.util.Map;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.archive.FflArchiveAdapter;
import org.virgo.datadisplay.dto.DdQueryRequestDto;
import org.virgo.datadisplay.dto.DdQueryResponseDto;
import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.service.AdapterException;

/**
 * POST /api/v1/datadisplay/plots/query
 *
 * <pre>
 * {
 *   "channels": ["V1:DER_DATA_H"],
 *   "ffl_source": "trend",
 *   "start_utc_ms": 1745000000000,
 *   "end_utc_ms":   1745003600000,
 *   "target_buckets": 720          // omit or 0 for raw
 * }
 * </pre>
 */
@WebServlet(urlPatterns = "/api/v1/datadisplay/plots/query")
public final class DdPlotQueryServlet extends DdAbstractServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        addCorsHeaders(resp);
        try {
            DdTomcatServices services = services(req);
            Map<String, Object> body = readJsonMap(req);

            List<String> channels = requireStringList(body, "channels");
            String fflId = requireStringParam(body, "ffl_source");
            long startUtcMs = requireLongParam(body, "start_utc_ms");
            long endUtcMs = requireLongParam(body, "end_utc_ms");
            Integer targetBuckets = optIntParam(body, "target_buckets");
            boolean preserveExtrema = Boolean.TRUE.equals(body.get("preserve_extrema"));
            Integer chunkDurationSeconds = optIntParam(body, "chunk_duration_seconds");
            Long cursorStartUtcMs = optLongParam(body, "cursor_start_utc_ms");

            FflArchiveAdapter adapter = services.getAdapter(fflId);
            if (adapter == null) {
                throw AdapterException.notFound("FFL_NOT_FOUND", "FFL source not found: " + fflId);
            }

            DdQueryRequestDto request = new DdQueryRequestDto(
                    channels, fflId, startUtcMs, endUtcMs,
                    targetBuckets, preserveExtrema, chunkDurationSeconds, cursorStartUtcMs);
            DdQueryResponseDto response = services.getPlotService().query(request, adapter);

            writeJson(resp, 200, DdDtoMapper.queryResponse(response));
        } catch (AdapterException ex) {
            handleAdapterException(resp, ex);
        } catch (Exception ex) {
            handleUnexpected(resp, ex);
        }
    }
}
