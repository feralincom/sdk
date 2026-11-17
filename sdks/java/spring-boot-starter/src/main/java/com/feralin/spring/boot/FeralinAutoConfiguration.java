package com.feralin.spring.boot;

import com.feralin.sdk.Consent;
import com.feralin.sdk.Feralin;
import com.feralin.sdk.FeralinClient;
import com.feralin.sdk.Transport;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.web.context.annotation.RequestScope;

/**
 * {@code feralin.project-key} ve {@code feralin.collect-url} verilince devreye girer. Kuyruk ve gönderici uygulama
 * genelinde tektir ({@link FeralinClient}); Servlet uygulamasında {@link Feralin} enjeksiyonu istek başına görünüm verir,
 * böylece bir kullanıcının izni ve kimliği başka isteğe sızmaz.
 */
@AutoConfiguration
@ConditionalOnClass(FeralinClient.class)
@ConditionalOnProperty(prefix = "feralin", name = {"project-key", "collect-url"})
@EnableConfigurationProperties(FeralinProperties.class)
public class FeralinAutoConfiguration {
    private static final System.Logger LOG = System.getLogger("feralin");

    @Bean(destroyMethod = "close")
    @ConditionalOnMissingBean
    public FeralinClient feralinClient(FeralinProperties properties, ObjectProvider<Transport> transport) {
        FeralinClient.Builder builder = FeralinClient.builder(properties.getProjectKey(), properties.getCollectUrl())
                .consent(properties.getConsent().toConsent())
                .flushInterval(properties.getFlushInterval())
                .batchSize(properties.getBatchSize())
                .queueLimit(properties.getQueueLimit())
                .timeout(properties.getTimeout());
        transport.ifAvailable(builder::transport);
        return builder.build();
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
    @ConditionalOnClass({RequestScope.class, HttpServletRequest.class})
    static class RequestScopedFeralinConfiguration {

        @Bean
        @ConditionalOnMissingBean
        FeralinConsentResolver feralinConsentResolver(FeralinProperties properties) {
            return request -> properties.getConsent().toConsent();
        }

        // destroyMethod boş: istek bitince görünüm atılır, paylaşılan istemci kapanmaz. FeralinClient de Feralin
        // türünde olduğundan @Primary, istek içinde enjeksiyonun görünümü seçmesini sağlar.
        @Bean(destroyMethod = "")
        @RequestScope
        @Primary
        @ConditionalOnMissingBean(name = "feralin")
        Feralin feralin(FeralinClient client, FeralinConsentResolver resolver, HttpServletRequest request) {
            return client.scoped(resolveConsent(resolver, request));
        }

        // Çözümleyici uygulama kodudur; hatası bean oluşumunu düşürüp isteği 500 yapmamalı, izin yok sayılır.
        private static Consent resolveConsent(FeralinConsentResolver resolver, HttpServletRequest request) {
            try {
                Consent consent = resolver.resolve(request);
                return consent != null ? consent : Consent.none();
            } catch (RuntimeException exc) {
                // İleti anahtar veya çerez değeri taşıyabilir; yalnız tür yazılır.
                LOG.log(System.Logger.Level.DEBUG, "izin çözümleyici hata verdi, izin yok sayıldı: {0}", exc.getClass().getName());
                return Consent.none();
            }
        }
    }
}
