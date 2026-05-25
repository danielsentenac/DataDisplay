package org.virgo.dataviewer.adapter.service;

import java.util.List;

public final class AdapterException extends Exception {
    private final int statusCode;
    private final String errorCode;
    private final List<String> details;

    private AdapterException(int statusCode, String errorCode, String message, List<String> details) {
        super(message);
        this.statusCode = statusCode;
        this.errorCode = errorCode;
        this.details = details;
    }

    public int getStatusCode() { return statusCode; }
    public String getErrorCode() { return errorCode; }
    public List<String> getDetails() { return details; }

    public static AdapterException badRequest(String errorCode, String message) {
        return new AdapterException(400, errorCode, message, null);
    }

    public static AdapterException badRequest(String errorCode, String message, List<String> details) {
        return new AdapterException(400, errorCode, message, details);
    }

    public static AdapterException notFound(String errorCode, String message) {
        return new AdapterException(404, errorCode, message, null);
    }

    public static AdapterException serviceUnavailable(String message) {
        return new AdapterException(503, "SERVICE_UNAVAILABLE", message, null);
    }
}
