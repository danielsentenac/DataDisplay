package org.virgo.datadisplay.servlet;

import java.io.IOException;
import java.util.List;
import java.util.Map;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.dto.DdLiveRequestDto;
import org.virgo.datadisplay.dto.DdLiveResponseDto;
import org.virgo.datadisplay.dto.DdLiveSeriesDto;
import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.service.AdapterException;
import org.virgo.dataviewer.backend.live.ZJChvBuf;

/**
 * POST /api/v1/datadisplay/plots/live
 *
 * <p>Polled by the Flutter Dart client (TomcatLivePoller) at ~1 Hz.
 *
 * <pre>
 * {
 *   "channels": ["V1:DER_DATA_H"],
 *   "after_utc_ms": 1745000000000
 * }
 * </pre>
 */
@WebServlet(urlPatterns = "/api/v1/datadisplay/plots/live")
public final class DdPlotLiveServlet extends DdAbstractServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        addCorsHeaders(resp);
        try {
            DdTomcatServices services = services(req);
            ZJChvBuf liveBuffer = services.getLiveBuffer();
            if (liveBuffer == null || !liveBuffer.hasSource()) {
                throw AdapterException.serviceUnavailable("Live data source (ZCM) is not configured.");
            }

            Map<String, Object> body = readJsonMap(req);
            List<String> channels = requireStringList(body, "channels");
            long afterUtcMs = requireLongParam(body, "after_utc_ms");

            DdLiveRequestDto request = new DdLiveRequestDto(channels, afterUtcMs);
            List<DdLiveSeriesDto> series = liveBuffer.collectSeries(request.getChannels(), request.getAfterUtcMs());
            DdLiveResponseDto response = new DdLiveResponseDto(System.currentTimeMillis(), series);

            writeJson(resp, 200, DdDtoMapper.liveResponse(response));
        } catch (AdapterException ex) {
            handleAdapterException(resp, ex);
        } catch (Exception ex) {
            handleUnexpected(resp, ex);
        }
    }
}
