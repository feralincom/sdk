<?php

declare(strict_types=1);

namespace Feralin\Symfony\ValueResolver;

use Feralin\Symfony\EventSubscriber\FeralinSubscriber;
use Feralin\Symfony\RequestFeralin;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Controller\ValueResolverInterface;
use Symfony\Component\HttpKernel\ControllerMetadata\ArgumentMetadata;

/** Denetleyici argümanı: `public function siparis(RequestFeralin $feralin)`. Alt isteklerde yüzey yeniden çözülür. */
final class RequestFeralinResolver implements ValueResolverInterface
{
    public function __construct(private readonly FeralinSubscriber $subscriber)
    {
    }

    /** @return iterable<RequestFeralin> */
    public function resolve(Request $request, ArgumentMetadata $argument): iterable
    {
        if ($argument->getType() !== RequestFeralin::class) {
            return [];
        }
        $bound = $request->attributes->get(FeralinSubscriber::ATTRIBUTE);
        return [$bound instanceof RequestFeralin ? $bound : $this->subscriber->forRequest($request)];
    }
}
