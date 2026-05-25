package org.virgo.datadisplay.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;

import org.virgo.datadisplay.archive.FflArchiveAdapter;
import org.virgo.datadisplay.archive.FflSource;
import org.virgo.datadisplay.config.DdBackendConfig;
import org.virgo.datadisplay.dto.DdFflItemDto;
import org.virgo.dataviewer.backend.live.ZJChvBuf;
import org.virgo.dataviewer.backend.time.GpsTimeConverter;

/**
 * Container for all backend service objects — created once in DdBackendBootstrap and
 * stored in the servlet context via DdServiceRegistry.
 */
public final class DdTomcatServices implements AutoCloseable {
    private static final Logger LOGGER = Logger.getLogger(DdTomcatServices.class.getName());

    private final DdBackendConfig config;
    private final GpsTimeConverter gpsTimeConverter;
    private final Map<String, FflArchiveAdapter> adapterById;
    private final List<FflArchiveAdapter> adapters;
    private final ZJChvBuf liveBuffer;
    private final DdPlotService plotService;

    public DdTomcatServices(DdBackendConfig config) {
        this.config = config;
        this.gpsTimeConverter = new GpsTimeConverter();
        this.plotService = new DdPlotService(gpsTimeConverter);

        Map<String, FflArchiveAdapter> adapterMap = new LinkedHashMap<String, FflArchiveAdapter>();
        if ("jni".equalsIgnoreCase(config.getHistoryBackend())) {
            for (FflSource source : config.getFflSources()) {
                try {
                    FflArchiveAdapter adapter = new FflArchiveAdapter(
                            source,
                            config.getFrameJniLibraryName(),
                            config.getFrameJniLibraryPath());
                    adapterMap.put(source.getId(), adapter);
                    LOGGER.info("Registered FFL adapter: " + source.getId() + " -> " + source.getPath());
                } catch (Exception exception) {
                    LOGGER.warning("Failed to create FFL adapter for '" + source.getId() + "': " + exception.getMessage());
                }
            }
        } else {
            LOGGER.warning("Unknown history backend '" + config.getHistoryBackend() + "'; no FFL adapters registered.");
        }
        this.adapterById = Collections.unmodifiableMap(adapterMap);
        this.adapters = Collections.unmodifiableList(new ArrayList<FflArchiveAdapter>(adapterMap.values()));

        ZJChvBuf buf = null;
        if (!config.getZcmEndpoint().isEmpty()) {
            try {
                buf = new ZJChvBuf(config.getZcmEndpoint(), config.getGpsChannel(),
                        config.getLiveBufferSeconds(), gpsTimeConverter);
                LOGGER.info("ZJChvBuf live buffer started; endpoint=" + config.getZcmEndpoint());
            } catch (Exception exception) {
                LOGGER.warning("Failed to start ZJChvBuf: " + exception.getMessage());
            }
        } else {
            LOGGER.info("No ZCM endpoint configured; live buffer disabled.");
        }
        this.liveBuffer = buf;
    }

    // ─── Accessors ────────────────────────────────────────────────────────

    public DdBackendConfig getConfig() { return config; }
    public GpsTimeConverter getGpsTimeConverter() { return gpsTimeConverter; }
    public DdPlotService getPlotService() { return plotService; }
    public ZJChvBuf getLiveBuffer() { return liveBuffer; }

    public List<FflArchiveAdapter> getAdapters() { return adapters; }

    public FflArchiveAdapter getAdapter(String fflSourceId) {
        if (fflSourceId == null) return null;
        return adapterById.get(fflSourceId.trim());
    }

    public List<DdFflItemDto> listFflItems() {
        List<DdFflItemDto> items = new ArrayList<DdFflItemDto>(adapters.size());
        for (FflArchiveAdapter adapter : adapters) {
            FflSource source = adapter.getSource();
            items.add(new DdFflItemDto(source.getId(), source.getLabel(), source.getNominalSampleRateHz()));
        }
        return items;
    }

    @Override
    public void close() {
        if (liveBuffer != null) {
            try { liveBuffer.close(); } catch (Exception ignored) {}
        }
    }
}
