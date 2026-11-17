<?php
/**
 * Test toplayıcısı (php -S yönlendirici betiği): gelen /v1/batch gövdelerini günlüğe ekler, durum kodunu mod dosyasından okur.
 * FERALIN_FAKE_LOG ve FERALIN_FAKE_MODE ortam değişkenleri dosya yollarıdır.
 */

declare(strict_types=1);

$log = getenv('FERALIN_FAKE_LOG');
$modeFile = getenv('FERALIN_FAKE_MODE');
if (!is_string($log) || !is_string($modeFile)) {
    http_response_code(500);
    return;
}
$body = (string) file_get_contents('php://input');
file_put_contents($log, json_encode(['path' => $_SERVER['REQUEST_URI'] ?? '', 'key' => $_SERVER['HTTP_X_FERALIN_PROJECT_KEY'] ?? '', 'body' => $body]) . "\n", FILE_APPEND | LOCK_EX);
$status = (int) trim((string) @file_get_contents($modeFile));
$status = $status > 0 ? $status : 202;
http_response_code($status);
header('Content-Type: application/json');
$decoded = json_decode($body, true);
$count = is_array($decoded) && is_array($decoded['events'] ?? null) ? count($decoded['events']) : 0;
echo $status === 202 ? json_encode(['batch_id' => 'b_test', 'accepted' => $count, 'rejected' => 0]) : '{"error":"test"}';
