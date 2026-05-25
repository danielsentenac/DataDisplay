package org.virgo.datadisplay.servlet;

import java.io.IOException;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.service.AdapterException;

/** GET /api/v1/datadisplay/ffls — list all configured FFL sources. */
@WebServlet(urlPatterns = "/api/v1/datadisplay/ffls")
public final class DdFflListServlet extends DdAbstractServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        addCorsHeaders(resp);
        try {
            DdTomcatServices services = services(req);
            writeJson(resp, 200, DdDtoMapper.fflList(services.listFflItems()));
        } catch (AdapterException ex) {
            handleAdapterException(resp, ex);
        } catch (Exception ex) {
            handleUnexpected(resp, ex);
        }
    }
}
