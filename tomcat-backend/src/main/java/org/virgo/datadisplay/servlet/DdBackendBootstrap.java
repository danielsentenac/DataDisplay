package org.virgo.datadisplay.servlet;

import java.util.logging.Level;
import java.util.logging.Logger;

import javax.servlet.ServletContextEvent;
import javax.servlet.ServletContextListener;
import javax.servlet.annotation.WebListener;

import org.virgo.datadisplay.config.DdBackendConfig;
import org.virgo.datadisplay.service.DdServiceRegistry;
import org.virgo.datadisplay.service.DdTomcatServices;

/**
 * Initialises and tears down the DdTomcatServices singleton for the lifetime of the web application.
 */
@WebListener
public final class DdBackendBootstrap implements ServletContextListener {
    private static final Logger LOGGER = Logger.getLogger(DdBackendBootstrap.class.getName());

    @Override
    public void contextInitialized(ServletContextEvent event) {
        LOGGER.info("DataDisplay backend initialising...");
        try {
            DdBackendConfig config = DdBackendConfig.from(event.getServletContext());
            DdTomcatServices services = new DdTomcatServices(config);
            DdServiceRegistry.register(event.getServletContext(), services);
            LOGGER.info("DataDisplay backend ready. FFL sources: " + config.getFflSources().size());
        } catch (Exception exception) {
            LOGGER.log(Level.SEVERE, "DataDisplay backend failed to initialise", exception);
        }
    }

    @Override
    public void contextDestroyed(ServletContextEvent event) {
        LOGGER.info("DataDisplay backend shutting down...");
        DdTomcatServices services = DdServiceRegistry.get(event.getServletContext());
        if (services != null) {
            try { services.close(); } catch (Exception ignored) {}
        }
        DdServiceRegistry.remove(event.getServletContext());
        LOGGER.info("DataDisplay backend stopped.");
    }
}
