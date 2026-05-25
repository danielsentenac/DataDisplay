package org.virgo.datadisplay.service;

import javax.servlet.ServletContext;

/** Stores and retrieves the DdTomcatServices singleton from the servlet context. */
public final class DdServiceRegistry {
    private static final String ATTRIBUTE_KEY = DdTomcatServices.class.getName();

    private DdServiceRegistry() {}

    public static void register(ServletContext context, DdTomcatServices services) {
        context.setAttribute(ATTRIBUTE_KEY, services);
    }

    /** Returns the registered services, or null if not yet initialised. */
    public static DdTomcatServices get(ServletContext context) {
        return (DdTomcatServices) context.getAttribute(ATTRIBUTE_KEY);
    }

    public static void remove(ServletContext context) {
        context.removeAttribute(ATTRIBUTE_KEY);
    }
}
