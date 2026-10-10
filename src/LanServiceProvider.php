<?php

namespace Tuma\Lan;

use Illuminate\Support\ServiceProvider;
use Native\Mobile\Testing\FakeBridge;
use PHPUnit\Framework\Assert;

class LanServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton('tuma.lan', fn (): Lan => new Lan);
    }

    public function boot(): void
    {
        if ($this->app->runningInConsole()) {
            $this->commands([Commands\CopyPrivacyManifest::class]);
        }

        $this->registerFakeBridgeMacros();
    }

    /**
     * Test helpers for screens that use the plugin:
     *
     *   Native::fakeBridge()->withLocalIp('192.168.1.10');
     *   Native::fakeBridge()->assertRespondedTo('req-1', 200);
     */
    private function registerFakeBridgeMacros(): void
    {
        if (! class_exists(FakeBridge::class) || FakeBridge::hasMacro('withLocalIp')) {
            return;
        }

        FakeBridge::macro('withLocalIp', function (string $ip): FakeBridge {
            /** @var FakeBridge $this */
            return $this->respondTo('Lan.LocalIp', ['ip' => $ip]);
        });

        FakeBridge::macro('assertRespondedTo', function (string $requestId, int $status): FakeBridge {
            /** @var FakeBridge $this */
            $matching = array_filter(
                $this->callsTo('Lan.Respond'),
                fn (array $call): bool => ($call['params']['requestId'] ?? null) === $requestId
                    && (int) ($call['params']['status'] ?? 0) === $status,
            );

            Assert::assertNotEmpty($matching, "Expected Lan.Respond for request [{$requestId}] with status [{$status}].");

            return $this;
        });
    }
}
