package org.virgo.datadisplay.servlet;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.archive.FflArchiveAdapter;
import org.virgo.datadisplay.dto.DdChannelItemDto;
import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.service.AdapterException;

/**
 * GET /api/v1/datadisplay/channels/search?q=&ffl=&limit=&offset=
 *
 * <p>Searches the channel list for the requested FFL source. The channel list is obtained by reading
 * the archive bounds (which exposes the channel list) via the JNI library. Results are filtered
 * case-insensitively by the {@code q} query parameter and paginated.
 */
@WebServlet(urlPatterns = "/api/v1/datadisplay/channels/search")
public final class DdChannelSearchServlet extends DdAbstractServlet {
    private static final long serialVersionUID = 1L;
    private static final int DEFAULT_LIMIT = 100;
    private static final int MAX_LIMIT = 500;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        addCorsHeaders(resp);
        try {
            DdTomcatServices services = services(req);
            String fflId = req.getParameter("ffl");
            String query = req.getParameter("q");
            int limit = parsePositiveInt(req.getParameter("limit"), DEFAULT_LIMIT, MAX_LIMIT);
            int offset = parseNonNegativeInt(req.getParameter("offset"), 0);

            FflArchiveAdapter adapter = fflId == null || fflId.trim().isEmpty()
                    ? firstAdapter(services)
                    : services.getAdapter(fflId);
            if (adapter == null) {
                throw AdapterException.notFound("FFL_NOT_FOUND", "FFL source not found: " + fflId);
            }

            List<String> allChannels = adapter.listChannels();

            List<DdChannelItemDto> filtered = filterChannels(allChannels, query, adapter);
            int total = filtered.size();
            List<DdChannelItemDto> page = paginate(filtered, offset, limit);

            writeJson(resp, 200, DdDtoMapper.channelPage(page, total, offset, limit));
        } catch (AdapterException ex) {
            handleAdapterException(resp, ex);
        } catch (Exception ex) {
            handleUnexpected(resp, ex);
        }
    }

    private FflArchiveAdapter firstAdapter(DdTomcatServices services) throws AdapterException {
        List<FflArchiveAdapter> adapters = services.getAdapters();
        if (adapters.isEmpty()) throw AdapterException.serviceUnavailable("No FFL sources configured.");
        return adapters.get(0);
    }

    private List<DdChannelItemDto> filterChannels(List<String> names, String query, FflArchiveAdapter adapter) {
        String q = query == null ? "" : query.trim().toUpperCase(Locale.US);
        double rateHz = adapter.getSource().getNominalSampleRateHz();
        List<DdChannelItemDto> result = new ArrayList<DdChannelItemDto>(names.size());
        for (String name : names) {
            if (name == null || name.trim().isEmpty()) continue;
            if (!q.isEmpty() && !name.toUpperCase(Locale.US).contains(q)) continue;
            result.add(new DdChannelItemDto(name, deriveDisplayName(name), "", null, rateHz));
        }
        return result;
    }

    private List<DdChannelItemDto> paginate(List<DdChannelItemDto> list, int offset, int limit) {
        if (offset >= list.size()) return Collections.emptyList();
        int end = Math.min(offset + limit, list.size());
        return list.subList(offset, end);
    }

    private static String deriveDisplayName(String channelName) {
        int colon = channelName.lastIndexOf(':');
        String base = colon >= 0 && colon + 1 < channelName.length()
                ? channelName.substring(colon + 1)
                : channelName;
        return base.replace('_', ' ').trim();
    }

    private static int parsePositiveInt(String s, int defaultValue, int max) {
        if (s == null) return defaultValue;
        try {
            int v = Integer.parseInt(s.trim());
            if (v <= 0) return defaultValue;
            return Math.min(v, max);
        } catch (NumberFormatException ex) { return defaultValue; }
    }

    private static int parseNonNegativeInt(String s, int defaultValue) {
        if (s == null) return defaultValue;
        try {
            int v = Integer.parseInt(s.trim());
            return v >= 0 ? v : defaultValue;
        } catch (NumberFormatException ex) { return defaultValue; }
    }
}
