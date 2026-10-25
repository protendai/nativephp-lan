<?php

/*
 * Source-level checks for the audit fixes (native code is compiled and
 * device-tested separately; these guard against regressions).
 */

it('passes PHP status codes through to the sender', function () {
    expect(kotlinSources())->toContain('if (status in 400..599) status else 500')
        ->toContain('sessionId is required with status 200')
        ->and(swiftSources())->toContain('(400...599).contains(status) ? status : 500')
        ->toContain('sessionId is required with status 200');
});

it('reports the remote IP with every send request on both platforms', function () {
    expect(kotlinSources())->toContain('.put("remoteIp", remoteIp)')
        ->toContain('JSONObject(sender.toString()).put("ip", remoteIp)')
        ->and(swiftSources())->toContain('"remoteIp": remoteIp')
        ->toContain('senderOut["ip"] = remoteIp');
});

it('dispatches SessionCancelled(timeout) when PHP does not answer', function () {
    expect(kotlinSources())->toContain('.put("reason", "timeout")')
        ->and(swiftSources())->toContain('"reason": "timeout"');
});

it('never blocks an iOS queue while PHP decides', function () {
    $server = file_get_contents(pluginPath('resources/ios/Sources/LanHttpServer.swift'));
    $manager = file_get_contents(pluginPath('resources/ios/Sources/LanManager.swift'));

    expect($manager)->not->toContain('DispatchSemaphore')
        ->and(substr_count($server, 'DispatchSemaphore'))->toBe(1) // listener start only
        ->and($server)->toContain('maxHeaderBytes')
        ->toContain('maxJsonBytes')
        ->toContain('idleTimeout')
        ->toContain('maxConnections')
        ->toContain('try upload.handle.write(contentsOf: slice)');
});

it('enforces limits and one-shot tokens on both platforms', function () {
    foreach ([kotlinSources(), swiftSources()] as $source) {
        expect($source)
            ->toContain('411')   // Content-Length required
            ->toContain('413')   // larger than declared / too large
            ->toContain('501')   // chunked bodies rejected
            ->toContain('507')   // not enough storage
            ->toContain('Token already used')
            ->toContain('Larger than declared');
    }
});

it('only honours cancels from the session address', function () {
    expect(kotlinSources())->toContain('if (session.senderIp != remoteIp) return')
        ->toContain('it.senderFingerprint == fingerprint && it.remoteIp == remoteIp')
        ->and(swiftSources())->toContain('sessions[sessionId]?.senderIp == remoteIp')
        ->toContain('$0.senderFingerprint == fingerprint && $0.remoteIp == remoteIp');
});

it('locks out IPs that guess PINs', function () {
    expect(kotlinSources())->toContain('class PinGuard')->toContain('Retry-After')
        ->and(swiftSources())->toContain('struct PinGuard')->toContain('Retry-After');
});

it('caps probe responses', function () {
    expect(kotlinSources())->toContain('MAX_PROBE_BYTES')
        ->and(swiftSources())->toContain('maxProbeBytes');
});

it('opens files inside a try/catch on the UI thread and holds the activity weakly', function () {
    expect(kotlinSources())->toContain("activity.runOnUiThread {\n                try {")
        ->toContain('WeakReference<FragmentActivity>');
});

it('decodes query strings with "=" and "+" in values on iOS', function () {
    expect(swiftSources())->toContain('split(separator: "=", maxSplits: 1')
        ->toContain('replacingOccurrences(of: "+", with: " ")');
});
