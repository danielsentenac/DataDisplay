package org.virgo.dataviewer.backend.live;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

import org.virgo.datadisplay.dto.DdChannelItemDto;
import org.virgo.datadisplay.dto.DdLiveSeriesDto;
import org.virgo.dataviewer.backend.time.GpsTimeConverter;

/**
 * Rolling buffer of ZFD snapshots decoded from the zFdVac ZCM endpoint.
 * Provides the live channel catalog and collects per-channel series for poll responses.
 */
public final class ZJChvBuf implements AutoCloseable {
    private static final Logger LOGGER = Logger.getLogger(ZJChvBuf.class.getName());

    private final String zcmEndpoint;
    private final int maxSnapshots;
    private final GpsTimeConverter gpsTimeConverter;
    private final ZfdPayloadDecoder decoder;
    private final Object lock = new Object();
    private final Deque<LiveSnapshot> snapshots = new ArrayDeque<LiveSnapshot>();
    private final Map<String, String> catalogUnitsByName = new LinkedHashMap<String, String>();
    private final Map<String, Integer> channelIndexesByName = new HashMap<String, Integer>();
    private final Map<String, String> normalizedCatalogNames = new HashMap<String, String>();
    private volatile boolean running;
    private volatile Thread subscriberThread;

    public ZJChvBuf(String zcmEndpoint, String gpsChannel, int bufferSeconds, GpsTimeConverter gpsTimeConverter) {
        this.zcmEndpoint = zcmEndpoint == null ? "" : zcmEndpoint.trim();
        this.maxSnapshots = bufferSeconds;
        this.gpsTimeConverter = gpsTimeConverter;
        this.decoder = new ZfdPayloadDecoder(gpsChannel, gpsTimeConverter);
        if (!this.zcmEndpoint.isEmpty()) {
            start();
        } else {
            LOGGER.warning("datadisplay.zcm.endpoint is not configured; live buffer will stay idle.");
        }
    }

    public boolean hasSource() { return !zcmEndpoint.isEmpty(); }
    public int getConfiguredBufferSeconds() { return maxSnapshots; }

    public int snapshotCount() {
        synchronized (lock) { return snapshots.size(); }
    }

    public long getOldestBufferedUtcMs() {
        synchronized (lock) { return snapshots.isEmpty() ? -1L : snapshots.getFirst().getUtcMs(); }
    }

    public long getLatestBufferedUtcMs() {
        synchronized (lock) { return snapshots.isEmpty() ? -1L : snapshots.getLast().getUtcMs(); }
    }

    /** Snapshot of the live channel catalog derived from observed ZFD payloads. */
    public List<DdChannelItemDto> snapshotCatalog() {
        synchronized (lock) {
            List<DdChannelItemDto> entries = new ArrayList<DdChannelItemDto>(catalogUnitsByName.size());
            for (Map.Entry<String, String> entry : catalogUnitsByName.entrySet()) {
                String name = entry.getKey();
                if (name == null || name.trim().isEmpty()) continue;
                entries.add(new DdChannelItemDto(name, deriveDisplayName(name), entry.getValue(), deriveCategory(name), 1));
            }
            return entries;
        }
    }

    /** Collect per-channel time series from the rolling buffer for all snapshots after afterUtcMs. */
    public List<DdLiveSeriesDto> collectSeries(List<String> channels, long afterUtcMs) {
        List<LiveSnapshot> buffered;
        List<String> requestedChannels = channels == null ? Collections.<String>emptyList() : channels;
        List<Integer> resolvedIndexes = new ArrayList<Integer>(requestedChannels.size());
        synchronized (lock) {
            buffered = new ArrayList<LiveSnapshot>(snapshots.size());
            for (LiveSnapshot snapshot : snapshots) {
                if (snapshot.getUtcMs() > afterUtcMs) buffered.add(snapshot);
            }
            for (String channel : requestedChannels) {
                resolvedIndexes.add(resolveStoredChannelIndex(channel));
            }
        }
        if (buffered.isEmpty() || requestedChannels.isEmpty()) return Collections.emptyList();

        long startGps = buffered.get(0).getGpsSeconds();
        long endGps = buffered.get(buffered.size() - 1).getGpsSeconds();
        int span = (int) Math.max(1L, endGps - startGps + 1L);
        Map<Long, LiveSnapshot> byGps = new HashMap<Long, LiveSnapshot>(buffered.size());
        for (LiveSnapshot snapshot : buffered) {
            byGps.put(Long.valueOf(snapshot.getGpsSeconds()), snapshot);
        }

        List<DdLiveSeriesDto> result = new ArrayList<DdLiveSeriesDto>(requestedChannels.size());
        for (int ci = 0; ci < requestedChannels.size(); ci++) {
            String channel = requestedChannels.get(ci);
            Integer resolvedIndex = resolvedIndexes.get(ci);
            List<Double> values = new ArrayList<Double>(Collections.nCopies(span, (Double) null));
            for (long gps = startGps; gps <= endGps; gps++) {
                LiveSnapshot snapshot = byGps.get(Long.valueOf(gps));
                if (snapshot == null || resolvedIndex == null) continue;
                values.set((int) (gps - startGps), snapshot.findNumericValue(resolvedIndex.intValue()));
            }
            result.add(new DdLiveSeriesDto(channel, gpsTimeConverter.gpsSecondsToUtcMs(startGps), 1000, values));
        }
        return result;
    }

    private void start() {
        running = true;
        Thread thread = new Thread(new Runnable() {
            @Override public void run() { runSubscriberLoop(); }
        }, "DD-ZJChvBuf-Subscriber");
        thread.setDaemon(true);
        subscriberThread = thread;
        thread.start();
    }

    private void runSubscriberLoop() {
        while (running) {
            Object context = null;
            Object socket = null;
            try {
                Class<?> zmqClass = Class.forName("org.zeromq.ZMQ");
                int subType = ((Integer) zmqClass.getField("SUB").get(null)).intValue();
                context = zmqClass.getMethod("context", int.class).invoke(null, Integer.valueOf(1));
                socket = context.getClass().getMethod("socket", int.class).invoke(context, Integer.valueOf(subType));
                Class<?> socketClass = socket.getClass();
                socketClass.getMethod("setLinger", int.class).invoke(socket, Integer.valueOf(0));
                socketClass.getMethod("setReceiveTimeOut", int.class).invoke(socket, Integer.valueOf(500));
                socketClass.getMethod("subscribe", byte[].class).invoke(socket, new Object[] { new byte[0] });
                socketClass.getMethod("connect", String.class).invoke(socket, zcmEndpoint);
                while (running) {
                    Object frame = socketClass.getMethod("recv", int.class).invoke(socket, Integer.valueOf(0));
                    if (frame instanceof byte[]) acceptPayload((byte[]) frame);
                }
            } catch (Throwable exception) {
                if (running) LOGGER.log(Level.WARNING, "ZJChvBuf live subscriber error: " + exception.getMessage(), exception);
            } finally {
                closeZmqObject(socket);
                closeZmqObject(context);
            }
            if (!running) break;
            try { Thread.sleep(1000L); } catch (InterruptedException exception) {
                Thread.currentThread().interrupt(); break;
            }
        }
    }

    private void acceptPayload(byte[] payload) {
        DecodedSnapshot decoded = decoder.decode(payload);
        if (decoded == null) return;
        synchronized (lock) {
            LiveSnapshot last = snapshots.peekLast();
            if (last != null && decoded.getGpsSeconds() < last.getGpsSeconds()) return;
            if (last != null && decoded.getGpsSeconds() == last.getGpsSeconds()) snapshots.removeLast();
            retainCatalogEntries(decoded.getCatalogUnits());
            ensureValueChannels(decoded.getNumericValues());
            snapshots.addLast(toLiveSnapshot(decoded));
            while (snapshots.size() > maxSnapshots) snapshots.removeFirst();
        }
    }

    private void retainCatalogEntries(Map<String, String> catalogUnits) {
        for (Map.Entry<String, String> entry : catalogUnits.entrySet()) {
            String name = entry.getKey();
            if (name == null || name.isEmpty()) continue;
            ensureChannelIndex(name);
            if (!catalogUnitsByName.containsKey(name)) {
                catalogUnitsByName.put(name, entry.getValue());
                String normalized = normalizeChannelKey(name);
                if (!normalizedCatalogNames.containsKey(normalized)) normalizedCatalogNames.put(normalized, name);
            } else if (catalogUnitsByName.get(name) == null && entry.getValue() != null) {
                catalogUnitsByName.put(name, entry.getValue());
            }
        }
    }

    private void ensureValueChannels(Map<String, Double> numericValues) {
        for (String name : numericValues.keySet()) ensureChannelIndex(name);
    }

    private LiveSnapshot toLiveSnapshot(DecodedSnapshot decoded) {
        double[] valuesByIndex = new double[channelIndexesByName.size()];
        Arrays.fill(valuesByIndex, Double.NaN);
        for (Map.Entry<String, Double> entry : decoded.getNumericValues().entrySet()) {
            Integer idx = channelIndexesByName.get(entry.getKey());
            if (idx == null || entry.getValue() == null) continue;
            valuesByIndex[idx.intValue()] = entry.getValue().doubleValue();
        }
        return new LiveSnapshot(decoded.getGpsSeconds(), decoded.getUtcMs(), valuesByIndex);
    }

    private Integer resolveStoredChannelIndex(String requestedChannel) {
        if (requestedChannel == null) return null;
        String trimmed = requestedChannel.trim();
        if (trimmed.isEmpty()) return null;
        Integer direct = channelIndexesByName.get(trimmed);
        if (direct != null) return direct;
        String resolved = normalizedCatalogNames.get(normalizeChannelKey(trimmed));
        return resolved == null ? null : channelIndexesByName.get(resolved);
    }

    private void ensureChannelIndex(String channelName) {
        if (channelName == null || channelName.isEmpty() || channelIndexesByName.containsKey(channelName)) return;
        channelIndexesByName.put(channelName, Integer.valueOf(channelIndexesByName.size()));
    }

    private static void closeZmqObject(Object value) {
        if (value == null) return;
        try { value.getClass().getMethod("close").invoke(value); }
        catch (Throwable firstFailure) {
            try { value.getClass().getMethod("term").invoke(value); } catch (Throwable ignored) {}
        }
    }

    private static String deriveDisplayName(String channelName) {
        String base = stripVersionPrefix(channelName);
        int colon = base.indexOf(':');
        if (colon >= 0 && colon + 1 < base.length()) base = base.substring(colon + 1);
        return base.replace('_', ' ').trim();
    }

    private static String deriveCategory(String channelName) {
        String base = stripVersionPrefix(channelName);
        int colon = base.indexOf(':');
        if (colon >= 0 && colon + 1 < base.length()) base = base.substring(colon + 1);
        String[] tokens = base.split("[-_]");
        if (tokens.length >= 2) {
            String first = tokens[0].trim().toUpperCase(Locale.US);
            String second = tokens[1].trim();
            if (!first.isEmpty() && !second.isEmpty()) {
                if ("INF".equals(first) || "VAC".equals(first) || "HVAC".equals(first))
                    return first + "_" + second.toUpperCase(Locale.US);
                return second.toUpperCase(Locale.US);
            }
        }
        if (tokens.length >= 1 && !tokens[0].trim().isEmpty()) return tokens[0].trim().toUpperCase(Locale.US);
        return null;
    }

    private static String stripVersionPrefix(String key) {
        if (key == null) return "";
        String trimmed = key.trim();
        int sep = trimmed.indexOf(':');
        if (sep > 1 && sep < trimmed.length() - 1 && (trimmed.charAt(0) == 'V' || trimmed.charAt(0) == 'v')) {
            boolean digits = true;
            for (int i = 1; i < sep; i++) {
                char ch = trimmed.charAt(i);
                if (ch < '0' || ch > '9') { digits = false; break; }
            }
            if (digits) return trimmed.substring(sep + 1).trim();
        }
        return trimmed;
    }

    private static String normalizeChannelKey(String key) {
        return stripVersionPrefix(key).toUpperCase(Locale.US);
    }

    @Override
    public void close() {
        running = false;
        Thread thread = subscriberThread;
        if (thread != null) {
            try { thread.join(1000L); } catch (InterruptedException exception) { Thread.currentThread().interrupt(); }
            subscriberThread = null;
        }
        synchronized (lock) {
            snapshots.clear(); catalogUnitsByName.clear(); channelIndexesByName.clear(); normalizedCatalogNames.clear();
        }
    }
}
