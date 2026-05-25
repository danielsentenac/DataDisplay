package org.virgo.datadisplay.servlet;

import java.io.IOException;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.virgo.datadisplay.service.DdServiceRegistry;
import org.virgo.datadisplay.service.DdTomcatServices;
import org.virgo.dataviewer.adapter.json.JsonCodec;
import org.virgo.dataviewer.adapter.json.NashornJsonCodec;
import org.virgo.dataviewer.adapter.service.AdapterException;

/** Base class for all DataDisplay servlets: CORS, JSON I/O, error handling. */
public abstract class DdAbstractServlet extends HttpServlet {
    private static final long serialVersionUID = 1L;
    private static final Logger LOGGER = Logger.getLogger(DdAbstractServlet.class.getName());
    private static final JsonCodec JSON = new NashornJsonCodec();

    // ─── Subclass API ─────────────────────────────────────────────────────

    protected DdTomcatServices services(HttpServletRequest req) throws AdapterException {
        DdTomcatServices services = DdServiceRegistry.get(req.getServletContext());
        if (services == null) throw AdapterException.serviceUnavailable("Backend is initialising; try again.");
        return services;
    }

    protected Object readJson(HttpServletRequest req) throws IOException {
        return JSON.read(req.getInputStream());
    }

    @SuppressWarnings("unchecked")
    protected Map<String, Object> readJsonMap(HttpServletRequest req) throws IOException, AdapterException {
        Object parsed = readJson(req);
        if (parsed == null || !(parsed instanceof Map)) {
            throw AdapterException.badRequest("INVALID_REQUEST", "Expected a JSON object body.");
        }
        return (Map<String, Object>) parsed;
    }

    protected void writeJson(HttpServletResponse resp, int status, Object value) throws IOException {
        resp.setStatus(status);
        resp.setContentType("application/json;charset=UTF-8");
        JSON.write(resp.getOutputStream(), value);
    }

    // ─── CORS helpers ─────────────────────────────────────────────────────

    protected void addCorsHeaders(HttpServletResponse resp) {
        resp.setHeader("Access-Control-Allow-Origin", "*");
        resp.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
        resp.setHeader("Access-Control-Allow-Headers", "Content-Type");
    }

    @Override
    protected void doOptions(HttpServletRequest req, HttpServletResponse resp) {
        addCorsHeaders(resp);
        resp.setStatus(HttpServletResponse.SC_NO_CONTENT);
    }

    // ─── Error helpers ────────────────────────────────────────────────────

    protected void handleAdapterException(HttpServletResponse resp, AdapterException ex) throws IOException {
        LOGGER.log(Level.FINE, "Adapter error {0}: {1}", new Object[]{ ex.getErrorCode(), ex.getMessage() });
        writeJson(resp, ex.getStatusCode(), DdDtoMapper.errorBody(ex.getErrorCode(), ex.getMessage()));
    }

    protected void handleUnexpected(HttpServletResponse resp, Throwable ex) throws IOException {
        LOGGER.log(Level.SEVERE, "Unexpected error in servlet", ex);
        writeJson(resp, 500, DdDtoMapper.errorBody("INTERNAL_ERROR", "An unexpected error occurred."));
    }

    // ─── Param helpers ────────────────────────────────────────────────────

    protected static String stringParam(Map<String, Object> body, String key) throws AdapterException {
        Object v = body.get(key);
        if (v == null) return null;
        return String.valueOf(v).trim();
    }

    protected static String requireStringParam(Map<String, Object> body, String key) throws AdapterException {
        String v = stringParam(body, key);
        if (v == null || v.isEmpty()) throw AdapterException.badRequest("MISSING_FIELD", "'" + key + "' is required.");
        return v;
    }

    protected static long requireLongParam(Map<String, Object> body, String key) throws AdapterException {
        Object v = body.get(key);
        if (v == null) throw AdapterException.badRequest("MISSING_FIELD", "'" + key + "' is required.");
        if (v instanceof Number) return ((Number) v).longValue();
        try { return Long.parseLong(String.valueOf(v).trim()); }
        catch (NumberFormatException ex) { throw AdapterException.badRequest("INVALID_FIELD", "'" + key + "' must be a number."); }
    }

    protected static Integer optIntParam(Map<String, Object> body, String key) {
        Object v = body.get(key);
        if (v == null) return null;
        if (v instanceof Number) return ((Number) v).intValue();
        try { return Integer.parseInt(String.valueOf(v).trim()); }
        catch (NumberFormatException ex) { return null; }
    }

    protected static Long optLongParam(Map<String, Object> body, String key) {
        Object v = body.get(key);
        if (v == null) return null;
        if (v instanceof Number) return ((Number) v).longValue();
        try { return Long.parseLong(String.valueOf(v).trim()); }
        catch (NumberFormatException ex) { return null; }
    }

    @SuppressWarnings("unchecked")
    protected static java.util.List<String> requireStringList(Map<String, Object> body, String key) throws AdapterException {
        Object v = body.get(key);
        if (v instanceof java.util.List) {
            java.util.List<?> raw = (java.util.List<?>) v;
            java.util.List<String> result = new java.util.ArrayList<String>(raw.size());
            for (Object item : raw) {
                String s = item == null ? null : String.valueOf(item).trim();
                if (s != null && !s.isEmpty()) result.add(s);
            }
            if (!result.isEmpty()) return result;
        }
        throw AdapterException.badRequest("MISSING_FIELD", "'" + key + "' must be a non-empty array of strings.");
    }
}
