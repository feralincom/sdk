<?php

declare(strict_types=1);

namespace Feralin;

/**
 * Web, Node, .NET, Android ve Flutter SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve olay sayısı.
 * Sıradan bağımsızdır; farklı içerik farklı anahtar üretir.
 */
final class Idempotency
{
    /** @param list<string> $eventIds ASCII kimlikler; şema deseni bunu garanti eder. */
    public static function keyFor(array $eventIds): string
    {
        sort($eventIds, SORT_STRING);
        $text = implode(',', $eventIds);
        // PHP tam sayısı taşınca float'a döner: 64 bit çarpım iki 32 bit parçayla yapılır.
        // FNV asalı 2^40 + 0x1b3 olduğundan h * asal = (h << 40) + h * 0x1b3 (mod 2^64).
        $high = 0xcbf29ce4;
        $low = 0x84222325;
        $length = strlen($text);
        for ($i = 0; $i < $length; $i++) {
            $low ^= ord($text[$i]);
            $product = $low * 0x1b3;
            $carry = $product >> 32;
            $nextHigh = (($high * 0x1b3) + $carry + ($low << 8)) & 0xffffffff;
            $low = $product & 0xffffffff;
            $high = $nextHigh;
        }
        return sprintf('%08x%08x-%d', $high, $low, count($eventIds));
    }
}
