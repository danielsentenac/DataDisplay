package org.virgo.dataviewer.adapter.json;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

import javax.script.ScriptEngine;
import javax.script.ScriptEngineManager;
import javax.script.ScriptException;

public class NashornJsonCodec implements JsonCodec {
    @Override
    public Object read(InputStream inputStream) throws IOException {
        String json = readUtf8(inputStream);
        if (json.trim().isEmpty()) {
            return null;
        }
        ScriptEngine engine = new ScriptEngineManager().getEngineByName("nashorn");
        if (engine == null) {
            throw new IOException("Nashorn JavaScript engine is not available.");
        }
        engine.put("__json_input__", json);
        try {
            return engine.eval("Java.asJSONCompatible(JSON.parse(__json_input__))");
        } catch (ScriptException exception) {
            throw new IOException("Invalid JSON payload.", exception);
        }
    }

    @Override
    public void write(OutputStream outputStream, Object value) throws IOException {
        outputStream.write(stringify(value).getBytes(StandardCharsets.UTF_8));
    }

    private String readUtf8(InputStream inputStream) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        byte[] chunk = new byte[4096];
        int read;
        while ((read = inputStream.read(chunk)) != -1) {
            buffer.write(chunk, 0, read);
        }
        return new String(buffer.toByteArray(), StandardCharsets.UTF_8);
    }

    @SuppressWarnings("unchecked")
    private String stringify(Object value) throws IOException {
        if (value == null) return "null";
        if (value instanceof String) return quote((String) value);
        if (value instanceof Number || value instanceof Boolean) return String.valueOf(value);
        if (value instanceof Map) {
            StringBuilder b = new StringBuilder("{");
            Iterator<Map.Entry<Object, Object>> it = ((Map<Object, Object>) value).entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<Object, Object> e = it.next();
                b.append(quote(String.valueOf(e.getKey()))).append(':').append(stringify(e.getValue()));
                if (it.hasNext()) b.append(',');
            }
            return b.append('}').toString();
        }
        if (value instanceof List) {
            StringBuilder b = new StringBuilder("[");
            Iterator<Object> it = ((List<Object>) value).iterator();
            while (it.hasNext()) {
                b.append(stringify(it.next()));
                if (it.hasNext()) b.append(',');
            }
            return b.append(']').toString();
        }
        throw new IOException("Unsupported JSON value type: " + value.getClass().getName());
    }

    private String quote(String value) {
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': case '\\': b.append('\\').append(c); break;
                case '\b': b.append("\\b"); break;
                case '\f': b.append("\\f"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }
}
