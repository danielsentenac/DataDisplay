package org.virgo.dataviewer.backend.live;

final class LiveCatalogChannel {
    private final String name;
    private final String unit;

    LiveCatalogChannel(String name, String unit) {
        this.name = name;
        this.unit = unit;
    }

    String getName() {
        return name;
    }

    String getUnit() {
        return unit;
    }
}
