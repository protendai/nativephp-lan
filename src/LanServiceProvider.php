<?php

namespace Protendai\Lan;

use Illuminate\Support\ServiceProvider;
use Native\Mobile\Testing\FakeBridge;
use Protendai\Lan\Testing\LanMacros;

class LanServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__.'/../config/lan.php', 'lan');

        $this->app->singleton(Lan::class, fn ($app): Lan => new Lan((array) $app['config']->get('lan', [])));

        // Test sugar (withLocalIp(), assertRespondedTo() ...), only on a core with a macroable FakeBridge.
        if (class_exists(FakeBridge::class) && method_exists(FakeBridge::class, 'macro')) {
            LanMacros::register();
        }
    }

    public function boot(): void
    {
        if ($this->app->runningInConsole()) {
            $this->publishes([
                __DIR__.'/../config/lan.php' => config_path('lan.php'),
            ], 'lan-config');
        }
    }
}
