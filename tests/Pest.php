<?php

use Illuminate\Container\Container;
use Native\Mobile\Testing\FakeBridge;
use Protendai\Lan\Lan;
use Protendai\Lan\Testing\LanMacros;

/*
 * The core's nativephp_call() polyfill routes every bridge call to the bound
 * FakeBridge, so the facade is tested exactly as an app's tests would see it.
 */
require_once dirname(__DIR__).'/vendor/nativephp/mobile/src/jump_bridge_functions.php';

LanMacros::register();

/** A fresh container with a FakeBridge bound, like Native::fakeBridge() in an app. */
function fakeBridge(): FakeBridge
{
    Container::setInstance(new Container);

    return FakeBridge::enable();
}

/** The params of the last call to $method. */
function lastCall(FakeBridge $bridge, string $method): array
{
    $calls = array_values(array_filter($bridge->calls, fn (array $c): bool => $c['method'] === $method));

    expect($calls)->not->toBeEmpty();

    return end($calls)['params'];
}

function pluginPath(string $path = ''): string
{
    return dirname(__DIR__).($path !== '' ? '/'.$path : '');
}

function manifest(): array
{
    return json_decode(file_get_contents(pluginPath('nativephp.json')), true, flags: JSON_THROW_ON_ERROR);
}

function kotlinSources(): string
{
    return implode("\n", array_map('file_get_contents', glob(pluginPath('resources/android/src/*.kt'))));
}

function swiftSources(): string
{
    return implode("\n", array_map('file_get_contents', glob(pluginPath('resources/ios/Sources/*.swift'))));
}

function lan(array $config = []): Lan
{
    return new Lan($config);
}
