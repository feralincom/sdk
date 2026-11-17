package com.feralin.spring.boot;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.feralin.sdk.ClientClosedException;
import com.feralin.sdk.ConfigurationException;
import com.feralin.sdk.Consent;
import com.feralin.sdk.Feralin;
import com.feralin.sdk.FeralinClient;
import com.feralin.sdk.Transport;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.scope.ScopedObject;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.boot.test.context.runner.WebApplicationContextRunner;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

class FeralinAutoConfigurationTest {
    private static final String KEY = "pk_test_0123456789abcdef";
    private static final String[] REQUIRED = {"feralin.project-key=" + KEY, "feralin.collect-url=http://collect.example.test", "feralin.flush-interval=0"};

    private final List<String> sentBodies = Collections.synchronizedList(new ArrayList<>());
    private final Transport capturing = (url, body, headers, timeout) -> {
        sentBodies.add(new String(body, StandardCharsets.UTF_8));
        return new Transport.Response(202, "{\"accepted\":1,\"rejected\":0,\"batch_id\":\"01B\"}".getBytes(StandardCharsets.UTF_8), Map.of());
    };

    private final WebApplicationContextRunner web = new WebApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(FeralinAutoConfiguration.class))
            .withBean(Transport.class, () -> capturing);

    private final ApplicationContextRunner plain = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(FeralinAutoConfiguration.class))
            .withBean(Transport.class, () -> capturing);

    @AfterEach
    void clearRequest() {
        RequestContextHolder.resetRequestAttributes();
    }

    private static ServletRequestAttributes request(String consentHeader) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        if (consentHeader != null) {
            request.addHeader("X-Consent", consentHeader);
        }
        ServletRequestAttributes attributes = new ServletRequestAttributes(request);
        RequestContextHolder.setRequestAttributes(attributes);
        return attributes;
    }

    private static final FeralinConsentResolver HEADER_RESOLVER = request -> {
        String header = request.getHeader("X-Consent");
        return header == null ? Consent.none() : header.contains("advertising") ? Consent.analyticsAndAdvertising() : Consent.analyticsOnly();
    };

    @Test
    void withoutKeyOrUrlNoBeansAreCreated() {
        web.run(context -> assertThat(context).doesNotHaveBean(FeralinClient.class).doesNotHaveBean(Feralin.class));
        web.withPropertyValues("feralin.project-key=" + KEY).run(context -> assertThat(context).doesNotHaveBean(FeralinClient.class));
        web.withPropertyValues("feralin.collect-url=http://collect.example.test").run(context -> assertThat(context).doesNotHaveBean(FeralinClient.class));
    }

    @Test
    void nonWebApplicationGetsOnlyTheSharedClient() {
        plain.withPropertyValues(REQUIRED).run(context -> {
            assertThat(context).hasSingleBean(FeralinClient.class).hasSingleBean(Feralin.class).doesNotHaveBean(FeralinConsentResolver.class);
            assertThat(context.getBean(Feralin.class)).isSameAs(context.getBean(FeralinClient.class));
        });
    }

    @Test
    void webApplicationInjectsRequestScopedProxy() {
        web.withPropertyValues(REQUIRED).run(context -> {
            assertThat(context).hasNotFailed().hasSingleBean(FeralinClient.class).hasSingleBean(FeralinConsentResolver.class);
            assertThat(context.getBean(Feralin.class)).isInstanceOf(ScopedObject.class).isNotInstanceOf(FeralinClient.class);
        });
    }

    @Test
    void eachRequestHasItsOwnConsentAndIdentityOnOneQueue() {
        web.withPropertyValues(REQUIRED).withBean(FeralinConsentResolver.class, () -> HEADER_RESOLVER).run(context -> {
            Feralin feralin = context.getBean(Feralin.class);
            FeralinClient client = context.getBean(FeralinClient.class);

            ServletRequestAttributes first = request("analytics,advertising");
            feralin.identify("user_a");
            assertThat(feralin.track("order_completed", Map.of("fr_click", "clk")).orElseThrow().properties()).containsEntry("fr_click", "clk");
            first.requestCompleted();

            ServletRequestAttributes second = request("analytics");
            assertThat(feralin.status()).containsEntry("user_id", null);
            assertThat(feralin.track("order_completed", Map.of("fr_click", "clk")).orElseThrow().properties()).isEmpty();
            second.requestCompleted();

            ServletRequestAttributes third = request(null);
            assertThat(feralin.track("order_completed")).isEmpty();
            third.requestCompleted();

            RequestContextHolder.resetRequestAttributes();
            assertThat(client.queued()).isEqualTo(2);
            assertThat(client.status()).containsEntry("closed", false);
        });
    }

    @Test
    void sameRequestSeesSameInstance() {
        web.withPropertyValues(REQUIRED).withBean(FeralinConsentResolver.class, () -> HEADER_RESOLVER).run(context -> {
            Feralin feralin = context.getBean(Feralin.class);
            request("analytics");
            feralin.identify("user_a");
            assertThat(context.getBean(Feralin.class).status()).containsEntry("user_id", "user_a");
        });
    }

    @Test
    void withdrawalInRequestKeepsOtherRequestsEvents() {
        web.withPropertyValues(REQUIRED).withBean(FeralinConsentResolver.class, () -> HEADER_RESOLVER).run(context -> {
            Feralin feralin = context.getBean(Feralin.class);
            FeralinClient client = context.getBean(FeralinClient.class);
            request("analytics");
            feralin.track("kept");
            request("analytics");
            feralin.track("withdrawn");
            feralin.setConsent(Consent.none());
            assertThat(client.queued()).isEqualTo(1);
        });
    }

    @Test
    void defaultConsentIsNoneAndComesFromProperties() {
        web.withPropertyValues(REQUIRED).run(context -> {
            request("analytics");
            assertThat(context.getBean(Feralin.class).track("page_view")).isEmpty();
        });
        web.withPropertyValues(REQUIRED).withPropertyValues("feralin.consent.analytics=true").run(context -> {
            request(null);
            assertThat(context.getBean(Feralin.class).track("page_view")).isPresent();
        });
    }

    @Test
    void useOutsideRequestFailsClearlyAndClientStillWorks() {
        web.withPropertyValues(REQUIRED).withPropertyValues("feralin.consent.analytics=true").run(context -> {
            assertThatThrownBy(() -> context.getBean(Feralin.class).track("job")).isInstanceOf(RuntimeException.class).hasMessageContaining("request");
            assertThat(context.getBean(FeralinClient.class).track("job")).isPresent();
        });
    }

    @Test
    void propertiesAreBound() {
        web.withPropertyValues(REQUIRED)
                .withPropertyValues("feralin.batch-size=7", "feralin.queue-limit=2", "feralin.timeout=3s", "feralin.consent.session-replay=true", "feralin.consent.analytics=true")
                .run(context -> {
                    FeralinProperties properties = context.getBean(FeralinProperties.class);
                    assertThat(properties.getBatchSize()).isEqualTo(7);
                    assertThat(properties.getTimeout()).isEqualTo(Duration.ofSeconds(3));
                    assertThat(properties.getFlushInterval()).isEqualTo(Duration.ZERO);
                    assertThat(properties.getConsent().isSessionReplay()).isTrue();

                    FeralinClient client = context.getBean(FeralinClient.class);
                    for (int i = 0; i < 3; i++) {
                        client.track("e");
                    }
                    assertThat(client.queued()).as("queue-limit uygulanmalı").isEqualTo(2);
                });
    }

    @Test
    void secretKeyFailsAtStartupWithoutEchoingIt() {
        web.withPropertyValues("feralin.project-key=sk_live_supersecret", "feralin.collect-url=http://collect.example.test").run(context -> {
            assertThat(context).hasFailed();
            assertThat(context.getStartupFailure()).rootCause().isInstanceOf(ConfigurationException.class);
            assertThat(context.getStartupFailure()).hasStackTraceContaining("gizli anahtar");
            assertThat(context.getStartupFailure().getMessage()).doesNotContain("supersecret");
        });
    }

    @Test
    void keyIsNotInPropertiesToString() {
        FeralinProperties properties = new FeralinProperties();
        properties.setProjectKey(KEY);
        assertThat(properties.toString()).doesNotContain(KEY);
    }

    @Test
    void contextCloseFlushesQueueAndClosesClient() {
        FeralinClient[] holder = new FeralinClient[1];
        web.withPropertyValues(REQUIRED).withPropertyValues("feralin.consent.analytics=true").run(context -> {
            holder[0] = context.getBean(FeralinClient.class);
            holder[0].track("before_shutdown");
            assertThat(sentBodies).isEmpty();
        });
        assertThat(sentBodies).hasSize(1);
        assertThat(sentBodies.get(0)).contains("before_shutdown");
        assertThatThrownBy(() -> holder[0].track("late")).isInstanceOf(ClientClosedException.class);
    }

    @Test
    void requestEndDoesNotCloseSharedClient() {
        web.withPropertyValues(REQUIRED).withPropertyValues("feralin.consent.analytics=true").run(context -> {
            Feralin feralin = context.getBean(Feralin.class);
            ServletRequestAttributes attributes = request(null);
            feralin.track("in_request");
            attributes.requestCompleted();
            RequestContextHolder.resetRequestAttributes();
            FeralinClient client = context.getBean(FeralinClient.class);
            assertThat(client.status()).containsEntry("closed", false);
            assertThat(client.queued()).isEqualTo(1);
        });
    }

    @Test
    void resolverFailureMeansNoConsentAndRequestSurvives() {
        FeralinConsentResolver broken = request -> {
            throw new IllegalStateException("cerez=GIZLI_CEREZ anahtar=" + KEY);
        };
        List<String> logs = new ArrayList<>();
        Handler capture = new Handler() {
            @Override
            public void publish(LogRecord record) {
                logs.add(record.getLevel() + " " + record.getMessage() + " " + java.util.Arrays.toString(record.getParameters()) + " " + record.getThrown());
            }

            @Override
            public void flush() {
            }

            @Override
            public void close() {
            }
        };
        Logger logger = Logger.getLogger("feralin");
        Level previous = logger.getLevel();
        logger.setLevel(Level.FINE);
        logger.addHandler(capture);
        try {
            web.withPropertyValues(REQUIRED).withPropertyValues("feralin.consent.analytics=true").withBean(FeralinConsentResolver.class, () -> broken).run(context -> {
                request("analytics");
                Feralin feralin = context.getBean(Feralin.class);
                assertThat(feralin.track("order_completed")).isEmpty();
                assertThat(feralin.status()).containsEntry("closed", false);
                assertThat(context.getBean(FeralinClient.class).queued()).isZero();
            });
        } finally {
            logger.removeHandler(capture);
            logger.setLevel(previous);
        }
        assertThat(logs).anyMatch(line -> line.contains("IllegalStateException"));
        assertThat(logs).noneMatch(line -> line.contains("GIZLI_CEREZ") || line.contains(KEY));
    }

    @Test
    void resolverReturningNullMeansNoConsent() {
        web.withPropertyValues(REQUIRED).withBean(FeralinConsentResolver.class, () -> request -> null).run(context -> {
            request("analytics");
            assertThat(context.getBean(Feralin.class).track("order_completed")).isEmpty();
        });
    }

    @Test
    void userBeansWin() {
        FeralinClient custom = FeralinClient.builder(KEY, "http://custom.example.test").flushInterval(Duration.ZERO).build();
        web.withPropertyValues(REQUIRED).withBean("myClient", FeralinClient.class, () -> custom).run(context -> {
            assertThat(context).hasSingleBean(FeralinClient.class);
            assertThat(context.getBean(FeralinClient.class)).isSameAs(custom);
        });
    }
}
