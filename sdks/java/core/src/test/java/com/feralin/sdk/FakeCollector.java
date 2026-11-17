package com.feralin.sdk;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/** Yerel gerçek HTTP sunucusu (JDK httpserver). Önceden yazılmış yanıtlar tükenince 202 ack döner. */
final class FakeCollector implements AutoCloseable {
    static final class Scripted {
        final int status;
        final byte[] body;
        final String[] headers;

        Scripted(int status, String body, String... headers) {
            this.status = status;
            this.body = body.getBytes(StandardCharsets.UTF_8);
            this.headers = headers;
        }
    }

    static final class Recorded {
        final Headers headers;
        final Map<String, Object> body;

        Recorded(Headers headers, Map<String, Object> body) {
            this.headers = headers;
            this.body = body;
        }

        String header(String name) {
            return headers.getFirst(name);
        }

        @SuppressWarnings("unchecked")
        List<Map<String, Object>> events() {
            return (List<Map<String, Object>>) body.get("events");
        }
    }

    private final Object lock = new Object();
    private final List<Recorded> requests = new ArrayList<>();
    private final Deque<Scripted> script = new ArrayDeque<>();
    private final Semaphore received = new Semaphore(0);
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final HttpServer server;
    private boolean closed;

    FakeCollector() throws IOException {
        server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.setExecutor(executor);
        server.createContext("/v1/batch", this::handle);
        server.start();
    }

    @SuppressWarnings("unchecked")
    private void handle(HttpExchange exchange) throws IOException {
        byte[] raw = exchange.getRequestBody().readAllBytes();
        Map<String, Object> body = (Map<String, Object>) Json.parse(new String(raw, StandardCharsets.UTF_8));
        Scripted scripted;
        synchronized (lock) {
            requests.add(new Recorded(exchange.getRequestHeaders(), body));
            scripted = script.pollFirst();
        }
        if (scripted == null) {
            int count = ((List<?>) body.get("events")).size();
            scripted = new Scripted(202, "{\"batch_id\":\"01TESTBATCH0000000000000000\",\"accepted\":" + count + ",\"rejected\":0}");
        }
        exchange.getResponseHeaders().set("Content-Type", scripted.status >= 400 ? "application/problem+json" : "application/json");
        for (int i = 0; i + 1 < scripted.headers.length; i += 2) {
            exchange.getResponseHeaders().set(scripted.headers[i], scripted.headers[i + 1]);
        }
        exchange.sendResponseHeaders(scripted.status, scripted.body.length == 0 ? -1 : scripted.body.length);
        if (scripted.body.length > 0) {
            exchange.getResponseBody().write(scripted.body);
        }
        exchange.close();
        received.release();
    }

    void script(Scripted... responses) {
        synchronized (lock) {
            script.addAll(Arrays.asList(responses));
        }
    }

    String url() {
        return "http://" + server.getAddress().getAddress().getHostAddress() + ":" + server.getAddress().getPort();
    }

    int count() {
        synchronized (lock) {
            return requests.size();
        }
    }

    Recorded request(int index) {
        synchronized (lock) {
            return requests.get(index);
        }
    }

    List<Recorded> requests() {
        synchronized (lock) {
            return Collections.unmodifiableList(new ArrayList<>(requests));
        }
    }

    boolean await(long seconds) throws InterruptedException {
        return received.tryAcquire(seconds, TimeUnit.SECONDS);
    }

    @Override
    public void close() {
        synchronized (lock) {
            if (closed) {
                return;
            }
            closed = true;
        }
        server.stop(0);
        executor.shutdownNow();
    }
}
