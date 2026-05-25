package org.virgo.dataviewer.adapter.json;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

public interface JsonCodec {
    Object read(InputStream inputStream) throws IOException;
    void write(OutputStream outputStream, Object value) throws IOException;
}
