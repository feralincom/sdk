<?php

declare(strict_types=1);

namespace Feralin\Symfony;

use Feralin\Client;
use Feralin\Symfony\EventSubscriber\FeralinSubscriber;
use Feralin\Symfony\ValueResolver\RequestFeralinResolver;
use Symfony\Component\Config\Definition\Configurator\DefinitionConfigurator;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\DependencyInjection\Reference;
use Symfony\Component\HttpKernel\Bundle\AbstractBundle;

/**
 * config/packages/feralin.yaml:
 *
 *     feralin:
 *         project_key: '%env(FERALIN_PROJECT_KEY)%'   # yalnız pk_ anahtarı
 *         collect_url: '%env(FERALIN_COLLECT_URL)%'
 *         consent_resolver: App\Feralin\Izin           # ConsentResolverInterface servisi; yoksa izin yok
 */
final class FeralinBundle extends AbstractBundle
{
    public function configure(DefinitionConfigurator $definition): void
    {
        $definition->rootNode()
            ->children()
                ->scalarNode('project_key')->isRequired()->cannotBeEmpty()->end()
                ->scalarNode('collect_url')->isRequired()->cannotBeEmpty()->end()
                ->scalarNode('consent_resolver')->defaultNull()->end()
                ->scalarNode('identity_resolver')->defaultNull()->end()
                ->booleanNode('include_context')->defaultTrue()->end()
                ->arrayNode('client')
                    ->children()
                        ->integerNode('batchSize')->end()
                        ->integerNode('queueLimit')->end()
                        ->floatNode('timeoutSeconds')->end()
                    ->end()
                ->end()
            ->end();
    }

    /** @param array<string, mixed> $config */
    public function loadExtension(array $config, ContainerConfigurator $container, ContainerBuilder $builder): void
    {
        $services = $container->services();
        $services->set(Client::class)->args([$config['project_key'], $config['collect_url'], $config['client'] ?? []]);
        $services->set(FeralinSubscriber::class)
            ->args([
                new Reference(Client::class),
                $config['consent_resolver'] !== null ? new Reference($config['consent_resolver']) : null,
                $config['identity_resolver'] !== null ? new Reference($config['identity_resolver']) : null,
                $config['include_context'],
            ])
            ->tag('kernel.event_subscriber');
        $services->set(RequestFeralinResolver::class)
            ->args([new Reference(FeralinSubscriber::class)])
            ->tag('controller.argument_value_resolver', ['priority' => 100]);
    }
}
