package org.virgo.dataviewer.backend.time;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;

import org.virgo.dataviewer.adapter.service.AdapterException;

public final class GpsTimeConverter {
    private static final long GPS_EPOCH_UNIX_SECONDS = 315964800L;
    private static final long[] UTC_LEAP_EFFECTIVE_UNIX_SECONDS = new long[] {
            epochSecond("1981-07-01T00:00:00Z"),
            epochSecond("1982-07-01T00:00:00Z"),
            epochSecond("1983-07-01T00:00:00Z"),
            epochSecond("1985-07-01T00:00:00Z"),
            epochSecond("1988-01-01T00:00:00Z"),
            epochSecond("1990-01-01T00:00:00Z"),
            epochSecond("1991-01-01T00:00:00Z"),
            epochSecond("1992-07-01T00:00:00Z"),
            epochSecond("1993-07-01T00:00:00Z"),
            epochSecond("1994-07-01T00:00:00Z"),
            epochSecond("1996-01-01T00:00:00Z"),
            epochSecond("1997-07-01T00:00:00Z"),
            epochSecond("1999-01-01T00:00:00Z"),
            epochSecond("2006-01-01T00:00:00Z"),
            epochSecond("2009-01-01T00:00:00Z"),
            epochSecond("2012-07-01T00:00:00Z"),
            epochSecond("2015-07-01T00:00:00Z"),
            epochSecond("2017-01-01T00:00:00Z")
    };
    private static final long[] GPS_LEAP_EFFECTIVE_SECONDS = buildGpsLeapThresholds();

    public long localTimeToUtcMs(String localIso, String timeZone) throws AdapterException {
        if (localIso == null || localIso.trim().isEmpty()) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE", "timeRange.startLocalIso is required.");
        }
        if (timeZone == null || timeZone.trim().isEmpty()) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE", "timeRange.timeZone is required.");
        }

        ZoneId zoneId;
        try {
            zoneId = ZoneId.of(timeZone.trim());
        } catch (Exception exception) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE", "Unsupported time zone: " + timeZone);
        }

        LocalDateTime localDateTime = parseLocalDateTime(localIso.trim());
        return localDateTime.atZone(zoneId).toInstant().toEpochMilli();
    }

    public long utcMsToGpsSeconds(long utcMs) {
        long utcSeconds = Math.floorDiv(utcMs, 1000L);
        return utcSeconds - GPS_EPOCH_UNIX_SECONDS + leapSecondsAtUtc(utcSeconds);
    }

    public long gpsSecondsToUtcMs(long gpsSeconds) {
        long utcSeconds = gpsSeconds + GPS_EPOCH_UNIX_SECONDS - leapSecondsAtGps(gpsSeconds);
        return utcSeconds * 1000L;
    }

    private static long[] buildGpsLeapThresholds() {
        long[] out = new long[UTC_LEAP_EFFECTIVE_UNIX_SECONDS.length];
        for (int i = 0; i < UTC_LEAP_EFFECTIVE_UNIX_SECONDS.length; i++) {
            out[i] = UTC_LEAP_EFFECTIVE_UNIX_SECONDS[i] - GPS_EPOCH_UNIX_SECONDS + (i + 1);
        }
        return out;
    }

    private static int leapSecondsAtUtc(long utcSeconds) {
        int count = 0;
        for (long threshold : UTC_LEAP_EFFECTIVE_UNIX_SECONDS) {
            if (utcSeconds < threshold) {
                break;
            }
            count++;
        }
        return count;
    }

    private static int leapSecondsAtGps(long gpsSeconds) {
        int count = 0;
        for (long threshold : GPS_LEAP_EFFECTIVE_SECONDS) {
            if (gpsSeconds < threshold) {
                break;
            }
            count++;
        }
        return count;
    }

    private static LocalDateTime parseLocalDateTime(String localIso) throws AdapterException {
        String candidate = localIso.replace(' ', 'T');
        try {
            return LocalDateTime.parse(candidate, DateTimeFormatter.ISO_LOCAL_DATE_TIME);
        } catch (DateTimeParseException exception) {
            throw AdapterException.badRequest("INVALID_TIME_RANGE",
                    "Invalid startLocalIso. Expected ISO local date-time, got: " + localIso);
        }
    }

    private static long epochSecond(String isoInstant) {
        return Instant.parse(isoInstant).getEpochSecond();
    }
}
