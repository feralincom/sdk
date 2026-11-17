package com.feralin.sdk;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Yalnız JDK {@code java.net.http} kullanan taşıma. Bütün istek, yanıt gövdesi dahil, süre sınırına tabidir. */
public final class HttpClientTransport implements Transport {
    static final int MAX_RESPONSE_BODY = 64 * 1024;

    // HTTP/1.1: düz http üzerinde h2c Upgrade başlıkları bazı ters vekillerde sorun çıkarır; kısa POST'lar h2'den kazanmaz.
    private final HttpClient client = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    @Override
    public Response send(String url, byte[] body, Map<String, String> headers, Duration timeout) {
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url))
                .timeout(timeout)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body));
        headers.forEach(builder::header);
        Future<HttpResponse<byte[]>> pending = client.sendAsync(builder.build(), info -> new LimitedBody(MAX_RESPONSE_BODY));
        try {
            // HttpRequest.timeout yalnız başlıklara kadar geçerlidir; takılan gövde göndericiyi kilitlemesin diye süre burada da uygulanır.
            HttpResponse<byte[]> response = pending.get(timeout.toNanos(), TimeUnit.NANOSECONDS);
            return new Response(response.statusCode(), response.body(), firstValues(response.headers().map()));
        } catch (TimeoutException exc) {
            pending.cancel(true);
            throw new TemporaryException("ağ hatası: zaman aşımı", exc);
        } catch (InterruptedException exc) {
            pending.cancel(true);
            Thread.currentThread().interrupt();
            throw new TemporaryException("ağ hatası: iş parçacığı kesildi", exc);
        } catch (ExecutionException exc) {
            Throwable cause = exc.getCause() == null ? exc : exc.getCause();
            throw new TemporaryException("ağ hatası: " + cause.getClass().getSimpleName(), cause);
        }
    }

    private static Map<String, String> firstValues(Map<String, List<String>> headers) {
        Map<String, String> out = new LinkedHashMap<>();
        headers.forEach((name, values) -> {
            if (!values.isEmpty()) {
                out.put(name, values.get(0));
            }
        });
        return out;
    }

    /** Yanıtın en fazla {@code limit} baytını toplar, fazlasını okumadan bağlantıyı bırakır. */
    private static final class LimitedBody implements HttpResponse.BodySubscriber<byte[]> {
        private final int limit;
        private final ByteArrayOutputStream collected = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> result = new CompletableFuture<>();
        private Flow.Subscription subscription;

        LimitedBody(int limit) {
            this.limit = limit;
        }

        @Override
        public CompletionStage<byte[]> getBody() {
            return result;
        }

        @Override
        public void onSubscribe(Flow.Subscription value) {
            subscription = value;
            subscription.request(Long.MAX_VALUE);
        }

        @Override
        public void onNext(List<ByteBuffer> buffers) {
            for (ByteBuffer buffer : buffers) {
                while (buffer.hasRemaining() && collected.size() < limit) {
                    collected.write(buffer.get());
                }
            }
            if (collected.size() >= limit && !result.isDone()) {
                result.complete(collected.toByteArray());
                subscription.cancel();
            }
        }

        @Override
        public void onError(Throwable error) {
            result.completeExceptionally(error);
        }

        @Override
        public void onComplete() {
            result.complete(collected.toByteArray());
        }
    }
}
