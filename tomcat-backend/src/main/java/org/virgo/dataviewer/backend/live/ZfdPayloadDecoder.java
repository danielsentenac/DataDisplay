package org.virgo.dataviewer.backend.live;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

import org.virgo.dataviewer.backend.time.GpsTimeConverter;

public final class ZfdPayloadDecoder {
    private static final int ZFD_BIN_VALUE_F64 = 1;
    private static final int ZFD_BIN_VALUE_F32 = 2;
    private static final int ZFD_BIN_VALUE_I64 = 3;
    private static final int ZFD_BIN_VALUE_U64 = 4;
    private static final int ZFD_BIN_VALUE_I32 = 5;
    private static final int ZFD_BIN_VALUE_U32 = 6;
    private static final int ZFD_BIN_VALUE_I16 = 7;
    private static final int ZFD_BIN_VALUE_U16 = 8;
    private static final int ZFD_BIN_VALUE_I8 = 9;
    private static final int ZFD_BIN_VALUE_U8 = 10;
    private static final int ZFD_BIN_STATUS_OK = 0;
    private static final int ZFD_BIN_FLAG_HAS_UNITS = 1;
    private static final int ZFD_BIN_VERSION = 2;

    private final String gpsChannel;
    private final GpsTimeConverter gpsTimeConverter;
    private final ConcurrentMap<String, String> identifierPool = new ConcurrentHashMap<String, String>();

    public ZfdPayloadDecoder(String gpsChannel, GpsTimeConverter gpsTimeConverter) {
        this.gpsChannel = gpsChannel;
        this.gpsTimeConverter = gpsTimeConverter;
    }

    public DecodedSnapshot decode(byte[] payload) {
        Map<String, Double> values = new LinkedHashMap<String, Double>();
        Map<String, String> catalogUnits = new LinkedHashMap<String, String>();
        long gpsSeconds;
        long utcMs;
        if (!parseZfdBinaryPayload(payload, values, catalogUnits)) {
            return null;
        }
        Double gpsValue = values.get("GPS_S");
        if (gpsValue == null || !Double.isFinite(gpsValue.doubleValue())) {
            return null;
        }
        gpsSeconds = (long) gpsValue.doubleValue();
        utcMs = gpsTimeConverter.gpsSecondsToUtcMs(gpsSeconds);
        return new DecodedSnapshot(gpsSeconds, utcMs, values, catalogUnits);
    }

    private boolean parseZfdBinaryPayload(
            byte[] payload,
            Map<String, Double> values,
            Map<String, String> catalogUnits) {
        int version;
        int flags;
        long gpsS;
        long gpsNs;
        long count;
        boolean hasUnits;

        if (values == null || payload == null || payload.length < 20) {
            return false;
        }
        if (payload[0] != 'Z' || payload[1] != 'F' || payload[2] != 'D' || payload[3] != '1') {
            return false;
        }

        version = readLeU16(payload, 4);
        flags = readLeU16(payload, 6);
        gpsS = readLeU32(payload, 8);
        gpsNs = readLeU32(payload, 12);
        count = readLeU32(payload, 16);
        if (flags < 0 || gpsS < 0 || gpsNs < 0 || count < 0 || version != ZFD_BIN_VERSION) {
            return false;
        }

        hasUnits = (flags & ZFD_BIN_FLAG_HAS_UNITS) != 0;
        putDirectChannelValue(values, gpsChannel, (double) gpsS);
        putDirectChannelValue(values, "GPS", (double) gpsS);
        putDirectChannelValue(values, "GPS_S", (double) gpsS);
        putDirectChannelValue(values, "GPS_NS", (double) gpsNs);
        return parseZfdBinaryPayloadEntries(payload, count, hasUnits, values, catalogUnits);
    }

    private boolean parseZfdBinaryPayloadEntries(
            byte[] payload,
            long serCount,
            boolean hasUnits,
            Map<String, Double> values,
            Map<String, String> catalogUnits) {
        int off = 20;
        for (long serIndex = 0; serIndex < serCount; serIndex++) {
            int serLen;
            long nparam;
            String ser = "";

            if (off + 6 > payload.length) {
                return false;
            }
            serLen = readLeU16(payload, off);
            nparam = readLeU32(payload, off + 2);
            off += 6;
            if (serLen < 0 || nparam < 0 || off + serLen > payload.length) {
                return false;
            }
            if (serLen > 0) {
                ser = canonicalizeIdentifier(new String(payload, off, serLen, StandardCharsets.UTF_8).trim());
                off += serLen;
            }

            for (long paramIndex = 0; paramIndex < nparam; paramIndex++) {
                int nameLen;
                int valueKind;
                int status;
                String channelName;
                String unit;
                if (off + 4 > payload.length) {
                    return false;
                }
                nameLen = readLeU16(payload, off);
                valueKind = payload[off + 2] & 0xFF;
                status = payload[off + 3] & 0xFF;
                off += 4;
                if (nameLen < 0 || off + nameLen > payload.length) {
                    return false;
                }
                channelName = canonicalizeIdentifier(new String(payload, off, nameLen, StandardCharsets.UTF_8).trim());
                off += nameLen;
                if (channelName.isEmpty()) {
                    continue;
                }

                if (status == ZFD_BIN_STATUS_OK) {
                    int[] offRef = new int[] { off };
                    Double value = decodeTypedValueToDouble(payload, offRef, valueKind);
                    if (value == null) {
                        return false;
                    }
                    off = offRef[0];
                    if (Double.isFinite(value.doubleValue())) {
                        putDecodedChannelValue(values, ser, channelName, value.doubleValue());
                    }
                }

                int[] offRef = new int[] { off };
                unit = readUnitSuffixIfPresent(payload, offRef, hasUnits);
                if (INVALID_UNIT_MARKER.equals(unit)) {
                    return false;
                }
                off = offRef[0];
                registerCatalogChannel(catalogUnits, ser, channelName, unit);
            }
        }
        return true;
    }

    private void putDirectChannelValue(Map<String, Double> values, String channelName, double value) {
        if (values == null || channelName == null) {
            return;
        }
        String canonical = canonicalizeIdentifier(channelName);
        if (canonical == null || canonical.isEmpty()) {
            return;
        }
        values.put(canonical, Double.valueOf(value));
    }

    private void putDecodedChannelValue(Map<String, Double> values, String serName, String channelName, double value) {
        if (values == null || channelName == null) {
            return;
        }
        String canonical = canonicalChannelName(serName, channelName);
        if (canonical.isEmpty()) {
            return;
        }
        values.put(canonical, Double.valueOf(value));
    }

    private void registerCatalogChannel(
            Map<String, String> catalogUnits,
            String serName,
            String channelName,
            String unit) {
        String canonicalName = canonicalChannelName(serName, channelName);
        if (canonicalName.isEmpty() || catalogUnits.containsKey(canonicalName)) {
            return;
        }
        catalogUnits.put(canonicalName, emptyToNull(canonicalizeIdentifier(unit)));
    }

    private String canonicalChannelName(String serName, String channelName) {
        String channel = channelName == null ? "" : channelName.trim();
        String ser = serName == null ? "" : serName.trim();
        if (channel.isEmpty()) {
            return "";
        }
        channel = canonicalizeIdentifier(channel);
        if (!ser.isEmpty()) {
            ser = canonicalizeIdentifier(ser);
            String joined = canonicalizeIdentifier(ser + "_" + channel);
            if (ser.indexOf(':') > 0) {
                return joined;
            }
            return canonicalizeIdentifier("V1:" + joined);
        }
        return channel;
    }

    private static final String INVALID_UNIT_MARKER = "INVALID_UNIT_MARKER";

    private String readUnitSuffixIfPresent(byte[] payload, int[] offRef, boolean hasUnits) {
        if (!hasUnits) {
            return null;
        }
        int off = offRef[0];
        int unitLen;
        if (off + 2 > payload.length) {
            return INVALID_UNIT_MARKER;
        }
        unitLen = readLeU16(payload, off);
        off += 2;
        if (unitLen < 0 || off + unitLen > payload.length) {
            return INVALID_UNIT_MARKER;
        }
        String unit = unitLen == 0 ? null : new String(payload, off, unitLen, StandardCharsets.UTF_8).trim();
        offRef[0] = off + unitLen;
        return unit;
    }

    private String canonicalizeIdentifier(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if (trimmed.isEmpty()) {
            return "";
        }
        String existing = identifierPool.putIfAbsent(trimmed, trimmed);
        return existing == null ? trimmed : existing;
    }

    private Double decodeTypedValueToDouble(byte[] payload, int[] offRef, int valueKind) {
        int off = offRef[0];
        long bits64;
        long u32;
        int u16;
        switch (valueKind) {
        case ZFD_BIN_VALUE_F64:
            if (off + 8 > payload.length) {
                return null;
            }
            bits64 = readLeI64Bits(payload, off);
            offRef[0] = off + 8;
            return Double.valueOf(Double.longBitsToDouble(bits64));
        case ZFD_BIN_VALUE_F32:
            if (off + 4 > payload.length) {
                return null;
            }
            u32 = readLeU32(payload, off);
            offRef[0] = off + 4;
            return Double.valueOf(Float.intBitsToFloat((int) (u32 & 0xFFFFFFFFL)));
        case ZFD_BIN_VALUE_I64:
            if (off + 8 > payload.length) {
                return null;
            }
            bits64 = readLeI64Bits(payload, off);
            offRef[0] = off + 8;
            return Double.valueOf((double) bits64);
        case ZFD_BIN_VALUE_U64:
            if (off + 8 > payload.length) {
                return null;
            }
            bits64 = readLeI64Bits(payload, off);
            offRef[0] = off + 8;
            return Double.valueOf(unsignedLongToDouble(bits64));
        case ZFD_BIN_VALUE_I32:
            if (off + 4 > payload.length) {
                return null;
            }
            u32 = readLeU32(payload, off);
            offRef[0] = off + 4;
            return Double.valueOf((double) (int) (u32 & 0xFFFFFFFFL));
        case ZFD_BIN_VALUE_U32:
            if (off + 4 > payload.length) {
                return null;
            }
            u32 = readLeU32(payload, off);
            offRef[0] = off + 4;
            return Double.valueOf((double) (u32 & 0xFFFFFFFFL));
        case ZFD_BIN_VALUE_I16:
            if (off + 2 > payload.length) {
                return null;
            }
            u16 = readLeU16(payload, off);
            offRef[0] = off + 2;
            return Double.valueOf((double) (short) (u16 & 0xFFFF));
        case ZFD_BIN_VALUE_U16:
            if (off + 2 > payload.length) {
                return null;
            }
            u16 = readLeU16(payload, off);
            offRef[0] = off + 2;
            return Double.valueOf((double) (u16 & 0xFFFF));
        case ZFD_BIN_VALUE_I8:
            if (off + 1 > payload.length) {
                return null;
            }
            offRef[0] = off + 1;
            return Double.valueOf((double) payload[off]);
        case ZFD_BIN_VALUE_U8:
            if (off + 1 > payload.length) {
                return null;
            }
            offRef[0] = off + 1;
            return Double.valueOf((double) (payload[off] & 0xFF));
        default:
            return null;
        }
    }

    private static double unsignedLongToDouble(long value) {
        if (value >= 0L) {
            return (double) value;
        }
        return (double) (value & Long.MAX_VALUE) + 0x1.0p63;
    }

    private static int readLeU16(byte[] payload, int off) {
        if (payload == null || off < 0 || off + 2 > payload.length) {
            return -1;
        }
        return (payload[off] & 0xFF) | ((payload[off + 1] & 0xFF) << 8);
    }

    private static long readLeU32(byte[] payload, int off) {
        if (payload == null || off < 0 || off + 4 > payload.length) {
            return -1;
        }
        return (payload[off] & 0xFFL)
                | ((payload[off + 1] & 0xFFL) << 8)
                | ((payload[off + 2] & 0xFFL) << 16)
                | ((payload[off + 3] & 0xFFL) << 24);
    }

    private static long readLeI64Bits(byte[] payload, int off) {
        long value = 0;
        if (payload == null || off < 0 || off + 8 > payload.length) {
            return 0;
        }
        for (int i = 0; i < 8; i++) {
            value |= ((long) (payload[off + i] & 0xFF)) << (8 * i);
        }
        return value;
    }

    private static String emptyToNull(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
