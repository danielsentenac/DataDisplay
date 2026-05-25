package org.virgo.datadisplay.servlet;

import java.io.IOException;
import java.util.Collections;
import java.util.Map;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.dto.DdLiveRawResponseDto;
import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.service.AdapterException;

/**
 * POST /api/v1/datadisplay/plots/live-raw
 *
 * <p>Stub endpoint for future raw/50 Hz live streaming.
 * Currently returns an empty series list with 501 Not Implemented.
 */
@WebServlet(urlPatterns = "/api/v1/datadisplay/plots/live-raw")
public final class DdPlotLiveRawServlet extends DdAbstractServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        addCorsHeaders(resp);
        try {
            services(req); // verify the backend is alive
            writeJson(resp, 501, DdDtoMapper.errorBody("NOT_IMPLEMENTED",
                    "Raw/50Hz live streaming is not yet implemented. Use /api/v1/datadisplay/plots/live for 1 Hz Ser data."));
        } catch (AdapterException ex) {
            handleAdapterException(resp, ex);
        } catch (Exception ex) {
            handleUnexpected(resp, ex);
        }
    }
}
