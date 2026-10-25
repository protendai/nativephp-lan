<?php

namespace Protendai\Lan\Testing;

use Native\Mobile\Testing\FakeBridge;
use PHPUnit\Framework\Assert;

/**
 * LAN test vocabulary, registered as FakeBridge macros so app tests read in LAN terms:
 *
 *     Native::test(Receive::class)
 *         ->withLocalIp('192.168.1.10')
 *         ->withServerPort(53531)
 *         ->emitNative(UploadRequested::class, [...])
 *         ->assertRespondedTo('req-1', 409);
 */
class LanMacros
{
    public static function register(): void
    {
        if (FakeBridge::hasMacro('assertRespondedTo')) {
            return;
        }

        /** Lan::localIp() answers $ip. */
        FakeBridge::macro('withLocalIp', function (string $ip) {
            /** @var FakeBridge $this */
            return $this->respondTo('Lan.LocalIp', ['ip' => $ip]);
        });

        /** Lan::startServer() succeeds on $port (null: the port that was asked for). */
        FakeBridge::macro('withServerPort', function (?int $port = null) {
            /** @var FakeBridge $this */
            return $this->respondTo('Lan.StartServer', fn (array $params) => [
                'ok' => true,
                'port' => $port ?? (int) ($params['deviceInfo']['port'] ?? $params['config']['port'] ?? 0),
            ]);
        });

        /** Lan::respond() returns true (the request is still waiting natively). */
        FakeBridge::macro('withPendingRequests', function () {
            /** @var FakeBridge $this */
            return $this->respondTo('Lan.Respond', ['ok' => true]);
        });

        /** Assert Lan::respond() answered $requestId, optionally with $status. */
        FakeBridge::macro('assertRespondedTo', function (string $requestId, ?int $status = null) {
            /** @var FakeBridge $this */
            $matching = array_filter(
                $this->calls,
                fn (array $call): bool => $call['method'] === 'Lan.Respond'
                    && ($call['params']['requestId'] ?? null) === $requestId
                    && ($status === null || (int) ($call['params']['status'] ?? 0) === $status),
            );

            Assert::assertNotEmpty($matching, "Expected Lan.Respond for request [{$requestId}]".($status !== null ? " with status [{$status}]" : '').'.');

            return $this;
        });

        /** Assert discovery was started, optionally matching its params (deviceInfo, config). */
        FakeBridge::macro('assertDiscoveryStarted', function (?callable $filter = null) {
            /** @var FakeBridge $this */
            return $this->assertCalled('Lan.StartDiscovery', $filter);
        });

        /** Assert the receive server was started, optionally matching its params. */
        FakeBridge::macro('assertServerStarted', function (?callable $filter = null) {
            /** @var FakeBridge $this */
            return $this->assertCalled('Lan.StartServer', $filter);
        });
    }
}
