<?php

use Protendai\Lan\Lan;

beforeEach(function () {
    $this->bridge = fakeBridge();
});

it('sends discovery the device info with the service marker and the resolved config', function () {
    lan()->startDiscovery(['alias' => 'Phone', 'fingerprint' => 'fp-1']);

    $params = lastCall($this->bridge, 'Lan.StartDiscovery');

    expect($params['deviceInfo'])->toBe(['alias' => 'Phone', 'fingerprint' => 'fp-1', 'app' => 'nativephp-lan', 'port' => 53530, 'protocol' => 'http'])
        ->and($params['config'])->toBe([
            'serviceId' => 'nativephp-lan',
            'apiPrefix' => '/api/nativephp-lan/v1',
            'port' => 53530,
            'multicastGroup' => '224.0.0.170',
            'multicastPort' => 53530,
            'prepareTimeout' => 60,
            'maxFileSize' => 0,
            'maxFiles' => 1000,
            'maxConnections' => 32,
            'pinMaxAttempts' => 3,
        ]);
});

it('uses the app config and per-call options', function () {
    $lan = lan(['service_id' => 'myapp', 'api_prefix' => 'api/myapp/v1/', 'port' => 50000, 'multicast_group' => '224.0.0.200']);

    $lan->startDiscovery(['fingerprint' => 'fp'], ['port' => 50010]);

    $params = lastCall($this->bridge, 'Lan.StartDiscovery');

    expect($params['config']['serviceId'])->toBe('myapp')
        ->and($params['config']['apiPrefix'])->toBe('/api/myapp/v1')
        ->and($params['config']['port'])->toBe(50010)
        ->and($params['config']['multicastGroup'])->toBe('224.0.0.200')
        ->and($params['deviceInfo']['app'])->toBe('myapp');
});

it('never overrides an app marker or port the app set itself', function () {
    expect(lan()->deviceInfo(['app' => 'other', 'port' => 1234]))
        ->toMatchArray(['app' => 'other', 'port' => 1234]);
});

it('returns the bound port from startServer', function () {
    $this->bridge->respondTo('Lan.StartServer', ['ok' => true, 'port' => 53531]);

    expect(lan()->startServer(['fingerprint' => 'fp'], '/tmp/in', publicFolder: 'MyApp'))->toBe(53531);

    $params = lastCall($this->bridge, 'Lan.StartServer');
    expect($params['incomingDir'])->toBe('/tmp/in')
        ->and($params['publicFolder'])->toBe('MyApp')
        ->and($params['config']['serviceId'])->toBe('nativephp-lan');
});

it('falls back to the requested port, and null when the server failed', function () {
    $this->bridge->respondTo('Lan.StartServer', ['ok' => true]);
    expect(lan()->startServer(['port' => 50001], '/tmp/in'))->toBe(50001);

    $this->bridge->respondTo('Lan.StartServer', ['ok' => false]);
    expect(lan()->startServer([], '/tmp/in'))->toBeNull();
});

it('unwraps the {status, data} result envelope', function () {
    $this->bridge->respondTo('Lan.StartServer', ['status' => 'success', 'data' => ['ok' => true, 'port' => 50002]]);

    expect(lan()->startServer([], '/tmp/in'))->toBe(50002);
});

it('shapes respond() and reports whether the request was still waiting', function () {
    $this->bridge->respondTo('Lan.Respond', ['ok' => true]);

    expect(lan()->respond('req-1', ['a', 'b'], 'sess-1'))->toBeTrue();
    expect(lastCall($this->bridge, 'Lan.Respond'))->toBe([
        'requestId' => 'req-1',
        'acceptedFileIds' => ['a', 'b'],
        'sessionId' => 'sess-1',
        'status' => 200,
    ]);

    $this->bridge->respondTo('Lan.Respond', ['ok' => false, 'error' => 'unknown request']);
    expect(lan()->respond('gone', [], null, 409))->toBeFalse();
});

it('has accept() and decline() shorthands', function () {
    $this->bridge->respondTo('Lan.Respond', ['ok' => true]);

    lan()->accept('req-1', ['f1'], 'sess');
    expect(lastCall($this->bridge, 'Lan.Respond'))->toMatchArray(['status' => 200, 'sessionId' => 'sess', 'acceptedFileIds' => ['f1']]);

    lan()->decline('req-2', 409);
    expect(lastCall($this->bridge, 'Lan.Respond'))->toMatchArray(['requestId' => 'req-2', 'status' => 409, 'acceptedFileIds' => [], 'sessionId' => null]);

    lan()->decline('req-3');
    expect(lastCall($this->bridge, 'Lan.Respond')['status'])->toBe(403);
});

it('sends announce to the configured port unless one is given', function () {
    lan(['port' => 50100])->announce(['fingerprint' => 'fp'], '192.168.49.1');
    expect(lastCall($this->bridge, 'Lan.Announce'))->toMatchArray(['host' => '192.168.49.1', 'port' => 50100, 'seconds' => 20]);

    lan()->announce(['fingerprint' => 'fp'], '192.168.49.1', 50200, 5);
    expect(lastCall($this->bridge, 'Lan.Announce'))->toMatchArray(['port' => 50200, 'seconds' => 5]);
});

it('sweeps a subnet prefix', function () {
    lan()->sweepSubnet(['fingerprint' => 'fp'], '192.168.49', 30);

    expect(lastCall($this->bridge, 'Lan.SweepSubnet'))->toMatchArray(['prefix' => '192.168.49', 'seconds' => 30]);
});

it('decodes network info with safe defaults', function () {
    expect(lan()->localIp())->toBeNull()
        ->and(lan()->wifiEnabled())->toBeTrue();

    $this->bridge->respondTo('Lan.LocalIp', ['ip' => '192.168.1.10'])
        ->respondTo('Lan.WifiEnabled', ['enabled' => false]);

    expect(lan()->localIp())->toBe('192.168.1.10')
        ->and(lan()->wifiEnabled())->toBeFalse();
});

it('shapes the utility calls', function () {
    $this->bridge->respondTo('Lan.Thumbnail', ['ok' => true])->respondTo('Lan.OpenFile', ['ok' => true]);

    lan()->pickFiles(['image/*']);
    lan()->pickMedia();

    expect(lan()->thumbnail('/a.jpg', '/t.jpg', 'image/jpeg', 128))->toBeTrue()
        ->and(lan()->openFile('content://x', 'image/jpeg'))->toBeTrue()
        ->and(lastCall($this->bridge, 'Lan.PickFiles'))->toBe(['mimeTypes' => ['image/*']])
        ->and(lastCall($this->bridge, 'Lan.Thumbnail'))->toBe(['source' => '/a.jpg', 'dest' => '/t.jpg', 'mime' => 'image/jpeg', 'size' => 128])
        ->and(lastCall($this->bridge, 'Lan.OpenFile'))->toBe(['uri' => 'content://x', 'mime' => 'image/jpeg']);

    $this->bridge->assertCalled('Lan.PickMedia');
});

it('cancels a session and stops everything', function () {
    $this->bridge->respondTo('Lan.CancelSession', ['ok' => true]);

    expect(lan()->cancelSession('sess-1'))->toBeTrue();
    lan()->stopServer();
    lan()->stopDiscovery();

    $this->bridge->assertCalled('Lan.CancelSession', fn ($p) => $p['sessionId'] === 'sess-1')
        ->assertCalled('Lan.StopServer')
        ->assertCalled('Lan.StopDiscovery');
});

it('provides FakeBridge macros for app tests', function () {
    $this->bridge->withLocalIp('10.0.0.5')->withServerPort()->withPendingRequests();

    expect(lan()->localIp())->toBe('10.0.0.5')
        ->and(lan()->startServer(['port' => 50300], '/tmp'))->toBe(50300)
        ->and(lan()->respond('req-9', [], null, 409))->toBeTrue();

    $this->bridge->assertRespondedTo('req-9', 409)
        ->assertRespondedTo('req-9')
        ->assertServerStarted(fn ($p) => $p['incomingDir'] === '/tmp');

    lan()->startDiscovery([]);
    $this->bridge->assertDiscoveryStarted();
});

it('fails assertRespondedTo when the status differs', function () {
    $this->bridge->withPendingRequests();
    lan()->respond('req-1', [], null, 403);

    $this->bridge->assertRespondedTo('req-1', 409);
})->throws(\PHPUnit\Framework\AssertionFailedError::class);

it('resolves through the facade and service provider', function () {
    $app = new \Illuminate\Foundation\Application(pluginPath());
    $app['config'] = new \Illuminate\Config\Repository(['lan' => ['service_id' => 'from-config']]);
    $app->register(\Protendai\Lan\LanServiceProvider::class);

    expect($app->make(Lan::class)->config()['serviceId'])->toBe('from-config')
        ->and($app->make(Lan::class)->config()['port'])->toBe(53530);
});
